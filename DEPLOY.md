# Deploying Notesy

This document describes how Notesy goes from a commit on `main` to a running app, what was built for each milestone in `DEPLOYMENT_GUIDE.md`, how to configure it (including every GitHub secret and variable), and how to operate, recover, and roll it back.

Values in angle brackets, like `<your-domain>`, are placeholders. Replace them with your own.

## At a glance

```
push to main
  └─ gitleaks → build (TS bundle + Django check) → trivy-fs + tests (Postgres) → SonarCloud quality gate
                                                                                  │
          ┌───────────────────────────────────────────────────────────────────────┴──────────────────────────────┐
          │ Container track                                                                                      │ Artifact track
          │ build image once → Trivy image scan → push :<sha> + :latest to ECR                                   │ tar release bundle + record its sha256
          │ → register new task definition → ECS Fargate rolling deploy (waits for stability)                    │ → upload to JFrog (creds read from Vault)
          │ → https://<ecs-subdomain>.<your-domain>  (ALB + ACM certificate)                                    │ → download from JFrog, verify sha256 → SSH to Lightsail
          │                                                                                                      │ → activate release → smoke test https://<vm-subdomain>.<your-domain>
          └──────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Piece | Where it lives |
|---|---|
| Pipeline | `.github/workflows/cicd.yml` |
| AWS infrastructure: VPC, ALB, ACM, ECS, RDS, ECR, Secrets Manager, OIDC deploy role, Lightsail | `infra/` (Terraform) |
| Lightsail first-boot setup | `infra/lightsail_user_data.sh` |
| JFrog Artifactory, HashiCorp Vault and SonarQube host | separate repo `jfrog-install` |
| Local stack | `Dockerfile`, `docker-compose.yml`, `.env.example` |

| Environment | URL | TLS |
|---|---|---|
| ECS Fargate | `https://<ecs-subdomain>.<your-domain>` | ACM certificate on the ALB, HTTP redirects to HTTPS |
| Lightsail | `https://<vm-subdomain>.<your-domain>` | Let's Encrypt via Caddy, auto-renewed |

---

## 1. What was built

### Milestone 1: Containerize it

- **Environment-driven settings.** `notesy/settings.py` hardcodes nothing. These come from the environment:
  - `DJANGO_SECRET_KEY`, `DJANGO_DEBUG`, `DJANGO_ALLOWED_HOSTS`, `DATABASE_URL` (parsed by `dj-database-url`)
  - `DJANGO_CSRF_TRUSTED_ORIGINS`: the HTTPS origins allowed to submit forms
  - `DJANGO_BEHIND_TLS_PROXY`: set when TLS ends at the ALB or at Caddy. It trusts `X-Forwarded-Proto` and marks session and CSRF cookies `Secure`.

  With `DEBUG` off, a missing secret key is a hard error. In local dev with `DEBUG` on, a random key is generated per process, so there is no fallback secret in the code.
- **Multi-stage `Dockerfile`.** A `node:20-alpine` stage runs `npm ci --ignore-scripts` from the committed `package-lock.json`, typechecks and bundles the TypeScript. The runtime stage is `python:3.12-slim` with no Node. It installs wheels only (`--only-binary :all:`), copies only `manage.py`, `notesy/` and `apps/` (no `COPY . .`), runs `collectstatic`, and runs as a non-root `app` user.
- **Static files** are served by WhiteNoise, so gunicorn serves CSS/JS with `DEBUG=False`.
- **`docker-compose.yml`** runs the app with Postgres. Migrations and the idempotent demo seed run on startup. The Postgres password must come from `.env`, and Compose refuses to start without it. `.dockerignore` keeps `.git`, `.env`, `infra/` and build output out of the image.
- **Sessions** use the database, so they work across several ECS tasks and survive Lightsail release swaps.
- **ALB health checks.** The ALB health checker sends the task's private IP as the `Host` header. `settings.py` reads the task IP from the ECS metadata endpoint and adds it to `ALLOWED_HOSTS`. Otherwise Django would answer health checks with 400.

### Milestone 2: Automate the build

- **Tests run against real Postgres** in a service container, with a per-run password (`ci-${{ github.run_id }}`). A failing test fails the workflow.
- **The frontend bundle is built and typechecked in CI**, and passed to later jobs as an artifact.
- **The Docker image builds and is scanned on every PR**, but is only pushed from `main`.
- **Security gates:**
  - Gitleaks secret scan
  - Trivy filesystem/config scan and Trivy image scan
  - SonarCloud quality gate, with coverage from `pytest-cov`. Coverage excludes code that doesn't need unit tests: migrations, settings, WSGI/ASGI, management commands and test files. `apps/notes/test_views.py` covers the auth flow, detail and editor views, and summarize (with the 8-second sleep mocked out).
- **Supply-chain hygiene:**
  - every third-party action is pinned to a full commit SHA, with the tag as a comment
  - npm uses a lockfile, with lifecycle scripts disabled
  - pip installs wheels only
  - the Lightsail SSH key is passed through `env:`, not expanded in `run:`

### Milestone 3: Publish

On a push to `main`, one build is published to two destinations, both keyed by the commit SHA:

- **ECR**: the container image, tagged `:<commit-sha>` and `:latest`. The repository is `IMMUTABLE_WITH_EXCLUSION`: SHA tags can never be overwritten, only `latest` moves.
- **JFrog Artifactory**: a release bundle `notesy-<sha>.tar.gz` (app code, built JS, `requirements.txt`) in the Generic repo `<jfrog-repo>` under `notesy/<sha>/`. The upload sends an `X-Checksum-Sha256` header, so Artifactory rejects a corrupted upload.

**How this differs from the guide.** The guide asks for the same Docker image in both registries. The self-hosted instance is **Artifactory OSS**, which does not support Docker repositories. So JFrog carries the non-container release artifact, and that artifact drives a second, non-container deployment target. One commit still produces one set of SHA-addressed outputs, and each target can be pinned to an exact SHA. With JFrog Container Registry or Pro, adding a `docker push` to JFrog in the `image` job would give true dual image publishing.

**Authentication:**

- **AWS uses GitHub OIDC**, with no static keys. The role `<app-name>-github-deploy` trusts only this repository's `main` branch. It can only push to this ECR repo, register task definitions, update this ECS service, and pass the two task roles.
  - The repo has GitHub's **immutable subject** enabled, so the token's `sub` includes numeric owner and repo IDs: `repo:<github-owner>@<owner-id>/<repo>@<repo-id>:ref:refs/heads/main`.
  - The trust policy accepts that form, through the Terraform variable `github_oidc_sub_prefix`, and the classic `repo:<github-owner>/<repo>:ref:refs/heads/main` as a fallback.
- **JFrog credentials never live in GitHub.** The pipeline logs in to Vault with an AppRole (Role ID and Secret ID as GitHub secrets) and reads `username` and `password` from `<vault-jfrog-secret-path>` at run time. The values are masked in logs.

### Deploy targets

**ECS Fargate** behind an Application Load Balancer, with RDS Postgres in private subnets:

- Secrets (`DJANGO_SECRET_KEY`, `DATABASE_URL`) come from Secrets Manager and are injected by ECS.
- **HTTPS:** an ACM certificate for `<ecs-subdomain>.<your-domain>`, validated through a Route 53 DNS record. There is a 443 listener, and port 80 redirects to 443.
- The pipeline takes the latest task definition, swaps only the image, registers a new revision, and waits for the service to be stable.
- A deployment circuit breaker rolls back automatically if new tasks never become healthy.
- Migrations run in the container command before gunicorn starts.

**Lightsail (Ubuntu 24.04)**:

- **Caddy** terminates HTTPS for `<vm-subdomain>.<your-domain>`, gets and renews a Let's Encrypt certificate automatically, and proxies to gunicorn on `127.0.0.1:8000`.
- gunicorn runs under systemd (`notesy.service`). Only ports 22, 80 and 443 are open.
- The deploy job:
  1. downloads the bundle from JFrog and verifies it against the SHA-256 computed at build time
  2. SSHes in using a **pinned host key**
  3. installs the bundle into its own virtualenv at `/opt/notesy/releases/<sha>`
  4. ensures the domain and HTTPS settings in `/etc/notesy/notesy.env`
  5. runs migrations and `collectstatic`, repoints `/opt/notesy/current`, and restarts the service
  6. smoke-tests over HTTPS

  The five newest releases are kept on the box.

---

## 2. Tradeoffs

| Decision | Alternative | Why |
|---|---|---|
| **JFrog holds a release bundle, not an image** | Docker repo in JFrog | Artifactory OSS can't host Docker images. The bundle also gives a genuinely different deploy path (VM vs. container). |
| **ECS Fargate** | EKS / Kubernetes | Far less to operate for one service. The ALB, circuit breaker and rolling deploys cover what this app needs. |
| **Tasks in public subnets with public IPs** | Private subnets + NAT gateway | Saves roughly $32/month for a lab. Security groups still only accept traffic from the ALB. Production should use private subnets with a NAT gateway or VPC endpoints. |
| **Pipeline owns the running task definition** (`ignore_changes = [task_definition]`) | Terraform manages every revision | Stops `terraform apply` from rolling the service back to the bootstrap image. The cost is that task-definition changes in Terraform (env vars, CPU) only take effect on the next pipeline deploy. |
| **Migrations in the container command** | A one-off migration task before deploy | Simple, and fine at one task. With many tasks starting at once, a dedicated migration step is safer. |
| **Vault AppRole for JFrog creds** | JFrog token as a GitHub secret | The credential lives in one place and can be rotated in Vault without touching GitHub. Vault must be reachable and unsealed for a release. |
| **Artifact verified against the build-time hash** | A `.sha256` file stored next to the artifact in JFrog | A checksum stored in the same place as the artifact can be tampered with along with it. Artifactory also treats URLs ending in `.sha256` as a request for its own checksum, so a stored checksum file can't be read back as written. |
| **SSH host key pinned as a secret** (`LIGHTSAIL_KNOWN_HOSTS`) | `ssh-keyscan` at run time | Keyscan trusts whatever answers, and it was unreliable against this host. Pinning refuses to connect if the key changes. The cost is refreshing the secret if the instance is replaced. |
| **Caddy for Lightsail HTTPS** | nginx + certbot, or a Lightsail load balancer | One small config file, automatic certificates and renewals, and no extra monthly cost. |
| **ACM certificate on the ALB** | Terminate TLS in the container | Free, managed renewal, and no certificate handling in the app. |
| **SQLite on Lightsail** | Postgres on the box, or RDS | RDS is private in the ECS VPC. SQLite keeps the second target self-contained, which is fine for a single VM but not for scaling out. |
| **SonarCloud lab findings accepted** (HTTP-only JFrog/Vault, no ALB access logs, no SRI on the CDN script, undeclared view HTTP methods, unpinned Python versions) | Fix all of them | These are environment choices, or app changes outside this task. They were reviewed and accepted with a comment, not silenced. |

---

## 3. How to run it

### Locally

```bash
cp .env.example .env        # set DJANGO_SECRET_KEY and POSTGRES_PASSWORD
docker compose up --build
```

Open http://localhost:8000 and log in as `demo` / `demo`.

### Infrastructure (one-time)

**1. JFrog, Vault and SonarQube host.** Run `terraform apply` in `jfrog-install`. Then:

- Log in to JFrog at `http://<jfrog-host>:8082` and change the admin password to the value stored in Vault.
- Create a **Generic** local repository named `<jfrog-repo>`.
- Note the **Role ID** and **Secret ID** from `vaultkey.txt`. You'll need them for the GitHub secrets.

**2. DNS zone.** The domain must be in a Route 53 hosted zone.

**3. Notesy AWS stack.**

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

Set these in `terraform.tfvars`:

```hcl
aws_region                  = "<aws-region>"
github_repo                 = "<github-owner>/<repo>"
create_github_oidc_provider = false   # false if the account already has token.actions.githubusercontent.com
app_domain                  = "<ecs-subdomain>.<your-domain>"
github_oidc_sub_prefix      = "repo:<github-owner>@<owner-id>/<repo>@<repo-id>"
```

Get the `github_oidc_sub_prefix` value from GitHub:

```bash
gh api repos/<github-owner>/<repo>/actions/oidc/customization/sub   # use "sub_claim_prefix"
```

Then apply:

```bash
terraform init && terraform apply
terraform output github_actions_variables
```

**4. DNS records.** In Route 53, create:

- `<ecs-subdomain>.<your-domain>`: an **Alias A** record pointing to the ALB (`terraform output app_url` shows its DNS name)
- `<vm-subdomain>.<your-domain>`: an **A** record pointing to `<lightsail-static-ip>` (`terraform output lightsail_host`)

**5. Lightsail HTTPS (Caddy).** Run this once per instance. Nothing listens on ports 80 and 443 until Caddy is installed, so do this after the DNS record exists.

```bash
ssh -i <path-to-lightsail-key> ubuntu@<lightsail-static-ip> 'bash -s' <<'EOF'
set -eux
DOMAIN=<vm-subdomain>.<your-domain>
sudo apt-get update
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update && sudo apt-get install -y caddy
printf '%s {\n  reverse_proxy 127.0.0.1:8000\n}\n' "$DOMAIN" | sudo tee /etc/caddy/Caddyfile
sudo systemctl enable --now caddy && sudo systemctl reload caddy
EOF
```

Caddy gets its certificate within about a minute of port 80 being reachable. Check its progress with `sudo journalctl -u caddy -n 40`.

**6. GitHub configuration.** See [section 4](#4-github-secrets-and-variables).

### Releasing

Push or merge to `main`. Pull requests run CI and the image build and scan, but never publish or deploy.

### First login

The pipeline doesn't seed a demo user in deployed environments. ECS (RDS) and Lightsail (SQLite) have separate databases, so create a user on each.

**Lightsail:**

```bash
ssh -t -i <path-to-lightsail-key> ubuntu@<lightsail-static-ip> \
  "sudo -u notesy bash -c 'cd /opt/notesy/current && set -a && . /etc/notesy/notesy.env && set +a && .venv/bin/python manage.py createsuperuser'"
```

**ECS:** run a one-off task in the service's network, overriding the command:

```bash
read -p "Username: " SU_USER; read -s -p "Password: " SU_PASS; echo
NET=$(aws ecs describe-services --cluster <app-name>-cluster --services <app-name>-service \
  --query 'services[0].networkConfiguration' --output json)
TASK=$(aws ecs run-task --cluster <app-name>-cluster --task-definition <app-name> \
  --launch-type FARGATE --network-configuration "$NET" \
  --overrides "{\"containerOverrides\":[{\"name\":\"<app-name>\",
    \"command\":[\"python\",\"manage.py\",\"createsuperuser\",\"--noinput\",\"--username\",\"$SU_USER\",\"--email\",\"\"],
    \"environment\":[{\"name\":\"DJANGO_SUPERUSER_PASSWORD\",\"value\":\"$SU_PASS\"}]}]}" \
  --query 'tasks[0].taskArn' --output text)
aws ecs wait tasks-stopped --cluster <app-name>-cluster --tasks "$TASK"
aws ecs describe-tasks --cluster <app-name>-cluster --tasks "$TASK" --query 'tasks[0].containers[0].exitCode'
```

An exit code of `0` means the user was created. Passwords can't be read back, because Django stores only a hash. To reset one, run the same kind of task with `manage.py shell -c` calling `set_password`.

---

## 4. GitHub secrets and variables

Everything the pipeline needs is configured under **Settings → Secrets and variables → Actions → Repository**. No environment-level secrets or variables are used.

Do not put any of these in an `environment:` on the AWS jobs. Doing so changes the OIDC `sub` claim, and the AWS role will refuse the token.

### Repository secrets (5)

| Name | What it is | Where to get it |
|---|---|---|
| `VAULT_ROLE` | Vault AppRole **Role ID** | `vaultkey.txt` in `jfrog-install` (line `Role ID:`) |
| `VAULT_SECRET_ID` | Vault AppRole **Secret ID** | `vaultkey.txt` (line `Secret ID:`) |
| `LIGHTSAIL_SSH_KEY` | Private key the pipeline uses to SSH into Lightsail | `terraform output -raw lightsail_ssh_private_key` (in `infra/`) |
| `LIGHTSAIL_KNOWN_HOSTS` | Pinned SSH host key(s) of the Lightsail instance | exported from your own `known_hosts` after verifying the fingerprint (below) |
| `SONAR_TOKEN` | SonarCloud token | SonarCloud → My Account → Security → Generate Tokens |

### Repository variables (15)

| Name | Placeholder | Where to get it |
|---|---|---|
| `AWS_REGION` | `<aws-region>` | `terraform output github_actions_variables` |
| `AWS_ROLE_ARN` | `arn:aws:iam::<aws-account-id>:role/<app-name>-github-deploy` | `terraform output github_actions_variables` |
| `ECR_REPOSITORY` | `<app-name>` | `terraform output github_actions_variables` |
| `ECS_CLUSTER` | `<app-name>-cluster` | `terraform output github_actions_variables` |
| `ECS_SERVICE` | `<app-name>-service` | `terraform output github_actions_variables` |
| `ECS_TASK_FAMILY` | `<app-name>` | `terraform output github_actions_variables` |
| `CONTAINER_NAME` | `<app-name>` | `terraform output github_actions_variables` |
| `LIGHTSAIL_HOST` | `<lightsail-static-ip>` | `terraform output lightsail_host` |
| `LIGHTSAIL_DOMAIN` | `<vm-subdomain>.<your-domain>` | the Lightsail DNS name you created |
| `JFROG_URL` | `http://<jfrog-host>:8082` | `jfrog-install` output `JFROG_URL`. No `/artifactory` and no trailing slash, since the pipeline appends the path. |
| `JFROG_REPO` | `<jfrog-repo>` | the Generic repo you created in JFrog |
| `VAULT_ADDR` | `http://<jfrog-host>:8200` | `jfrog-install` output `HASHICORP_VAULT_URL` |
| `VAULT_JFROG_SECRET_PATH` | `<vault-jfrog-secret-path>` (default `secrets/creds/jfrog`) | path of the KV secret holding the JFrog `username` and `password` |
| `SONAR_ORGANIZATION` | `<sonar-org-key>` | SonarCloud → project → Information → Organization Key |
| `SONAR_PROJECT_KEY` | `<sonar-project-key>` | SonarCloud → project → Information → Project Key |

`APP_NAME` is optional and defaults to `notesy`. It must match `app_name` in Terraform if you change it.

### Setting them from the terminal

This uses the GitHub CLI (`gh`). Replace every placeholder first, because shell treats `<...>` as syntax.

```bash
R=<github-owner>/<repo>

# Variables
gh variable set AWS_REGION              -R $R -b <aws-region>
gh variable set AWS_ROLE_ARN            -R $R -b arn:aws:iam::<aws-account-id>:role/<app-name>-github-deploy
gh variable set ECR_REPOSITORY          -R $R -b <app-name>
gh variable set ECS_CLUSTER             -R $R -b <app-name>-cluster
gh variable set ECS_SERVICE             -R $R -b <app-name>-service
gh variable set ECS_TASK_FAMILY         -R $R -b <app-name>
gh variable set CONTAINER_NAME          -R $R -b <app-name>
gh variable set LIGHTSAIL_HOST          -R $R -b <lightsail-static-ip>
gh variable set LIGHTSAIL_DOMAIN        -R $R -b <vm-subdomain>.<your-domain>
gh variable set JFROG_URL               -R $R -b http://<jfrog-host>:8082
gh variable set JFROG_REPO              -R $R -b <jfrog-repo>
gh variable set VAULT_ADDR              -R $R -b http://<jfrog-host>:8200
gh variable set VAULT_JFROG_SECRET_PATH -R $R -b secrets/creds/jfrog
gh variable set SONAR_ORGANIZATION      -R $R -b <sonar-org-key>
gh variable set SONAR_PROJECT_KEY       -R $R -b <sonar-project-key>

# Secrets: piped from files or command output, so values never land in shell history
VK=<path-to-jfrog-install>/vaultkey.txt
grep '^Role ID:'   "$VK" | awk '{printf "%s", $3}' | gh secret set VAULT_ROLE      -R $R
grep '^Secret ID:' "$VK" | awk '{printf "%s", $3}' | gh secret set VAULT_SECRET_ID -R $R

(cd infra && terraform output -raw lightsail_ssh_private_key) | gh secret set LIGHTSAIL_SSH_KEY -R $R

gh secret set SONAR_TOKEN -R $R        # prompts; paste the token

# Check
gh variable list -R $R     # expect 15
gh secret list -R $R       # expect 5
```

### Capturing `LIGHTSAIL_KNOWN_HOSTS`

`ssh-keyscan` is unreliable against this host, so take the key from a connection you've verified yourself:

```bash
ssh -i <path-to-lightsail-key> ubuntu@<lightsail-static-ip> true      # accept the key on first connect
ssh-keygen -F <lightsail-static-ip> | grep -v '^#' > /tmp/lightsail_known_hosts
ssh-keygen -lf /tmp/lightsail_known_hosts                             # compare the ED25519 fingerprint...
ssh -i <path-to-lightsail-key> ubuntu@<lightsail-static-ip> \
  'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'                  # ...with the one on the box
gh secret set LIGHTSAIL_KNOWN_HOSTS -R <github-owner>/<repo> < /tmp/lightsail_known_hosts
rm /tmp/lightsail_known_hosts
```

### What to update when something changes

| Event | Update |
|---|---|
| JFrog/Vault host gets a new IP (stop/start or rebuild without an Elastic IP) | `JFROG_URL`, `VAULT_ADDR` |
| `jfrog-install` reinstalled (Vault re-initialized) | `VAULT_ROLE`, `VAULT_SECRET_ID`, `JFROG_URL`, `VAULT_ADDR`. Also recreate the `<jfrog-repo>` Generic repo, and reset the JFrog admin password to match Vault. |
| JFrog password rotated | Only the Vault secret: `vault kv put <vault-jfrog-secret-path> username=admin password=<new>`. No GitHub change. |
| Lightsail instance replaced (e.g. `user_data` changed) | `LIGHTSAIL_KNOWN_HOSTS` (new host key). Re-run the Caddy step, and confirm the static IP is attached (`LIGHTSAIL_HOST` stays the same). |
| Lightsail key pair recreated | `LIGHTSAIL_SSH_KEY` |
| Lightsail domain changed | `LIGHTSAIL_DOMAIN`, the DNS A record, and the Caddyfile on the box |
| ECS domain changed | `app_domain` in `terraform.tfvars`, then `terraform apply` and push once (no GitHub change) |
| Sonar token rotated or revoked | `SONAR_TOKEN` |
| AWS stack recreated | `AWS_ROLE_ARN` and the other `terraform output github_actions_variables` values, if names changed |
| Repo renamed, transferred or recreated | `github_repo` and `github_oidc_sub_prefix` in Terraform (the repo/owner IDs change), then `terraform apply` |

---

## 5. Keeping the two registries in sync

**How they stay in step.** Both outputs are built in the same workflow run from the same checkout, and keyed by the same commit SHA:

- ECR: `<app-name>:<sha>`
- JFrog: `<jfrog-repo>/<app-name>/<sha>/<app-name>-<sha>.tar.gz`

Neither can overwrite the other, and ECR SHA tags are immutable.

**If one publish succeeds and the other fails.** The two tracks are independent jobs after the Sonar gate. A failure in one doesn't undo the other, and each track's deploy only runs if its own publish succeeded. So a failed JFrog upload means Lightsail doesn't get that release, while ECS still deploys and the run is marked failed.

Because the SHA is the key, the fix is `gh run rerun --failed`. It rebuilds that output for the same commit and fills the gap. Re-running the ECR track is safe, since an existing SHA tag can't be replaced.

**Detecting drift.** "In sync" means every SHA in one registry is also in the other:

```bash
aws ecr list-images --repository-name <app-name> --query 'imageIds[].imageTag' --output text \
  | tr '\t' '\n' | grep -E '^[0-9a-f]{40}$' | sort > /tmp/ecr.txt

curl -s -u "<jfrog-user>:<jfrog-password>" \
  "http://<jfrog-host>:8082/artifactory/api/storage/<jfrog-repo>/<app-name>" \
  | jq -r '.children[] | select(.folder) | .uri | ltrimstr("/")' | sort > /tmp/jfrog.txt

comm -3 /tmp/ecr.txt /tmp/jfrog.txt   # prints SHAs present in only one registry
```

This could run as a scheduled workflow that opens an issue when the output isn't empty. Expected differences come from retention: ECR keeps the 30 most recent images, while JFrog has no cleanup policy yet.

**What each target is running:**

```bash
aws ecs describe-services --cluster <app-name>-cluster --services <app-name>-service \
  --query 'services[0].taskDefinition' --output text \
  | xargs -I{} aws ecs describe-task-definition --task-definition {} \
      --query 'taskDefinition.containerDefinitions[0].image' --output text

ssh -i <path-to-lightsail-key> ubuntu@<lightsail-static-ip> 'sudo readlink /opt/notesy/current'
```

---

## 6. Rollback

Every release is addressable by commit SHA, so rolling back means pointing a target at an older SHA. Nothing needs rebuilding.

### ECS

**Automatic.** If a new revision never becomes healthy, the deployment circuit breaker returns the service to the last working revision on its own.

**Manual.** Each deploy registers a new task definition revision, and the previous revision references the previous image SHA:

```bash
aws ecs list-task-definitions --family-prefix <app-name> --sort DESC --max-items 5
aws ecs update-service --cluster <app-name>-cluster --service <app-name>-service \
  --task-definition <app-name>:<previous-revision>
aws ecs wait services-stable --cluster <app-name>-cluster --services <app-name>-service
```

Only the service's task definition revision changes. The next push to `main` deploys forward from the latest revision again, so revert the bad commit on `main` too, or the rollback won't stick.

### Lightsail

The previous five releases stay on disk, so rolling back is a symlink swap and a restart:

```bash
ssh -i <path-to-lightsail-key> ubuntu@<lightsail-static-ip> '
  sudo ls -1dt /opt/notesy/releases/*
  sudo ln -sfn /opt/notesy/releases/<old-sha> /opt/notesy/current
  sudo systemctl restart notesy'
```

If that release has been pruned from the box, it's still in JFrog under `<jfrog-repo>/<app-name>/<old-sha>/`. Re-running that commit's `deploy-lightsail` job re-installs it.

### Database migrations

Both rollbacks swap code, not schema. Older code against a newer schema is safe for additive changes (new nullable columns, new tables), but not for renames or drops. Before rolling back past such a migration, reverse it with `manage.py migrate notes <previous_migration>` while the new code is still deployed. Keeping migrations backward-compatible for one release avoids the problem.

---

## 7. Stretch goal (Kubernetes)

Not attempted. Instead, the time went into two real AWS targets with custom domains and HTTPS.

Moving to Kubernetes would reuse the image and pipeline. The main changes:

- **Manifests:** a `Deployment` pinned to `…/<app-name>:<sha>`, a `Service`, a `ConfigMap` for non-secret settings, and a `Secret` (or External Secrets Operator reading the existing Secrets Manager secret). A readiness probe on `/login/` would replace the ALB health check. The ECS task-IP workaround in `settings.py` isn't needed, because probes can send a `Host` header.
- **Migrations:** a pre-deploy `Job` or Helm hook, instead of the container command.
- **What a local cluster lets you skip:**
  - Image pull access to ECR. On EKS, this is node or IRSA IAM permissions.
  - Real ingress with TLS: AWS Load Balancer Controller plus ACM, reusing the same certificate and `DJANGO_CSRF_TRUSTED_ORIGINS` / `DJANGO_BEHIND_TLS_PROXY`.
  - Resource requests and limits, a `PodDisruptionBudget`, and a `HorizontalPodAutoscaler`.
  - Network policies, and a managed Postgres.
- **Delivery:** the deploy step becomes updating the image tag in a GitOps repo that Argo CD syncs.

---

## 8. Troubleshooting notes

These all came up during the build.

| Symptom | Cause | Fix |
|---|---|---|
| `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity` | The repo uses **immutable subjects**, so the token's `sub` includes numeric IDs and doesn't match the trust policy | Set `github_oidc_sub_prefix` from `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`, then `terraform apply`. Rejected claims are visible in CloudTrail under `AssumeRoleWithWebIdentity`. |
| `EntityAlreadyExists: Provider with url https://token.actions.githubusercontent.com` | The account already has a GitHub OIDC provider | Set `create_github_oidc_provider = false`. The existing provider must list `sts.amazonaws.com` as a client ID. |
| Lightsail first boot does nothing; log shows `set: Illegal option -o pipefail` | Lightsail wraps user data in its own script, which runs under `sh` | Use POSIX-only syntax in `lightsail_user_data.sh`: `set -eux`, `[ ]` not `[[ ]]`. Don't "fix" Sonar's `[[` suggestion there. |
| `sha256sum: no properly formatted checksum lines found` | Artifactory answers `<file>.sha256` with its own bare checksum | Verify against the hash passed from the `package` job (current design) |
| `ssh: connect to host … port 22: Connection timed out`, or `ssh-keyscan` returns nothing | The instance was replaced (new host, maybe no static IP attached), or keyscan is blocked | Check `aws lightsail get-static-ip`. Re-capture `LIGHTSAIL_KNOWN_HOSTS` from a verified login. |
| `Permission denied` reading `/opt/notesy` or `/etc/notesy/notesy.env` as `ubuntu` | Those paths belong to the `notesy` user, and the env file is `640 root:notesy` | Use `sudo`. The pipeline uses `sudo grep` so it doesn't append duplicate settings. |
| ACM validation "still creating" for many minutes | The DNS validation CNAME was never created | Create the record from `aws acm describe-certificate` (or use the Route 53 version of `acm.tf`), then check `dig CNAME <validation-name>`. |
| Lightsail HTTPS returns `000` right after opening ports | Caddy was still retrying the certificate request with backoff | Wait a minute, check `journalctl -u caddy`, or `sudo systemctl restart caddy` |
| Terraform always wants to replace `aws_lightsail_instance_public_ports` | Provider treats unspecified CIDR fields as unknown | Set `cidrs` and `ipv6_cidrs` explicitly (and `cidr_list_aliases = []` if needed) |
| Django returns 400 on health checks or a new domain | Host missing from `DJANGO_ALLOWED_HOSTS` | ECS: set `app_domain` and push. Lightsail: set `LIGHTSAIL_DOMAIN`. The ALB task IP is added automatically. |
| Login form fails with a CSRF error over HTTPS | Missing `DJANGO_CSRF_TRUSTED_ORIGINS` or `DJANGO_BEHIND_TLS_PROXY` | Both are set by Terraform (ECS) and the deploy job (Lightsail). Check the task definition env and `/etc/notesy/notesy.env`. |
| SonarCloud gate fails on `new_security_rating` after an infra or pipeline change | New lab-level findings in changed files | List them with `api/issues/search?inNewCodePeriod=true`. Fix what's real, and accept the rest with a comment. |
| Pipeline fails at the Vault step after the JFrog host rebooted | Vault uses file storage and comes back sealed | `vault operator unseal <unseal key from vaultkey.txt>` with `VAULT_ADDR` set |

---

## 9. Security notes and known limitations

- **JFrog, Vault and SonarQube run over plain HTTP** on a public IP, so credentials cross the internet unencrypted. Beyond a lab, put them behind TLS and restrict their security group. The `jfrog-install` instance role has `AdministratorAccess`, which should be scoped down.
- **The JFrog host has no Elastic IP.** A stop/start or rebuild changes `JFROG_URL` and `VAULT_ADDR`.
- **Caddy is installed by hand** on the Lightsail box, not by `lightsail_user_data.sh`. A replaced instance needs the Caddy step again, until it's added to the bootstrap script.
- **SSH on Lightsail is open to `0.0.0.0/0`**, because GitHub-hosted runner IPs aren't fixed. Access is key-only, and the host key is pinned.
- **Secrets removed from the repo** (the old `.env` with `SUMMARIZER_API_KEY`) remain in git history and must be rotated. `jfrog-install` commits the JFrog password in `terraform.tfvars`, so rotate it in JFrog and Vault together.
- **Summarizer.** `SUMMARIZER_API_KEY` and `SUMMARIZER_URL` are plumbed through Secrets Manager but unused. The summarize view is a stub.
- **Cost.** The ALB, RDS, Fargate and Lightsail bill continuously. For a lab, run `terraform destroy` in `infra/` and `jfrog-install` when finished. Route 53 hosted zones and records are billed separately.
