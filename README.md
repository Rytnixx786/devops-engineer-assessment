# DevOps assessment service

Run a three-endpoint Go service, observe its traffic in Grafana, and deploy two versions to a local Kubernetes cluster. The cloud release targets one EC2 instance using ECR, GitHub OIDC and Systems Manager.

[Actual verification results](docs/verification.md) · [Outstanding human steps and AWS runbook](docs/HUMAN_HANDOFF.md)

## Run locally

Use Docker Engine with Linux containers and Compose v2. On Windows, start Docker Desktop with the WSL2 backend and allow project-directory mounts. Ports 8080 and 3000 must be available. The exporters need a Linux engine with host mounts. On Docker Desktop the host dashboard describes the Docker Linux VM. Alloy discovers **all** containers on this engine; use a dedicated engine for a review session with unrelated sensitive workloads.

1. Copy `.env.example` to `.env` and supply a strong, unique `GRAFANA_ADMIN_PASSWORD`. Grafana initializes its admin credential on first startup against its data volume.
2. From the project root run `docker compose up -d --build` and `docker compose ps`. Wait for app health and at least two 15-second scrapes. Open [the service](http://127.0.0.1:8080/) and [Grafana](http://127.0.0.1:3000/). Sign in, then open Dashboards → Assessment → Application, Host or Containers.
3. Generate requests with the Bash loop below. Rate panels need more than one scrape to show a trend. Use `docker compose down` to stop this project and keep its data volumes.

```bash
for n in $(seq 1 100); do
  curl -fsS http://localhost:8080/ >/dev/null
  if [ "$n" -gt 30 ] && [ "$n" -lt 70 ]; then curl -s -o /dev/null http://localhost:8080/missing; fi
  sleep 1
done
```

| Endpoint | Result |
|---|---|
| GET / | 200 JSON with message "Hello from DevOps Task!", status "running" and the compiled version |
| GET /health | 200 while serving; 503 during the two-second drain window |
| GET /metrics | Prometheus exposition with app_requests_total, app_errors_total and app_request_duration_seconds histogram |

PORT defaults to 8080, LOG_LEVEL to info, APP_ENV to local. Unsupported methods on these routes return 405 and Allow: GET. Unknown routes return 404. Request logs on stdout contain timestamp, severity, route, path without query string, status, method, duration, environment and version. Both requests and metrics collection are concurrent. Each instance owns its counters. There are no business entities, database migrations, application credentials or external dependencies for serving a request.

## Architecture and design decisions

```mermaid
flowchart LR
  commit[Code commit] --> ci[GitHub Actions lint, test and scan]
  ci --> build[Buildx amd64 and arm64]
  build --> registry[ECR immutable release]
  registry --> ec2[Docker on EC2]
  ci -->|main release through SSM| ec2
  ec2 -->|JSON stdout| cw[CloudWatch Logs]
  build -->|local images| kind[kind Deployment]
  kind --> service[ClusterIP and port-forward]
  ms[Metrics Server] --> hpa[CPU HPA]
  hpa --> kind
  app[Compose service] -->|metrics| prom[Prometheus]
  host[Node Exporter] --> prom
  containers[cAdvisor] --> prom
  engine[Docker container logs] --> alloy[Grafana Alloy]
  alloy --> loki[Loki]
  prom --> grafana[Grafana]
  loki --> grafana
```

Go's standard HTTP server and JSON logger handle the API. The Prometheus client owns exposition, histogram buckets and concurrent metric updates. The repository keeps transport, lifecycle, metrics and their endpoint tests in `cmd/service/`.

**Distroless vs Alpine:** The final image uses `gcr.io/distroless/static-debian12:nonroot` pinned by SHA-256 digest rather than Alpine. Because the Go binary is statically linked (`CGO_ENABLED=0`), it needs neither `glibc` nor `musl`, and distroless removes the shell (`sh`), `apk`, and OS utilities — shrinking the attack surface and CVE footprint compared to Alpine. A compiled `/service healthcheck` subcommand lets Docker run native `HEALTHCHECK` probes without adding `curl`, `wget`, or a shell. Both base manifests are digest-pinned. Docker reported **5,081,380 bytes** (~5.08 MB) for the local `linux/amd64` image via `docker image inspect assessment-service:1.0.0 --format '{{.Size}}'` (platform, export format, containerd unpacked snapshot size, and registry compression affect reported figures).

**EC2 vs ECS vs EKS:** EC2 is the assessed cloud deployment target. A single host keeps infrastructure cost and the rollback procedure transparent. ECS would supply a managed container scheduler with built-in ALB draining; EKS would add a managed Kubernetes control plane with higher baseline cost ($73/month control plane alone). Kubernetes is exercised independently on `kind`. The app owns no durable state; operational state lives in Prometheus/Loki/Grafana volumes, S3, CloudWatch and the release registry.

## Observability and incident walkthrough

![Application dashboard with real request rates, latency and logs](docs/evidence/application.png)

![Host CPU, memory, disk and network](docs/evidence/host.png)

![Container CPU, working set and percentage of memory limit](docs/evidence/containers.png)

The Application screenshot includes an intentional burst of requests to a missing route. Select the interval where the 4xx line rises. Open the adjacent logs panel in Explore and query `{service="app",level="WARN"} | json | status = 404 | path = "/missing"`. Check the matching path, status, version and request time. Compare the same interval on Host and Containers. In this demonstration the requests themselves explain the 404s. For a 5xx spike, inspect ERROR logs and release timing, then check CPU and memory pressure before deciding whether to restore a prior release.

Prometheus scrapes the service, Node Exporter and cAdvisor every 15 seconds. Prometheus and Loki retain seven days; Loki uses the TSDB schema and retention-enabled compactor. Grafana provisions both data sources and all three dashboard JSON files at startup. Node Exporter reads network counters from host PID 1 through procfs. The traffic panel filters virtual bridge and veth interfaces to avoid double counting. Host data covers the engine's CPU, memory, mounted filesystems and interfaces. The container panels select this Compose project; percentage-of-limit includes finite positive limits. Alloy keeps container/service identity and bounded app severity as labels. Request paths remain JSON fields searched at query time. This prevents each distinct URL from creating a log stream.

| Alert | Threshold and reason |
|---|---|
| AppDown | One minute of failed app scrapes tolerates a short missed collection and surfaces sustained unavailability. |
| HighServerErrors | 5xx share above 5% over five minutes, at least 20 requests, sustained two minutes. The volume floor reduces noise on an idle service. |
| HostDiskPressure | Above 80% used for ten minutes on writable, capacity-bearing filesystems. Leaves time to reclaim space and filters transient writes. |
| ContainerMemoryPressure | Working set above 90% of a finite limit for five minutes. Sustained growth close to a hard limit can precede an OOM kill. |

## Tests and Linux automation

With Go 1.26.5 run `go vet ./...`, `go test -race -coverprofile=coverage.out ./...`, and `go tool cover -func=coverage.out`. The race detector needs a C compiler on Linux. The PR workflow checks formatting, tests and coverage, Hadolint, ShellCheck, Prometheus rules, the health CLI and a Trivy CRITICAL gate. To run the alert fixtures against the running stack:

```bash
docker compose exec -w /etc/prometheus prometheus promtool test rules tests.yml
```

On Linux install Bash, GNU coreutils, procps, util-linux (flock) and jq. Run `bash system_health.sh --help`, `bash system_health.sh --json`, and `bash scripts/test-health.sh`. CPU is sampled over one second, memory uses MemAvailable, disk includes all filesystem entries reported by df, and top processes are ordered by resident memory. A null disk percentage indicates unavailable capacity. The JSON stdout stream stays parseable when warnings go to stderr. The log always contains timestamped JSON lines.

Defaults are CPU 90%, memory 85%, disk 80% and critical 95%. Strictly exceeding a warning threshold yields exit 1; exceeding the common critical threshold yields 2. Healthy yields 0. Invalid inputs or collection errors yield 2. Example: `bash system_health.sh --cpu 80 --mem 85 --disk 75 --critical 95 --json`. HEALTH_LOG defaults to health_log.txt; HEALTH_LOG_MAX_BYTES defaults to 1048576. Writes and rotation use a lock and retain one backup. To install the five-minute job on a chosen host:

```bash
sudo install -d -m 0750 /var/log/assessment
sudo install -m 0755 system_health.sh /usr/local/sbin/system_health.sh
sudo install -m 0644 scripts/assessment-health.cron /etc/cron.d/assessment-health
```

## Kubernetes

Prerequisites: kind v0.30.0, kubectl, Docker, two local images, and Metrics Server v0.8.0. Run these Bash commands from the root on a fresh local setup. The empty local registry config is for preloaded images; for private ECR use a short-lived registry credential in this ignored file and refresh it when needed.

```bash
kind create cluster --name assessment-local --image kindest/node:v1.34.0
docker build -t assessment-service:1.0.0 .
docker build --build-arg VERSION=1.0.1 -t assessment-service:1.0.1 .
kind load docker-image assessment-service:1.0.0 assessment-service:1.0.1 --name assessment-local
# For preloaded images only; preserve any existing private registry config.
test -f k8s/registry.json || printf '{"auths":{}}\n' > k8s/registry.json
kubectl --context kind-assessment-local apply -k k8s/
kubectl --context kind-assessment-local apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.0/components.yaml
kubectl --context kind-assessment-local -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl --context kind-assessment-local rollout status deployment/app
kubectl --context kind-assessment-local get hpa
kubectl --context kind-assessment-local port-forward service/app 18080:8080
```

The kubelet TLS exception addresses kind's development certificates. Access the app at http://127.0.0.1:18080. For an update test start an in-cluster observer in a second terminal. Use the same explicit context or an isolated KUBECONFIG. Run the update once the observer is Ready, then undo it and inspect the samples:

```bash
kubectl --context kind-assessment-local run observer --image=busybox:1.37.0 --restart=Never --command -- sh -c \
 'while true; do wget -q -T 2 -O - http://app:8080/ || echo FAILED; sleep 0.2; done'
kubectl --context kind-assessment-local wait --for=condition=Ready pod/observer
kubectl --context kind-assessment-local set image deployment/app app=assessment-service:1.0.1
kubectl --context kind-assessment-local rollout status deployment/app
kubectl --context kind-assessment-local rollout undo deployment/app
kubectl --context kind-assessment-local rollout status deployment/app
kubectl --context kind-assessment-local logs observer
kubectl --context kind-assessment-local delete pod observer
```

Observed rollout and rollback output (54 sampled responses across both versions, 0 failures; see [full recorded rollout results](docs/evidence/kubernetes.md)):

```console
$ kubectl set image deployment/app app=assessment-service:1.0.1
deployment.apps/app image updated
$ kubectl rollout status deployment/app
deployment "app" successfully rolled out
$ kubectl rollout undo deployment/app
deployment.apps/app rolled back
$ kubectl rollout status deployment/app
deployment "app" successfully rolled out
```

```text
NAME   REFERENCE        TARGETS       MINPODS   MAXPODS   REPLICAS
app    Deployment/app   cpu: 2%/65%   2         5         2
```

For production EKS, use an ingress controller with TLS and a managed load balancer, signed kubelet certificates, external secret delivery, EKS Pod Identity or IAM roles for service accounts, and node autoscaling with capacity for surge replicas. Spread replicas across failure domains. Use managed worker image-pull identity for ECR. The development HPA uses CPU requests as its utilization baseline.

## Infrastructure as Code (Terraform) & CI/CD configuration

Terraform is split into two roots using S3 remote state with native state locking (`use_lockfile = true`) and encryption (`encrypt = true`):
- `infra/bootstrap/`: shared immutable ECR repository (`scan_on_push = true`).
- `infra/`: per-environment (`staging` or `production`) EC2 instance, restricted security group, least-privilege IAM instance profile + GitHub OIDC release role, CloudWatch Log Group (14-day retention), and custom SSM deploy document.

Offline validation and mocked multi-environment plan assertions (no AWS credentials required):

```bash
terraform -chdir=infra init -backend=false
terraform -chdir=infra validate
terraform -chdir=infra test
terraform -chdir=infra/bootstrap init -backend=false
terraform -chdir=infra/bootstrap validate
```

Live AWS provisioning (`staging` or `production`) with an authenticated short-lived AWS profile (`AWS_PROFILE`, `AWS_REGION`, `STATE_BUCKET`, and `TF_VAR_*` inputs documented in [docs/HUMAN_HANDOFF.md](docs/HUMAN_HANDOFF.md)):

```bash
# 1. Shared immutable ECR repository
terraform -chdir=infra/bootstrap init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" -backend-config="region=$AWS_REGION" \
  -backend-config="key=assessment/shared/ecr.tfstate"
terraform -chdir=infra/bootstrap plan -out=registry.tfplan
terraform -chdir=infra/bootstrap apply registry.tfplan

# 2. Per-environment EC2 target (use separate state keys for staging and production)
terraform -chdir=infra init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" -backend-config="region=$AWS_REGION" \
  -backend-config="key=assessment/$TF_VAR_environment/terraform.tfstate"
terraform -chdir=infra plan -out=environment.tfplan
terraform -chdir=infra apply environment.tfplan

# 3. Teardown after testing (empty ECR images before destroying infra/bootstrap)
terraform -chdir=infra destroy
terraform -chdir=infra/bootstrap destroy
```

### GitHub Actions variables & secrets

No static AWS access keys are stored in GitHub Secrets. Authentication uses short-lived GitHub OIDC tokens (`id-token: write`) scoped to `refs/heads/main`. Configure these **repository variables** (*Settings → Secrets and variables → Actions → Variables*) from Terraform outputs:

| Name | Type | Purpose |
|---|---|---|
| `AWS_REGION` | Repository variable | Target AWS region (e.g. `us-east-1`) |
| `ECR_REPOSITORY` | Repository variable | ECR repository name (without registry hostname) |
| `AWS_RELEASE_ROLE_ARN` | Repository variable | IAM role ARN from `terraform -chdir=infra output -raw role_arn` |
| `INSTANCE_ID` | Repository variable | EC2 instance ID from `terraform -chdir=infra output -raw instance_id` |
| `SSM_DOCUMENT` | Repository variable | SSM document name from `terraform -chdir=infra output -raw ssm_document` |

## Deployment and rollback strategy

The PR workflow (`Quality`) runs with read-only repository permissions (`contents: read`). On `main`, quality checks run before Buildx publishes a multi-architecture (`linux/amd64`, `linux/arm64`) image with GitHub Actions layer caching (`type=gha`). Every release is tagged with both the full git commit SHA and a semantic prerelease (`<VERSION>-build.<run_number>`) — never relying on `latest`. Re-running the same completed publish verifies the immutable tags before deployment.

The release role assumes short-lived credentials through GitHub OIDC. It sends a custom SSM document to a specific instance. Bootstrap and deployment share one host script (`scripts/deploy.sh`). The script acquires an exclusive `flock`, pulls the candidate image before stopping the incumbent container, verifies `/health` and release identity, and automatically restores the previous immutable image reference on failure while still returning a nonzero exit code to fail the pipeline. Single-host replacement can briefly interrupt in-flight requests; Kubernetes avoids this with `maxUnavailable: 0, maxSurge: 1`.

## Security considerations

**Image scanning & supply-chain hygiene:** Every PR and release runs `hadolint` on the `Dockerfile`, `shellcheck` on all shell scripts, and Trivy (`aquasec/trivy:0.69.3`) against the built image, failing the pipeline on any `CRITICAL` vulnerability (`--severity CRITICAL --exit-code 1`). ECR repositories enforce immutable tags and `scan_on_push = true`, and all container base/monitoring images are pinned to explicit versions or SHA-256 digests.

**Runtime, IAM & network isolation:** The app runs as UID/GID `65532`, with a read-only root filesystem and dropped capabilities locally and on Kubernetes. Its runtime needs no inbound administrative port. The EC2 security group permits only port `8080` from a restricted IPv4 CIDR, enforces IMDSv2 (`http_tokens = "required"`), and leaves port 22 closed. The instance has the SSM managed core policy, repository-scoped ECR pull access, and CloudWatch log writes scoped to its log group. Registry authentication requires the AWS wildcard-resource `ecr:GetAuthorizationToken` action. S3 state uses native locking and encryption. AWS account credentials, Terraform state, `k8s/registry.json`, and local `.env` files are gitignored and never committed.

Only app 8080 and Grafana 3000 bind host loopback. The collectors share an internal Docker network. Node Exporter receives read-only host root/proc/sys views and the host PID namespace for host measurements. cAdvisor uses privileged runtime access and read-only rootfs, /sys, /var/run, Docker storage and /dev/disk for cgroups, runtime discovery and disk metadata. Alloy reads the Docker socket for discovery and log access. A read-only bind mount of a socket still permits powerful API calls. Run the stack on a trusted assessment engine. The host-root bind is static, so restart the exporter to include newly mounted filesystems where mount propagation is unavailable.

## Estimated monthly AWS cost

Illustrative budget for us-east-1, 730 hours, one on-demand Linux t3.micro, 8 GiB gp3, one public IPv4, 1 GB of CloudWatch log ingestion, minimal ECR/state storage and light traffic: **about USD 12–14/month** before tax, credits or free-tier discounts. Assumed rates give EC2 about $7.59, IPv4 $3.65, gp3 $0.64, log ingestion about $0.50 and small additional storage/request charges. Estimate prepared 19 November 2026. Traffic, CPU credit usage, retention and region affect the bill. The local monitoring stack and kind cluster use the reviewer's machine. [EC2 pricing](https://aws.amazon.com/ec2/pricing/on-demand/) · [VPC pricing](https://aws.amazon.com/vpc/pricing/) · [EBS pricing](https://aws.amazon.com/ebs/pricing/) · [CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/).

## What I would improve with more time

A second EC2 deployment target behind a load balancer would reduce replacement downtime. A private, TLS-terminated service endpoint would improve the exposure model. Image signing and a verified SBOM would tie published artifacts to a trusted build. Operational alert routing would turn the existing alert rules into on-call notifications.

## AI assistance

AI coding assistants (OpenAI Codex and Antigravity / Gemini) assisted with assessment analysis, service and infrastructure implementation, CI/CD workflow setup, documentation, and verification. Every component, design trade-off, and verification result was reviewed and is owned by the candidate.
