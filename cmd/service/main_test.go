package main

import (
	"bytes"
	"encoding/json"
	"github.com/prometheus/common/expfmt"
	"github.com/prometheus/common/model"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEndpoints(t *testing.T) {
	var logs bytes.Buffer
	s := newService(slog.New(slog.NewJSONHandler(&logs, nil)))
	for _, tc := range []struct {
		method, path string
		code         int
		keys         map[string]string
	}{
		{"GET", "/", 200, map[string]string{"message": "Hello from DevOps Task!", "status": "running", "version": version}},
		{"GET", "/health", 200, map[string]string{"status": "ok"}},
		{"POST", "/", 405, map[string]string{"error": "method not allowed"}},
		{"GET", "/missing?private=secret", 404, map[string]string{"error": "route not found"}},
	} {
		w := httptest.NewRecorder()
		s.handler.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, nil))
		if w.Code != tc.code || w.Header().Get("Content-Type") != "application/json" {
			t.Fatal(w.Result())
		}
		var body map[string]string
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || len(body) != len(tc.keys) {
			t.Fatal(w.Body.String())
		}
		for k, v := range tc.keys {
			if body[k] != v {
				t.Fatal(body)
			}
		}
		if tc.code == 405 && w.Header().Get("Allow") != "GET" {
			t.Fatal("missing Allow")
		}
	}
	s.draining.Store(true)
	w := httptest.NewRecorder()
	s.handler.ServeHTTP(w, httptest.NewRequest("GET", "/health", nil))
	if w.Code != 503 {
		t.Fatal(w.Code)
	}
	w = httptest.NewRecorder()
	s.handler.ServeHTTP(w, httptest.NewRequest("GET", "/metrics", nil))
	if w.Code != 200 || !strings.Contains(w.Header().Get("Content-Type"), "text/plain") {
		t.Fatal(w.Result())
	}
	parser := expfmt.NewTextParser(model.LegacyValidation)
	families, err := parser.TextToMetricFamilies(w.Body)
	if err != nil {
		t.Fatal(err)
	}
	total := 0.0
	for _, m := range families["app_requests_total"].GetMetric() {
		total += m.GetCounter().GetValue()
	}
	if total != 5 {
		t.Fatal(total)
	}
	total = 0
	for _, m := range families["app_errors_total"].GetMetric() {
		total += m.GetCounter().GetValue()
	}
	if total != 3 {
		t.Fatal(total)
	}
	var count uint64
	for _, m := range families["app_request_duration_seconds"].GetMetric() {
		count += m.GetHistogram().GetSampleCount()
	}
	if count != 5 {
		t.Fatal(count)
	}
	if strings.Contains(logs.String(), "private=") {
		t.Fatal("query leaked")
	}
	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		if !json.Valid([]byte(line)) {
			t.Fatal(line)
		}
	}
}
func TestConfig(t *testing.T) {
	t.Setenv("PORT", "9090")
	t.Setenv("APP_ENV", "test")
	t.Setenv("LOG_LEVEL", "debug")
	c, e := readConfig()
	if e != nil || c.port != "9090" || c.environment != "test" || c.level != slog.LevelDebug {
		t.Fatal(c, e)
	}
	t.Setenv("PORT", "65536")
	if _, e := readConfig(); e == nil {
		t.Fatal("invalid port accepted")
	}
	t.Setenv("PORT", "")
	t.Setenv("LOG_LEVEL", "invalid")
	if _, e := readConfig(); e == nil {
		t.Fatal("invalid level accepted")
	}
}
