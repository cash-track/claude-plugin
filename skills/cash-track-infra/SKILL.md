---
name: cash-track-infra
description: Work with and debug Cash-Track infrastructure on DigitalOcean. Use this skill whenever investigating incidents, alerts, service outages (502/500), container restarts, MySQL or backup failures, disk/memory pressure, Tailscale access issues, Traefik routing problems, Ofelia job failures, observability stack issues (Grafana, Prometheus, Loki, Tempo), Terraform state or reprovisioning problems, Ansible playbook failures, or any production cloud infrastructure issue in the Cash-Track stack. Invoke before SSHing into prod or running any `make` infra command. Also covers local Ansible and Terraform lint conventions before running playbooks.
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
- **Cron job conflict?** — Ofelia log in Loki: `{container="ofelia"}` — did a backup, purge, or maintenance job overlap with peak traffic?
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

Post the report as a GitHub issue in `cash-track/infra` with label `incident` so it's searchable. This also serves as the audit trail if the same pattern recurs.

### 7. Capture the Case in This Skill

After every non-trivial incident, update the "Common Failure Patterns" section of this skill with:
- The symptom that presented
- The root cause found
- The exact commands that diagnosed it

This converts institutional knowledge into a repeatable playbook. Use the `cash-track-infra` skill itself or edit this file directly. For broader design decisions or architectural changes discovered during the incident, update `./infra/docs/design.md` as well.

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
| crashers-bot, home-exporter, mysql-backup-crashers | `docker-telegram` | `compose.telegram.yml` |

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
| `HTTPServiceHighResponseLatency` | p90 >1s for 2m | warning | API/gateway logs, DB query latency |
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
{container="api"}

# Errors only:
{container="api"} |= "error" | logfmt

# Ofelia scheduled job results:
{container="ofelia"}

# MySQL backup execution:
{container="mysql-backup"}

# Traefik access log (all 5xx):
{container="traefik"} |= "\"status\":5"

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
# Loki query in Grafana: {container="ofelia"}
# Prometheus metric: ofelia_job_failures_total
```

### Potwora (WordPress) container `unhealthy` + `potwora.com.ua` returns "404 page not found"

The `potwora` / `potwora-backup` services live in `compose.potwora.yml`; use the
`docker-potwora` wrapper (core + potwora), e.g. `./infra/ssh-prod docker-potwora ps`.
The compose file defines **no** healthcheck — `unhealthy` comes from the
`serversideup/php:8.1-fpm-apache` image's built-in check (`curl localhost:8080`).

A plain-text "404 page not found" is **Traefik's** default response (no live
upstream), not a WordPress/Apache 404 — so the container, not WordPress, is the
problem.

```bash
./infra/ssh-prod docker-potwora ps                         # look for "(unhealthy)"
./infra/ssh-prod docker-potwora logs --tail=80 potwora     # the smoking gun ↓
# potwora-1 | mktemp: failed to create directory via template
#            '/var/run/apache2/socks.XXXXXXXXXX': Permission denied
./infra/ssh-prod 'docker exec cashtrack-potwora-1 sh -c "id; ls -ld /var/run/apache2"'
# id => www-data (uid 33);  dir => drwxr-xr-x root root   ← the mismatch
./infra/ssh-prod 'docker inspect cashtrack-potwora-1 --format "{{json .State.Health}}"'
# FailingStreak high, Output: "Failed to connect to localhost port 8080"
```

**Root cause:** `compose.potwora.yml` mounts a `tmpfs` over `/var/run/apache2`
(added in `ad77f54` to clear a stale `apache2.pid`). The tmpfs comes up
`root:root 0755`, but Apache runs as **www-data (uid 33)** and can't create its
FastCGI socket dir → Apache never binds 8080 → healthcheck fails → Traefik 404.
Deterministic on every container recreate; a plain `restart` does NOT fix it
(re-mounts root-owned).

**Immediate mitigation** (no redeploy — the Apache run-script retry-loops, so it
binds within seconds of the dir becoming writable):
```bash
./infra/ssh-prod 'docker exec -u 0 cashtrack-potwora-1 chmod 0777 /var/run/apache2'
# verify: container goes healthy, https://potwora.com.ua => 200
```

**Permanent fix** (already applied): tmpfs in long form with `mode: 0777` in
`compose/compose.potwora.yml`, then `make -C infra deploy` (or
`gh workflow run ansible-apply.yml --repo cash-track/infra -f tags=compose`).
If it ever recurs after a deploy, confirm the rendered mode survived:
`docker compose ... config | grep -A4 tmpfs` should show `mode: 511` (octal 0777).

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
