# Deploying Notesy

This document describes how Notesy goes from a commit on `main` to a running app, what was built for each milestone in `DEPLOYMENT_GUIDE.md`, and the decisions behind it.

## At a glance

```
push to main
  └─ gitleaks → build (TS bundle + Django check) → trivy-fs + tests (Postgres) → SonarCloud gate
                                                                                  │
                        ┌─────────────────────────────────────────────────────────┴───────────────────────────┐
                        │ Container track                                                                     │ Artifact track
                        │ build image once → Trivy image scan → push :<sha> + :latest to ECR                  │ tar release bundle + sha256 → upload to JFrog (creds from Vault)
                        │ → register new task definition → ECS Fargate rolling deploy (waits for stability)   │ → pull same bundle back, verify sha256 → SSH to Lightsail → activate release → smoke test
                        └─────────────────────────────────────────────────────────────────────────────────────┘
```

| Piece | Where it lives |
|---|---|
| Pipeline | `.github/workflows/cicd.yml` |
| AWS infrastructure (VPC, ALB, ECS, RDS, ECR, Secrets Manager, OIDC role, Lightsail) | `infra/` (Terraform) |
| Lightsail first-boot setup | `infra/lightsail_user_data.sh` |
| JFrog Artifactory, HashiCorp Vault, SonarQube host | separate repo `matteceejay/jfrog-install` |
| Local stack | `Dockerfile`, `docker-compose.yml`, `.env.example` |

---

## 1. What was built

### Milestone 1: Containerize it

- **Environment-driven settings.** `notesy/settings.py` no longer hardcodes anything. `DJANGO_SECRET_KEY`, `DJANGO_DEBUG`, `DJANGO_ALLOWED_HOSTS` and `DATABASE_URL` come from the environment (`dj-database-url` parses the URL). With `DEBUG` off, a missing secret key is a hard error. In local dev with `DEBUG` on, a random key is generated per process, so there is no fallback secret in the code.
- **Multi-stage `Dockerfile`.** A `node:20-alpine` stage runs `npm ci --ignore-scripts`, typechecks and bundles the TypeScript. The runtime stage is `python:3.12-slim` with no Node, installs wheels only (`--only-binary :all:`), copies only `manage.py`, `notesy/` and `apps/` (no `COPY . .`), runs `collectstatic`, and runs as a non-root `app` user.
- **Static files** are served by WhiteNoise, so gunicorn can serve CSS/JS with `DEBUG=False` and no separate web server.
- **`docker-compose.yml`** runs the app with Postgres. Migrations and the idempotent demo seed run on startup. `.dockerignore` keeps `.git`, `.env`, `infra/` and build output out of the image.
- **Sessions** use the database instead of files, so they work across several ECS tasks and survive Lightsail release swaps.

### Milestone 2: Automate the build

- **Tests run against real Postgres** (a `postgres:16-alpine` service container) with a per-run password, and a failing test fails the workflow. There is no `|| true`.
- **The frontend bundle is built and typechecked in CI** (`npm run typecheck`, `npm run build`), and the bundle is passed to later jobs as an artifact.
- **The Docker image builds on every PR** and is scanned by Trivy, but is only pushed from `main`.
- **Security gates:** Gitleaks secret scan, Trivy filesystem/config scan, Trivy image scan, and a SonarCloud quality gate with coverage from `pytest-cov`. Coverage excludes code that doesn't need unit tests (migrations, settings, WSGI/ASGI, management commands, tests).
- **Supply-chain hygiene:** every third-party action is pinned to a full commit SHA (tag kept as a comment), npm uses a committed `package-lock.json`, and pip installs wheels only.

### Milestone 3: Publish

On a push to `main`, the pipeline publishes one build to two destinations, both keyed by the commit SHA:

- **ECR**: the container image, tagged `:<commit-sha>` and `:latest`. The repository is `IMMUTABLE_WITH_EXCLUSION`: SHA tags can never be overwritten, only `latest` moves.
- **JFrog Artifactory**: a release bundle `notesy-<sha>.tar.gz` (app code, built JS, `requirements.txt`) in the Generic repo `devops-project` under `notesy/<sha>/`.

**How this differs from the guide.** The guide asks for the same Docker image in both registries. The self-hosted instance is **Artifactory OSS**, which does not support Docker repositories. Rather than add a second product, JFrog carries the non-container release artifact, and that artifact drives a second, non-container deployment target. The equivalent to the guide's intent still holds: one commit produces one set of versioned outputs, and each deploy target can be pinned to an exact SHA. If the instance were moved to JFrog Container Registry or Pro, adding a `docker push` to JFrog in the `image` job would give true dual image publishing with no other changes.

**Authentication:**

- **AWS uses GitHub OIDC**, with no static keys. The role `notesy-github-deploy` trusts only this repository's `main` branch. The repo has GitHub's *immutable subject* enabled, so the trust policy matches `repo:matteceejay@187773256/Notesy-app@1384331480:ref:refs/heads/main` (owner and repo IDs included), with the classic `repo:matteceejay/Notesy-app:ref:refs/heads/main` as a fallback. The role can only push to this ECR repo, register task definitions, update this ECS service, and pass the two task roles.
- **JFrog credentials never live in GitHub.** The pipeline logs in to Vault with an AppRole (Role ID and Secret ID as GitHub secrets) and reads `secrets/creds/jfrog` at run time. The values are masked in logs.

### Deploy targets

- **ECS Fargate** behind an Application Load Balancer, with RDS Postgres in private subnets. Secrets (`DJANGO_SECRET_KEY`, `DATABASE_URL`) come from Secrets Manager and are injected by ECS. The pipeline takes the latest task definition, swaps only the image, registers a new revision, and waits for the service to be stable. A deployment circuit breaker rolls back automatically if new tasks never become healthy. Migrations run in the container command before gunicorn starts.
- **Lightsail (Ubuntu 24.04)** running gunicorn under systemd on port 8000. The deploy job downloads the bundle from JFrog, checks it against the SHA-256 computed at build time, copies it over SSH, installs it into its own virtualenv at `/opt/notesy/releases/<sha>`, runs migrations and `collectstatic`, repoints the `/opt/notesy/current` symlink, restarts the service and runs a smoke test. The five newest releases are kept.

---

## 2. Tradeoffs

| Decision | Alternative | Why |
|---|---|---|
| **JFrog holds a release bundle, not an image** | Docker repo in JFrog | Artifactory OSS can't host Docker images. The bundle also gives a genuinely different deploy path (VM vs. container) to compare. |
| **ECS Fargate** | EKS / Kubernetes | Far less to operate for one service. The ALB, circuit breaker and rolling deploys cover what this app needs. |
| **Tasks in public subnets with public IPs** | Private subnets + NAT gateway | Saves roughly $32/month for a lab. Security groups still only accept traffic from the ALB. Production should move tasks to private subnets with a NAT gateway or VPC endpoints. |
| **Pipeline owns the running task definition** (`ignore_changes = [task_definition]`) | Terraform manages every revision | Stops `terraform apply` from rolling the service back to the bootstrap image. The cost is that task-definition changes in Terraform (env vars, CPU) take effect on the next pipeline deploy. |
| **Migrations in the container command** | A separate one-off migration task before deploy | Simple, and fine at one task. With many tasks starting at once, a dedicated migration step is safer. |
| **Vault AppRole for JFrog creds** | JFrog token stored directly as a GitHub secret | Keeps the credential in one place, and it can be rotated in Vault without touching GitHub. The cost is that Vault must be reachable and unsealed for a release. |
| **Artifact verified against the build-time hash** | A `.sha256` file stored next to the artifact in JFrog | A checksum stored in the same place as the artifact can be tampered with along with it. Passing the hash between jobs checks JFrog's copy against what CI built. It also avoids Artifactory's special handling of URLs ending in `.sha256`. |
| **SSH host key pinned as a secret** (`LIGHTSAIL_KNOWN_HOSTS`) | `ssh-keyscan` at run time | Keyscan trusts whatever answers, and it was unreliable against this host. Pinning refuses to connect if the key changes. The cost is refreshing the secret if the instance is replaced. |
| **SQLite on Lightsail** | Postgres on the box or RDS | RDS is private in the ECS VPC. SQLite keeps the second target self-contained. It is fine for a single VM but not for scaling out. |
| **SonarCloud findings accepted for lab items** (HTTP-only tools, no ALB access logs, no SRI on the CDN script, view HTTP methods) | Fix all of them | These are environment choices or app changes outside this task's scope. They were reviewed and accepted with a comment rather than silenced. |

---

## 3. How to run it

### Locally

```bash
cp .env.example .env        # then set DJANGO_SECRET_KEY and POSTGRES_PASSWORD
docker compose up --build
```

Open http://localhost:8000 and log in as `demo` / `demo`. `docker compose` refuses to start without `POSTGRES_PASSWORD` in `.env`, so there is no built-in default password.

### Infrastructure (one-time)

1. **JFrog, Vault and SonarQube host:** `terraform apply` in `jfrog-install`. Then change the JFrog admin password to match the value stored in Vault, create a Generic local repo `devops-project`, and note the Role ID and Secret ID from `vaultkey.txt`.
2. **Notesy AWS stack:**

   ```bash
   cd infra
   cp terraform.tfvars.example terraform.tfvars   # set create_github_oidc_provider = false if the account already has one
   terraform init && terraform apply
   terraform output github_actions_variables
   ```

3. **GitHub configuration** (Settings → Secrets and variables → Actions):

   | Variables | Secrets |
   |---|---|
   | `AWS_REGION`, `AWS_ROLE_ARN`, `ECR_REPOSITORY`, `ECS_CLUSTER`, `ECS_SERVICE`, `ECS_TASK_FAMILY`, `CONTAINER_NAME`, `LIGHTSAIL_HOST` (from Terraform output) | `VAULT_ROLE`, `VAULT_SECRET_ID` (from `vaultkey.txt`) |
   | `JFROG_URL` (e.g. `http://<jfrog-ip>:8082`, no `/artifactory`), `JFROG_REPO` = `devops-project` | `LIGHTSAIL_SSH_KEY` (`terraform output -raw lightsail_ssh_private_key`) |
   | `VAULT_ADDR` (e.g. `http://<jfrog-ip>:8200`), `VAULT_JFROG_SECRET_PATH` = `secrets/creds/jfrog` | `LIGHTSAIL_KNOWN_HOSTS` (host key, see below) |
   | `SONAR_ORGANIZATION`, `SONAR_PROJECT_KEY` | `SONAR_TOKEN` |

   To capture the Lightsail host key, log in once with SSH, confirm the fingerprint, then export the saved entry:

   ```bash
   ssh-keygen -F <LIGHTSAIL_HOST> | grep -v '^#' | gh secret set LIGHTSAIL_KNOWN_HOSTS -R matteceejay/Notesy-app
   ```

### Releasing

Push or merge to `main`. Pull requests run CI and the image build and scan, but never publish or deploy.

### First login

The pipeline doesn't seed a demo user in deployed environments. Create a user on each target, since ECS (RDS) and Lightsail (SQLite) have separate databases:

- **Lightsail:** SSH in and run `manage.py createsuperuser` as the `notesy` user with `/etc/notesy/notesy.env` loaded.
- **ECS:** run a one-off Fargate task from the `notesy` task definition in the service's network configuration, overriding the command to `manage.py createsuperuser --noinput` with `DJANGO_SUPERUSER_PASSWORD` set.

---

## 4. Keeping the two registries in sync

**How they stay in step.** Both outputs are built in the same workflow run from the same checkout, and both are keyed by the same commit SHA: `notesy:<sha>` in ECR and `devops-project/notesy/<sha>/notesy-<sha>.tar.gz` in JFrog. Neither job can overwrite the other's output, and ECR SHA tags are immutable.

**If one publish succeeds and the other fails.** The two tracks are independent jobs after the Sonar gate. A failure in one doesn't undo the other, and each track's deploy only runs if its own publish succeeded. So a failed JFrog upload means Lightsail simply doesn't get that release. ECS still deploys, and the run is marked failed. Because the SHA is the key, the fix is to re-run the failed job (`gh run rerun --failed`). It rebuilds that output for the same commit and fills the gap. A re-run of the ECR track is safe: SHA tags are immutable, so an existing image is never replaced.

**Detecting drift.** "In sync" means every SHA in one registry is also in the other. Compare the two lists:

```bash
aws ecr list-images --repository-name notesy --query 'imageIds[].imageTag' --output text \
  | tr '\t' '\n' | grep -E '^[0-9a-f]{40}$' | sort > /tmp/ecr.txt

curl -s -u "$JFROG_USER:$JFROG_PASSWORD" \
  "$JFROG_URL/artifactory/api/storage/devops-project/notesy" \
  | jq -r '.children[] | select(.folder) | .uri | ltrimstr("/")' | sort > /tmp/jfrog.txt

comm -3 /tmp/ecr.txt /tmp/jfrog.txt   # lines are SHAs present in only one registry
```

This could run as a scheduled workflow that opens an issue when the output isn't empty. Expected differences come from retention: ECR keeps the 30 most recent images, while JFrog has no cleanup policy yet. Matching retention on both sides is on the improvement list.

**What each target is running** can be checked against the registries at any time:

```bash
aws ecs describe-services --cluster notesy-cluster --services notesy-service \
  --query 'services[0].taskDefinition' --output text \
  | xargs -I{} aws ecs describe-task-definition --task-definition {} \
      --query 'taskDefinition.containerDefinitions[0].image' --output text

ssh ubuntu@<LIGHTSAIL_HOST> 'sudo readlink /opt/notesy/current'
```

---

## 5. Rollback

Every release is addressable by commit SHA, so rolling back means pointing a target at an older SHA. Nothing needs rebuilding.

### ECS

**Automatic.** If a new revision never becomes healthy, the deployment circuit breaker returns the service to the last working revision on its own.

**Manual.** Each deploy registers a new task definition revision, and the previous revision still references the previous image SHA:

```bash
aws ecs list-task-definitions --family-prefix notesy --sort DESC --max-items 5
aws ecs update-service --cluster notesy-cluster --service notesy-service \
  --task-definition notesy:<previous-revision>
aws ecs wait services-stable --cluster notesy-cluster --services notesy-service
```

What has to change is only the service's task definition revision. Code, the image and ECR are untouched. The next push to `main` deploys forward from the latest revision again, so to keep a rollback in place, revert the bad commit on `main` too.

### Lightsail

The previous five releases stay on disk, so rolling back is a symlink swap and a restart:

```bash
ssh ubuntu@<LIGHTSAIL_HOST> '
  sudo ls -1dt /opt/notesy/releases/*
  sudo ln -sfn /opt/notesy/releases/<old-sha> /opt/notesy/current
  sudo systemctl restart notesy'
```

If the release has already been pruned from the box, it's still in JFrog under `devops-project/notesy/<old-sha>/`. Re-running that commit's `deploy-lightsail` job re-installs it.

### Database migrations

Both rollbacks swap code, not schema. If the bad release included a migration, the older code runs against the newer schema. That is safe for additive changes (new nullable columns, new tables) but not for renames or drops. Before rolling back past such a migration, reverse it with `manage.py migrate notes <previous_migration>` while the new code is still deployed. Keeping migrations backward-compatible for one release avoids the problem.

---

## 6. Stretch goal (Kubernetes)

Not attempted. Instead, time went into two real AWS deployment targets (ECS Fargate and Lightsail) driven by the published outputs.

Moving to Kubernetes would reuse the image and pipeline as they are. The main changes:

- **Manifests:** a `Deployment` pinned to `…/notesy:<sha>`, a `Service`, a `ConfigMap` for non-secret settings, and a `Secret` (or External Secrets Operator reading the existing Secrets Manager secret). A readiness probe on `/login/` would replace the ALB health check. The ALB host-header workaround in `settings.py` is ECS-specific and not needed on Kubernetes, since kube-probes can send a `Host` header.
- **Migrations:** a pre-deploy `Job`, or Helm hook, instead of the container command, so replicas don't race each other.
- **Things a local cluster lets you skip:**
  - Image pull secrets for ECR. On EKS, node or IRSA IAM permissions are used instead.
  - Real ingress with TLS (AWS Load Balancer Controller plus ACM), and `CSRF_TRUSTED_ORIGINS` for the HTTPS origin.
  - Resource requests and limits, a `PodDisruptionBudget`, and a `HorizontalPodAutoscaler`.
  - Network policies, and a managed Postgres instead of an in-cluster database.
- **Delivery:** the deploy step becomes updating the image tag in a GitOps repo that Argo CD syncs, rather than calling the ECS API.

---

## Security notes and known limitations

- **JFrog, Vault and SonarQube run over plain HTTP** on a public IP, so credentials cross the internet unencrypted. For anything beyond a lab, put them behind TLS and restrict their security group to known sources. The instance role in `jfrog-install` also has `AdministratorAccess`, which should be scoped down.
- **The JFrog host has no Elastic IP.** If it is stopped and started, or recreated, `JFROG_URL` and `VAULT_ADDR` must be updated. Vault uses file storage and comes back **sealed** after a reboot, so unseal it before the next release.
- **The Lightsail host key is pinned.** If the instance is replaced, refresh `LIGHTSAIL_KNOWN_HOSTS` and confirm the static IP is attached. SSH is open to `0.0.0.0/0` because GitHub-hosted runner IPs aren't fixed. Access is key-only.
- **Secrets removed from the repo** (the old `.env` with `SUMMARIZER_API_KEY`) remain in git history and must be rotated. The `jfrog-install` repo commits the JFrog password in `terraform.tfvars`, so rotate it in JFrog and Vault together.
- **The ALB serves HTTP only.** Add an ACM certificate, an HTTPS listener with an HTTP→HTTPS redirect, and `CSRF_TRUSTED_ORIGINS`.
- **Summarizer.** `SUMMARIZER_API_KEY` and `SUMMARIZER_URL` are plumbed through Secrets Manager but not used by the app. The summarize view is a stub.

## Operational notes

These came up during the build and are worth knowing when something breaks:

- **Lightsail user data runs under `sh`**, because Lightsail wraps it in its own launch script. Use POSIX-only options (`set -eux`, not `-o pipefail`) in `lightsail_user_data.sh`.
- **Artifactory treats `<file>.sha256` as a request for its own checksum** of `<file>`, returning a bare hash, so a stored checksum file can't be read back as written.
- **GitHub OIDC with immutable subjects** changes the `sub` claim to include numeric IDs. Check the exact value with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`, and see rejected claims in CloudTrail under `AssumeRoleWithWebIdentity`.
- **The ALB health checker sends the task's private IP as the `Host` header.** `settings.py` adds that IP to `ALLOWED_HOSTS` from the ECS metadata endpoint, or Django answers health checks with 400.
