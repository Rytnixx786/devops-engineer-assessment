package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var version = "1.0.0"

type config struct {
	port, environment string
	level             slog.Level
}

func readConfig() (config, error) {
	c := config{port: os.Getenv("PORT"), environment: os.Getenv("APP_ENV")}
	if c.port == "" {
		c.port = "8080"
	}
	if c.environment == "" {
		c.environment = "local"
	}
	n, err := strconv.Atoi(c.port)
	if err != nil || n < 1 || n > 65535 {
		return c, fmt.Errorf("PORT must be between 1 and 65535")
	}
	if level := os.Getenv("LOG_LEVEL"); level != "" {
		if err = c.level.UnmarshalText([]byte(level)); err != nil {
			return c, err
		}
	}
	return c, nil
}

type service struct {
	draining atomic.Bool
	handler  http.Handler
}

func jsonReply(w http.ResponseWriter, status int, body map[string]string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

type response struct {
	http.ResponseWriter
	status int
}

func (w *response) WriteHeader(n int) { w.status = n; w.ResponseWriter.WriteHeader(n) }
func newService(log *slog.Logger) *service {
	s := new(service)
	reg := prometheus.NewRegistry()
	requests := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "app_requests_total", Help: "HTTP responses by route and status class."}, []string{"route", "class"})
	errors := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "app_errors_total", Help: "Unsuccessful HTTP responses."}, []string{"class"})
	latency := prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: "app_request_duration_seconds", Help: "HTTP response latency.", Buckets: prometheus.DefBuckets}, []string{"route"})
	reg.MustRegister(requests, errors, latency)
	for _, class := range []string{"4xx", "5xx"} {
		errors.WithLabelValues(class)
	}
	metrics := promhttp.HandlerFor(reg, promhttp.HandlerOpts{})
	s.handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		out := &response{w, 200}
		route := r.URL.Path
		switch route {
		case "/", "/health", "/metrics":
		default:
			route = "unmatched"
		}
		switch {
		case route == "unmatched":
			jsonReply(out, 404, map[string]string{"error": "route not found"})
		case r.Method != http.MethodGet:
			out.Header().Set("Allow", "GET")
			jsonReply(out, 405, map[string]string{"error": "method not allowed"})
		case route == "/metrics":
			metrics.ServeHTTP(out, r)
		case route == "/health" && s.draining.Load():
			jsonReply(out, 503, map[string]string{"status": "draining"})
		case route == "/health":
			jsonReply(out, 200, map[string]string{"status": "ok"})
		default:
			jsonReply(out, 200, map[string]string{"message": "Hello from DevOps Task!", "status": "running", "version": version})
		}
		class := strconv.Itoa(out.status/100) + "xx"
		requests.WithLabelValues(route, class).Inc()
		if out.status >= 400 {
			errors.WithLabelValues(class).Inc()
		}
		elapsed := time.Since(start).Seconds()
		latency.WithLabelValues(route).Observe(elapsed)
		level := slog.LevelInfo
		if out.status >= 500 {
			level = slog.LevelError
		} else if out.status >= 400 {
			level = slog.LevelWarn
		}
		log.Log(r.Context(), level, "request", "method", r.Method, "path", strings.ToValidUTF8(r.URL.EscapedPath(), "?"), "route", route, "status", out.status, "duration_seconds", elapsed)
	})
	return s
}
func run() error {
	c, err := readConfig()
	if err != nil {
		return err
	}
	if len(os.Args) == 2 && os.Args[1] == "healthcheck" {
		client := http.Client{Timeout: 2 * time.Second}
		res, err := client.Get("http://127.0.0.1:" + c.port + "/health")
		if err != nil {
			return err
		}
		defer res.Body.Close()
		if res.StatusCode != 200 {
			return fmt.Errorf("health returned %d", res.StatusCode)
		}
		return nil
	}
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: c.level})).With("environment", c.environment, "version", version)
	s := newService(log)
	server := &http.Server{Handler: s.handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	ln, err := net.Listen("tcp", ":"+c.port)
	if err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- server.Serve(ln) }()
	log.Info("listening", "port", c.port)
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
	}
	s.draining.Store(true)
	log.Info("draining")
	time.Sleep(2 * time.Second)
	deadline, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return server.Shutdown(deadline)
}
func main() {
	if err := run(); err != nil {
		slog.New(slog.NewJSONHandler(os.Stdout, nil)).Error("service stopped", "error", err)
		os.Exit(1)
	}
}
