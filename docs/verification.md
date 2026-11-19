# Verification & CI Evidence — 19 November 2026

End-to-end verification summary against all seven steps of the DevOps Engineer assessment brief.

| Area | Implementation | Observed Evidence | Status |
|---|---|---|---|
| **Step 1 — Service & Tests** | `cmd/service/main.go`, `cmd/service/main_test.go` | Verified `/`, `/health` (200 serving, 503 during 2s drain), `/metrics` (Prometheus request count, error count, latency histogram), 404/405 handling, env config, structured JSON logs, SIGTERM graceful drain & shutdown, `gofmt`, `go vet`, and `go test -race` (59.1% statement coverage + uploaded CI artifact). | Verified (Local + CI) |
| **Step 1 — Container & Compose** | `Dockerfile`, `.dockerignore`, `docker-compose.yml` | Multi-stage digest-pinned distroless (`nonroot` UID/GID `65532`) image with compiled `/service healthcheck`, OCI labels, **5,081,380 bytes** (`docker image inspect`), Hadolint clean, Trivy 0 CRITICAL, Compose on `127.0.0.1:8080` with health check, `unless-stopped`, and CPU/memory limits. | Verified (Local + CI) |
| **Step 2 — PR Quality Gates** | `.github/workflows/quality.yml` | Hosted PRs [#1](https://github.com/Rytnixx786/devops-engineer-assessment/pull/1) ([run 44588673011](https://github.com/Rytnixx786/devops-engineer-assessment/actions/runs/44588673011)), [#2](https://github.com/Rytnixx786/devops-engineer-assessment/pull/2), and [#3](https://github.com/Rytnixx786/devops-engineer-assessment/pull/3) ([run 44589931258](https://github.com/Rytnixx786/devops-engineer-assessment/actions/runs/44589931258)) passed with zero warnings: Go lint/vet/test/coverage, ShellCheck, `test-health.sh`, `test-release.sh`, Hadolint, Terraform `fmt`/`validate`/`test`, `promtool test rules`, and Trivy CRITICAL gate. `main` branch protection requires `checks` (`strict: true`). | Verified (Live GitHub Actions) |
| **Step 2 — Multi-Arch Release & Caching** | `.github/workflows/release.yml` | Two consecutive green `Release` runs on `main` published real `linux/amd64` + `linux/arm64` OCI indexes to `ghcr.io/rytnixx786/devops-engineer-assessment` tagged with git SHA + semantic version: [run 44589077576](https://github.com/Rytnixx786/devops-engineer-assessment/actions/runs/44589077576) (`1.0.0-build.3`, cold publish 1m31s) and [run 44590280087](https://github.com/Rytnixx786/devops-engineer-assessment/actions/runs/44590280087) (`1.0.1-build.4` / `434bfeef`, digest `sha256:f8ea82fb...`, warm `type=gha` cache hits `#12–#15 CACHED`, 1m05s). | Verified (Live GHCR + CI) |
| **Step 2 — EC2 SSM Deploy & Rollback** | `scripts/deploy.sh`, `scripts/test-release.sh`, `deploy-ec2` job | `scripts/test-release.sh` runs in GitHub Actions `quality.yml` inside a fresh Linux container and verifies initial install, upgrade, failed pull preservation, and failed `/health` automatic rollback while returning exit 1. `deploy-ec2` uses GitHub OIDC (`id-token: write`) and activates automatically when AWS repository variables are set. | Verified in CI (Live AWS apply skipped — no billing-enabled account) |
| **Step 3 — Terraform IaC** | `infra/bootstrap/main.tf`, `infra/main.tf`, `infra/bootstrap.sh.tftpl`, `infra/tests/environments.tftest.hcl` | `terraform fmt -check`, `terraform validate`, and `terraform test` (3/3 assertions: `staging`, `production`, and `0.0.0.0/0` ingress rejection; 14-day CloudWatch retention; IMDSv2; least-privilege IAM; S3 `use_lockfile = true`) run and pass on every PR and `main` push in GitHub Actions. | Verified in CI (Live AWS apply skipped — no billing-enabled account) |
| **Step 4 — Kubernetes (`kind`)** | `k8s/workload.yml`, `k8s/kustomization.yaml`, `docs/evidence/kubernetes.md` | Deployed on `kind` v1.34.0 with 2 replicas, rolling update (`maxUnavailable: 0, maxSurge: 1`), liveness/readiness probes, CPU/memory requests & limits, ConfigMap + Kustomize-generated Secret, non-root `readOnlyRootFilesystem`, and CPU HPA (`2% / 65%`). Zero-downtime update (`1.0.0` → `1.0.1`) and `kubectl rollout undo`: 54/54 successful client requests, 0 failures. | Verified (Live `kind` Cluster) |
| **Step 5 — Observability Stack** | `docker-compose.yml`, `observability/`, `docs/evidence/*.png` | All 6 components running (Prometheus 7d retention, Grafana provisioned datasources + 3 JSON dashboards, Loki 7d compactor retention, Alloy Docker discovery + low-cardinality JSON parsing, Node Exporter host PID-1 network metrics, cAdvisor container limits). 4 Prometheus alerts verified with `promtool test rules`. Fresh 3-minute dashboards captured including visible `WARN` (`404`) logs during error burst. | Verified (Live Stack + `promtool` in CI) |
| **Step 6 — Linux Automation** | `system_health.sh`, `scripts/assessment-health.cron`, `scripts/test-health.sh` | Verified CPU/memory/disk/load/top-5-process collection, timestamped `health_log.txt` + `--json`, configurable thresholds, `[WARNING]` messages, exit codes `0`/`1`/`2`, `flock`-locked log rotation, `--help`, ShellCheck clean, and 5-minute cron execution in Debian Linux. | Verified (Linux + CI) |
| **Step 7 — Docs & Git Practices** | `README.md`, merged PRs `#1`–`#3`, branch protection | Self-contained `README.md` covering all 9 required sections (local setup, tests, Terraform, Kubernetes, Mermaid architecture diagram, design decisions, deployment/rollback, security, monthly AWS cost estimate, improvements, and AI disclosure). Atomic commits across feature branches and merged PRs. | Verified |

## Project layout

```text
cmd/service/                         Go service and endpoint/configuration tests
Dockerfile, .dockerignore            Reproducible multi-stage distroless image
docker-compose.yml, .env.example     App and six local monitoring services
go.mod, go.sum, VERSION              Dependencies and semantic release base version
.github/workflows/                   PR quality gates and multi-arch release workflow
infra/bootstrap/                     Shared immutable ECR repository
infra/main.tf, bootstrap.sh.tftpl    Per-environment EC2, IAM/OIDC, SSM and CloudWatch Logs
infra/tests/                         Terraform plan assertions (staging, production, security)
k8s/                                 Service, Deployment, HPA, ConfigMap and Secret generation
observability/                       Alloy, Loki and host exporter startup
  prometheus/                        Scrapes, 4 alert rules and promtool test fixtures
  grafana/                           Provisioned datasources and 3 JSON dashboards
system_health.sh                     Linux health monitoring, thresholds and log rotation
scripts/                             EC2 deploy/rollback script, cron entry and test suites
docs/evidence/                       Grafana dashboard PNGs and Kubernetes rollout output
README.md                            Reviewer setup, architecture and design decisions
```

## Reproducing the CI Terraform & Rollback Checks Locally

```bash
terraform -chdir=infra fmt -check
terraform -chdir=infra init -backend=false
terraform -chdir=infra validate
terraform -chdir=infra test
terraform -chdir=infra/bootstrap fmt -check
terraform -chdir=infra/bootstrap init -backend=false
terraform -chdir=infra/bootstrap validate
docker run --rm -v "$PWD/scripts:/src/scripts:ro" debian:bookworm-slim bash -ec \
  'apt-get update -qq && apt-get install -y -qq jq >/dev/null && bash /src/scripts/test-release.sh'
```
