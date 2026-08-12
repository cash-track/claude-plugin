---
name: frontend
description: |
  Standards, conventions, and architecture rules for the Cash-Track Vue 3 SPA (`./frontend`):
  Nuxt UI components, views, Pinia stores, composables, the `src/api/` layer, vue-router,
  vue-i18n, Vitest, and Playwright. ALWAYS use it for any file under `./frontend`, and for
  frontend questions about pages, components, stores, forms, or charts in this project. The
  Vue 2 + Bootstrap app under `./frontend/old/` is read-only legacy reference.
  ALWAYS load these alongside it: `vue-best-practices`,
  `vue-options-api-best-practices`, `vue-router-best-practices`, `vue-pinia-best-practices`,
  `vue-testing-best-practices`, `nuxt-ui`.
---

# Cash-Track Frontend — Development Standards

The new app is a **Vue 3 + TypeScript + Vite + Pinia + Nuxt UI v4** SPA. It replaced a
Vue 2 + Bootstrap Vue + Vuex app. The Vue 2→3 migration is complete; this skill captures the
conventions that the migration established and that all ongoing development must follow.

## Self-Check

Two tiers — **don't run the full gate on every edit; run it before committing.**

### While iterating (per change) — keep it cheap
- Verify the patterns you used match this skill.
- Keep what you touched **type-clean and lint-clean**, and run the **unit test(s) covering the
  changed code** (e.g. `npm run test:unit -- --run src/components/.../Foo.spec.ts`, or watch mode).
- No need for the full build, the full unit suite, or any E2E run on every change.
- If you discovered something new (a pattern, a Nuxt UI / Vitest gotcha, a convention not documented
  here), update this `SKILL.md` so the next session benefits.

### Before commit — required gate (all must pass)

Commits happen **only when the user asks** (see Hard Rules), so this is the verification point. Run
the full self-check, and re-confirm the tests the change required (per "Test coverage required for
every change") exist and pass:

```bash
npm run type-check          # vue-tsc --build — zero errors
npm run lint                # oxlint + eslint — clean
npm run test:unit -- --run  # full Vitest suite (non-watch)
npm run build               # production build — zero errors (a pre-existing chunk-size warning is OK)
```

`npm install`, `npm run dev`, `npm run build`, `npm run lint`, `npm run type-check`,
`npm run test:unit` run **without asking for permission**. `npm run test:unit` defaults to watch
mode — always pass `-- --run` for a one-shot check.

**E2E is scoped to the blast radius of the change — do NOT default to the full suite.** The full
run is ~6–7 min (both projects, `--workers=1`) *when nothing goes wrong*, and it burns the shared
dev account and the reused auth state. Pick the smallest tier that actually covers what you
touched:

| Change | E2E to run |
|---|---|
| Simple fix — a component's copy/prop/computed, one view, a bug touching a handful of files | **Only the spec(s) covering it.** Usually one file, or `-g "SS-08"` for a single case. |
| Feature work on a domain (wallets, charges, tags, limits, settings) | **The domain's `S*` spec files** — the ones whose surfaces the change reaches. |
| Cross-cutting app code — `api/client.ts`, router, `stores/auth`, `lang/index.ts`, `App.vue`, `AppHeader`, `shared/env.ts`, anything imported nearly everywhere | **Full suite** (`npm run test:e2e`). |
| Core library upgrade — Nuxt UI, Vue, vue-router, Pinia, vue-i18n, Vite, Playwright | **Full suite**, both projects. Selector-level breakage from a Nuxt UI bump is exactly what it catches (issue #141). |
| Massive/structural change — a migration stage, a decomposition, a routing rework, a shared-component rewrite | **Full suite.** |
| Release / long-lived branch about to merge | **Full suite.** |

When in doubt between two tiers, `npm run test:e2e:smoke` (the P0 subset) is the middle ground —
not the full suite. **Say which tier you ran and why**; the thing to avoid is silently skipping E2E
entirely, not skipping the *full* suite on a one-line fix. If the dev stack isn't running, say that
too rather than reporting the change as verified.

All E2E tiers need the dev stack (`https://my.dev-cash-track.app` + gateway); see the E2E section
for the run recipe (JSON reporter, `--workers=1`, empty-creds auth reuse).

For visual/behavioural verification use the **`agent-browser`** skill against the running dev
stack (see "Browser Verification" below).

### Test coverage required for every change

Tests are **part of the change, not a follow-up.** Decide the required coverage from the *kind* of
change before you start, and write/adjust the tests in the same session — the verification commands
above only prove the tests you wrote pass; they don't excuse missing ones.

| Kind of change | E2E (Playwright) | Unit (Vitest) |
|---|---|---|
| **New user-facing feature** — new page/route, button, dropdown or menu action, form, modal, toggle, or any new interactive surface | **A new E2E test is required.** Tag it `@smoke` **only if it's a P0 critical-path flow** (auth, wallet/charge/tag CRUD, navigation); otherwise a plain case. Add to the matching `S*` spec, or a new spec if the surface is new. | **Required** — add one |
| **Change to an existing feature** — altered behaviour, props, validation, copy, or layout of something already shipped | **Verify first, then act:** read the existing `S*` spec (the spec files are the coverage source of truth). If a case covers it → **update that test**. If the behaviour is genuinely new → **add a test** (a plain case; `@smoke` only when it's a P0 critical-path flow). | **Required** — modify the existing unit test if one covers the code, else add one |
| Pure refactor, no behaviour change | None new; keep the suite green | Update only if structure moved; keep green |

Non-negotiables:
- **A unit test is required for both feature work and feature changes.** If the touched code already
  has a `__tests__/` spec, update it to cover the new behaviour; if it has none, add one. A change
  that leaves a unit gap is incomplete — don't defer it.
- **A new user-facing feature without an E2E test is incomplete** — but `@smoke` is **reserved for
  P0 critical-path surfaces** (auth, wallet/charge/tag CRUD, navigation). Tag a new flow `@smoke`
  only if it belongs in that fast guard (`npm run test:e2e:smoke`, 66 cases today); a minor surface
  (e.g. a new dropdown action) gets a plain E2E case. Don't let `@smoke` drift toward "all E2E", or
  the subset stops being a fast P0 check.
- **"Verify if an existing test needs changing" means read it first.** Don't leave a now-false
  assertion passing, and don't leave a new code path uncovered — decide update-vs-add deliberately.
- New/changed E2E specs follow the suite conventions (see the E2E section below): bilingual
  `label()` / role / aria selectors, `assertNoErrorLeak(page)`, unique timestamped names + cleanup,
  and the shared `support/` helpers — never re-derive them.

---

## Hard Rules

- **Never read any `.env*` file** (`.env`, `.testing.local`, `.env.actions`, …) — they may hold real
  secrets and test credentials. The only env vars the app reads are declared in `env.d.ts`
  (`VITE_WEBSITE_URL`, `VITE_GATEWAY_URL`). Add new ones there with strict typing.
- **Config is resolved at runtime, never via `import.meta.env` directly.** Vite inlines
  `import.meta.env.VITE_*` at *build* time, so the Docker image (which builds with `.env`
  `.dockerignore`d) would bake the literal `undefined` and the SPA would redirect-loop to
  `/undefined/undefined/…` (`webSiteLink('/') = undefined + '/'` → a relative URL). To serve one
  image across all envs, config is injected **at container start**: `index.html` declares
  `window.__APP_CONFIG__` with `__VITE_*__` placeholders, `entrypoint.sh` `sed`-replaces them
  from container env vars (and fails fast if unset), and `src/shared/env.ts#getEnv()` reads
  `window.__APP_CONFIG__` first, falling back to `import.meta.env` for local dev / preview / unit
  tests (where the placeholder stays). **Always read config through `getEnv('VITE_…')`** (as
  `links.ts` and `client.ts` do) — never `import.meta.env.VITE_*` inline. A new `VITE_*` var
  means: add it to `env.d.ts`, to the `window.__APP_CONFIG__` block in `index.html`, and to the
  `sed` list in `entrypoint.sh`.
- **`./frontend/old/` is read-only legacy.** It is the source of truth for business logic and
  API contracts when porting, but never import from it (`grep -r "from.*old/" src/` must return
  nothing), never lint/test it (already excluded in `eslint.config.ts`, `vitest.config.ts`,
  `.gitignore`). Do not "fix" files under `old/`.
- **The API contract source of truth is `/api/docs/openapi.yaml`** (OAS 3.1, 76 routes) — not the
  old app's interfaces, which may be stale. Generate/verify model shapes against it.
- **All API calls go through the gateway**, not the PHP API directly. `baseURL` is
  `VITE_GATEWAY_URL`; paths are prefixed with `/api` (the gateway strips it). Auth is
  cookie-based (`withCredentials: true`); the frontend never handles Bearer tokens.

---

## Tech Stack & Pinned Versions

| Concern | Choice |
|---|---|
| Framework | Vue 3 (`^3.5`), Composition API + `<script setup lang="ts">` only |
| Build | Vite `^6` (defer v7/v8), `@vitejs/plugin-vue` `^5` |
| UI | Nuxt UI `^4` (Tailwind CSS **v4** under the hood) |
| State | Pinia `^3` (setup-store style) |
| Routing | vue-router `^4` (defer v5 — removes `next()` callback) |
| i18n | vue-i18n `^11`, `legacy: false` |
| HTTP | axios `^1` |
| Charts | chart.js `^4` + vue-chartjs `^5` |
| WebAuthn | `@simplewebauthn/browser` `^13` |
| Drag/drop | vuedraggable `^4` |
| Tests | Vitest `^3` (defer v4) + `@vue/test-utils`; Playwright for E2E |
| Lang | TypeScript `~5.9`, vue-tsc `^2` (defer v3) |

Before upgrading anything, check `npm outdated` and respect the "defer" notes above — several
majors carry breaking changes the project intentionally postpones. Verify a version exists with
`npm show <pkg> version` before installing.

---

## Project Structure

```
src/
  api/
    client.ts            # axios instance + apiCall() CSRF-retry wrapper
    <domain>.ts          # plain async fns returning typed models (wallets, charges, tags, …)
    profile/             # profile sub-modules: email.ts, password.ts, passkeys.ts
    models/              # one class per OpenAPI schema + _validators.ts
      __tests__/
    __tests__/           # api function module tests
  components/
    <domain>/            # AppHeader, wallets/, wallets/charges/, wallets/limits/, tags/,
    Shared/              # profile/, settings/, settings/passkeys/
      __tests__/         # MoneyAmount, ConfirmModal, TotalsRow, HamburgerMenu
  composables/           # useMoneyFormatter, useTimeAgo, useApiErrors, useNotifications
  stores/                # auth, profile, wallets, locale (Pinia setup stores)
  views/                 # one per route; settings/ holds nested settings views
  router/index.ts        # name-based routes, meta.title, beforeEach title guard
  lang/                  # index.ts (i18n setup) + messages/en.ts + messages/uk.ts
  shared/                # env.ts, links.ts, strings.ts
  assets/                # base.css, main.css
  App.vue, main.ts
```

`@/` is the alias for `src/`. Use it in all imports (`@/api/...`, `@/components/...`).

---

## Code Style

Enforced by Prettier + ESLint + Oxlint + EditorConfig. Match the existing files exactly:

- **4-space indent**, LF, final newline, max line length 100 (`.editorconfig`).
- **No semicolons**, **single quotes**, `printWidth: 100` (`.prettierrc.json`). (A few legacy
  scaffold files like `lang/index.ts` still carry semicolons — new code follows Prettier.)
- `.vue` SFC order: **`<script setup lang="ts">` first, then `<template>`.** No `<style>` blocks —
  styling is Tailwind utility classes inline (Nuxt UI v4 / Tailwind v4).
- `defineProps<{ ... }>()` with a TS type literal (not the object/runtime form).
- Component **filenames are multi-word** to satisfy `vue/multi-word-component-names`
  (`AppHeader.vue`, not `Header.vue`). For an unavoidably single-word file (e.g. `Tag.vue`), add
  `defineOptions({ name: 'TagChip' })`.
- **Import own components explicitly** (`import MoneyAmount from '@/components/Shared/MoneyAmount.vue'`)
  even though `unplugin-vue-components` auto-registers them — explicit imports keep dependencies
  obvious and tests stub-able. **Nuxt UI `U*` components and Nuxt UI composables are
  auto-imported** (via `@nuxt/ui/vite`) — do not import `UButton`, `UCard`, etc.
- No unused imports, no dead code, no `console.log` left behind.
- `replaceAll` is **not** in the TS lib target — use `str.replace(/pattern/g, ...)`.
- **Do not run bare `prettier --write` on existing files.** ESLint uses
  `@vue/eslint-config-prettier/skip-formatting` (formatting is *not* lint-enforced), and the
  committed code is **not** prettier-clean — it uses `arrow-parens: avoid` (`t =>`, `w =>`) while
  `.prettierrc.json` sets no `arrowParens`, so prettier's default `"always"` rewrites every arrow
  in the file. Running it produces a huge noisy diff of untouched lines. Match the surrounding
  style by hand (4-space indent, `t =>` not `(t) =>`); `npm run lint` won't reformat it for you.
- When wrapping an existing template block in a new element, re-indent the wrapped lines by hand
  (`vue/html-indent` is disabled by skip-formatting, so nothing auto-fixes it).

---

## Component Conventions

```vue
<script setup lang="ts">
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'
import type { Wallet } from '@/api/models/wallet'
import { useProfileStore } from '@/stores/profile'
import MoneyAmount from '@/components/Shared/MoneyAmount.vue'

const props = defineProps<{ wallet: Wallet }>()
const emit = defineEmits<{ 'charge-created': [] }>()

const { t } = useI18n()
const router = useRouter()
const profileStore = useProfileStore()

const lastUpdated = computed(() => /* ... */)
</script>

<template>
  <!-- Tailwind utilities + Nuxt UI components; no <style> block -->
</template>
```

- **All user-facing text via i18n** — `{{ t('wallets.active') }}`, never hardcoded strings. Every
  key must exist in **both** `lang/messages/en.ts` and `lang/messages/uk.ts`. The two files are at
  full key parity — identical key paths (the leaf-key count grows as features land, so don't
  hardcode a number in checks; diff the key *sets*, not the counts). Adding a key to
  one without the other breaks that parity, so always edit both. The `en.ts`/`uk.ts` ordering
  differs slightly (e.g. `common` is placed differently) — that's fine; only the key set matters.
- **Use Nuxt UI semantic color tokens**, not raw Tailwind palette colors:
  `text-success` / `text-error` / `text-muted` / `text-secondary`, `bg-default` (white/base) /
  `bg-elevated` (subtle grey), `border-default` / `border-primary`. These adapt to dark mode for
  free. Reserve raw colors (`bg-red-500`) only where a semantic token doesn't fit (e.g. limit
  progress bars).
- **Tooltips:** wrap the trigger in `<UTooltip :text="..." :arrow="true">`. Always include
  `:arrow="true"`. Never substitute the native `title` attribute.
- **Per-section loading skeletons (required pattern):** never gate a whole page on one top-level
  `loading` boolean. Give each independently-fetched section its own `loadingFoo` ref initialised
  to `true`, fire its fetch **without `await`** so sections resolve independently, and show a
  `USkeleton` shaped like the real content while loading:
  ```vue
  <template v-if="loadingFoo">
    <USkeleton class="h-8 w-40 rounded-md" />
  </template>
  <template v-else-if="foo">
    <!-- real content -->
  </template>
  ```
- **Views are thin orchestrators.** A view loads data and composes child components; it holds no
  business logic inline. The old 942-line `WalletView` was decomposed into ~9 focused components
  — keep that altitude.
- Money is always rendered via the `MoneyAmount` component (wraps `useMoneyFormatter`) — don't
  format currency ad-hoc in templates.
- Dynamic tag colors come from the API as hex strings. Tailwind JIT can't generate arbitrary hex
  classes at runtime — use a CSS custom property + Tailwind v4 arbitrary value:
  `style="--tag-color: <hex>"` with `class="bg-[var(--tag-color)]"`, or an inline
  `background-color` with an alpha tint (`tag.color + '1a'` for a 10%-opacity background).
- **A negative margin that cancels a responsive-only padding MUST carry the same breakpoint.**
  `-my-2` against a `sm:py-2` parent: at `sm`+ the margin cancels the padding and the child's
  margin box lands on the parent's border box, but below `sm` there's nothing to cancel, so the
  child overflows 8px past *each* edge into its siblings. Harmless with opaque children; with a
  **translucent** one (the charge timeline's `bg-black/10` connector) the overlap composites —
  two 10% layers over white give `255·0.9² = 206` vs the normal `229` — reading as a clipped or
  doubled border (issue #108). Fix by matching breakpoints (`sm:-my-2`) and making any
  compensating offset responsive too (`h-3 sm:h-5` for the spacer aligning the icon to the title).
  Verify with `getBoundingClientRect()` (overflow == the margin) and pixel luminance, not by eye.

---

## Nuxt UI v4 Gotchas (hard-won — check before fighting these)

- `useToast` must be imported from `@nuxt/ui/composables`, **not** the root `@nuxt/ui` package
  (the named export isn't re-exported from root in the Vue/Vite setup). It's wrapped by
  `useNotifications` (`notifySuccess` / `notifyError`) — prefer that.
- `USelect` with literal-union item values (e.g. `'en' | 'uk'`) trips TS on a `string`-typed
  v-model — cast the item value: `value: code as string`.
- **Icons are bundled offline — a new collection needs a new dependency.** Icons used to be
  fetched from `api.iconify.design` on first render (issue #122). Now `vite.config.ts` passes
  `icon.clientBundle.scan` to `ui()` (needs `@nuxt/ui` ≥ 4.10) so every icon referenced under
  `src/` is embedded at build time, and `@iconify/vue` is aliased to `@iconify/vue/offline` so
  there is no HTTP fallback left. Consequences:
  - **Use `i-lucide-*`** (e.g. `i-lucide-arrow-up`) — `lucide` is the default collection and the
    one Nuxt UI's own components use. Anything else needs its `@iconify-json/<collection>`
    package installed as a devDependency, or the icon renders as **nothing** (no request, no
    error). `src/__tests__/icons.spec.ts` fails the build in that case — heed it, don't delete it.
  - The scan glob is `src/**/*` on purpose. Nuxt UI's default (`**/*.{vue,jsx,tsx,md,…}`) skips
    `.ts`, and `useNotifications` keeps its toast icons there.
  - Hyphenated collections (`simple-icons`) still break `@iconify/vue`'s dash parser, but Nuxt UI's
    own icons plugin now registers both forms, so `name="simple-icons:telegram"` just works — the
    old manual `addIcon` workaround in `src/plugins/icons.ts` is gone.
  - **In unit tests an unstubbed `UIcon` now renders nothing at all.** `vitest.config.ts` merges
    `vite.config.ts`, so the offline alias applies there too, but no test calls `app.use(ui)` — the
    `virtual:nuxt-ui-icons` payload is never registered, and offline `Icon` falls back to
    `renderSlot(slots, 'default')`, i.e. no element and no `class`. Stub it as **both** `UIcon` and
    `Icon` (see the stub-by-internal-name rule) whenever a test asserts on classes near an icon.
- **Nuxt UI 4.10 renamed `UAlert`'s close event to `update:open`.** A closable alert is
  `<UAlert close @update:open="err = null">`; the old `@close` handler compiles fine, type-checks
  fine, lints fine, and simply never fires — the alert becomes undismissable. Grep for `@close` on
  any `U*` component after a Nuxt UI bump.
- **Toasts no longer expose `role="alert"` on the visible element.** Reka moved the role onto a
  visually-hidden announce `<span aria-hidden="true">`; the visible toast is an `<li>` inside the
  `[data-slot="viewport"]` `<ol>`. E2E selectors must match it structurally
  (`page.locator('[data-slot="viewport"] li').filter({ hasText })`) — `getByRole('alert')` resolves
  to the hidden span and never becomes visible.
- `UInput` event handling: the reliable pattern is **`v-model` + a watcher**, not
  `:model-value` + `@input` (UInput uses `inheritAttrs: false` with VueUse `useVModel`). Add
  `class="w-full"` when it must fill a flex container (its root is `inline-flex`).
- `UInputDate` replaces native `<input type="date">`; use `granularity="minute"` for combined
  date+time. The custom `DateTimePicker.vue` (UCalendar + hour/minute inputs) is the shared
  popover for charge forms.
- Tailwind v4 gradient utilities don't resolve CSS custom properties in gradient stops — use an
  inline `style="background: linear-gradient(..., var(--ui-bg))"` instead of `from-[--ui-bg]`.
- **Vertical expand/collapse = `UCollapsible`, not `v-if`/`v-show`.** For toolbar-driven sections
  where the toggle button is elsewhere (not adjacent to the content), omit the default slot — the
  trigger only renders when a default slot exists — and drive it controlled with `v-model:open`.
  Put the panel in `<template #content>`; it animates 200ms (`collapsible-down`/`-up`) for free.
  `unmountOnHide` defaults to **true**, so content mounts on open / unmounts on close (same as
  `v-if`) — fine for children that self-load `onMounted` and reload via a `watch(wallet.id)`.
  Reka measures `getBoundingClientRect().height` of the content node and the slot is always
  `overflow-hidden` (a BFC), so a child's `mb-*` is contained and animates smoothly — no need to
  convert margins to padding. Charts inside it must keep a **fixed-height** parent
  (`h-[300px]` + `maintainAspectRatio: false`) so chart.js doesn't measure 0 during the animation.
- **Desktop-visibility trap:** a `UCollapsible` whose only toggle is a mobile-only (`md:hidden`)
  control stays `closed` on desktop and so hides its content there too. Drive `v-model:open` with a
  writable computed that force-opens on desktop:
  `const isDesktop = useMediaQuery('(min-width: 768px)')` plus
  `computed({ get: () => isDesktop.value || isOpen.value, set: v => { isOpen.value = v } })` —
  desktop always open, mobile still toggles via the hamburger. This is the `AppHeader` nav pattern;
  a dropped `content-visibility` media rule used to mask the bug, so it only surfaced post-migration.
- When unsure about a Nuxt UI v4 component API, consult the **`nuxt-ui` skill** and, for the
  latest props/slots, **`context7-auto-research`** before guessing — v4 differs from v3.

---

## Charts (chart.js v4 + vue-chartjs v5)

`<Bar>` / `<Doughnut>` from `vue-chartjs`, registered per-component
(`ChartJS.register(...)`). Two sizing/scaling traps that cost real debugging time:

- **The fixed height must sit on the chart's *immediate* positioned parent — not a grandparent.**
  With `responsive: true` + `maintainAspectRatio: false`, chart.js sizes the canvas to its
  **direct** parent's box. A height-less wrapper *between* the fixed-height ancestor and the
  `<Bar>` collapses the chart to ~0, even when that ancestor has `h-[300px]`. The recurring bug:
  `<div class="relative h-[300px]"> … <div v-if="hasData"><Bar/></div> </div>` — the `v-if`
  wrapper has no height, so the canvas measures 0. Fix: give the wrapper `class="relative h-full"`
  so it fills the ancestor (`ChargesFlowChart.vue`, `TagChargesFlowChart.vue`). The doughnut
  (`ChargesTotalChart.vue`) never broke because there the height is on the same div as the `v-if`.
  (Distinct from the UCollapsible note above, which is about *why* a fixed-height parent is needed
  at all — this is about *where* it must go.)
- **The value axis caps exactly at a round data max — add `grace` for headroom.** chart.js sets
  the axis max to the smallest "nice" tick ≥ the data max. A round max (e.g. 120, step 20) lands
  *on* a tick, so the tallest bar touches the ceiling; a non-round max (72 169) rounds up to 80 000
  and gets incidental headroom. This is auto-scaling, **not** a regression — the old Vue 2 app
  configured no max/headroom either, it just rarely hit a round max. For deliberate headroom set
  `grace: '5%'` on the `y` scale (pads the range beyond the data so the top bar never touches the
  ceiling: 120 → ceiling 140). It's a no-op when the padded max still rounds to the same tick
  (72 169 + 5% → 75 800 → still 80 000), so it only changes the round-number cases.

---

## API Layer

Three layers under `src/api/`:

### 1. `client.ts` — never bypass it

Every API function wraps its call in `apiCall(...)`:

```ts
import { apiCall } from './client'
import { Wallet } from './models/wallet'

export async function getUnarchived(): Promise<Wallet[]> {
    return apiCall(async client => {
        const res = await client.get('/api/wallets/unarchived')
        return (res.data.data as unknown[]).map(Wallet.from)
    })
}

export interface CreateWalletRequest {
    name: string
    isPublic?: boolean
    defaultCurrencyCode?: string | null
}

export async function createWallet(request: CreateWalletRequest): Promise<Wallet> {
    return apiCall(async client => {
        const res = await client.post('/api/wallets', request)
        return Wallet.from(res.data.data)
    })
}
```

- **Double-unwrap: `res.data.data`.** Axios wraps the HTTP body in `.data`; the API wraps its
  payload in `{ "data": ... }`. Reading `res.data` instead of `res.data.data` is a recurring bug.
- `apiCall` handles **401 → redirect to login**, and **417 (CSRF) → refresh `GET /csrf` and retry
  once** (only for mutating methods; GET/OPTIONS aren't retried). On second failure it
  redirects/reloads. Don't reimplement this per call.
- Functions are **plain async functions** returning typed model instances (or `void`). No
  `Repository` class, no decorators (those were dropped from the old app).
- Request bodies are typed via exported `interface XxxRequest`. Map results with `Model.from`.
- Empty arrays the API rejects: e.g. charges `tags: []` fails validation — send `tags: null` when
  nothing is selected. Watch for similar "condition `of` not met" cases.

### 2. `models/` — one class per OpenAPI schema

```ts
export class WalletShort {
    readonly id: number
    readonly name: string
    // ... all readonly

    constructor(data: { id: number; name: string; /* ... */ }) {
        this.id = data.id
        this.name = data.name
    }

    static from(raw: unknown): WalletShort {
        if (!raw || typeof raw !== 'object') {
            throw new Error('WalletShort.from: expected object')
        }
        const d = raw as Record<string, unknown>
        return new WalletShort({
            id: requireNumber(d, 'id'),
            name: requireString(d, 'name'),
            defaultCurrency: d.defaultCurrency ? Currency.from(d.defaultCurrency) : null,
            createdAt: new Date(requireString(d, 'createdAt')),
        })
    }
}
```

- **Classes, not bare interfaces.** All properties `readonly`; construct via constructor or the
  static `from(raw: unknown)` factory only — no mutation.
- `from()` validates shape and converts types using the shared validators in
  `models/_validators.ts`: `requireString` / `requireNumber` / `requireBoolean` / `requireDate`
  and `optionalString` / `optionalDate` / `optionalNumber`. Errors include the field name.
- Type mapping from OAS 3.1: `type: [string, "null"]` → `string | null`; `format: date-time` →
  `Date` (parse the ISO string); `format: uuid`/`uri` → `string`; `integer`/`number` → `number`.
- Parse nested models recursively (`d.users.map(UserShort.from)`); use the **short** variant to
  break circular refs (`Charge` holds `WalletShort`, never `Wallet`). Reuse via class inheritance
  (`Wallet extends WalletShort`) instead of duplicating fields.
- `Charge` IDs are **UUID strings**; every other entity ID is a `number`.
- Convenience getters are fine (`displayName`, `isExceeded`) — keep them pure.

### 3. Domain function modules

`wallets.ts`, `charges.ts`, `tags.ts`, `limits.ts`, `currency.ts`, `users.ts`, `auth.ts`,
`graph.ts`, and `profile.ts` (+ `profile/email.ts`, `profile/password.ts`, `profile/passkeys.ts`).
Implement only endpoints that exist in `openapi.yaml` — don't invent functions for routes the API
doesn't have (the migration plan listed several that don't exist; they were dropped). Auth
functions return the gateway's `{ redirectUrl }`, not raw JWTs.

---

## Pinia Stores

Setup-store style, primitives/class-arrays held in `shallowRef`:

```ts
import { shallowRef } from 'vue'
import { defineStore } from 'pinia'
import type { Wallet } from '@/api/models/wallet'
import { getUnarchived } from '@/api/wallets'

export const useWalletsStore = defineStore('wallets', () => {
    const activeWallets = shallowRef<Wallet[]>([])
    const loading = shallowRef(false)
    const failed = shallowRef(false)

    async function loadActive() {
        loading.value = true
        failed.value = false
        try {
            activeWallets.value = await getUnarchived()
        } catch {
            activeWallets.value = []
            failed.value = true
        } finally {
            loading.value = false
        }
    }

    return { activeWallets, loading, failed, loadActive }
})
```

- Stores: `auth` (`isLogged`, `isEmailConfirmed`), `profile` (`profile: User | null`, `loadProfile`,
  `setProfile`, `updatePhotoUrl`), `wallets` (`activeWallets`, `loadActive`), `locale` (cookie
  persistence via `cshtrkl`, syncs with vue-i18n through `syncLocaleWithI18n()`).
- Use `shallowRef` for primitives and for class-instance arrays (class instances need full
  replacement to trigger reactivity — spread/replace, don't mutate in place).
- `auth.logout()` is async: it calls `POST /api/auth/logout` then redirects to `webSiteLink('/')`;
  errors are swallowed so the redirect always fires.

---

## Composables

Four shared composables in `src/composables/`, each `useXxx()` returning refs + functions:

- `useMoneyFormatter` — `format(amount, currency, showFraction = true)`. Formats the number with a plain
  `Intl.NumberFormat(locale)` (number only — **not** `style: 'currency'` / ISO 4217 code), then
  appends `currency.char`. **Output uses NBSP (` `) as the group separator and before the currency char; the composable defaults to 2 decimals, but
  `MoneyAmount` passes `showFraction ?? false`, so the component default is whole units** (e.g. `1234.56` → `1 235 $`). Tests
  assert the NBSP form — don't change formatting casually.
- `useTimeAgo` — `timeAgo(date)` via `Intl.RelativeTimeFormat`, no extra dependency.
- `useApiErrors` — `handleError(error)` populates `fieldErrors: Ref<Record<string, string[]>>`
  and `generalError: Ref<string | null>`; resets on each call. Handles 422 via
  `ValidationError.from`, other errors via `ApiError.from`. Wire `fieldErrors` into form fields.
- `useNotifications` — `notifySuccess(msg)` / `notifyError(msg)` over Nuxt UI's `useToast`.

---

## Routing & i18n

- Routes are **name-based** with `meta.title`; a `beforeEach` guard sets `document.title`. A route
  may also carry `meta.namedTitle` (e.g. `titles.walletNamed` = `'{name}'`), which
  `setDocumentTitle` renders with `t(namedTitle, { name: route.params.nameForTitle })` — a **named
  i18n param**, not a string replace.
- **Never post-process an i18n message with `.replace(/\{name\}/g, …)` — always pass named params
  to `t()`.** vue-i18n's message compiler owns `{…}`: `t(key)` with no params resolves every
  placeholder to the **empty string**, so a subsequent `.replace()` finds nothing left to match and
  silently yields `delete PassKey ""?` (issue #133, `PasskeyItem.vue`). The correct form is
  `t('passkeySettings.deleteConfirm', { name: props.passkey.name })`. The trap is that the bug is
  invisible in unit tests whose `t` mock is `(key) => key` — the key has no `{name}` in it either
  way. To actually cover interpolation, use a **param-aware mock**
  (`mockT.mockImplementation((key, params) => params ? \`${key}:${JSON.stringify(params)}\` : key)`)
  and assert the serialized params (`ChargeItem.spec.ts`, `PasskeyItem.spec.ts`). E2E should assert
  the rendered text contains the entity name, not just that the dialog opened.
- Messages carrying placeholders today: `passkeySettings.deleteConfirm`, `wallets.deletingConfirm`,
  `tags.deletingConfirm` (`{name}`), `charges.deletingConfirm` (`{title}`), `charges.selectedCount`
  (`{count}`), `titles.walletNamed`/`walletEditNamed`/`walletShareNamed`/`tagNamed` (`{name}`).
- Navigate by name with string params: `router.push({ name: 'wallets.show', params: { walletID: id.toString() } })`.
- Settings is a **single `/settings` route rendering `UTabs`** — not nested routes. The legacy
  `/settings/profile` and `/settings/security` paths remain only as `redirect`s to `settings`.
  Reka Tabs mounts just the active panel, so the Security form isn't in the DOM until its tab is
  clicked (see the E2E section).
- i18n: `legacy: false`, locales `en` + `uk`. `en` is preloaded; `uk` lazy-loaded via dynamic
  import in `lang/index.ts`. Use `const { t } = useI18n()` then `t('namespace.key')`. Currency
  names are keyed `t('currency.USD')`. **Add every new key to both `en.ts` and `uk.ts`** — they
  must stay at key parity. After editing messages, confirm parity holds: a quick leaf-key count
  (`grep -c ":" src/lang/messages/en.ts` vs `uk.ts` is a rough proxy) or flatten both default
  exports and diff the key paths; the sets must be identical.

---

## Unit Testing (Vitest + Vue Test Utils)

- Tests live in colocated `__tests__/` dirs as `*.spec.ts`. jsdom environment.
- Mock cross-cutting modules at the top of the file:
  ```ts
  vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: (k: string) => k, locale: ref('en') }) }))
  vi.mock('vue-router', () => ({ useRouter: () => ({ push: vi.fn() }) }))
  vi.mock('@/stores/profile', () => ({ useProfileStore: () => ({ profile: null }) }))
  ```
  With mocked `t`, assert against the **key** (`expect(wrapper.text()).toContain('wallets.active')`).
- For stores, `setActivePinia(createPinia())` in `beforeEach`. Use `vi.hoisted()` for mock
  variables referenced inside `vi.mock` factories (vitest hoists the factory above the file).
- **VueUse `useMediaQuery` returns a permanently-`false` ref under jsdom** (no `matchMedia`), so
  responsive branches never take their desktop path in tests. Mock it deterministically with
  hoisted mutable state: `const mediaState = vi.hoisted(() => ({ matches: false }))`, then
  `vi.mock('@vueuse/core', async importOriginal => ({ ...(await importOriginal<typeof import('@vueuse/core')>()), useMediaQuery: () => ({ value: mediaState.matches }) }))`.
  Flip `mediaState.matches = true` per desktop test; reset it to `false` in `beforeEach`. (See
  `AppHeader.spec.ts` for the desktop-open vs mobile-closed cases.)
- **Stub Nuxt UI components** in `mount` to avoid the `UApp` provider dependency:
  ```ts
  global: { stubs: {
    UBadge: { template: '<span><slot /></span>', props: ['color', 'variant'] },
    UAvatar: { template: '<div />', props: ['src', 'alt', 'size'] },
    UIcon: { template: '<span />', props: ['name', 'class'] },
  } }
  ```
  Known stub quirks: `UIcon` renders as `<icon-stub>` (Nuxt UI registers it as `Icon`); `UTooltip`'s
  internal name is `Tooltip` (stub both keys); `UDropdownMenu` can't be found via `findComponent`
  (global registration overrides the stub) — assert via `wrapper.text()` and `defineExpose` the
  computed you need. **Stub-by-internal-name (general rule):** Nuxt UI `<script setup>` SFCs have no
  explicit `name`, so the compiler derives it from the filename — test-utils matches the stub by that
  bare name, not the `U*` key. So `USwitch`→`Switch`, `USeparator`→`Separator`,
  `UFileUpload`→`FileUpload`, `UTooltip`→`Tooltip`, `UIcon`→`Icon`, `UContainer`→`Container`.
  Always provide both keys in
  `stubs`; a missing bare-name stub silently mounts the real component. (Concretely: a pass-through
  `Container: { template: '<div><slot /></div>' }` stub is what makes a `UContainer`-wrapped `<h1>`
  reachable in `shallowMount`; keying it `UContainer` does nothing and the slot content is dropped.) `UFileUpload` in particular
  must be stubbed — its real render calls `URL.createObjectURL`, which jsdom doesn't implement
  (throws an unhandled rejection). jsdom normalises `#rrggbbaa` hex to `rgba(...)` — don't assert raw hex+alpha
  in style tests. Money assertions must use the NBSP form (`1 235 $`).
- Build helper factories for model fixtures (`makeWallet(overrides)`) rather than repeating large
  object literals.
- **Every changed component/store/composable needs its test updated or added.** Run
  `npm run test:unit -- --run` before finishing.

---

## E2E Testing (Playwright)

- Specs in `e2e/`; `e2e/setup/global-setup.ts` logs in via the gateway to set auth cookies and
  saves `e2e/setup/.auth.json` (gitignored). Credentials come from `E2E_EMAIL` / `E2E_PASSWORD`
  (auto-loaded from `frontend/.env.local` via dotenv if present — but **never read it yourself**; the
  harness blocks `.env*` reads, while dotenv still loads the values at runtime without exposing them).
- `baseURL` defaults to the real dev stack `https://my.dev-cash-track.app`; the web server is not
  auto-started outside CI (the stack is expected to be running). CI starts the preview server on
  port 4173 (build first).
- Selectors must support **both EN and UK** locale labels (a logged-in account may be in either).
- Run: `npm run test:e2e` (all), `npm run test:e2e:smoke` (the `@smoke` P0 subset — 66 tests across
  both projects), `npm run test:e2e -- --project=chromium`, or a single file/case
  (`-g "SS-08" e2e/settings-security.spec.ts`) — **the last is the right default for a simple fix**;
  see the tier table under "Before commit". The smoke script is
  bare `playwright test --grep @smoke` with **no `--workers=1`**, so a local run uses default
  parallelism (~half the cores); the subset includes shared-account mutators (`WC-03`, `WE-02/05`,
  `WA-07`, `TG-05`, `LM-02/03/04`, `SH-06`), so pass `npm run test:e2e:smoke -- --workers=1` when you
  want the serial, shared-account-safe execution the full suite uses.
- **Settings is `UTabs`, not nested routes.** `/settings` is the only real URL (Profile is the
  default tab); the legacy `/settings/profile` and `/settings/security` are now redirects to
  `/settings`. So assert `toHaveURL(/\/settings$/)`, **never** `/\/settings\/profile/`. UTabs is
  not URL-synced and Reka Tabs only mounts the **active** panel — the Security form isn't in the
  DOM until you `getByRole('tab', { name: /security|безпека/i }).click()`. Same pattern for any
  view that migrates nested routes → tabs.
- **Tag chips open a popover, they don't navigate.** On `/tags`, `<TagComponent>` renders with
  `navigable=false` inside a `UPopover`; clicking a chip opens View/Edit/Delete actions. To reach
  the detail page, click the chip then the View action: `getByRole('button', { name:
  /^(view|переглянути)$/i }).click()` → `/tags/{id}`. A bare chip click stays on `/tags`.

### Suite layout & how to run/validate (S1–S22, ~186 cases)

- **Shared helpers live in `e2e/support/`** — import everything from the `../support` barrel:
  `label`/`labelExact`/`labelStrings` (i18n.ts), `routeError`/`routeAbort`/`routeEmpty`/`routeJson`/
  `route422`/`route401`/`routeDelay` (state.ts), `create*ViaApi`/`delete*ViaApi` factories
  (factories.ts), and the `shell`/`overlay`/`calendar`/`wallet`/`charge`/`tag`/`settings` selector
  groups + `assertNoErrorLeak` / `pickFirstAvailableDate` (selectors.ts). Don't re-derive locators a
  spec already has shared.
- **UCalendar (Reka) has no `role="grid"`.** Since Nuxt UI 4.5.1 the grid table renders as
  `<table role="application" data-slot="grid">`; date cells still carry `role="gridcell"`, so only
  the grid gate broke (issue #141 — five `@smoke` cases timed out on `[role="grid"]`). Match
  `[data-slot="grid"]` — structural, and stable across Reka role changes. Cell structure is
  `<td role="gridcell" data-slot="cell"><div role="button" data-reka-calendar-cell-trigger
  data-value="YYYY-MM-DD" data-slot="cellTrigger">`; on selection the `td` gains
  `aria-selected="true"` and the trigger `data-selected="true"`. Note the popover does **not**
  auto-close after picking a day, so "popover still open" proves nothing about whether the click
  landed — check the input segments or the badge.
- **Exclude `[data-outside-view]` padding days when picking a date.** The 6-week (42-cell) grid pads
  with adjacent-month days; clicking one both selects the date **and navigates the grid to that
  month**, and the re-render races whatever the test asserts next.
- **Clicking a calendar day is not reliable single-shot — use `pickFirstAvailableDate(page)`.** Under
  full-suite load a click on the portalled popover is occasionally not delivered to the cell trigger:
  every Playwright actionability check passes, the popover stays open, and no date is set (the
  date-from segments still read `mm/dd/yyyy`). It reproduced ~1 full run in 3 and **never** in
  isolation (0/40 in a tight open→click loop), and the badge is pure local state
  (`v-if="dateFrom"` in `ChargesFilter.vue`) so no API call is involved. The helper clicks the
  trigger and re-issues the click inside `expect(...).toPass()` until the cell reports
  `aria-selected="true"` (selecting a day is idempotent). Verified by swallowing the first click with
  a capturing `addInitScript` listener: the single-click path then fails with the exact CF-04
  signature, the helper recovers.
- **Icons are inline `<svg>`, not `.i-lucide-*` classes.** A locator like `.i-lucide-calendar` matches
  nothing, so a guard such as `if (await calIconBtn.isVisible())` silently skips the whole assertion
  block. Match the popover trigger instead (`form button[aria-haspopup="dialog"]`); prefer the i18n
  `aria-label` where the component sets one (`charges.filterInputFrom`/`To` do; `ChargeCreate`'s
  calendar button does not).
- **Mobile specs MUST be named `*.mobile.spec.ts`** — that's the only thing the `mobile-chrome`
  (Pixel 5, touch) project matches; `chromium` ignores them. A mobile case in a plain `*.spec.ts`
  runs on desktop Chrome and the touch/viewport assertions fail.
- **Validating specs from an RTK terminal (skip this if you are on an ordinary shell):** the wrapper mangles Playwright's stdout reporter, so
  always use the JSON reporter to a temp file and parse it, never read stdout:
  ```bash
  unset -f npm node npx 2>/dev/null          # nvm installs these as shell functions
  NODE_BIN="$(dirname "$(command -v node)")"
  [ -x "$NODE_BIN/node" ] && export PATH="$NODE_BIN:$PATH"
  E2E_EMAIL= E2E_PASSWORD= PLAYWRIGHT_JSON_OUTPUT_NAME=/tmp/v.json \
    npx playwright test --project=chromium --workers=1 --reporter=json e2e/FILE.spec.ts \
    >/tmp/out.log 2>/tmp/err.log
  # then parse /tmp/v.json: r.stats = {expected, unexpected, flaky, skipped}
  ```
- **The empty-creds trick (`E2E_EMAIL= E2E_PASSWORD=`) is mandatory for ad-hoc runs.** `globalSetup`
  runs once per `playwright test` invocation; with creds present it re-logs-in via the gateway, and
  concurrent logins from parallel runs return 502. Empty creds make it **reuse** the existing
  `.auth.json` instead. Those cookies (`cshtrka`/`cshtrkr`) last ~6.6 days — re-login only when a
  `GET /api/profile` through the gateway stops returning 200 (a one-off 502 is just a RoadRunner
  cold start; retry before assuming the stack is down).
- **A mid-run cascade of `503` on *every* request means the reused auth state went stale — drop the
  empty-creds trick and let `globalSetup` re-login.** The gateway emits 503 from exactly one place
  (`service/api/forward.go`): the API answered 401, the gateway's automatic token refresh failed, and
  it deliberately returns a retryable status **without clearing cookies**. So once the saved access
  token expires and its (single-use) refresh token can't be redeemed, every subsequent call 503s and
  the run collapses — browser requests *and* `request`-fixture `createWalletViaApi` alike, with
  `Unable to load your profile. Please try again.` in the page snapshot. Signature: empty body,
  `server: fasthttp`, CORS headers present. It is **not** RoadRunner dying — check with
  `./rr workers` from `/api` (workers keep their PIDs and sit ~42 MB against the
  `max_worker_memory: 100` cap).
  **A bare `curl …/api/profile` does NOT pre-flight this** — with no cookies it returns 401 whether
  the stack is healthy or the saved state is stale, so it only proves the gateway is up. Cheaper
  gate: check `e2e/setup/.auth.json`'s mtime; if it's more than a day old, just **drop the
  empty-creds trick for that run** rather than burning ~8 min discovering the cascade mid-suite
  (the failure pattern is distinctive — the first N specs pass, then everything after a point fails,
  a mix of `POST /api/wallets -> 503` from the `request` fixture and missing-element timeouts on
  pages that never loaded).
- **`--project=setup` exits 1** ("no tests found") — `global-setup.ts` has no `test()` calls; it's a
  config-level `globalSetup`, not a runnable project. Run `--project=chromium` / `--project=mobile-chrome`.
- **Run headed (non-CI).** `headless: isCI`, and you can't set `CI=1` to force headless (it flips
  `baseURL` to `localhost:4173` and spawns `npm run preview`). The full suite (both projects,
  `--workers=1`) takes ~6 min headed; use `--workers=1` to avoid shared-account data races.
- **Heavy multi-navigation tests need `test.slow()` under full-suite parallel load.** A test doing
  3+ full `page.goto`s (each re-firing the profile + section data loads) plus heading/title
  assertions can pass solo in ~6–24s yet blow the default 30s timeout once the full suite runs its 5
  workers in parallel (hit on IT-05 and TD-12). Add `test.slow()` (triples the budget to 90s) rather
  than thinning coverage. Expect whack-a-mole: raising one heavy test's budget redistributes worker
  load and can tip the *next*-most-borderline test over — fix the genuinely heavy ones, then re-run
  the **full** suite to confirm green; a solo rerun won't reproduce a parallel-load timeout.
- **`e2e/` IS type-checked** via `e2e/tsconfig.json` (extends `../tsconfig.app.json` → DOM lib +
  `moduleResolution: Bundler` + the `@/*` paths; `include: ["**/*"]`, `types: ["node"]`),
  referenced from the root `tsconfig.json`. So `npm run type-check` (`vue-tsc --build`) covers the
  specs — a type error in `e2e/**` now **breaks the build**, not just lint. Playwright still runs the
  specs via its own esbuild transform (tsconfig is only for the IDE + `type-check`). Two things to know:
  - **TS2834 root cause.** create-vue scaffolds `e2e/tsconfig.json` extending
    `@tsconfig/node22/tsconfig.json`, which sets `module: nodenext` + `moduleResolution: node16`. That
    mode forbids extensionless / barrel relative imports, so the IDE flags every `./support` /
    `../../src/...` import with **TS2834: Relative import paths need explicit file extensions…**. The
    IDE TS server resolves an open file by walking UP the directory tree for the nearest
    `tsconfig.json` *before* consulting the root's `references`, so a directory-local node22 config
    wins and you can't override it from root. **Fix = repoint that file to
    `extends: "../tsconfig.app.json"`** (Bundler resolution) — silences TS2834 with **zero import
    changes** and matches how Vite/Playwright actually resolve. Do NOT "fix" TS2834 by adding `.js` /
    barrel-index extensions to the imports: that accommodates the wrong resolution mode, churns every
    spec + support file, and diverges from the project's Bundler convention. Note `vue-tsc --build`
    (CLI) loads ALL references unconditionally, so a CLI `type-check` can pass green while the IDE
    still mis-routes a file via walk-up — verify a resolution fix in both, and "Restart TS Server"
    after editing the e2e tsconfig.
  - **Typing the suite caught real latent bugs** the untyped specs hid (e.g. `locator.textContent()`
    is `string \| null` but `.not.toHaveText()` rejects `null` → coerce with `?? ''`). DOM globals
    (`document`/`window`/`navigator`/`localStorage`) used inside `page.evaluate(() => …)` callbacks
    need the DOM lib — another reason the config extends `tsconfig.app` (DOM), not `tsconfig.node`
    (node-only lib). Keep `support/*.ts` and specs type-clean — `npm run type-check` enforces it now.
- **`npm run lint` on the suite: zero errors, ~50 advisory warnings — that's the expected state.**
  `eslint.config.ts` applies `pluginPlaywright.configs['flat/recommended']` to `e2e/**`, which makes
  `no-wait-for-timeout` / `no-conditional-in-test` / `no-conditional-expect` / `no-skipped-test` /
  `expect-expect` **warning-severity** (they don't fail the run). The warnings are legitimate E2E
  patterns, not bugs: `waitForTimeout` for proving a negative (Enter on a disabled form fires no
  request — there's no event to await), vuedraggable's 250ms drag-activation delay, third-party
  tooltip/chart animation settling; ternaries selecting a locale-dependent expected value; the two
  documented `test.skip`s (SS-09 real WebAuthn ceremony, SS-10 unforceable `browserSupportsWebAuthn`).
  Leave them — don't rewrite into `waitForResponse`/unconditional forms (couples to request timing,
  reintroduces flake) and don't sprinkle `eslint-disable`. **Errors** (not warnings) must stay at
  zero: ternary-as-statement trips `@typescript-eslint/no-unused-expressions` (use `if/else` in a
  `page.route` handler, not `cond ? a() : b()`), and `@ts-ignore` trips `ban-ts-comment` (prefer
  `@ts-expect-error`, or just drop it — `Object.defineProperty(obj, …)` is already error-free since
  its `PropertyDescriptor` arg isn't checked against the existing property type).
- **Shared-account hygiene:** every seeded entity is named with an `E2E ` prefix and create-then-
  delete'd in a `finally`. Never assert fixed row counts. `assertNoErrorLeak(page)` on every page
  test — **except** intentional-error tests, where the app legitimately renders `unknownError`
  ('Невідома помилка'); skip the assertion there with a comment.

### Nuxt UI selectors in a real browser (differ from jsdom unit tests)

- **`UAlert` has no `role="alert"`.** Match its text via `[data-slot="title"]` / `[data-slot="description"]`
  + `.filter({ hasText })`. Don't use `[data-slot="root"]` — it collides with `UTabs`.
- **`USelect` IS a `role="combobox"` in a real browser** (unlike jsdom). Options render as
  `[role="option"]` in a portal *after* clicking the trigger; the shown value sits in
  `[data-slot="value"]`. `.toHaveValue()` still does not work — assert the value slot's text.
- **`UInputDate` is `role="group"` of `role="spinbutton"` segments**, not a textbox. Keyboard typing
  truncates; drive the calendar popover instead (`td[role="gridcell"]:not([data-disabled])`).
- **`UButton` with `:to` + `:disabled`** drops the href but keeps `role="link"` +
  `aria-disabled="true"` → assert `toHaveAttribute('aria-disabled','true')`, not `toBeDisabled()`.
- **`UDropdownMenu`:** `type:'label'` items render as `[data-slot="label"]` (not `role=menuitem`);
  `type:'separator'` is decorative. Menu items are `role="menuitem"`.
- **`ConfirmModal` description** is a `<p class="text-sm text-muted">` in the `#body` slot, **not**
  `[data-slot="description"]`. Assert the dialog title instead (and beware `labelStrings` containing
  regex-special chars like `?`/`.` — escape, or match the title text).
- **Don't assert on internal Tailwind classes** (`bg-elevated`, `!bg-elevated`, etc.) to detect
  open/selected state — they're brittle implementation detail. Assert an observable consequence
  (e.g. a gated control becoming visible: clicking a charge tag opens the wallet Tags section, so
  the `wallets.clear` button — which only renders when a tag is selected — appears).
- **`TagFormInput`** is a custom dropdown, not a listbox: results are `button[class*="rounded-full"]`
  inside `.absolute.z-10`; `getByRole('option')` / `[role="listbox"]` don't match.
- **Expanded charge row: the first `button[class*="rounded-full"]` is the (text-less) select control,
  not a tag chip.** Scope tag-chip locators by the seeded name —
  `row.locator('button[class*="rounded-full"]').filter({ hasText: tagName }).first()` — or you target
  the select toggle and the click is a no-op.

### Component behaviours that bite when scripting

- **Charge row actions** are `invisible group-hover:visible … pointer-coarse:visible`: `await row.hover()`
  before clicking the menu on desktop; on the mobile/touch project they're always visible.
- **`WalletHeader` more-actions:** only **Delete** opens a `ConfirmModal`; Archive/Disable/Activate/
  Unarchive fire immediately (no confirm dialog).
- **Wallet switcher links** can match an `/Edit/i` name regex — target `a[href*="/wallets/${id}/edit"]`
  to disambiguate.
- **Locale-specific cancel labels:** `wallets.cancel` = 'Відміна' and `limits.cancel` = 'Відміна', but
  `common.cancel` = 'Скасувати'. ConfirmModal cancel/confirm labels are component props — match the
  actual key the component passes, not `common.*`.
- **`/settings` profile tab has two Save buttons** (ProfileSettings + ProfilePhoto) → `.first()`.
  `securitySettings.newPassword` (`/New Password/i`) also matches "Confirm New Password" → use
  `labelExact` for the two password fields.
- **`label()` is a substring match, so shared prefixes collide — and the collision can be
  locale-specific.** The charge edit form's submit is `charges.update` = 'Update'/'Змінити', but the
  same form has 'Edit details'/'Edit date' toggles whose UK translations ('Змінити деталі'/'Змінити
  дату') share the 'Змінити' stem — `label('charges.update')` matches all three, `labelExact(...)`
  only the submit. The mirror trap: when a message interpolates a count (`'{count} selected'` /
  `'{count} обрано'`) you can't use `label()` and must hardcode the word in a regex — copy the
  *actual* uk.ts string, don't guess (it's 'обрано' here, not 'вибрано'). Sanity-check selectors in
  *both* locales; the EN side can be collision-free and correct while the UK side isn't.
- **`UCollapsible` with `:unmount-on-hide="false"`** mounts its content (and fires its data fetches)
  on page load even while closed — register `page.waitForResponse(...)` **before** `page.goto`.
  Charts inside a collapsible need the panel opened before asserting the canvas.
- **App-init state settles *after* `domcontentloaded` — poll, never single-read it.** After
  `page.reload()` (or first `goto`), the locale (`loadCachedLocale()` reads the `cshtrkl` cookie on
  mount, then GET /api/profile confirms it) and dark mode (VueUse `colorMode` reapplies `html.dark`
  from localStorage) land a tick or two *after* `waitForLoadState('domcontentloaded')`. A raw
  `const v = await page.evaluate(() => document.documentElement.lang); expect(v).toBe(...)` is a race
  that wins ~most runs and fails intermittently (cost me a flaky IT-02/IT-04/NAV-07). Use the
  web-first form: `await expect.poll(() => page.evaluate(() => …), { timeout: 5000 }).toBe(target)`.
  Reads gated by a preceding web-first assertion on the *same* state change (e.g. a
  `toContainText(/Гаманці/)` on the nav before reading `html.lang`) are already safe — i18n sets the
  nav label and `html.lang` together — so those don't need converting.
- **The profile load also STOMPS in-window writes — wait for it before switching locale or editing a
  form, not just before reading.** A subtler cousin of the read-race: AppHeader (nav links + the
  language toggle) renders immediately, *outside* the `<RouterView v-if="loading || isLogged">` gate,
  so the locale menu works and the nav has labels a beat *before* GET /api/profile resolves. When it
  does, `setProfile()` runs `localeChange(account.locale)` and profile forms run `watch(profile)` —
  overwriting anything changed in that window (a locale switch reverts to the account locale; a typed
  Name/Nickname resets to the loaded value and submits the original). `expect(nav).not.toBeEmpty()`
  does **not** guard this — the nav is non-empty from first paint. Fix: wait for the initial profile
  load before interacting — register the response **before** `goto`, then await it:
  ```ts
  const profileLoaded = page.waitForResponse(
      r => r.url().endsWith('/api/profile') && r.request().method() === 'GET' && r.status() < 500,
      { timeout: 15000 })
  await page.goto('/wallets')
  await profileLoaded
  ```
  (the `gotoReady` helper in `i18n-theme.spec.ts`). For form edits the equivalent guard is asserting
  the field is already populated — `await expect(settings.nameInput(page)).not.toHaveValue('', …)` —
  before typing. This killed the flake in IT-01..03, NAV-08, and the two settings-profile edit tests.
- **Route helpers are method-agnostic per glob** — gate with `route.request().method()` to fail only
  one verb. Don't install a GET-error route before `goto` if the page needs that GET to render
  (navigate first, then intercept the mutation). `routeDelay` + `page.unroute()` races
  ("Route is already handled") — use one handler that awaits the gate then `route.continue()`.
- **Model `.from()` is strict** — a malformed mock makes `User.from()`/`Wallet.from()` throw, which
  trips `authStore.logout()` → redirect to `VITE_WEBSITE_URL` (test looks like it "navigated away").
  `Currency.from()` needs id/code/name/char/rate/updatedAt; `Tag.from()` needs userId/createdAt/
  updatedAt. Use `defaultCurrency: null` in user mocks unless the test is about currency.
- **Limits:** `POST /api/wallets/{id}/limits` rejects `tags: []` / `null` (422) — a limit needs ≥1
  tag. `createLimitViaApi(request, walletId, tagId, opts)` takes a pre-seeded tag id (seed it with
  `createTagViaApi` and clean both up); in the UI you must pick a tag in `LimitForm`.
- **Out of scope (do not script):** WebAuthn ceremony (SS-09; `navigator.credentials` isn't
  overridable via `addInitScript` in the app's module closure, so the unsupported-state test
  SS-10 auto-skips headless), Google OAuth popup, real S3 upload, real email delivery.

---

## Browser Verification (agent-browser)

After a UI change, verify behaviour with the **`agent-browser`** skill against the running dev
stack (start order and URLs are in the cash-track:base skill → Local dev stack).

- Standard flow: `agent-browser open https://dev-cash-track.app` → Login → fill creds → redirect to
  `https://my.dev-cash-track.app` → run the change-specific checks.
- **Login workaround** if the website returns 500: see the `cash-track:base` skill, `## Local dev
  stack` section, for the `fetch()`-based cookie-setting flow.
- `agent-browser select` does not work with Nuxt UI custom comboboxes — click the combobox ref to
  open it, then snapshot and click the option ref.
- `agent-browser fill` clears the field before typing — no need for triple-click (which is not a
  valid command anyway).
- **Target stable selectors, not translated text.** Live-app `aria-label`s are i18n strings (the
  hamburger renders `aria-label="Меню"`, not `"menu"`, because the test account defaults to
  **Ukrainian**), whereas the unit-test `t` mock returns the raw key. Match on `aria-controls`,
  `id`, or `role` in browser tests — never on label or visible text.
- For each change verify: affected routes, forms (valid + invalid + submit), mobile width
  (375×812 single-column), both EN/UK locales if i18n strings changed, and light + dark mode.

---

## Skills to Load

Per the user's global instructions, **always load all applicable Vue skills together** plus
`nuxt-ui`. Beyond those, pull in the rest as the task demands:

| Skill | When |
|---|---|
| `vue-best-practices` + the other `vue-*` skills | Any Vue work — Composition API, `<script setup>`, reactivity, router, pinia, testing |
| `nuxt-ui` | Any component using Nuxt UI (the default — almost everything) |
| `tailwind-design-system` | Layout, grids, design tokens, dynamic colors, progress bars, sidebars (Tailwind v4) |
| `frontend-design` | UI/aesthetic decisions, spacing, component composition |
| `context7-auto-research` | Latest docs for Nuxt UI v4, vue-i18n, chart.js, axios, vue-router |
| `security-reviewer` | Auth flows, passkeys/WebAuthn, token/cookie handling |
| `openapi-spec-generation` | Cross-checking model classes against `/api/docs/openapi.yaml` |
| `agent-browser` | Browser verification of any UI change |

---

## Commits

Conventional Commits, scope = `frontend` (or a feature scope like `wallets`, `settings`):
`feat(frontend): ...`, `fix(wallets): ...`, `test(e2e): ...`, `refactor(charges): ...`,
`chore(frontend): ...`. Commit only after the verification commands pass. Never mention Claude
Code in commit messages, PR descriptions, or comments (per global instructions).

---

## Reference Docs

- Vue 3: https://vuejs.org/guide/  · Composition API / `<script setup>`
- Nuxt UI v4: https://ui.nuxt.com/  (Tailwind CSS v4: https://tailwindcss.com/docs)
- Pinia: https://pinia.vuejs.org/  · vue-router: https://router.vuejs.org/
- vue-i18n: https://vue-i18n.intlify.dev/  · Vite: https://vite.dev/config/
- chart.js: https://www.chartjs.org/docs/  · vue-chartjs: https://vue-chartjs.org/
- Vitest: https://vitest.dev/  · Vue Test Utils: https://test-utils.vuejs.org/
- Playwright: https://playwright.dev/
- API contract: `/api/docs/openapi.yaml`

When unsure about a current library API, consult `context7-auto-research` before guessing —
several of these libraries (Nuxt UI v4, vue-i18n 11) changed APIs across recent majors.