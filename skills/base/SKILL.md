---
name: base
description: >
  Monorepo-wide facts for Cash-Track: component layout, request flow, per-component
  commands, local dev stack start order and URLs, and commit conventions. ALWAYS load
  this first in any cash-track repository, then load the skill for the component you
  are editing.
---

# Cash-Track Base — Monorepo Facts

Shared facts about the Cash-Track monorepo that every component skill assumes. Load this
first, then the skill for the specific directory you're editing (`cash-track:api`,
`cash-track:frontend`, `cash-track:gateway`, `cash-track:infra`, or the others).

---

## Repo Layout

The `cash-track/.github` shared-actions repo is checked out at the `.github` sibling
directory, alongside `/api`, `/frontend`, `/website`, `/infra`, and this plugin repo — edit
it directly, never clone it elsewhere.

| Repo/Dir | Stack | Purpose |
|---|---|---|
| `/claude-plugin` | Markdown skills (Claude Code plugin) | Claude Code plugin repo holding these skills |

---

## Project Overview

Cash-Track is a financial management SaaS. The monorepo contains four components, plus a separate gateway service:

| Repo/Dir | Stack | Purpose |
|---|---|---|
| `/api` | PHP 8.4+, Spiral Framework, RoadRunner | Backend REST API |
| `/frontend` | Vue 3, TypeScript, Vite, Pinia, Nuxt UI | SPA client |
| `/website` | Nuxt 3, SSR, i18n (EN, UK) | Marketing site |
| `/infra` | Kubernetes (current) → Docker Compose (in progress) on DigitalOcean | Infrastructure; see `/infra/migration/` for the active K8s→Compose plan |
| `github.com/cash-track/gateway` | Go 1.26, FastHTTP | API gateway (separate repo at `${CASHTRACK_GATEWAY_PATH:-$(go env GOPATH)/src/github.com/cash-track/gateway}`) |

### Request flow

```
WebApp → Gateway (:80) → strips /api prefix → PHP API (RoadRunner)
```

The gateway sits in front of every API call. It handles auth cookies, CSRF, captcha, token refresh, and CORS — the PHP API receives plain Bearer tokens and never deals with cookies.

### Active migrations

Two independent migrations; don't conflate them. The frontend one is complete; infra is still in flight.

- **Frontend: Vue 2 → Vue 3 + Nuxt UI — complete.** The new SPA fully replaced the Vue 2 app; verified per stage with `agent-browser`.
- **Infra: Kubernetes → single-droplet Docker Compose.** Design doc: `/infra/migration/2026-04-21-kubernetes-to-docker-compose-design.md`. Implementation plan: `/infra/migration/2026-04-23-implementation-plan.md`. Stages marked `[OPERATOR-ONLY]` involve secrets/production actions; stages marked `[CLAUDE CODE]` are pure code. The `/infra/` repo is a separate git repo from this one.

---

## Commands

### Gateway (`github.com/cash-track/gateway`)

```bash
make run              # go run -race main.go (local dev)
make test             # go test -race -v ./...
make build            # docker build
make start            # run container on port 8081 using .env
make stop             # stop container
make mock-gen         # regenerate mocks (go.uber.org/mock)
```

Key env vars (see `.env.example`):

| Var | Purpose |
|---|---|
| `GATEWAY_ADDRESS` | Listen address, default `:80` |
| `API_URL` | Backend PHP API URL |
| `WEBAPP_URL` | SPA URL (login redirect target) |
| `WEBSITE_URL` | Marketing site URL (logout redirect target) |
| `CORS_ALLOWED_ORIGINS` | Comma-separated allowed origins |
| `CSRF_ENABLED` | Enable Redis-backed CSRF protection |
| `CAPTCHA_SECRET` | Google reCAPTCHA v3 secret (empty = disabled) |
| `REDIS_CONNECTION` | Redis address for CSRF token store |
| `DEBUG_HTTP` | Log full request/response headers |
| `COMPRESS` | Enable gzip compression |

### API (`/api`)

```bash
composer phpunit          # Run tests (parallel via paratest)
composer phpunit:ci       # Tests with coverage
composer checks           # All checks: tests + phpcs + psalm
composer phpcs            # PSR-12 linting
composer psalm            # Static analysis
composer mjml             # Build email templates
make build                # Build Docker image
make start                # Run local dev container
```

Run a single test file:
```bash
./vendor/bin/phpunit tests/Feature/Controller/Wallets/WalletControllerTest.php
```

### Frontend (`/frontend`)

```bash
npm run dev               # Dev server (Vite, port 3001)
npm run build             # Production build
npm run test:unit         # Vitest unit tests
npm run test:unit -- --run  # Run once (non-watch, for CI / manual checks)
npm run test:e2e          # Playwright E2E tests
npm run lint              # ESLint + Oxlint
```

### Website (`/website`)

```bash
npm run dev               # Dev server (port 3000)
npm run build             # Production build
npm run generate          # Static generation
npm run lint:js           # Linting
```

---

## Local dev stack

First stage is to start Traefik (configuration directory `./certs/conf`), MySQL, Redis: 

```bash
cd ./certs && make start
```

Then start API (`spiral-dev` is a local binary alias for `php app.php serve` with hot reload)

```bash
cd ./api && ./spiral-dev
```

Then start Gateway

```bash
cd "${CASHTRACK_GATEWAY_PATH:-$(go env GOPATH)/src/github.com/cash-track/gateway}" && make run
```

Then start Website

```bash
cd ./website && npm run dev
```

Then start Frontend

```bash
cd ./frontend && npm run dev
```

Each component should be started on it own terminal session.

- Home page is located at `https://dev-cash-track.app` (served by website).
- After login you will be redirected to `https://my.dev-cash-track.app` (served by frontend).
- API calls are going to `https://gateway.dev-cash-track.app` (served by gateway) and proxied to `https://api.dev-cash-track.app` (PHP API).

Local testing account credentials are stored in `.testing.local` (not committed).

**Login workaround:** if `https://dev-cash-track.app` returns a 500, open `https://gateway.dev-cash-track.app` in the browser console and run:
```js
fetch('/api/auth/login', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({email, password, remember: true})})
```
to set the HttpOnly auth cookies, then navigate to `https://my.dev-cash-track.app`.

---

## API Documentation

- Backend API spec: `/api/docs/openapi.yaml` (76 routes) — conventions, lint command, and OAS rules live in the `cash-track:api` skill.
- Gateway spec: `${CASHTRACK_GATEWAY_PATH:-$(go env GOPATH)/src/github.com/cash-track/gateway}/docs/openapi.yaml` — conventions and lint command live in the `cash-track:gateway` skill.

---

## Code Standards

- PHP: PSR-12, Psalm strict analysis, Deptrac for architecture boundaries
- JS/TS: ESLint + Oxlint, Prettier
- Conventional Commits for commit messages; scope matches the directory: `feat(api):`, `fix(gateway):`, `chore(frontend):`, `feat(infra):`, `docs(website):`
