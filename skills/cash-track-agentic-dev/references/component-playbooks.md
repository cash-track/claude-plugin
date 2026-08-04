# Component Playbooks

Per-component map of: which **skills** the developer/reviewer must load, how to run **tests**
and **linters**, what **test types** the tester runs, and the **commit scope** + repo path.
Sourced from the project and global `CLAUDE.md`. When a component's `CLAUDE.md` and this file
disagree, the component's `CLAUDE.md` wins — it's closer to the code.

> All cash-track components are **separate git repos**. Always `cd` into the right repo before
> running anything. The gateway lives outside the monorepo tree.

---

## api — PHP / Spiral / RoadRunner

| | |
|---|---|
| Path | `./api` |
| Commit scope | `feat(api):`, `fix(api):` |
| Skills to load | `cash-track-api` **and** `php-pro` (or `php-guidelines-from-spatie`) — the project skill builds on the generic PHP one |
| Tests | `composer phpunit` (parallel via paratest); single file: `./vendor/bin/phpunit tests/Feature/Controller/Wallets/WalletControllerTest.php` |
| Linters / static analysis | `composer phpcs` (PSR-12), `composer psalm` (strict). All-in-one: `composer checks` |
| Tester test types | `composer phpunit` feature + unit; for endpoint changes, exercise the API path through the gateway against the running stack |
| Notes | Email confirmation required before creating wallets/charges/tags; Charge IDs are UUID, other IDs integer; encrypted fields (name/email/nickName) returned plain; keep `api/docs/openapi.yaml` in sync when routes/shapes change |

## frontend — Vue 3 / TS / Vite / Pinia / Nuxt UI

| | |
|---|---|
| Path | `./frontend` |
| Commit scope | `feat(frontend):`, `chore(frontend):`, `fix(frontend):` |
| Skills to load | `cash-track-frontend`, **all** Vue skills (`vue-best-practices`, `vue-options-api-best-practices`, `vue-router-best-practices`, `vue-pinia-best-practices`, `vue-test-best-practices`/`vue-testing-best-practices`), and `nuxt-ui` |
| Tests | `npm run test:unit -- --run` (Vitest, non-watch); E2E: `npm run test:e2e` (Playwright) |
| Linters | `npm run lint` (ESLint + Oxlint) |
| Tester test types | Vitest unit, Playwright E2E, and the **`agent-browser`** skill for user-visible changes against the running stack (login flow per project `CLAUDE.md`) |
| Notes | Vue 2 app under `frontend/old/` is read-only legacy. Watch the Vitest/agent-browser gotchas in the project `CLAUDE.md` (UIcon stub names, USelect union types, UDropdownMenu findComponent, Nuxt UI combobox handling) |

## website — Nuxt 3 SSR / i18n (EN, UK)

| | |
|---|---|
| Path | `./website` |
| Commit scope | `docs(website):`, `feat(website):`, `fix(website):` |
| Skills to load | `nuxt-ui` and the Vue skills (same set as frontend) |
| Tests | build smoke: `npm run build`; static gen: `npm run generate` |
| Linters | `npm run lint:js` |
| Tester test types | build/generate success + lint; `agent-browser` for visible changes; verify both EN and UK locales for copy changes |

## gateway — Go 1.26 / FastHTTP

| | |
|---|---|
| Path | `${CASHTRACK_GATEWAY_PATH:-$(go env GOPATH)/src/github.com/cash-track/gateway}` (separate repo, outside the monorepo) |
| Commit scope | `feat(gateway):`, `fix(gateway):` |
| Skills to load | `golang-pro` |
| Tests | `make test` (`go test -race -v ./...`); regenerate mocks after interface changes: `make mock-gen` |
| Linters | `go vet ./...`; rely on `golang-pro` for idiom/style |
| Tester test types | `make test`; for routing/cookie/CSRF/captcha behaviour, run `make run` and exercise the route against a local API |
| Notes | Strips `/api` prefix; cookie↔Bearer translation; auto token refresh on 401; CSRF in Redis. Keep `gateway/docs/openapi.yaml` in sync when middleware/cookies/captcha/CSRF change |

## infra — Terraform + Ansible + Docker Compose (DigitalOcean)

| | |
|---|---|
| Path | `./infra` (separate repo) |
| Commit scope | `feat(infra):`, `fix(infra):` |
| Skills to load | `cash-track-infra`, plus `terraform-engineer` / `devops-engineer` / `kubernetes-specialist` as relevant |
| Tests / checks (offline only) | Ansible: `ansible-playbook site.yml --syntax-check` (with the `TF_OUTPUT='{...}'` stub from project `CLAUDE.md`) and `ansible-lint <explicit file list>`; Terraform: `terraform validate`, `terraform fmt -check` |
| Tester test types | **Offline syntax/lint only.** Never run production actions. Stages marked `[OPERATOR-ONLY]` (secrets/prod) are out of scope for this workflow |
| Notes | Many lint gotchas live in the project `CLAUDE.md` (role-prefix var naming, Title-cased handlers, `docker_compose_v2` `state: restarted`, `no_log: true` for secret tasks). Honour them or `ansible-lint` fails |

## Local service images — mysql / redis / mysql-backup / certs

| | |
|---|---|
| Path | `./mysql`, `./redis`, `./mysql-backup`, `./certs` (built/pushed as `cashtrack/<name>`) |
| Commit scope | `chore(<dir>):` or `feat(infra):` per change |
| Tests | each has its own `Makefile`: `make build` (and `make push` when releasing) |
| Tester test types | `make build` succeeds; `mysql-backup` is PHP-based dump+S3 — exercise the script logic, not a live S3 push |

---

## Picking the branch base

`main` vs `master` is per-repo. Always detect, never assume:
```bash
git fetch origin
DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT=${DEFAULT:-$(git remote show origin | sed -n 's/.*HEAD branch: //p')}
git switch -c <type>/<slug> origin/$DEFAULT
```
