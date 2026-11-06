---
name: infra
description: Work with and debug Cash-Track infrastructure on DigitalOcean such as incidents, alerts, 502/500 outages, container restarts, MySQL and backup failures, disk or memory pressure, Tailscale, Traefik, Ofelia, the Grafana/Prometheus/Loki/Tempo stack, Terraform, and Ansible. Invoke before SSHing into prod or running any infra `make` command. Also covers local Ansible and Terraform lint conventions.
---

# Cash-Track Infrastructure Debugger

## Architecture at a Glance

Single DigitalOcean droplet (`s-4vcpu-8gb`, AMS3) running Docker Compose, fronted by Traefik. Traffic flow:

```
User → Cloudflare (TLS/WAF) → Reserved IP → Droplet → Traefik → Services
```

Persistent state lives on a Block Volume at `/mnt/data/`. Access is via Tailscale (`ops@cashtrack-prod-0`).

Full design rationale and all sizing/retention numbers: `./infra/docs/design.md`
Operational runbook and service-specific commands: `./infra/README.md`

---

## Investigation Workflow

Follow these steps in order for any incident. Don't skip straight to mitigation — evidence collected upfront prevents misdiagnosis and repeated incidents.

### 0. Search Past Incidents

Past incidents are stored as GitHub issues in `cash-track/infra` with the label `incident`, not in this skill. Before diagnosing, search them for the alert name, service, or symptom. A match often has the diagnosis commands and the fix ready to use.

```bash
gh issue list --repo cash-track/infra --label incident --state all --search "<AlertName or service or symptom>"
gh issue view <number> --repo cash-track/infra
```

Search several terms if the first one misses: the alert name (`HTTPServiceHighClientErrorRate`), the Traefik service (`gateway@docker`), and the symptom (`401`, `unhealthy`, `404 page not found`). A closed match whose symptom is back means either the fix regressed or the root cause is different. Confirm which one before you reuse the old fix.

### 1. Collect Evidence

Before touching anything, snapshot the current state. This prevents you from destroying the evidence you need.

```bash
# Container state overview
./infra/ssh-prod docker-all ps

# Recent logs across all services (last 5 minutes)
./infra/ssh-prod docker-all logs --since=5m 2>&1 | grep -i "error\|fatal\|panic\|oom"

# Host resource snapshot
./infra/ssh-prod free -h
./infra/ssh-prod df -h /mnt/data /
./infra/ssh-prod cat /proc/pressure/memory

# Recent OOM kills
./infra/ssh-prod dmesg | grep -i oom | tail -10
```

Also check:
- **Prometheus Alerts** — `http://ct-prod-prometheus` → Alerts (what is currently firing and since when)
- **Loki** — Grafana → Explore → `{container=~".+"} |= "error"` filtered to the incident window
- **What changed recently** — `gh run list --repo cash-track/<service>` or check Telegram deploy notifications

### 2. Identify Functional Area

Use the evidence from step 1 to determine what layer is affected before acting.

| Symptom | Likely area |
|---|---|
| One service returns 502/500 | Service-level — its logs |
| All services unreachable | Traefik / Docker daemon / droplet |
| Droplet unreachable via Tailscale | Network / droplet gone |
| Telegram alert from Alertmanager | Check alert rule table below |
| MySQLBackupStale alert | Ofelia scheduler or mysql-backup container |
| High memory / PSI alert | Host-level OOM — check `oom_score_adj` order |
| BlockVolumeIOPSSaturated | MySQL + obs stack contending on Block Volume |
| HostRebootRequired >7d | `04:00 UTC` reboot window missed |
| Terraform unexpected changes | State drift — `make plan` to confirm before touching |
| Ansible playbook failure | Check role output, tags, inventory |

Key question to answer before moving on: **Is this isolated to one service, or systemic?** Systemic failures point to Traefik, Docker daemon, host resources, or the Block Volume. Isolated failures point to that service's config, image, or dependencies.

### 3. Immediate Mitigation

Restore service as fast as possible. Work from least-disruptive to most.

**Level 1 — Service restart (10–30s)**
```bash
./infra/ssh-prod docker-all logs --tail=200 <service>
./infra/ssh-prod docker-app restart <service>
```
If a recent deploy caused it, roll back first:
```bash
gh workflow run deploy.yml --repo cash-track/<service> -f tag=<previous-tag>
```

**Level 2 — Docker daemon (30–60s)**
```bash
./infra/ssh-prod sudo systemctl restart docker
./infra/ssh-prod docker-all up -d
```

**Level 3 — OS power-cycle (60–120s)**
```bash
doctl compute droplet-action power-cycle <droplet-id>
```

**Level 4 — Full droplet replacement (5–8 min RTO)**
```bash
cd infra && make replace
```
`make replace` requires user confirmation — never run it autonomously. MySQL data survives (Block Volume). Redis is lost (accepted). Cloudflare DNS never changes.

### 4. Root Cause Analysis

Once service is restored, determine why it happened. Without this step, the same incident recurs.

Look for changes in the relevant time window:
- **Deploy/config change?** — Check `gh run list` and Telegram deploy notifications
- **Resource exhaustion?** — Grafana: memory/CPU/disk trend leading up to the event; `dmesg` for OOM kills
- **Cron job conflict?** — Ofelia log in Loki: `{service="ofelia"}` — did a backup, purge, or maintenance job overlap with peak traffic?
- **External dependency?** — Cloudflare status, DigitalOcean status, 1Password availability (for deploys)
- **Gradual drift?** — Block Volume approaching capacity, Prometheus retention cap not holding, Redis maxmemory eviction storm

In Grafana, zoom to the incident window and look at the overview dashboard. Correlate the moment service degraded with any metric spike (memory, IOPS, connection count, error rate).

For traces: Grafana → Explore → Tempo — find requests from the incident window and look for slow spans.

### 5. Permanent Fix

Mitigations buy time. If the root cause requires more than a restart:

- **Quick fix available** (config change, image rollback, secret rotation): implement it, deploy via `make deploy` or `gh workflow run`, verify with post-incident checklist below.
- **Fix requires code change**: open an issue/PR in the relevant repo with the root cause documented. Don't leave a temporary workaround running without a tracked follow-up.
- **Systemic capacity issue** (memory, disk, IOPS consistently near limits): document the resize plan (`terraform.tfvars` change) and schedule it — don't wait for the next incident.

### 6. Write the RCA Report

Every non-trivial incident (anything that affected users or required manual intervention) deserves a brief RCA report. Use this structure:

```
## RCA: <short title>

**Date/time:** <when it started and ended>
**Duration:** <how long users were affected>
**Severity:** <critical / warning / informational>

### What happened
One paragraph: what broke, what users experienced, when it was detected.

### Timeline
- HH:MM — <event>
- HH:MM — <action taken>
- HH:MM — <service restored>

### Root cause
The specific technical reason it happened. Not "mysql was down" — the reason mysql went down.

### Contributing factors
Conditions that made the failure possible or worse (capacity headroom, missing alert, missing retry logic, etc.)

### Fix applied
What was done to restore service.

### Follow-up actions
- [ ] <concrete task with owner and deadline>
- [ ] <e.g., raise mem_limit for api, open PR in cash-track/api>
```

Post the report as a GitHub issue in `cash-track/infra` with label `incident`. Step 0 depends on these issues being searchable, so:
- **Title:** `RCA: <AlertName> on <service> (<root cause in a few words>)`. Put the alert name and the Traefik service in the title, because those are what the next responder will search for.
- **Body:** include the exact diagnosis commands and their tell-tale output, in addition to the RCA sections above. That turns the issue into a reusable playbook.
- **Recurrence:** if step 0 found the same root cause, comment on that issue with the new dates and evidence, and reopen it if the fix failed. Don't open a duplicate.
- **Close** the issue once the follow-ups are done or tracked elsewhere. Step 0 searches all states.

### 7. Update This Skill Only With Reusable Knowledge

Don't add incident write-ups to this skill. They belong in the issue. Edit this file only when the incident taught something that applies beyond the incident itself: a new or changed alert, a service or wrapper missing from the tables, a diagnosis command that's wrong, or a logging gotcha. For design decisions or architectural changes, update `./infra/docs/design.md`.

---

## Escalation Ladder

Reference for step 3. Work from least-disruptive to most. Never jump straight to `make replace`.

### Level 1 — Service-level (10–30s recovery)

```bash
./infra/ssh-prod docker-all ps
./infra/ssh-prod docker-all logs --tail=200 <service>
./infra/ssh-prod docker-app restart <service>
```

### Level 2 — Docker daemon (30–60s recovery)

```bash
./infra/ssh-prod sudo systemctl restart docker
./infra/ssh-prod docker-all up -d
```

### Level 3 — OS-level, droplet reachable (60–120s recovery)

```bash
doctl compute droplet-action power-cycle <droplet-id>
# Wait, then verify Tailscale rejoins before proceeding
```

### Level 4 — Droplet gone or unrecoverable (5–8 min RTO)

```bash
cd infra && make replace
```

`make replace` runs the backup-freshness preflight, Terraform-replaces the droplet, reattaches the Block Volume + Reserved IP, and re-runs `ansible-playbook site.yml`. MySQL data survives (same volume). Redis is lost (accepted). Cloudflare DNS never changes.

Important! Never run this without user confirmation.

---

## Service → Compose File Mapping

| Services | SSH wrapper | Compose file |
|---|---|---|
| traefik, mysql, redis, ofelia | `docker-core` | `compose.core.yml` |
| api, gateway, frontend, website, mysql-backup, mysql-exporter | `docker-app` | `compose.app.yml` |
| prometheus, loki, tempo, grafana, alertmanager, promtail, node-exporter, cadvisor, otel-collector | `docker-obs` | `compose.obs.yml` |
| crashers-bot, home-exporter, mysql-backup-crashers, recipes-bot | `docker-telegram` | `compose.telegram.yml` |
| potwora, potwora-backup (WordPress, potwora.com.ua) | `docker-potwora` (core + potwora) | `compose.potwora.yml` |

All wrappers accept standard `docker compose` args. Run them remotely via `./infra/ssh-prod <wrapper> <args>`.

---

## Access

```bash
./infra/ssh-prod                          # Tailscale SSH as `ops`, drops into /opt/cashtrack
tailscale ssh ops@cashtrack-prod-0        # explicit form

# If Tailscale is unavailable:
make -C infra ssh-open                    # opens TCP 22 for your current public IP
ssh root@<reserved-ip>
make -C infra ssh-close                   # close it when done
```

Internal services exposed on the tailnet only:

| Service | Address |
|---|---|
| Grafana | `http://ct-prod-grafana:8081` |
| Prometheus | `http://ct-prod-prometheus` |
| Alertmanager | `http://ct-prod-alertmanager` |
| MySQL | `tcp://ct-prod-mysql:3306` |
| Redis | `tcp://ct-prod-redis:6379` |

---

## Observability Debugging

### Grafana (primary investigation tool)

Access: `http://ct-prod-grafana:8081` (tailnet). Pre-provisioned dashboards: overview, Traefik, API latency, MySQL, Redis, Node, Ofelia jobs.

Start here for any performance or trend investigation — Grafana correlates metrics, logs, and traces in one view.

```bash
# If Grafana itself is down:
./infra/ssh-prod docker-obs logs grafana
./infra/ssh-prod docker-obs restart grafana
# Data dir:
./infra/ssh-prod ls -la /mnt/data/grafana
```

### Prometheus (metrics and alerts)

Access: `http://ct-prod-prometheus` (tailnet). UI → Status → Targets to see scrape health. UI → Alerts to see currently firing rules.

Scrape jobs and their targets:

| Job | Container:port | What it covers |
|---|---|---|
| `api` | `api:2112` | Spiral framework + PHP metrics |
| `gateway` | `gateway:8081` | Go HTTP metrics |
| `traefik` | `traefik:8080` | Request rates, 5xx, latency per service |
| `node-exporter` | `host.docker.internal:9100` | Host CPU, memory, disk, PSI, network |
| `mysql-exporter` | `mysql-exporter:9104` | MySQL connections, query time, replication |
| `cadvisor` | `cadvisor:8080` | Per-container CPU, memory, restarts |
| `loki` | `loki:3100` | Loki ingestion and compaction |
| `tempo` | `tempo:3200` | Tempo ingestion |
| `alertmanager` | `alertmanager:9093` | Alertmanager health |

```bash
# Reload Prometheus config without restart (e.g., after editing rules):
./infra/ssh-prod curl -X POST http://localhost:9090/-/reload
# Or on tailnet:
curl -X POST http://ct-prod-prometheus/-/reload
```

**Key alert rules** (defined in `./infra/compose/config/prometheus/rules/`):

| Alert | Condition | Severity | First action |
|---|---|---|---|
| `ServiceContainerDown` | Container not seen by cAdvisor >2m | critical | `docker-all ps`, check logs |
| `ServiceContainerRestarting` | Container restarted >2× in 30m | warning | `docker-all logs --tail=100 <svc>` |
| `HTTPServiceHighServerErrorRate` | 5xx rate >20% for 5m | critical | Traefik logs, then service logs |
| `HTTPServiceHighClientErrorRate` | 4xx other than 404 >80% of requests for 5m | info | Group by code first; at low traffic, one client can dominate. Get the client IP from the gateway log (see Loki) |
| `HTTPServiceHighResponseLatency` | p90 of non-4xx >1s for 2m | warning | API/gateway logs, DB query latency; website only → check incident issues for scanner bursts |
| `GatewayUpstreamErrorRateHigh` | >20% of gateway→API calls failing for 10m | warning | `docker-app logs api`, then gateway logs |
| `GatewayUpstreamLatencyHigh` | gateway→API p95 >1s for 10m | warning | API latency dashboard, DB query latency |
| `GatewayTokenRefreshFailing` | refresh rejections >0.1/s for 15m | warning | Gateway logs, API auth logs |
| `AppLoginFailureRateHigh` | >70% of logins failing for 15m | warning | API auth logs; credential stuffing vs. a broken login path |
| `AppUserGaugeMissing` | `app_users` absent while API is up for 30m | warning | API metrics endpoint `api:2112` |
| `PrometheusTargetMissing` | `up == 0` for 15m | warning | Prometheus → Status → Targets |
| `HostDataVolumeElevated` | `/mnt/data` >80% full for 5m | warning | `du -sh /mnt/data/*` before it hits 90% |
| `RecipesBotJobFailures` | any failed recipes-bot job in 1h | warning | `docker-telegram logs recipes-bot` |
| `MySQLExporterDown` | `up{job="mysql-exporter"} == 0` for 5m | critical | `docker-core ps mysql mysql-exporter` |
| `TraefikDown` | Traefik metrics endpoint down for 5m | critical | `docker-core logs traefik` |
| `HostMemoryPressure` | PSI >10% for 2m | warning | `docker stats`, check for OOM kills |
| `NodeHighMemoryUsage` | Available <10% for 30m | warning | `free -h`, consider resize |
| `HostRebootRequired` | `node_reboot_required == 1` for 7d | warning | `sudo reboot` (post-reboot check runs automatically) |
| `MySQLBackupStale` | Last backup >6h ago | critical | Ofelia + mysql-backup logs |
| `BlockVolumeIOPSSaturated` | IO util >80% for 15m | warning | `iostat -x 5`, check MySQL/Loki/Prom concurrency |
| `HostDataVolumeFull` | `/mnt/data` >90% full | critical | `du -sh /mnt/data/*`, prune or resize volume |
| `HostRootDiskFull` | `/` >90% full | warning | `docker system prune -af` |
| `NodeHighCPUUsage` | CPU >90% for 30m | warning | `docker stats`, consider resize |

```bash
# Useful Prometheus queries on tailnet:
# Container memory usage vs limit:
# container_memory_usage_bytes / container_spec_memory_limit_bytes * 100

# API request rate:
# sum(rate(traefik_service_requests_total{service="api@docker"}[5m]))

# MySQL connections:
# mysql_global_status_threads_connected
```

### Loki (container logs)

Access: Grafana → Explore → Loki datasource. All container stdout is shipped by Promtail via Docker socket.

**Common LogQL queries:**

```logql
# All logs from a container:
{service="api"}

# Errors only:
{service="api"} |= "error" | logfmt

# Ofelia scheduled job results:
{service="ofelia"}

# MySQL backup execution:
{service="mysql-backup"}

# Traefik access log (all 5xx). The log is plain text, not JSON: `"GET /path HTTP/2.0" 502 ...`
{service="traefik"} |~ `HTTP/[0-9.]+" 5[0-9]{2} `

# Gateway (JSON). The real client IP is only here: Traefik and Loki's traefik stream have the Cloudflare edge IP.
{service="gateway"} | json | status = 401

# All containers, last 15 minutes of errors:
{container=~".+"} |= "error" | logfmt | level = "error"
```

```bash
# If Loki is down (OOM is the most common cause — oom_score_adj=500):
./infra/ssh-prod docker-obs logs loki
./infra/ssh-prod docker-obs restart loki
./infra/ssh-prod ls -la /mnt/data/loki
# If Loki data directory is corrupted, Loki logs will show WAL/chunk errors.
# Retention: 168h (7d). If disk full, loki compactor should have cleared old chunks.
```

### Tempo (distributed traces)

Access: Grafana → Explore → Tempo datasource. Traces from `api`, `gateway`, `website` (OTLP via gRPC `:4317` → otel-collector → Tempo).

The `otel-collector` sidecar drops healthcheck spans before they reach Tempo. Retention: 72h (3d).

```bash
# If Tempo is not receiving traces:
./infra/ssh-prod docker-obs logs tempo
./infra/ssh-prod docker-obs logs otel-collector
./infra/ssh-prod docker-obs restart tempo otel-collector
# Note: otel-collector shares network_mode with tempo — restart both together.
```

---

## Terraform Debugging

Terraform manages: DigitalOcean droplet, Block Volume (`prevent_destroy`), Reserved IP (`prevent_destroy`), Firewall (CF IP ranges). State lives in Spaces (`cash-track-tfstate`).

### Before anything: check what Terraform sees

```bash
cd infra && make plan   # runs `terraform -chdir=terraform plan`
```

Never run `make apply` without reviewing `plan` output first — the Block Volume and Reserved IP have `prevent_destroy`, but the droplet does not.

### State lock issues

```bash
# If a plan/apply is stuck with "state locked":
cd infra/terraform && terraform force-unlock <lock-id>
# Get the lock ID from the error message. Verify no other apply is running in CI first.
# CI guard: concurrency group `terraform-prod` in GitHub Actions should prevent concurrent applies.
```

### Drift — resource changed outside Terraform

```bash
# Refresh state only (no apply):
cd infra/terraform && terraform refresh
make plan  # see what has drifted
```

### Firewall out of sync with Cloudflare IP ranges

```bash
make -C infra firewall-refresh
# This runs: terraform apply -target=module.firewall -refresh=false -auto-approve
# Safe to run anytime — only touches the firewall rule set.
```

### Viewing Terraform outputs (droplet ID, Reserved IP, Tailscale hostname)

```bash
cd infra/terraform && terraform output
terraform output -raw tailscale_hostname   # e.g. cashtrack-prod-0
terraform output -raw reserved_ip
```

### Droplet resize

Edit `terraform/terraform.tfvars` → change `droplet_size` → `make -C infra apply`. Uses the same replacement mechanics as `make replace` (5–8 min RTO). The Block Volume and Reserved IP survive.

### Backend credentials (not in git)

`terraform/backend.hcl` must be present and rendered from 1Password before `terraform init`. If missing:

```bash
eval "$(op signin)"
cat > infra/terraform/backend.hcl <<EOF
endpoints = { s3 = "https://ams3.digitaloceanspaces.com" }
access_key = "$(op read op://cash-track-prod/cash-track-tfstate/ACCESS_KEY_ID)"
secret_key = "$(op read op://cash-track-prod/cash-track-tfstate/SECRET_ACCESS_KEY)"
skip_credentials_validation = true
skip_metadata_api_check = true
skip_requesting_account_id = true
skip_region_validation = true
skip_s3_checksum = true
use_path_style = true
EOF
chmod 600 infra/terraform/backend.hcl
export DIGITALOCEAN_TOKEN="$(op read op://cash-track-prod/do-api/TOKEN)"
cd infra/terraform && terraform init -backend-config=backend.hcl
```

### Terraform + Ansible — when to use which

| Problem | Tool |
|---|---|
| DO resource doesn't exist / wrong size / wrong region | Terraform |
| Cloudflare IPs out of sync with DO Firewall | Terraform (`make firewall-refresh`) |
| Container not running / wrong image / wrong config | Ansible (`make deploy`) or direct SSH |
| OS config drift (swap, sysctls, docker daemon) | Ansible (`make bootstrap`) |
| Droplet replacement (DR) | Terraform + Ansible combined (`make replace`) |

---

## Common Failure Patterns

### Service returns 502

```bash
./infra/ssh-prod docker-all logs --tail=200 <service>
./infra/ssh-prod docker-all restart <service>
# If 502 is from Traefik (no upstream):
./infra/ssh-prod docker-core logs --tail=100 traefik
```

A plain-text `404 page not found` is Traefik's response when no router has a healthy upstream. It doesn't come from the app. Check whether the container is `(unhealthy)`, because Traefik drops unhealthy containers from routing:
```bash
./infra/ssh-prod docker-all ps | grep -i unhealthy
./infra/ssh-prod 'docker inspect <container> --format "{{json .State.Health}}"'
```

### MySQL won't start / healthcheck failing

```bash
./infra/ssh-prod docker-core logs mysql
./infra/ssh-prod docker-core exec mysql mysqladmin ping -h 127.0.0.1
# Check Block Volume is mounted and has data:
./infra/ssh-prod df -h /mnt/data
./infra/ssh-prod ls -la /mnt/data/mysql
```

If the volume filesystem itself is corrupt, `make replace` will **not** help — it reattaches the same volume. See `./infra/docs/design.md` §15 for the separate Block Volume corruption runbook.

### Backup stale (MySQLBackupStale alert)

```bash
./infra/ssh-prod docker-all logs ofelia           # check scheduler fired
./infra/ssh-prod docker-all logs mysql-backup     # check execution
./infra/ssh-prod docker-all exec mysql-backup php app.php backup   # trigger manually
./infra/ssh-prod docker-all exec mysql-backup php app.php list     # list stored backups
```

Backup metric: `mysql_backup_last_success_timestamp_seconds` in node-exporter textfile at `/mnt/data/node-exporter-textfile/`.

### High memory / OOM

```bash
./infra/ssh-prod docker stats --no-stream
./infra/ssh-prod free -h
./infra/ssh-prod cat /proc/pressure/memory        # PSI
./infra/ssh-prod dmesg | grep -i oom | tail -20   # recent OOM kills
```

Expected OOM death order by `oom_score_adj`: Loki/Tempo/cadvisor/otel-collector (500, first) → Prometheus/Grafana/Alertmanager/promtail (300) → node-exporter/ofelia/mysql-backup (0) → api/gateway/redis (-200) → traefik (-300) → MySQL (-500, last).

If PSI stays elevated for hours: resize to `s-4vcpu-16gb` via `terraform.tfvars` + `make -C infra apply`.

### Full disk on Block Volume

```bash
./infra/ssh-prod df -h /mnt/data
./infra/ssh-prod du -sh /mnt/data/*
./infra/ssh-prod docker system df
./infra/ssh-prod docker system prune -af --filter until=168h
```

Retention caps enforced at process level: Prometheus 7d / 3 GB, Loki 168h, Tempo 72h. If a cap isn't holding, check `./infra/compose/config/{prometheus,loki,tempo}/`. Volume resize requires editing `terraform.tfvars` (`volume_size_gb`) and running `make -C infra apply`.

### Traefik not routing / TLS error

```bash
./infra/ssh-prod docker-core logs traefik
./infra/ssh-prod openssl x509 -enddate -noout \
  -in /opt/cashtrack/config/traefik/origin-cert.pem
make -C infra traefik-cf-refresh    # refresh Cloudflare IP allowlist
```

### Droplet unreachable via Tailscale

```bash
tailscale status | grep cashtrack
make -C infra ssh-open              # open TCP 22 for your IP
ssh root@<reserved-ip>
sudo tailscale status
sudo systemctl status tailscaled
```

### Ofelia jobs not running

```bash
./infra/ssh-prod docker-all logs ofelia
# Loki query in Grafana: {service="ofelia"}
# Prometheus metric: ofelia_job_failures_total
```

### Anything not covered above

Incident-specific failures are kept as `incident` issues in `cash-track/infra`, not in this skill. Search them as described in step 0 of the Investigation Workflow.

---

## Deploying and Rolling Back

```bash
# Deploy a new image version to prod:
./infra/ssh-prod deploy-service <service> <tag>

# Rollback a service via GitHub Actions (no rebuild):
gh workflow run deploy.yml --repo cash-track/<service> -f tag=<old-tag>

# Secret rotation re-render (restarts only affected service):
gh workflow run ansible-apply.yml --repo cash-track/infra -f tags=compose
```

`/opt/cashtrack/.env` is a symlink to `/mnt/data/cashtrack.env` (survives droplet replacement). `VERSION_*` lines are updated in place by `deploy-service`. If you add a new `VERSION_*` to `env.tpl`, seed it manually after `make deploy`:

```bash
./infra/ssh-prod "echo 'VERSION_NEWSERVICE=1.0.0' >> /mnt/data/cashtrack.env"
```

---

## Re-provisioning Triggers

| What changed | Command |
|---|---|
| `compose/*.yml` or `compose/config/` | `make -C infra deploy` |
| `ansible/roles/{base,docker,tailscale,volume,mysql-init}/` | `make -C infra bootstrap` |
| `terraform/` (non-firewall) | `make -C infra plan && make -C infra apply` |
| Cloudflare IP ranges | `make -C infra firewall-refresh` |
| Traefik trusted-proxy CF IPs | `make -C infra traefik-cf-refresh` |

---

## Post-Incident Verification

After any recovery:

1. `./infra/ssh-prod docker-all ps` — all services `Up (healthy)` where applicable
2. `curl https://api.cash-track.app/healthcheck`
3. `./infra/ssh-prod tailscale status` — droplet listed in tailnet
4. Prometheus → Alerts — no active critical alerts firing
5. Grafana: MySQL connections, API p95, Traefik 5xx rate back to baseline

---

## Full Reference

- Architecture & design decisions: `./infra/docs/design.md`
- Operational runbook & commands: `./infra/README.md`
- Compose files: `./infra/compose/`
- Prometheus alert rules: `./infra/compose/config/prometheus/rules/`
- Ansible playbooks: `./infra/ansible/`
- Terraform modules: `./infra/terraform/`

---

## Local Ansible and lint conventions

- Run `ansible-playbook` and `ansible-lint` from `infra/ansible/` — `ansible.cfg` uses a relative inventory path
- Offline syntax / lint: `TF_OUTPUT='{"reserved_ip":{"value":"192.0.2.1"},"droplet_id":{"value":"123456"},"tailscale_hostname":{"value":"cashtrack-prod"},"volume_id":{"value":"vol-abc123"}}' ansible-playbook site.yml --syntax-check`
- `ansible-lint` from Homebrew has its own Python and ignores `brew install ansible` collections — export `ANSIBLE_COLLECTIONS_PATH=/opt/homebrew/Cellar/ansible/$(brew list --versions ansible | awk '{print $2}')/libexec/lib/python3.14/site-packages/ansible_collections:$HOME/.ansible/collections/ansible_collections` or modules resolve as missing
- `var-naming[no-role-prefix]` at the `production` profile fails any `register:`/`set_fact:` inside a role that isn't prefixed with the role name (`volume_data_mount`, not `data_mount`)
- `ansible-lint .` silently reports "0 files processed of 1 encountered" — pass an explicit file list to get real coverage
- `production` profile: handler/task names must be Title-cased (`Restart api`, not `restart api`); `notify:` strings must match exactly
- `production` profile: `name[template]` requires jinja at the **end** (`for /32 of {{ ip }}`, not `for {{ ip }}/32`); aligned inline dicts trip `yaml[commas]`/`yaml[colons]` — one space only
- `community.docker.docker_compose_v2` uses `state: restarted` (not `restarted: true` as the design doc shows)
- Role `copy:` `src:` searches `<role>/files/` first; for files outside the role tree, anchor with `{{ playbook_dir }}/../...` not bare `../../...`
- `mysql` container in `compose.core.yml` doesn't publish 3306 to the host — talk to it via `docker exec`, pass root password via `MYSQL_PWD` env (never argv), wrap every secret-touching task in `no_log: true`
- `secret_files` in `group_vars/all/main.yml` and `roles/compose-render/defaults/main.yml` are **bare names** (no `.env` suffix) — the role appends `.env.tpl` and `.env` at template-load and copy time
- DO firewall: `community.digitalocean.digital_ocean_firewall` is declarative (replaces the full ruleset → conflicts with terraform-managed firewall). For additive single-rule changes (e.g. `ssh-open`/`ssh-close`), POST/DELETE to `/v2/firewalls/{id}/rules` via `ansible.builtin.uri` instead
- `shellcheck` isn't installed locally; `bash -n <script>` is the parse-only fallback

---

## Kubernetes Services (current state being migrated)

This is the **pre-migration** stack that the Docker Compose migration (see the design doc and
implementation plan under `/infra/migration/`) is replacing — not the target architecture. The
rest of this skill assumes the Compose/Traefik topology described in "Architecture at a Glance"
above; use this list only when comparing old vs. new topology or tracing a service that hasn't
cut over yet.

Kubernetes services in `/infra/services/`: API, website, frontend, nginx gateway, MySQL
(StatefulSet), Redis (StatefulSet), MySQL backup, Prometheus, Grafana, Loki, Tempo, AlertManager,
Promtail, Node Exporter.

---

## Local Service Images

Top-level directories (siblings of `/api`, `/frontend`, `/infra`, outside the `/infra` repo
itself) holding Dockerfiles for cashtrack-owned images, built and pushed to Docker Hub as
`cashtrack/<name>`:

- `/mysql` — `cashtrack/mysql` (MySQL with tuned `my.cnf`)
- `/redis` — `cashtrack/redis`
- `/mysql-backup` — `cashtrack/mysql-backup` (PHP-based dump + S3 upload)
- `/certs` — local Traefik + dev TLS (`make start` brings up the dev reverse proxy)

Each has its own `Makefile`; `make build` / `make push` inside the directory.
