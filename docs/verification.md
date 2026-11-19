# Assessment verification — 19 November 2026

Reviewed all five pages of the source brief. The table uses the Phase 1 IDs. **Complete** means the local requirement has observed evidence. **Incomplete** identifies an external acceptance condition even when the source implementation exists. [Human handoff and cloud runbook](HUMAN_HANDOFF.md).

| Requirement | Implementation | Verification | Status |
|---|---|---|---|
| A1 — API | cmd/service, Prometheus Go client | Tests asserted exact greeting, version, JSON types, 404/405, Allow, 503 and parsed request/error counters and histogram sample counts. The live Compose service responded to requests. | Complete |
| A2 — configuration, logs, shutdown | Environment parser, structured stdout, readiness and HTTP shutdown | Ran a container on port 9000 with custom environment/debug level. Its JSON logs identified the environment and responses. SIGTERM changed health from 200 to 503 and process exited 0. A keep-alive HTTP request held open beyond the two-second drain completed with 200 after SIGTERM. | Complete |
| A3 — unit tests | cmd/service/main_test.go | Go tests passed on Windows and Linux. Linux go vet and the race detector passed. Statement coverage 59.1%; process-level checks are additional. | Complete |
| A4 — image | Dockerfile, .dockerignore | Built digest-pinned multi-stage image; observed process UID 65532 and configured user 65532:65532, OCI labels, functional shell-free health probe. Docker-reported amd64 size 5,081,380 bytes. Hadolint passed. Trivy 0.69.3 reported zero CRITICAL vulnerabilities in inspected Debian packages and Go binary at scan time. | Complete |
| A5 — Compose | docker-compose.yml | Started app on 127.0.0.1:8080; Docker reported healthy, restart unless-stopped, memory 100663296 bytes, NanoCpus 500000000. | Complete |
| C1 — PR code quality | .github/workflows/quality.yml | Workflow syntax linted; local Go checks and coverage passed. Hosted PR run and coverage artifact require candidate repository activity. | Incomplete |
| C2 — PR lint and security | Quality workflow | Hadolint, ShellCheck and Trivy ran locally. Scan command sets --exit-code 1 for CRITICAL. A hosted blocking run was not exercised. | Incomplete |
| C3 — multi-architecture publish, tags and cache | .github/workflows/release.yml | Exported a real Linux amd64/arm64 OCI index locally; build output showed cached layers. ECR tags, GitHub cache and remote digest equality await a live release. | Incomplete |
| C4 — EC2 deployment and auto-rollback | scripts/deploy.sh, Terraform SSM document | Offline script test exercised initial install, upgrade, failed pull preserving incumbent, and failed health restoring previous image while returning failure. Docker/ECR/HTTP were stubbed in this test. EC2 end-to-end evidence is outstanding. | Incomplete |
| C5 — credentials and configuration | OIDC trust, IAM, release workflow and human runbook | Reviewed branch-bound trust, short-lived identity, documented variables and local ignored credential files. Role assumption in target account outstanding. | Incomplete |
| I1 — VPC, security group, IAM | infra/main.tf | Provider validation and mocked staging/production plans passed. Public CIDR rejection passed. Live AWS effective policies and ingress outstanding. | Incomplete |
| I2 — fresh instance, logs, retention | EC2 bootstrap, awslogs driver, CloudWatch log group | Terraform mock test asserted 14-day retention. Fresh boot and CloudWatch ingestion require real AWS. | Incomplete |
| I3 — remote state, locking and environment reuse | Two S3 backends with locking and encryption, separate keys, environment variables | Both roots validated with provider 6.73.0; three offline Terraform tests passed across staging/production and invalid ingress. Remote lock contention outstanding. | Incomplete |
| I4 — cloud evidence and destruction | Human runbook | No AWS resources were created. Real clean plan, apply and teardown evidence outstanding. | Incomplete |
| K1 — deployment and resources | k8s/workload.yml | Applied manifests to kind v1.34.0. Two ready pods, rolling updates, probes, requests/limits. Live CPU/memory collected for both pods. | Complete |
| K2 — access, configuration, secrets, security | Service, ConfigMap, Kustomize-generated Secret, pod/container security context | Cluster accepted generated objects and served traffic through the ClusterIP. The documented port-forward returned version 1.0.0 and the container runtime reported a read-only root. Offline pull-secret input contained an empty auth map and preloaded images were used. Private ECR authentication needs the target account. | Complete locally |
| K3 — HPA, rollout, rollback | CPU HPA and rolling Deployment | CPU HPA showed 2% / 65%, two replicas. 54 observed client responses, both versions, zero failures across update and undo. [Output and sample counts](evidence/kubernetes.md). | Complete |
| K4 — EKS design | README Kubernetes section | Reviewed ingress/TLS, secrets, node capacity/autoscaling, workload identity, image pulls and failure domains. | Complete |
| O1 — metrics and retention | Compose, Prometheus config, exporters | All three live targets returned up=1. App counts, Linux VM hardware metrics and per-container measurements were queryable. Verified host network interfaces from PID 1 after correcting exporter namespace. Prometheus retention set to 7 days. | Complete |
| O2 — logs | Alloy Docker discovery, JSON stage, Loki compactor | A generated /proof-missing request was retrieved from Loki using app, WARN and parsed path; its JSON recorded 404 and route unmatched. Retention is configured at 168 h. No seven-day expiration wait was performed. | Complete |
| O3 — provisioned dashboards | Two provisioned data sources, three JSON dashboards | Started against fresh Grafana storage. Headless browser rendered every expected panel with no “No data” panels, including application logs. Container panel showed utilization relative to finite limits. | Complete |
| O4 — four alerts | observability/prometheus/alerts.yml and tests.yml | promtool checked config and four rules. Deterministic fixtures passed for pending, firing and cleared states; thresholds and durations are explained in README. | Complete |
| O5 — monitoring security | Pinned images, environment credential, internal network and loopback bindings | Inspected service ports and verified internal network flag. Mounts, required privileges, whole-engine log visibility and socket access are documented. | Complete |
| O6 — investigation evidence | README and docs/evidence/*.png | Captured three real Grafana dashboards. Reproduced a 4xx burst and retrieved a matching WARN entry. | Complete |
| S1 — Linux health collection | system_health.sh | Exercised real /proc, df, ps and JSON output under Linux. Scheduled capture returned five process entries. | Complete |
| S2 — CLI and exit codes | Health thresholds, strict comparisons, highest-severity selection | Exercised healthy/warning/critical exits 0/1/2, warning stream, JSON parsing, help and invalid input. | Complete |
| S3 — rotation, lint, schedule | Log locking and rotation, scripts/assessment-health.cron | Rotation created a nonempty backup. ShellCheck passed. Installed the shipped five-minute cron entry in a disposable Debian container; cron wrote a valid entry at 17:05:02 UTC. Production-host installation is user-owned. | Complete |
| D1 — setup | README and cloud handoff | Local app, observability and Kubernetes run paths exercised. AWS procedure documented; live AWS rehearsal outstanding under I1–I4. | Complete as documentation |
| D2 — architecture, release, security | README diagram and decisions | Reviewed paths from CI to EC2, kind and observability; includes rollback, logging labels, IAM and network trade-offs. | Complete |
| D3 — costs, improvements, AI | README final sections | Includes dated assumed us-east-1 cost, operational improvements and AI assistance note. Cost is an estimate, not an observed bill. | Complete |
| G1 — Git history, public repo, deadline | Candidate-owned | No Git operations performed. Public URL, repository practices and submission timing remain with the candidate. | Incomplete |

## Project layout

```text
cmd/service/                         Go service and endpoint/configuration tests
Dockerfile, .dockerignore             Reproducible runtime image
docker-compose.yml, .env.example      App and six local monitoring services
go.mod, go.sum, VERSION               Dependencies and release base version
.github/workflows/                    PR quality and main release workflows
infra/bootstrap/                      Shared immutable ECR repository
infra/main.tf, bootstrap.sh.tftpl      Per-environment EC2, IAM, SSM and logs
infra/tests/                          Offline Terraform plan assertions
k8s/                                 Service, Deployment, HPA, config and secret generation
observability/                       Alloy, Loki and host exporter startup
  prometheus/                        Scrapes, alert rules and fixtures
  grafana/                           Data sources, dashboard provisioning and JSON
system_health.sh                     Linux health collection and rotation
scripts/                             Deployment, cron entry and shell tests
docs/evidence/                       Dashboard PNGs and kind rollout output
docs/                                Verification and outstanding human steps
README.md                            Reviewer setup, architecture and decisions
```

## Reproducing the offline infrastructure checks

```bash
terraform -chdir=infra init -backend=false
terraform -chdir=infra validate
terraform -chdir=infra test
terraform -chdir=infra/bootstrap init -backend=false
terraform -chdir=infra/bootstrap validate
docker run --rm -v "$PWD/scripts:/src/scripts:ro" debian:bookworm-slim bash -ec \
  'apt-get update -qq; apt-get install -y -qq jq >/dev/null; bash /src/scripts/test-release.sh'
```

The real AWS backend requires a separate init with the handoff inputs. No cloud credentials are needed for these offline checks.
