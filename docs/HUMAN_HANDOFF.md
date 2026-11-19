# Remaining work that needs a human or an external account

Scope agreed on 19 November 2026: local implementation and verification. No Git commands, publication, AWS API calls, cloud deployment, or live cloud teardown were performed by the implementer. The submission deadline runs from receipt of the assessment; confirm the original receipt timestamp.

| Requirement | Existing implementation | Outstanding evidence and owner |
|---|---|---|
| G1 — submission and Git practices (PDF pp. 1, 5) | Source, manifests, runbooks, screenshots, workflows | Candidate owns repository history, branches, commits, PRs, public visibility and submission link. Review files before publication. Reviewers will see only history actually created. |
| C1–C2 — hosted PR checks (pp. 1–2) | [Quality workflow](../.github/workflows/quality.yml), local checks in [verification](verification.md) | Candidate opens a real PR. Save the hosted run URL, coverage summary, scan exit status and lint results. Make the quality check required on main. |
| C3 — publishing and build cache (p. 2) | [Release workflow](../.github/workflows/release.yml), local amd64/arm64 OCI build | Candidate sets the repository variables below. After a main push, capture the ECR manifest platforms, matching SHA/version digests, cache behavior on a later build, and run URL. |
| C4–C5 — deployment and rollback (p. 2) | [SSM deployment script](../scripts/deploy.sh), branch-restricted OIDC trust and custom SSM document | Target the assessment account only. Capture healthy release, failed staging candidate, restored prior version and failed command status. Redact credentials. |
| I1–I4 — AWS (p. 2) | [Environment infrastructure](../infra/main.tf), [registry bootstrap](../infra/bootstrap/main.tf) | Candidate supplies account, region, subnet, restricted reviewer CIDR and state bucket. Capture real plan/apply, second empty plan, state locking, deployed IAM/SG, CloudWatch request and retention, scoped destruction. Offline provider checks are recorded separately. |
| S3 — host scheduling (p. 4) | [Five-minute cron entry](../scripts/assessment-health.cron) | Install on the intended Linux server if operational deployment is wanted. Check timestamps across two timer intervals and host-specific paths/permissions. The real Debian cron daemon fired once in the disposable local test; deployment on your target server remains optional. |
| D3 — ownership (p. 4) | README cost model and AI note | Candidate checks prices for the chosen region, reads the AI disclosure, and ensures they can explain the submission. |

## AWS and GitHub runbook for a later authorized session

Use Bash with Terraform 1.10+, AWS CLI v2, Docker Buildx, a signed-in short-lived AWS profile, and the intended public GitHub repository. Provide the following environment values. The profile identity needs permissions to provision the named AWS resources. GitHub only receives the narrower release role.

| Input | Meaning |
|---|---|
| AWS_PROFILE, AWS_REGION | Your SSO/federated assessment profile and region |
| STATE_BUCKET | Globally unique private assessment state bucket |
| TF_VAR_repository_name | Dedicated immutable ECR repository name |
| TF_VAR_environment | staging or production |
| TF_VAR_subnet_id | Public subnet with internet gateway route so Docker, SSM, ECR and CloudWatch are reachable |
| TF_VAR_reviewer_cidr | Trusted reviewer IPv4 address with /32 or restricted network |
| TF_VAR_github_repo | Exact owner/repository |
| TF_VAR_oidc_provider_arn | Account OIDC provider for token.actions.githubusercontent.com with sts.amazonaws.com audience |
| TF_VAR_initial_tag | Initial ECR tag to bootstrap on new instances; keep fixed across ordinary releases |

1. Confirm the account with `aws sts get-caller-identity`. Create or select a dedicated S3 bucket in the chosen region. Enable versioning, default encryption and Block Public Access. Grant the Terraform operator list access for the relevant prefix and object access to its state and lock files (including deletion of lockfiles). Use a pre-existing account GitHub OIDC provider or create it once in IAM. Never duplicate or destroy a shared provider.
2. Initialize the shared registry root, create ECR, and seed the first real release. Commands assume the variables above are exported. Use separate prefixes for each environment.

```bash
export TF_VAR_region="$AWS_REGION"
terraform -chdir=infra/bootstrap init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" -backend-config="region=$AWS_REGION" \
  -backend-config="key=assessment/shared/ecr.tfstate"
terraform -chdir=infra/bootstrap plan -out=registry.tfplan
terraform -chdir=infra/bootstrap apply registry.tfplan
repo=$(terraform -chdir=infra/bootstrap output -raw repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "${repo%%/*}"
export TF_VAR_initial_tag=1.0.0
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg VERSION="$TF_VAR_initial_tag" -t "$repo:$TF_VAR_initial_tag" --push .
```

3. Provision the environment. The module derives the VPC from the supplied subnet. Its app port is restricted to the reviewer CIDR; SSM needs outbound access. The user data installs Docker and starts the seeded tag. Allow cloud-init and SSM registration to finish. For a second environment initialize the matching state key before planning.

```bash
terraform -chdir=infra init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" -backend-config="region=$AWS_REGION" \
  -backend-config="key=assessment/$TF_VAR_environment/terraform.tfstate"
terraform -chdir=infra plan -out=environment.tfplan
terraform -chdir=infra apply environment.tfplan
terraform -chdir=infra plan -detailed-exitcode
terraform -chdir=infra output
```

   In assessment staging, hold the state lock in one interactive Terraform operation and attempt a second plan with a short lock timeout. Record rejection, release the first operation normally, and repeat. Keep state, binary plan files and credentials private.
4. Configure GitHub **repository variables** AWS_REGION, ECR_REPOSITORY (name only), AWS_RELEASE_ROLE_ARN (role_arn output), INSTANCE_ID and SSM_DOCUMENT. No AWS access-key secret is used. Local Grafana credentials belong only in the local environment. Review OIDC audience/subject and branch protections before enabling the workflow. The release role can send the specific deployment document to the specific instance.
5. Open a PR and capture its run. After the approved main push, inspect both tags with `docker buildx imagetools inspect "$repo:$TAG"`. Check the workflow SSM command output, call the instance's /health and / from the allowed network, and find that request in CloudWatch under /assessment/ENV/app. Record log retention and effective ingress.
6. In staging, publish a separately tagged controlled unhealthy candidate to the dedicated ECR repository, invoke the same restricted document with its tag, and capture the nonzero SSM result, restored immutable image, health response and previous version. A first deployment has no predecessor; conduct the rollback drill after a known-good deploy.
7. Save sanitized evidence before teardown. With the correct account, environment variables and state key selected, review `terraform -chdir=infra plan -destroy`, then destroy that assessment environment. Verify instance, instance role, security group and assessment log group removal. Once all environments are done, remove only assessment ECR images, destroy the registry root, and retire the dedicated state bucket and its historical versions according to the owner's retention policy. Leave shared subnets, VPCs and account identity providers intact.

The local source brief, DevOps_Engineer_Assessment_Task.pdf (page 2), permits saved successful workflow/apply evidence after destruction. Keep the public evidence and the original private operational artifacts separate.
