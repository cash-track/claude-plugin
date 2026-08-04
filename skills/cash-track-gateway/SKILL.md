---
name: cash-track-gateway
description: |
  Standards, conventions, and architecture for the Cash-Track API Gateway — the Go /
  FastHTTP service in the separate cash-track/gateway repository that sits in front of the
  PHP API. ALWAYS use this skill when editing any file in that repo, or when asked about
  gateway behaviour: request forwarding, auth cookie ↔ Bearer translation, token refresh,
  CSRF rotation, captcha verify, CORS, or the `/api/*` proxy. Also load the `golang-pro`
  skill alongside for general Go best practices.
---

# Cash-Track Gateway — Development Standards

The gateway is the single entry point in front of the PHP API. It owns everything the
PHP API deliberately does not deal with: auth cookies, CSRF, captcha, token refresh,
CORS, and Cloudflare header normalisation. Request flow:

```
WebApp → Gateway (:80) → strips /api prefix → PHP API (RoadRunner, plain Bearer tokens)
```

Repo location: `${CASHTRACK_GATEWAY_PATH:-$(go env GOPATH)/src/github.com/cash-track/gateway}` (a **separate** git repo from the
`cash-track` monorepo — never clone it elsewhere). Module path:
`github.com/cash-track/gateway`. Go version: see `go.mod` (currently 1.26+).

## Self-Check After Every Change

**This is the last step of every session that touches the gateway.** Before finishing:
1. Verify every pattern you used matches this skill.
2. If you discovered something new (a pattern, a gotcha, a convention not documented here), update this SKILL.md with that knowledge.
3. Run `make test` (race detector on) — it must pass.
4. Run `golangci-lint run` and fix every issue. Never suppress without an inline comment explaining why.
5. Confirm coverage did not regress (see **Test Coverage** below — the bar is 100% on logic packages).
6. If you added or changed an interface, regenerate mocks with `make mock-gen` and add the new `mockgen` line to the Makefile.
7. If the change touched any **OpenAPI fact** (see below), update `docs/openapi.yaml` in the same change and lint it. A code change that alters an OpenAPI fact without a matching spec update is incomplete.

---

## Hard Rules

- **Never open or read `.env`** in the gateway repo — it may contain real secrets (captcha secret, redis connection). Read `.env.example` for variable *names* only, and `config/config.go` for how they're loaded and defaulted.
- **Never log tokens, cookies, or secrets.** Access/refresh tokens, the captcha secret, and CSRF tokens never go into a log line. Log the client IP and the error, not the credential. The existing refresh-token code is the reference (`service/api/forward.go`).
- **Always run with `-race`.** `make run` and `make test` both enable it; never strip the flag.

---

## Design Principles

Apply these in every change — load `golang-pro` for the generic Go idioms that underpin them:

- **Small interfaces, concrete `Http*` implementations.** Every capability is defined as a narrow interface (`Service`, `Handler`, `Provider`, `CSRFSeeder`, `Client`) and implemented by a struct (`HttpService`, `HttpHandler`, …) constructed via a `New…` function. Depend on the interface, never the concrete type — this is what keeps the package mockable and the 100% coverage achievable.
- **Constructor injection.** Dependencies arrive through the `New…` constructor and are stored as unexported fields. No global lookups inside handlers/services (the one sanctioned global is `config.Global`, loaded once in `main`).
- **KISS / DRY / SOLID** as in the rest of the project: simplest correct solution first; extract a helper on the second duplication, not speculatively; one responsibility per type.
- **Errors are wrapped, never swallowed.** `fmt.Errorf("API request error: %w", err)`. Handle every error explicitly; no `_ =` discards without a justification comment (a few sanctioned ones exist where fasthttp's API can't fail in practice — match the surrounding style and comment).
- **Context propagation.** Pass `*fasthttp.RequestCtx` through; for tracing use `traces.FindParentContext(ctx)` / `traces.GetTracer().Start(...)`. Don't create background contexts inside request handling.

---

## Package Map

| Package | Responsibility |
|---|---|
| `config/` | Env-loaded `Config` struct + `config.Global`. `Load()` reads env with `getEnv(key, default)`. |
| `captcha/` | `Provider` interface + Google reCAPTCHA v3 implementation. |
| `headers/` | Header name constants + copy/CORS/Cloudflare/client-IP/authorization helpers. |
| `headers/cookie/` | Auth cookie (`cshtrka`/`cshtrkr`) and CSRF cookie read/write; the `Auth` type. |
| `http/` | `Client` interface (thin fasthttp wrapper). |
| `http/retryhttp/` | Retrying fasthttp client (`Client` interface + `FastHttpRetryClient`). |
| `logger/` | Debug request/response logging (`DEBUG_HTTP`). |
| `router/` | FastHTTP router wiring (`router.New(api, csrf)` → route table). |
| `router/api/` | Auth + proxy handlers (`Handler` interface, `HttpHandler`): login, logout, captcha-verify, full-forward. |
| `router/csrf/` | `Handler` + `CSRFSeeder` interfaces; Redis-backed CSRF rotation/validation. |
| `router/response/` | Response writers (`ErrorResponse`, captcha responses) — all implement `.Write(ctx)`. |
| `service/api/` | `Service` interface + `HttpService`: forwards requests to the PHP API, handles token refresh + healthcheck. |
| `traces/` | OTEL tracer, propagator, span attribute helpers. |
| `mocks/`, `mocks/http/` | Generated mocks (`go.uber.org/mock`). Never hand-edit. |

Layering: `main` wires everything → `router` → `router/api` handler → `service/api` →
`http/retryhttp` client. Handlers orchestrate HTTP + auth/captcha/CSRF; the service does
the actual forwarding. Keep that separation — no forwarding logic in handlers, no
captcha/CSRF policy in the service.

---

## Interface + Implementation Pattern

Every new capability follows this shape (copy it exactly):

```go
// 1. Narrow interface — the contract other packages depend on.
type Service interface {
    ForwardRequest(ctx *fasthttp.RequestCtx, body []byte) error
    Healthcheck() error
}

// 2. Concrete struct, unexported fields = injected deps.
type HttpService struct {
    http   retryhttp.Client
    config config.Config
    csrf   csrf.CSRFSeeder
}

// 3. Constructor named New<Variant> returning the *concrete* pointer.
func NewHttp(http retryhttp.Client, config config.Config, csrf csrf.CSRFSeeder) *HttpService {
    http.WithReadTimeout(httpReadTimeout)
    // ...
    return &HttpService{http: http, config: config, csrf: csrf}
}
```

- `config.Config` is passed **by value** (it's plain data, read-only after `Load()`).
- Package-level tuning constants (timeouts, retry attempts, allowed-method sets) live at the top of the file as `const` / `var` maps — see `service/api/service.go` and `router/api/handler.go`. Reuse them; don't inline magic numbers.

---

## FastHTTP Idioms

The gateway is built on `valyala/fasthttp`, which **reuses buffers** — this is the single
biggest source of subtle bugs. Internalise these rules:

- **Handler signature is `func(ctx *fasthttp.RequestCtx)`.** Routes are registered in `router/router.go` via `r.GET/POST/ANY(path, handler)`.
- **Acquire/Release for outbound requests**, always with deferred release:
  ```go
  req := fasthttp.AcquireRequest()
  defer fasthttp.ReleaseRequest(req)
  resp := fasthttp.AcquireResponse()
  defer fasthttp.ReleaseResponse(resp)
  ```
- **`bytes.Clone()` anything you copy out of the ctx** — method, body, header bytes. fasthttp will overwrite the underlying array on the next request. The forward path clones method and body deliberately (`bytes.Clone(ctx.Request.Body())`).
- **Read/write headers via the `headers` package constants**, never string literals. If a header isn't there, add the constant to `headers/headers.go` first.
- **Status + body on the response ctx**: `ctx.SetStatusCode(...)`, `ctx.SetBody(bytes.Clone(resp.Body()))`. Error path: `response.ByErrorAndStatus(err, fasthttp.StatusBadGateway).Write(ctx)`.
- **Method/content constants** come from `fasthttp.MethodPost`, `fasthttp.StatusUnauthorized`, etc. — don't hardcode `"POST"` or `401`.

---

## Middleware Stack (execution order)

Assembled in `buildHandler()` in `main.go`, not in `router/router.go` — the router only maps paths
to handlers. Each `h = X(h)` makes `X` the new outermost layer, so the **last** wrapper applied is
the first to see a request. Outermost first:

1. Gzip compression — only when `COMPRESS=true`, and it wraps everything else
2. OpenTelemetry trace context extraction
3. Debug request/response logger (`DEBUG_HTTP=true`)
4. CORS validation against `CORS_ALLOWED_ORIGINS`
5. Default headers + real client IP extraction (Cloudflare → `X-Real-IP` → `X-Forwarded-For`), trace ID propagation, gateway build provenance
6. CSRF validation/rotation via Redis — only when `CSRF_ENABLED` (POST/PUT/PATCH/DELETE when logged in)
7. Prometheus metrics, which wraps the router itself and is passed in as the innermost handler

**Headers must wrap CSRF, never the reverse.** CSRF short-circuits a validation failure with a 417
without calling its inner handler. If CSRF were the outer layer, that 417 would go back with no
trace ID and no provenance headers. `buildHandler`'s own comment says so; preserve the order if you
touch it.

**Cloudflare header normalisation is not middleware.** `headers.CopyCloudFlareHeaders` is called
from the forward path (`service/api/forward.go`), not from `headers.Handler`. It renames inbound
`Cf-*` headers to `Cf-Original-*` on the outbound request so services behind the gateway still see
the original values. It renames **every** `Cf-`-prefixed header unconditionally and verifies
nothing: a client-set `Cf-Connecting-Ip` is renamed exactly like a genuine edge one. Do not treat
`Cf-Original-*` as proof a header came from Cloudflare, and do not build trust decisions on it.

---

## Auth, CSRF & Captcha Flow

These are the gateway's reason for existing — get them right.

- **Cookie ↔ Bearer.** Inbound: `cookie.ReadAuthCookie(ctx)` → if `auth.IsLogged()`, `headers.WriteBearerToken(req, auth.AccessToken)`. The PHP API only ever sees a Bearer token. Cookie names: `cshtrka` (access), `cshtrkr` (refresh), `cshtrkcsrf` (CSRF) — all defined as constants in `headers/cookie/`. Cookie domain is derived from `GATEWAY_URL`; the `Secure` flag is set when serving over HTTPS.
- **Auth-setting handlers** (login, register, passkey, google) run: captcha verify → forward → on 2xx set auth cookies + seed CSRF → return `{"redirectUrl": ...}`. `AuthSetHandler` → `CaptchaVerifyHandler` → `FullForwardedHandler` → `Login`.
- **Logout** forwards the refresh token in the body, then clears cookies.
- **Token refresh** is automatic on a 401 from the API (`service/api/forward.go`). The critical rule: a **transient** failure (API unreachable / 5xx) must **preserve the session** — do not delete cookies, return `503`. Only a genuine `nil`-error-but-not-logged outcome (refresh token actually expired) clears cookies. Re-read that function before touching refresh logic; the comments there are load-bearing.
- **CSRF seeding** happens after a successful login or token refresh, keyed to the new access token's `iat`, and stored in Redis as `CT:csrf:{userId}:{iat}`. It is **non-fatal**: a `Seed` error is logged, not surfaced — the user recovers via `GET /csrf`. Only seed on a 2xx response.
- **Captcha** reads the `X-Ct-Captcha-Challenge` header and verifies against Google reCAPTCHA v3. Empty secret = disabled.

When adding a new gateway route, decide deliberately: does it need captcha? CSRF? auth
cookies? Wire it through the matching handler rather than reimplementing the policy.

---

## Configuration

- Add new settings to `config/config.go`: a field on `Config`, then a line in `Load()` using `getEnv("ENV_NAME", "default")`. Booleans use the `getEnv(...) == "true"` idiom.
- Add the variable to `.env.example` with a placeholder (never a real value).
- Document non-obvious vars in the gateway README if they change behaviour.
- Secrets in production are injected at deploy time (1Password → env). Never commit a real secret; never read `.env`.

---

## Tracing & Logging

- **Tracing**: wrap forwarding spans with `traces.GetTracer().Start(traces.FindParentContext(ctx), name, trace.WithAttributes(...))` and `defer span.End()`. Record errors with `span.RecordError(err)`. Use the `traces.*Attributes(...)` / `MergeAttributes(...)` helpers to build attribute sets — don't assemble `attribute.KeyValue` slices by hand.
- **Logging**: `logger.DebugRequest/DebugResponse/FullForwarded` for the `DEBUG_HTTP` path; `log.Printf("[%s] ...", remoteIp, ...)` for operational events. Always include the client IP, never the token.

---

## Test Coverage — the bar is 100%

**Every logic package in this repo currently sits at 100% statement coverage.** The only
exclusions are `main.go` (wiring, not unit-testable), generated `mocks/`, and
`traces/semconv` (pure constants). Treat 100% as the standard, not a stretch goal: any
new code you add must be fully covered, and you must not let an existing package drop.

Verify before finishing:
```bash
go test ./... -cover                    # per-package summary; logic pkgs must read 100.0%
go test ./... -coverprofile=cov.out && go tool cover -func=cov.out   # line-level gaps
```
If a line is genuinely unreachable (e.g. an error branch fasthttp can't trigger),
restructure so it isn't, or document why with a comment — don't leave silent gaps.

### Test conventions

- **Framework**: standard `testing` + `github.com/stretchr/testify/assert`. Mocks via `go.uber.org/mock` (`gomock.NewController(t)`).
- **One behaviour per test function**, named `Test<Thing><Scenario>` (`TestLogin`, `TestLoginBadStatus`, `TestLoginInvalidResponse`, `TestLoginSeedError`). Cover the happy path **and** every failure branch — that's how the package reaches 100%.
- **gomock for generated mocks**: set expectations with `.EXPECT()`, drive responses with `DoAndReturn(func(req, resp) error { ... })`, and assert on the forwarded `req` inside the closure (method, URI, headers, body). See `service/api/forward_test.go`.
- **Hand-written stubs are fine for tiny interfaces** — e.g. `mockCSRFSeeder` in `router/api/login_test.go` is a 6-line struct recording calls. Prefer this over a generated mock when the interface has one method and you want to assert call/args directly.
- **Build the ctx explicitly**: `ctx := fasthttp.RequestCtx{}`, then `ctx.Request.Header.SetMethod(...)`, `ctx.Request.Header.SetCookie(...)`, `ctx.Request.SetURI(...)`, `ctx.SetRemoteAddr(...)`. Assert on `ctx.Response` (body, status, `PeekCookie`).
- **Use `assert.AnError`** for a generic injected error when the specific error value doesn't matter.
- Tests are excluded from lint (`.golangci.yml`) — but still keep them clean and readable.

### Mock generation

Mocks are generated, never hand-written. After adding/changing an interface:
1. Add a `mockgen` line to the `mock-gen` target in the `Makefile` (source file, package, destination, `-mock_names`).
2. Run `make mock-gen`.
3. Commit the regenerated mock alongside your change.

---

## Linting

`golangci-lint run` must pass clean. Config (`.golangci.yml`): `default: fast`, with
`depguard`, `cyclop`, `funlen`, `wsl` disabled; `mocks/` and `*_test.go` excluded. Don't
re-enable a disabled linter or add per-line `//nolint` without a comment justifying it.

---

## Routes the Gateway Owns

| Method | Path | Handler |
|---|---|---|
| ANY | `/live` | `LiveHandler` (always 200) |
| ANY | `/ready` | `ReadyHandler` (checks PHP API healthcheck) |
| GET | `/csrf` | `csrf.RotateTokenHandler` (requires auth) |
| POST | `/api/auth/login`, `/login/passkey`, `/register`, `/provider/google` | `AuthSetHandler` (captcha → forward → cookies) |
| POST | `/api/auth/login/passkey/init` | `CaptchaVerifyHandler` |
| POST | `/api/auth/logout` | `AuthResetHandler` |
| ANY | `/api/{path:*}` | `FullForwardedHandler` (catch-all proxy) |

Adding a route = a line in `router/router.go` pointing at a handler method on the `api`
or `csrf` interface, plus a test in `router/router_test.go`.

---

## OpenAPI Spec (`docs/openapi.yaml`)

Hand-maintained — there is no code generation, so the spec only stays correct if you
update it by hand alongside the code. **Whenever a change to the HTTP layer touches an
OpenAPI fact, update `docs/openapi.yaml` in the same change.** Treat the following as
OpenAPI facts — if your diff changes any of them, the spec must change too:

- A route added, removed, or re-pathed in `router/router.go` (or its method).
- Request shape: body fields, query params, required headers a client must send (e.g. `X-Ct-Captcha-Challenge`).
- Response shape: body fields, status codes a handler can now return (e.g. a new `503` branch), or response headers the gateway sets/forwards.
- Auth or cookie behaviour: cookie names (`cshtrka`/`cshtrkr`/`cshtrkcsrf`), which routes require auth, the CSRF rotation/seeding flow, or captcha requirements.

A pure refactor that preserves all of the above needs no spec change. When in doubt,
ask: "could a client observe this difference?" — if yes, it's an OpenAPI fact.

Conventions: security scheme is `cookieAuth` (`cshtrka` cookie), **not** Bearer. Lint
after editing: `npx @redocly/cli lint openapi.yaml` (from `gateway/docs/`).

---

## Commands

```bash
make run          # go run -race main.go (local dev)
make test         # go test -race -v ./...
make build        # docker build
make mock-gen     # regenerate go.uber.org/mock mocks
golangci-lint run # lint (must pass clean)

# Single package / single test:
go test -race ./service/api/...
go test -race -run TestLogin ./router/api/...
```

When unsure about a FastHTTP, go-redis, OTEL, or `go.uber.org/mock` API, consult the docs
via the `context7-auto-research` skill before guessing — these libraries change between
versions and the gateway pins specific ones in `go.mod`.
