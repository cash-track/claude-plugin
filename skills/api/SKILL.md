---
name: api
description: |
  Standards, conventions, and architecture rules for the Cash-Track PHP API (`./api`):
  Spiral, RoadRunner, Cycle ORM, controllers, services, repositories, entities, requests,
  views, migrations, jobs, mail, tests, and the OpenAPI spec. ALWAYS use it for any file
  under `./api`, and for backend questions about endpoints, DB schema, queue jobs, or mail
  in this project. Always load the `php-pro` skill alongside it for generic PHP context.
---

# Cash-Track API — Development Standards

## Self-Check After Every Change

**This is the last step of every session that touches `./api`.** Before finishing:
1. Verify that every pattern you used matches this skill.
2. If you discovered something new (a pattern, a gotcha, a convention not documented here), update this SKILL.md file with that knowledge.
3. Run `composer checks` (or at minimum `composer phpunit`) to confirm nothing is broken.

---

## Hard Rules

- **Never open or read any `.env*` file** (`.env`, `.env.local`, `.env.sample`, `.env.actions`, etc.) from any directory — these files may contain real secrets. Read `app/config/*.php` for config structure and `.env.sample` only as a last resort for variable names; even then, don't read `.env.sample` if another source answers the question. If you need to understand what env vars exist, check `app/config/` and `infra/ansible/roles/compose-render/templates/api.env.tpl`.
- **Writes to `.env*` files may be blocked outright by tool permissions**, including `.env.sample`. Read-only inspection (`grep`, `wc -l`) generally still works. If a write is denied, don't route around it with `printf >>`, `sed -i`, or similar — confirm what you need with `grep` and report the change as blocked so a human can apply it.

---

## Code Style (PSR-12 + Psalm)

- All files: `declare(strict_types=1)` as the second line after `<?php`.
- PSR-12 formatting. Enforce with `composer phpcs`; fix auto-fixable issues first.
- Psalm at strict level. Run `composer psalm` before finishing. Fix all issues; never suppress without a comment explaining why.
- Constructor promotion (`public readonly`) for injected dependencies.
- Named arguments for long calls when it improves clarity.
- `final` on all new concrete classes unless inheritance is genuinely required.
- No unused imports, no dead code.

---

## Design Principles

Apply these in every change — they are not suggestions:

- **SOLID**: Single responsibility per class, open for extension without modification, Liskov-safe substitution, narrow interfaces, depend on abstractions not concretions.
- **KISS**: The simplest solution that correctly solves the problem wins. Complexity must be justified by a concrete requirement. When in doubt, write less code.
- **DRY**: Extract duplication into a shared helper, trait, or base class when it appears a second time — not speculatively before then.
- **Design patterns over ad-hoc solutions**: Favour established patterns (Repository, Service, Factory, Strategy, Decorator) over one-off logic. But don't over-engineer — patterns must earn their place.
- **Simplicity and performance are not opposites**: Write the clearest solution first. Optimise only where there is a measured bottleneck or an obviously expensive operation (N+1 queries, missing index, unnecessary eager-load). Lazy loading, Cycle's `select()` builder, and index-backed queries are the primary performance levers.
- **Also load the `php-pro` skill** for generic PHP context — it covers language-level idioms, type safety, and patterns that underpin everything below.

---

## Architecture Boundaries

```
HTTP Request → Controller → Request (validation) → Service / Repository → Entity
                                 ↓
                              View (serialization) → ResponseInterface
```

- **Controllers**: HTTP orchestration only. No business logic, no direct DB queries.
- **Repositories** (`app/src/Repository/`): DB reads only. Extend Cycle's `Repository`. Named query methods, fluent `select()` builder. No writes, no business logic.
- **Services** (`app/src/Service/`): DB writes (via `EntityManagerInterface`) and business logic. Multiple entity persists in one `$tr->run()` call = one transaction.
- **Requests** (`app/src/Request/`): Validation + input mapping only. Extend Spiral `Filter`, use `#[Data]` + `#[Setter]` attributes, return `FilterDefinition` from `filterDefinition()`.
- **Views** (`app/src/View/`): Serialization only. Mark `#[Singleton]`, inject child views, implement `json()` wrapping data in `['data' => map()]`, `map()` returning plain array. Use `Relations` trait for conditional relation inclusion.
- **Entities** (`app/src/Database/`): Pure data + Cycle ORM annotations. No service calls inside entities.

---

## Codebase Map

Quick orientation inventory — deeper per-layer conventions are in the sections below, don't
restate them here:

- **Entry point**: `app/src/` — Spiral's bootloader pattern.
- **Bootloaders** (`src/Bootloader/`): wire up framework integrations — auth, routes, Redis, mailer, Firebase, Google API, CORS, S3, logging.
- **Controllers** (`src/Controller/`): Auth, Wallets, Charges, Tags, Profile, Users, Currency, Mails.
- **Domain models** (`src/Database/`): User, Wallet, Charge, Tag, Limit, Currency, GoogleAccount, Passkey, ForgotPasswordRequest, EmailConfirmation.
- **Migrations** (`app/migrations/`): Cycle ORM migrations, timestamp-prefixed filenames. Schema changes land here, never as raw SQL elsewhere.
- **Services** (`src/Service/`): WalletService, ChargeWalletService, UserService, TagService, PhotoStorageService, GoogleAccountService, etc.
- **Config** (`app/config/`): database, JWT, Firebase, Google, passkey, mail, Redis, cache, monolog.
- **Tests**: `tests/Feature/` (integration) and `tests/Unit/`; test environment via `tests/docker-compose.yml`.

---

## Controller Conventions

```php
// Route declaration via attribute — always on the method
#[Route(route: '/wallets/<id>', name: 'wallet.update', methods: 'PUT', group: 'auth')]
public function update(string $id, UpdateRequest $request): ResponseInterface
```

- Routes declared via `#[Route]` attributes directly on controller methods — there is no central route file.
- URL params injected by name as method arguments.
- Request (Filter) classes injected as typed arguments — Spiral validates automatically.
- Return `ResponseInterface` always.
- Use `group: 'auth'` for authenticated endpoints (auto-applies JWT auth + rate limit + locale).
- Extend `AuthAwareController` for authenticated endpoints. Call `$this->verifyIsProfileConfirmed()` on endpoints that require email confirmation.
- Use `$this->response->json(['data' => ...])` for success responses.
- Catch known exceptions in try/catch; log with `$this->logger->error(...)` before returning error response.
- 404 pattern: `return $this->response->create(404);`
- Error pattern: `return $this->response->json(['message' => $e->getMessage(), 'error' => 'short_code'], 500);`

### Tracing (for complex or auth-critical endpoints)

```php
public function login(LoginRequest $request, TracerInterface $tracer): ResponseInterface
{
    return $tracer->trace(
        name: 'auth.login',
        callback: static function (SpanInterface $span, AuthService $auth) use ($request): ?Authentication {
            $span->setAttributes(['email' => $request->email]);
            $result = $auth->login($request->email, $request->password);
            $span->setStatus($result ? StatusCode::STATUS_OK : StatusCode::STATUS_ERROR);
            return $result;
        },
        scoped: true,
    );
}
```

Inject `TracerInterface` via method argument (not constructor) when tracing is method-specific.

---

## Authentication Stack

Multiple auth methods coexist server-side:

- **JWT tokens** via `lcobucci/jwt` — the primary session mechanism; validated by the `group: 'auth'` controller group (see Controller Conventions above).
- **Firebase** — third-party auth provider integration.
- **Google OAuth 2.0** — `POST /auth/provider/google`, backed by the `GoogleAccount` domain model and `GoogleAccountService`.
- **WebAuthn / Passkeys** via `web-auth/webauthn-lib` — backed by the `Passkey` domain model.
- **Email confirmation** — required before creating wallets, charges, or tags; enforced via `$this->verifyIsProfileConfirmed()` (see Exception Handling below).
- **Forgot-password recovery** — backed by the `ForgotPasswordRequest` domain model.

The gateway (separate repo, `cash-track:gateway` skill) handles the cookie/CSRF/captcha layer in
front of all of this; the API itself only ever sees a Bearer token or an unauthenticated request.

---

## Request / Validation

```php
final class CreateRequest extends Filter implements HasFilterDefinition
{
    #[Data]
    public string $type = '';

    #[Data]
    #[Setter(filter: 'floatval')]
    public float $amount = 0.0;

    public function filterDefinition(): FilterDefinitionInterface
    {
        return new FilterDefinition(validationRules: [
            'type'   => ['type::notEmpty', ['in_array', [Charge::TYPE_EXPENSE, Charge::TYPE_INCOME], true]],
            'amount' => ['is_numeric', 'type::notEmpty', ['number::higher', 0]],
        ]);
    }
}
```

- Validation errors auto-return HTTP 422 `{"errors": {"field": ["message"]}}` via `JsonErrorsRenderer`.
- For encrypted unique-field checks use custom checker: `['encrypted-entity::unique', User::class, 'email']`.
- For encrypted field existence: `['encrypted-entity::exists', User::class, 'email']`.
- Use `#[Setter(filter: 'intval')]` / `#[Setter(filter: 'floatval')]` for type coercion.

---

## Database Entities (Cycle ORM)

```php
#[ORM\Entity(repository: WalletRepository::class, typecast: [Typecast::class, EncryptedTypecast::class])]
#[Behavior\CreatedAt(field: 'createdAt', column: 'created_at')]
#[Behavior\UpdatedAt(field: 'updatedAt', column: 'updated_at')]
final class Wallet
{
    #[ORM\Column(type: 'primary')]
    public int|null $id = null;

    #[ORM\Column(type: 'string(1536)', typecast: EncryptedTypecast::STORE)]
    public string $name = '';
}
```

- Always include `EncryptedTypecast::class` in `typecast` array if the entity has any encrypted column.
- Use `Behavior\CreatedAt` / `Behavior\UpdatedAt` — never set timestamps manually.
- UUID primary keys only for `Charge`; all other entities use integer primary keys.
- Relation FK fields must be kept in sync manually in setters: set both the relation object and the FK integer.
- Eager load (`load: 'eager'`) only for relations always needed; everything else is `'lazy'`.
- `PivotedCollection` for ManyToMany with custom pivot; `ArrayCollection` (Doctrine) for simple collections.

---

## Encrypted Fields

Two modes — choose based on whether you need to query by that field:

| Mode | Constant | Algorithm | Use when |
|------|----------|-----------|----------|
| Store | `EncryptedTypecast::STORE` | AES-256-GCM (random IV) | field is never queried by equality (name, description) |
| Query | `EncryptedTypecast::QUERY` | AES-256-ECB (deterministic) | field used in WHERE clauses (email, nickname) |

`name`, `email`, and `nickName` are stored encrypted in the DB, but the API contract returns them
as plain strings — decryption happens transparently through the typecast on read, so controllers,
views, and API consumers never see ciphertext.

Column size for encrypted fields: `string(1536)` for longer values, `string(767)` for short identifiers like email.

Never store a secret as plaintext. Never query by a STORE-encrypted column. Key comes from env `DB_ENCRYPTER_KEY` → empty in tests (encryption is no-op without a key, which is fine for local/test).

In tests, use `assertDatabaseHas($table, $plainWhere, $encryptedWhere)` — pass encrypted columns in `$encryptedWhere`, the helper encrypts them for you.

---

## Financial Amounts

- Store as `decimal(13,2)` column in MySQL; PHP type is `float`.
- Use `#[Setter(filter: 'floatval')]` on request fields.
- All arithmetic on amounts that affects wallet totals must go through `ChargeWalletService` — it keeps `wallet.totalAmount` consistent.
- Never use `round()` arbitrarily. The only sanctioned rounding is inside `safeFloatNumber()` — use that helper when you need to normalize a float to 2 decimal places. Amounts have exactly 2 decimal places by DB constraint everywhere else.
- Display formatting belongs in the View layer, not entities or services.

---

## Migrations

```php
final class CreateLimitsTable extends Migration
{
    public function up(): void
    {
        $this->table('limits')
             ->addColumn('id', 'primary', ['nullable' => false, 'default' => null])
             ->addColumn('wallet_id', 'integer', ['nullable' => false])
             ->addIndex(['wallet_id'], ['name' => 'limits_wallet_id_index', 'unique' => false])
             ->addForeignKey(['wallet_id'], 'wallets', ['id'], ['delete' => 'CASCADE', 'update' => 'CASCADE'])
             ->setPrimaryKeys(['id'])
             ->create();
    }

    public function down(): void
    {
        $this->table('limits')->drop();
    }
}
```

- Always implement both `up()` and `down()`.
- Use `->addForeignKey()` with explicit `delete`/`update` actions.
- Re-encrypt migrations exist (`20240922_re_encrypt_columns`) — any column cipher change requires a similar migration.
- After adding/changing a column, update the ORM entity annotation to match.

---

## Queue Jobs (RoadRunner)

```php
final class SendMailJob extends JobHandler
{
    public function invoke(string $id, array $payload, array $headers, MailerInterface $mailer): void
    {
        $mail = Mail::fromPayload($payload);
        $mailer->sendNow($mail);
    }
}
```

- Extend `JobHandler`, implement `invoke(string $id, array $payload, array $headers, ...services)`.
- Services are DI-resolved per invocation — inject them as named parameters after `$headers`.
- Two pipelines: `high-priority` (user-facing, e.g. auth emails) and `low-priority` (background, e.g. photo downloads).
- Dispatch: `$this->queue->push(MyJob::class, $payload, Options::onQueue('high-priority'))`.
- Serializable payloads only. For entities, use `EntityHeader` (holds class + primary key) and call `$header->hydrate($orm)` inside the job to re-fetch.
- Queue driver in tests: `QUEUE_CONNECTION=sync` (set in `phpunit.xml`) — jobs run synchronously.

---

## Mail

```php
final class WelcomeMail extends BaseMail
{
    public function __construct(User $user)
    {
        parent::__construct($user);
    }

    protected function build(): void
    {
        $this->subject($this->translator->trans('mail.welcome.subject'))
             ->view('email/welcome.dark');
    }
}
```

- All mails extend `BaseMail`, which handles `to()` from `$user->email` and `EntityHeader` serialization.
- Subject must be an i18n key via `$this->translator->trans(...)`.
- View is a pre-compiled Stempler template at `app/views/email/{name}.dark.php`.
- Source templates are MJML in `app/views/email-templates/`; compile with `composer mjml` (runs `build.sh`). Never hand-edit the `.dark.php` files.
- Send asynchronously: `$this->mailer->send($mail)` (pushes to queue). Send synchronously: `$this->mailer->sendNow($mail)`.
- `PayloadSerializer` trait handles queue serialization — `toPayload()` / `fromPayload()` via reflection.

---

## Logging

Inject `Psr\Log\LoggerInterface` via constructor. Usage:

```php
$this->logger->error('Unable to store tag', [
    'tag_id'  => $tag->id,
    'user_id' => $this->getUser()->id,
    'error'   => $e->getMessage(),
]);
```

- Use `->error()` for unexpected failures. Use `->warning()` for expected-but-notable conditions (e.g. entity not found when it should exist). Use `->info()` sparingly for audit trails.
- Always include context array with IDs and the exception message/class.
- Never log sensitive data (passwords, tokens, encryption keys, raw email content).
- Log channels: `default` (app errors), `roadrunner` (prod), `db` (query log, debug only).

---

## Exception Handling

- `UnconfirmedProfileException` → global handler maps it to HTTP 403. Throw via `$this->verifyIsProfileConfirmed()` in `AuthAwareController`.
- `AuthenticationRequiredException` → 401. Thrown by `AuthAwareController::__construct` when the actor is not a `User`.
- Validation errors → HTTP 422, handled globally by `ValidationHandlerMiddleware`.
- All other uncaught exceptions → HTTP 500 JSON `{"status": 500, "error": "message"}` + file snapshot in `runtime/snapshots/`.
- For expected domain errors (not found, conflict), return an explicit response rather than throwing a generic exception.
- When catching in a controller, log then return an error response — don't re-throw.

**Adding a mapped exception:** create it in `app/src/Exception/`, then add it to `ViewRenderer::MAP`. The map is consulted **only when errors are suppressed** (`EnvSuppressErrors`, i.e. `DEBUG=false`). With `DEBUG=true` the `ErrorHandlerMiddleware` renders the raw exception under the unmapped code (500), so a mapped 401/403 shows up as a 500 locally. Tests run with `DEBUG=false`, so they see the mapped code.

**Every route on an `AuthAwareController` subclass must carry `group: 'auth'`.** The constructor throws `AuthenticationRequiredException` when the actor is not a `User`, and Spiral builds the controller before invoking the method — a public route on such a controller returns 401 for every caller. Public actions belong on a plain `final class` controller (see `Auth\ConfirmEmailController` next to `Auth\EmailConfirmationsController`).

---

## Middleware

Global middleware is registered in `RoutesBootloader::globalMiddleware()` (`app/src/Bootloader/RoutesBootloader.php`) as a flat array of class-strings, and per-group middleware in `middlewareGroups()`.

**Ordering: the first entry in `globalMiddleware()` is the outermost.** Confirmed against `Spiral\Http\Pipeline::handle()` (`vendor/spiral/framework/src/Http/src/Pipeline.php`): the pipeline processes `$this->middleware[$position]` in ascending index order, and each middleware calls `$handler->handle($request)` (the pipeline itself) to invoke the next one — so index 0 wraps everything after it, including whatever index 0's downstream calls eventually return.

This matters most around `Spiral\Http\Middleware\ErrorHandlerMiddleware`, which catches `ClientException`/`RouterException` (→ 404-ish) and any other `\Throwable` (→ 500) thrown by everything *after* it in the array, and converts them into a fresh `ResponseInterface` via `$this->renderer`. A middleware placed **after** `ErrorHandlerMiddleware` in the array never runs for those converted responses — its call to `$handler->handle($request)` throws instead of returning, so any post-processing it does after that call (e.g. `withHeader(...)`) is simply skipped. Any middleware that must touch **every** response — success or error — has to be placed **before** `ErrorHandlerMiddleware` in the array. Example: `App\Middleware\ApiVersionMiddleware` (stamps `X-Ct-Api-Version` / `X-Ct-Api-Sha` on every response) sits right after `LocaleSelectorMiddleware` and before `ErrorHandlerMiddleware` for exactly this reason.

**Verify ordering changes with a real test, not just reasoning.** The cheapest way to prove a middleware is correctly placed: write a feature test hitting an unregistered route (→ 404 via `RouterException`) or another exception-driven path, assert the middleware's effect is present, then temporarily move the middleware after `ErrorHandlerMiddleware` and confirm the same test fails. Revert immediately after confirming.

**Header-only middleware that needs a value stable for the process lifetime (e.g. build metadata from env) should resolve it once in the constructor**, not on every `process()` call — mirrors `UserLocaleSelectorMiddleware`, which precomputes `$availableLocales` in its constructor and reuses it per request.

### `IdempotencyKeyMiddleware`

Deduplicates mutating requests carrying an `Idempotency-Key` (canonical lowercase UUIDv4) so a Traefik/gateway retry can't re-run the controller and double-apply a charge. It claims `idempotency:{userId|ip}:{method}:{path}:{key}` in Redis with `SET NX` under a 60s lease, caches the response for 24h, and replays it with `Idempotency-Replayed: true`. Duplicate still in flight → 409 + `Retry-After`; same key with a different body fingerprint → 422; malformed key → 400. Missing header = no dedupe, which is a valid request.

- **It matches routes by `Router::ROUTE_NAME`, never by path.** Route groups add the `/v1` prefix, so the path seen here is `/v1/auth/login` — an un-prefixed path string would silently never match. That is how `CREDENTIAL_ISSUING_ROUTES` (login / register / refresh / passkey / google) are excluded; caching one would park live access and refresh tokens in Redis for 24h, and replaying `/auth/refresh` defeats rotation.
- **Ordering, in both `middlewareGroups()`:** after `AuthMiddleware` (it scopes the key by user id, falling back to the client IP) and before `RateLimitMiddleware` (a replay skips the limiter, so `x-ratelimit-*` are dropped from the cached response along with the rest of `VOLATILE_HEADERS`). The `web` group gets it too — unauthenticated `password/forgot` and `email/confirmation/resend` amplify emails on retry.
- **Every Redis problem fails open** — store unavailable, corrupt payload, or a lost `SET NX`/`GET` race after `CLAIM_ATTEMPTS`. A duplicate write beats a hard outage; each path logs a warning.
- **5xx and >256KB responses are never cached.** A 5xx is precisely what a client is entitled to retry; pinning it for 24h would be worse than the duplicate.
- `RedisIdempotencyStore::LEASE_TTL` has callers outside the store: `S3Bootloader` derives the S3 timeout as half of it so a photo upload can't outlive its own lease. Changing the TTL means checking those, not just the store.

---

## Configuration

**Non-secret config** lives in `app/config/*.php`, loaded via `env('VAR_NAME', 'default')`. Wrap in a typed `Config` class (`app/src/Config/`) for DI injection.

**Secrets in production** are injected via 1Password CLI (`op inject`). The template `infra/ansible/roles/compose-render/templates/api.env.tpl` shows the pattern:

```
# Non-secret (plain value)
APP_ENV=prod
DEBUG=false

# Secret (resolved by op inject at deploy time)
DB_ENCRYPTER_KEY={{ op_prefix }}/api/DB_ENCRYPTER_KEY
DB_PASSWORD={{ op_prefix }}/mysql/MYSQL_PASSWORD
```

Rule: if it's a credential, token, key, or password → 1Password reference in the `.tpl` file. If it's a URL, flag, or non-sensitive setting → plain value in the `.tpl` file. Never commit actual secrets; never add them to `app/config/`.

**Adding a new env var:**
1. Add to `app/config/{relevant}.php` with `env('NEW_VAR', 'default')`.
2. Add to `.env.sample` with a placeholder.
3. If it's a secret, add `NEW_VAR={{ op_prefix }}/vault/NEW_VAR` to `api.env.tpl`.
4. If it's non-secret, add `NEW_VAR=value` to `api.env.tpl`.
5. Update the Config class if one wraps this file.

---

## Tests

Every new feature or feature change requires tests. Feature tests (HTTP integration) are the primary form; unit tests for isolated business logic.

```php
final class WalletControllerTest extends TestCase
{
    use DatabaseTransaction;

    public function testCreate(): void
    {
        $user = UserFactory::create();
        $auth = $this->makeAuth($user);

        $response = $this->withAuth($auth)->post('/wallets', [
            'name' => 'Savings',
            'defaultCurrencyCode' => 'USD',
        ]);

        $response->assertOk();
        $body = $this->getJsonResponseBody($response);
        $this->assertArrayContains('Savings', $body, 'data.name');
        $this->assertDatabaseHas('wallets', ['user_id' => $user->id], ['name' => 'Savings']);
    }
}
```

Rules:
- Always use `DatabaseTransaction` trait — transactions roll back after each test; no cleanup needed.
- Use Factories (`tests/Factories/`) to create entities. `Factory::make()` = in memory, `Factory::create()` = persisted.
- `withAuth($auth)` to simulate authenticated requests.
- Assert HTTP status + response body structure + DB state.
- For encrypted DB assertions: `assertDatabaseHas($table, $plainCols, $encryptedCols)`.
- Mock services via `$this->mock(ServiceClass::class, ['methodName'], fn($mock) => ...)`.
- Run: `composer phpunit` (parallel). Single file: `./vendor/bin/phpunit tests/Feature/Controller/Foo/FooTest.php`. `phpunit` takes **one** path argument — passing several silently runs only the first.
- PHPUnit is 9.6: data providers use the `@dataProvider` docblock and non-static provider methods, not `#[DataProvider]`.
- **Per-test env var overrides**: `Spiral\Testing\TestCase` supports `#[\Spiral\Testing\Attribute\Env('KEY', 'value')]` (repeatable) on an individual test method — it's folded into the env array the app boots with for that test, layered on top of `public const ENV` on the class. Use this when different test methods in the same class each need a different env combination (e.g. one env var set, one unset, both empty) rather than one static per-class `ENV` constant or manually re-calling `$this->initApp([...])` mid-test. Passing `value: null` reproduces "unset" deterministically (Spiral's `Environment::get()` uses `isset()`, which is `false` for `null`), which is safer than relying on the ambient shell having no such var.
- **A test asserting on an *unset* env var fails locally when your `.env` sets it.** Tests boot with the repo `.env` loaded, so a locally-configured `GATEWAY_SECRET` or `ACCESS_TOKEN_PUBLIC_KEY` flips the "not configured" branch and the test fails on your machine while passing in CI. Confirm with `GATEWAY_SECRET='' ./vendor/bin/phpunit tests/Feature/.../FooTest.php` before calling it a regression — and fix it at the source with `#[Env('GATEWAY_SECRET', null)]` on the method rather than leaving it ambient-dependent.
- **Adding a controller? Delete the stale tokenizer cache first.** The list of discovered controller classes is memoized in `runtime/cache/<hash>.php` (find it with `grep -l 'App\\\\Controller' runtime/cache/*.php`). Until it is removed, a newly added controller's routes 404 in tests with `Unable to route ...` while every pre-existing route keeps working. Production images build with a cold runtime, so this only bites locally.

---

## OpenAPI Spec (`docs/openapi.yaml`)

The spec is hand-maintained (no code generation). Update it for every change to:
- A route (URL, method, path params)
- Request body shape or query params
- Response body shape or HTTP status codes
- Authentication requirements
- New or removed endpoints

Conventions:
- OAS 3.1.0. Nullable fields: `type: [string, "null"]` (not `nullable: true`).
- Bearer JWT auth on all `auth`-group endpoints.
- Lint after editing: `npx @redocly/cli lint openapi.yaml` (run from `./api/docs/`).
- Reuse `$components/schemas` for shared shapes; avoid inline duplication.
- Timestamps in responses are RFC 3339 / W3C (`DATE_W3C`).
- Validation error response schema: `{"errors": {"field": "msg"}}` or `{"errors": {"field": ["msg"]}}`.
- Covers all 76 routes; debug-only `/mails/test` and `/mails/preview` are intentionally excluded.
- `servers:` lists `https://api.cash-track.app` (production) and `https://api.dev-cash-track.app` (local dev).

---

## Framework & ORM References

- Spiral Framework docs: https://spiral.dev/docs
- Cycle ORM docs: https://cycle-orm.dev/docs
- RoadRunner docs: https://roadrunner.dev/docs
- Spiral Testing: https://spiral.dev/docs/testing

When unsure about a Spiral or Cycle pattern, consult the docs via the `context7-auto-research` skill before guessing.
