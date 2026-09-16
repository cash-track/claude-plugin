---
name: security-upgrade
description: |
  Find and fix dependency security vulnerabilities in one Cash-Track repository, then
  raise a remediation PR. Invoke to patch, triage, or upgrade vulnerable dependencies, or
  to resolve CVE, GHSA, advisory, or Dependabot findings, for `api`, `frontend`, `website`,
  `infra`, `gateway`, `mysql`, `redis`, `mysql-backup`, or `.github`. Takes ONE argument,
  the repository name.
---

# Cash-Track Security Upgrade

Detect dependency vulnerabilities in a single cash-track repo, remediate them, and open a
well-documented PR assigned to the maintainer. Driven by **one argument: the repository
name**.

## How this skill thinks

Use the **best available evidence**, not all of it. Walk three sources in order and stop at
the first that yields findings — this avoids redundant scanning and noise:

1. **Dependabot alerts** — curated, deduplicated, carry CVE/GHSA + the exact patched version. The richest signal; prefer it whenever present.
2. **Security-scan GitHub Action** — only if Dependabot is empty/disabled. The last run of a security-named workflow (e.g. `api`'s `security.yml`) or Code Scanning alerts.
3. **Local package-manager audit** — only if the first two are empty. The catch-all (`composer audit`, `npm audit`, `govulncheck`).

If all three are empty, report "no vulnerabilities found" and **open no PR**.

Two rules override momentum, always (see [Stop and ask](#stop-and-ask)):
- **Critical decisions → ask** before acting.
- **An upgrade that needs codebase changes → ask;** only if approved, make the change and **prove tests pass** before committing.

## Inputs & repo resolution

The single argument is the repo. Accept a bare component name or a `cash-track/<repo>` slug.
If no argument is given, ask which repo before touching anything. Resolve it against this map:

| Arg | Local path | GitHub repo | Default branch* | Ecosystem | Audit tool (fallback) |
|---|---|---|---|---|---|
| `api` | `./api` | `cash-track/api` | `master` | PHP / Composer | `composer audit --locked --format=json` |
| `frontend` | `./frontend` | `cash-track/frontend` | `master` | npm | `npm audit --json` |
| `website` | `./website` | `cash-track/website` | `master` | npm | `npm audit --json` |
| `gateway` | `${CASHTRACK_GATEWAY_PATH:-$(go env GOPATH)/src/github.com/cash-track/gateway}` | `cash-track/gateway` | `main` | Go modules | `govulncheck ./...` |
| `infra` | `./infra` | `cash-track/infra` | `main` | none (Actions/Docker/Terraform) | — (Dependabot only) |
| `mysql` | `./mysql` | `cash-track/mysql` | `master` | Docker base image | — (Dependabot only) |
| `redis` | `./redis` | `cash-track/redis` | `main` | Docker base image | — (Dependabot only) |
| `mysql-backup` | `./mysql-backup` | `cash-track/mysql-backup` | `main` | PHP / Composer (+ Docker base image) | `composer audit --locked --format=json` |
| `.github` | `./.github` | `cash-track/.github` | `main` | GitHub Actions | — (Dependabot only) |

\* Never trust the local branch — `frontend` is often on a migration branch. Resolve the
real default authoritatively:
```bash
gh repo view cash-track/<repo> --json defaultBranchRef -q .defaultBranchRef.name
```
If the arg isn't in the map, or the local path doesn't exist, **ask** (clone to a temp dir
only with approval).

## Hard rules

- **Never read any `.env*` file** (`.env`, `.env.local`, `.env.sample`, `.env.actions`, …) — they may hold real secrets. You don't need them for this task.
- **Never push to `master`/`main`.** All work lands on a new branch and a PR.
- **Never run `npm audit fix --force`** (or any blanket auto-fix that performs major bumps) without explicit approval — it silently breaks APIs.
- Confirm the repo is under the `cash-track` org before opening a PR.
- Respect the existing version-constraint and formatting style of each lockfile/manifest; make the **minimum** bump that clears the advisory.

## Workflow

**Detection (Phases 1–3) is read-only and creates no git state.** Cut a branch only once
there's actually something to fix — an all-clean repo should never get an orphan branch.
Track the phases as todos.

### Phase 1 — Resolve & fetch (read-only)

```bash
# Resolve the arg against the table → LOCAL path, REPO=cash-track/<name>, DEFAULT branch.
DEFAULT=$(gh repo view cash-track/<repo> --json defaultBranchRef -q .defaultBranchRef.name)
git -C <LOCAL> fetch origin "$DEFAULT"
```
Confirm the repo is under the `cash-track` org. No branch yet.

### Phase 2 — Dependabot (primary source, read-only)

The helper ships in the plugin's `bin/`, which Claude Code puts on `PATH`, so call it bare:
```bash
cash-track-dependabot-alerts cash-track/<repo>
```
It prints a severity-sorted table and writes normalized JSON to
`/tmp/cash-track-<repo>-dependabot.json`. Exit codes:
- `0` = open alerts → **this is your work list; go to Phase 4.**
- `3` = none, `4` = unavailable (disabled / no permission) → continue to Phase 3.

### Phase 3 — Security-scan GitHub Action (fallback, read-only)

Only if Phase 2 was empty. Structured Code Scanning alerts first, then the newest
security-named workflow run:
```bash
gh api repos/cash-track/<repo>/code-scanning/alerts \
  --jq '[.[] | select(.state=="open")]' 2>/dev/null          # CodeQL/SARIF uploaders, if any
gh workflow list --repo cash-track/<repo> | grep -iE 'security|scan|audit|codeql|trivy|snyk|vuln'
gh run list --repo cash-track/<repo> --workflow=<file.yml> -L 1 --json databaseId,conclusion,headSha
gh run view <run-id> --repo cash-track/<repo> --log | grep -iE 'CVE-|GHSA-|advisor|vulnerab'
```
`api` uses `security.yml` (Symfony `security-checker-action`) — its findings live in the run
log, not Code Scanning. If findings exist → Phase 4. Otherwise → Phase 4's local audit.

### Phase 4 — Cut the branch, then (if needed) run the local audit

Reached when Phase 2 or 3 found work, **or** both were empty and the repo has a package
manager. If both were empty **and** there's no package manager (`infra`, `.github`, `mysql`,
`redis`), nothing is left to check — report "no vulnerabilities found", open no PR, stop.

Cut the branch from the **remote** default so in-progress local commits/edits don't leak in:
```bash
cd <LOCAL>
git status --porcelain        # dirty? (frontend is often mid-migration)
#   → if dirty: STOP and ask — `git stash push -u` and restore at the end, or abort. Never silently stash.
git checkout -b security/deps-$(date +%Y%m%d) "origin/$DEFAULT"    # append -2, -3… if it exists
```
- **Work list already came from Phase 2/3** → skip to Phase 5.
- **Phases 2–3 were empty** → run the ecosystem's audit now, on this clean branch (see
  [reference](#ecosystem-reference)):
  - Findings → that's the work list; go to Phase 5.
  - Nothing → roll back cleanly: `git checkout -` then `git branch -D <branch>`, restore any
    stash, report "No vulnerabilities via Dependabot, security workflow, or `<tool>`", open no PR.

### Phase 5 — Remediate

For each vulnerable package, target the minimum version that clears the advisory (Dependabot's
`patched` field, or the audit tool's recommendation). Then per ecosystem (see
[reference](#ecosystem-reference)):

- **Direct dependency, patched within current major** → bump it directly.
- **Transitive dependency** → bump via the parent, or pin (`composer` constraint, npm `overrides`, `go get` of the transitive module). Prefer the narrowest pin.
- **No code change needed** → apply, regenerate the lockfile, move on.
- **Major/breaking bump, or the advisory note implies an API change** → this is a codebase change: **stop and ask** (see below).

After every fix, re-run the audit / `govulncheck` to confirm the advisory is actually gone —
a bump that doesn't clear it is worse than none.

### Phase 6 — Commit & open the PR

```bash
git add -A
git commit -m "fix(<scope>): patch <N> dependency security advisories"
git push -u origin <branch>

# Labels must exist before the PR references them (idempotent):
for l in dependencies security; do
  gh label create "$l" --repo cash-track/<repo> --color ededed --force >/dev/null 2>&1 || true
done

gh pr create --repo cash-track/<repo> --base "$DEFAULT" --head <branch> \
  --title "fix(<scope>): security dependency upgrades (<N> advisories)" \
  --assignee vokomarov --label dependencies --label security \
  --body-file /tmp/<repo>-pr-body.md
```
`<scope>` = the repo name (`api`, `gateway`, `website`, `frontend`, `infra`, …). Use the
[PR body template](#pr-body-template). Finally, restore any stash and return the local
checkout to its original branch, then report the PR URL to the user.

## Stop and ask

These need the operator's call — present the specifics, then wait:

- **Dirty working tree** in the local checkout → stash & continue, or abort?
- **Upgrade requires a codebase change** (major bump, removed/renamed API, breaking
  changelog) → state the package, current → target, and what code must change. If approved,
  make the change, then run the ecosystem's tests and **only commit once they pass**. Paste
  the passing test output into the PR.
- **No patched version exists** for an advisory → document as a known/deferred item and
  ask whether to ship the partial fix or hold.
- **Version-constraint conflict** the resolver can't satisfy → surface it; don't force.
- **A repo not checked out locally** → clone to a temp dir first? ask.

## PR body template

```markdown
## Security dependency upgrades — `<repo>`

Source of findings: **<Dependabot | `security.yml` run #<id> | `<audit tool>`>**

| Severity | Package | From → To | CVE / GHSA |
|---|---|---|---|
| Critical | `pkg/name` | 1.2.3 → 1.2.7 | CVE-… / GHSA-… |
| …        |           |               |            |

### What changed
- Bumped `<pkg>` to clear `<advisory>` (<link>).
- <Any manifest/lockfile notes — e.g. added an npm `override`, `go mod tidy`.>

### Codebase changes (if any)
- <Files touched and why; otherwise "None — dependency bumps only.">

### Verification
- `<test command>` → <pass/fail summary; paste output if code changed>.
- Re-ran `<audit tool>` → advisories cleared.

### Deferred / no fix available
- <pkg> — no patched release yet (<link>); tracking.
```

## Ecosystem reference

| Ecosystem | Audit (fallback) | Remediate | Tests (run if code changed) |
|---|---|---|---|
| **PHP / Composer** (`api`, `mysql-backup`) | `composer audit --locked --format=json` | direct: raise constraint in `composer.json` then `composer update <pkg> -W`; transitive: `composer update <pkg> -W`. CI uses Symfony security-checker. | `api`: `composer checks` (or at least `composer phpunit`) — needs the test stack per the api README/`tests/docker-compose.yml`. `mysql-backup`: re-run `composer audit`, `make build`, and any `composer` test script if defined |
| **npm** (`frontend`, `website`) | `npm audit --json` | direct: `npm install <pkg>@<ver>`; transitive: add `overrides` in `package.json` then `npm install`. Avoid `npm audit fix --force`. See [keeping `npm ci` passing](#keeping-npm-ci-passing-in-ci) below before regenerating the lockfile. | frontend: `npm run test:unit -- --run` + `npm run lint`; website: `npm run lint:js` + `npm run build` |
| **Go modules** (`gateway`) | `command -v govulncheck \|\| go install golang.org/x/vuln/cmd/govulncheck@latest`; then `govulncheck ./...` (reachability-aware) | `go get <module>@<patched>` then `go mod tidy` | `make test` |
| **Actions/Docker/Terraform** (`infra`, `.github`, `mysql`, `redis`) | none — rely on Dependabot (Phase 2) for action SHAs, base images, providers | bump pinned action SHAs / `FROM` base tags / TF provider versions / Ansible collections as the alert dictates | infra: `ansible-lint` + `ansible-playbook site.yml --syntax-check` (see the `cash-track:infra` skill, `## Local Ansible and lint conventions` section, for the env it needs); Docker repos: `make build` |

## Keeping `npm ci` passing in CI

CI runs `npm ci`, which strictly requires `package-lock.json` to match `package.json` and to
list every platform's optional native binaries, not just the ones installed locally. A
regenerated lockfile that passes local tests can still fail CI. To avoid that:

1. Delete `node_modules` before reinstalling, then run a full, unscoped `npm install`.
   Installing over an existing `node_modules`, or scoping the install to just the bumped
   package, can skip full dependency resolution and produce a lockfile missing entries other
   platforms need — this passes locally and only fails on CI's runner.
2. If `npm install` errors during dependency resolution, retry with the latest npm
   (`npx -y npm@latest install`) — some npm versions have resolver bugs on certain dependency
   graphs. If that's needed, diff the resulting `package-lock.json` against the target
   branch's for any package version change outside the intended upgrade, and reconcile any
   drift before pushing — a different npm version can resolve unrelated transitive packages
   differently.
3. Verify with a real `npm ci` (not `npm install`, not `--dry-run`) using the same npm
   version CI uses. `npm ci --dry-run` only checks internal lockfile consistency — it will
   NOT catch a lockfile that's missing another platform's optional dependencies.

If open Dependabot PRs already exist for the same advisories and are failing CI on a stale
lockfile relative to the default branch, it's fine to replace them with one consolidated PR —
reference the closed PR numbers in the new PR body, then close the stale ones rather than
rebasing each individually.

## Final checklist

1. Branch cut from `origin/<default>`, not the dirty local tree — and only because there were findings.
2. Findings came from the highest-priority non-empty source only.
3. Every advisory in the fix list re-verified as cleared.
4. If code changed, the ecosystem's tests pass (output captured in the PR).
5. PR opened against the default branch, assigned to `@vokomarov`, labelled `dependencies` + `security`, with the full table + verification in the body.
6. Local checkout restored to its original branch and any stash popped.
7. PR URL reported to the user.