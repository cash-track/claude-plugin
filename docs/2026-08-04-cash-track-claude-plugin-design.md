# Cash-Track Claude Code plugin

Date: 2026-08-04
Status: approved, ready for implementation planning

## Problem

Six Cash-Track skills live in `/Users/vovan/projects/cash-track/.claude/skills/` (about 2,900 lines
across `SKILL.md` files, one `references/` tree, and one shell script). The monorepo root is not a
git repository, so none of it is tracked, backed up, or reachable by anyone else. The root
`CLAUDE.md` (15.6 KB) has the same problem, and two of its content blocks exist nowhere else.

Goal: move this content into a versioned, publicly installable Claude Code plugin that teammates
get and keep current without manual copying.

## Decisions

| Question | Decision |
|---|---|
| Audience | The maintainer plus teammates |
| Repo | `cash-track/claude-plugin`, public, in the existing org |
| Granularity | One repo, one plugin, marketplace manifest at the repo root |
| Scope | Full consolidation: skills, agents, commands, hook, and the root `CLAUDE.md` |
| Release model | Track `main` via `source: "./"`, gated by CI and branch protection |
| Precondition | Every hardcoded machine-specific path is fixed before the first publish |

Rejected alternatives:

- **Three plugins split by component area.** The always-on cost of a skill is its description. The
  six current descriptions measure about 1,381 tokens combined, so a seventh plus three agents and
  the hook lands near 1,800. Splitting would let a frontend contributor skip roughly 400 of those
  tokens, which does not justify three manifests, three version numbers, and a dependency graph.
  Trimming the descriptions is the better lever and is cheaper (see "Token budget").
- **Hosting inside `cash-track/.github`.** Saves creating a repo and costs permanent ambiguity.
  `.github` repos carry special GitHub semantics for org profile and community health files, and
  `claude plugin marketplace add cash-track/.github` reads like a typo.
- **Pinned semver releases.** Real rollback, but a three-step release ritual on a repo with one
  committer will be skipped. Revisit only if a bad push actually causes harm. `plugin.json` stays
  versioned so the option remains open.
- **`~/.claude/skills/` git clone.** Lowest ceremony, but it has no distribution story for
  teammates, which is the stated requirement.

## Constraints verified against Claude Code 2.1.221

These were confirmed on the target machine rather than assumed.

- Plugins contribute skills, agents, hooks, MCP servers, and LSP servers. There is **no** mechanism
  for a plugin to contribute a `CLAUDE.md` or a `.claude/rules/*.md` file.
- `${CLAUDE_PLUGIN_ROOT}` is substituted in hooks, commands, and `allowed-tools` frontmatter. It is
  **not** exported into Bash tool calls: `echo "${CLAUDE_PLUGIN_ROOT:-UNSET}"` prints `UNSET` in a
  normal session. A skill cannot use it to locate its own files.
- Every installed plugin's `bin/` directory **is** prepended to `PATH` for Bash tool calls. Verified:
  `command -v agent-browser` resolves inside the agent-browser plugin cache. This is the supported
  way to ship an executable helper.
- The per-marketplace auto-update flag is the key `autoUpdate` on the marketplace entry in
  `known_marketplaces.json`, recovered from the 2.1.221 binary. Confirm by diffing that file before
  and after toggling in `/plugin`.
- `manifest.userConfig` allows install-time prompting and `claude plugin install --config k=v`.
  Whether those values reach skill bodies is not documented.
- Claude Code auto-loads plugins found in `.claude/skills` directories with no marketplace involved.
- Marketplace auto-update is a **per-marketplace toggle and is not on by default**. Evidence: the
  local `laravel` clone sits at `340aeba` (2026-03-11) against upstream `ebf2b56`, and
  `agent-browser` at `5b5dffe` (2026-03-18) against upstream `01c1147`. Both were added in March
  and neither has pulled since, on a machine with `autoUpdateChannel: stable` and nothing in `env`
  disabling updates.
- `claude plugin validate <path>` checks plugin and marketplace manifests locally, no API key.
- `claude plugin details <name>` prints a component inventory and projected token cost.

The two undocumented items above are resolved empirically during implementation, with a stated
fallback for each (see "Path portability").

## Repository layout

```
cash-track/claude-plugin
├── .claude-plugin/
│   ├── marketplace.json          name "cash-track", one entry, source "./"
│   └── plugin.json               name "cash-track", version, repository, license
├── skills/
│   ├── cash-track-base/          new, distilled from the root CLAUDE.md
│   ├── cash-track-api/
│   ├── cash-track-frontend/
│   ├── cash-track-gateway/
│   ├── cash-track-infra/         renamed from cash-track-infra-debug
│   ├── cash-track-agentic-dev/
│   │   └── references/component-playbooks.md
│   └── cash-track-security-upgrade/
├── bin/
│   └── cash-track-dependabot-alerts   auto-added to PATH, see "Path portability"
├── agents/
│   ├── cash-track-developer.md   model: sonnet
│   ├── cash-track-reviewer.md    model: haiku
│   └── cash-track-tester.md      model: haiku
├── commands/
│   ├── cash-track-cve.md
│   └── cash-track-feature.md
├── hooks/
│   ├── hooks.json
│   └── session-start.sh
├── .github/workflows/validate.yml
├── README.md
└── LICENSE
```

Marketplace name `cash-track`, plugin name `cash-track`, so the plugin id is `cash-track@cash-track`.
This mirrors `agent-browser@agent-browser`, which is already installed and working on the target
machine.

## Components

### Skills

Seven skills. Six are ports of what exists today; `cash-track-base` is new.

`cash-track-infra-debug` is renamed to `cash-track-infra` because it absorbs the Ansible local-check
guidance from `CLAUDE.md`, which is lint advice rather than incident response. The rename also makes
skill naming uniform: one skill per component.

### Agents

`references/agent-prompts.md` currently holds three parameterised prompt templates that the
`cash-track-agentic-dev` orchestrator pastes into `general-purpose` dispatches. Each becomes a real
agent file with `model` pinned in frontmatter, and the reference file is deleted.

| Agent | Model | Replaces |
|---|---|---|
| `cash-track-developer` | sonnet | Section 1 of `agent-prompts.md`, dispatched once and kept alive via `SendMessage` |
| `cash-track-reviewer` | haiku | Section 2, fresh each round, exits on `NO MATERIAL FINDINGS` |
| `cash-track-tester` | haiku | Section 3, fresh each round |

`cash-track-agentic-dev/SKILL.md` is rewritten to dispatch by `subagent_type` instead of pasting
templates. This removes about 25 lines of prompt text per dispatch round and turns the model pins
from prose the orchestrator can ignore into frontmatter it cannot.

The "Notes" section of `agent-prompts.md` (pass diffs by reference, one dispatch at a time, model
upgrade guidance) moves into `cash-track-agentic-dev/SKILL.md`.

### Token budget

Measured on the current skills, per-skill frontmatter cost:

| Skill | Approx. always-on tokens |
|---|---|
| `cash-track-frontend` | 328 |
| `cash-track-agentic-dev` | 300 |
| `cash-track-security-upgrade` | 251 |
| `cash-track-api` | 218 |
| `cash-track-infra` | 151 |
| `cash-track-gateway` | 133 |
| **Current six** | **1,381** |

Adding `cash-track-base`, three agents, and the hook puts the plugin near 1,800 always-on
tokens. For comparison, superpowers carries 14 skills for 688 tokens, so these descriptions run
roughly 4 to 6 times longer than typical. That is a consequence of the multi-line trigger-phrase
lists in each description.

Budget: **stay under 2,000 always-on tokens**. Above that, trim the trigger-phrase lists rather than
splitting the plugin. The comparison that matters is the current state, which pays these 1,381
tokens *plus* about 3,900 for the 15.6 KB root `CLAUDE.md`, so the design cuts always-on cost by
roughly two thirds.

### Commands

`/cash-track-cve <repo>` exists because `cash-track-security-upgrade` takes exactly one argument and
a command passes arguments properly where a description trigger phrase does not. Its name must differ
from the skill's: a command and a skill sharing one name collide in the skill namespace, the command
wins, and the command's own "invoke the skill" line then resolves back to the command.

`/cash-track-feature <brief>` is a discoverability wrapper over `cash-track-agentic-dev`. It is thin
by design and can be dropped without affecting anything else.

### Hook

A `SessionStart` hook detects a Cash-Track checkout by matching `git remote get-url origin` against
`github.com[:/]cash-track/`, and falls back to the monorepo directory signature (`api/app/src` and
`frontend/src` both present) for the untracked monorepo root. On a match it emits roughly ten lines
pointing at the `cash-track-base` skill.

This exists because deleting the root `CLAUDE.md` would otherwise trade a guaranteed context
injection for a skill description Claude merely ought to act on. The hook restores the guarantee at
roughly 50 always-on tokens instead of the current 4,000, and unlike a `CLAUDE.md` stub it ships
with the plugin, so teammates need no local setup.

## Path portability

Nine hardcoded machine-specific paths must be fixed before the first publish.

| Location | Current | Fix |
|---|---|---|
| `agentic-dev/SKILL.md:82` | `~/go/src/github.com/cash-track/gateway` | Gateway resolution, below |
| `agentic-dev/references/component-playbooks.md:52` | same | Gateway resolution |
| `gateway/SKILL.md:5` | same | Gateway resolution |
| `gateway/SKILL.md:22` | same | Gateway resolution |
| `security-upgrade/SKILL.md:48` | same | Gateway resolution |
| `security-upgrade/SKILL.md:90` | `~/projects/cash-track/.claude/skills/.../dependabot-alerts.sh` | Move to `bin/cash-track-dependabot-alerts`, call it bare with no path |
| `frontend/SKILL.md:14` | `(per /Users/vovan/.claude/CLAUDE.md)` | Delete the parenthetical, keep the skill list |
| `frontend/SKILL.md:688` | `export PATH="/Users/vovan/.nvm/versions/node/v22.12.0/bin:$PATH"` | Capture `NODE_BIN="$(dirname "$(command -v node)")"` before the `unset -f`, then `export PATH="$NODE_BIN:$PATH"` |
| `frontend/SKILL.md:873` | `/Users/vovan/projects/cash-track/CLAUDE.md` → Testing | Point at the `cash-track-base` skill |

**Gateway resolution.** Use `${CASHTRACK_GATEWAY_PATH:-$(go env GOPATH)/src/github.com/cash-track/gateway}`.
This resolves with zero setup for anyone using the standard GOPATH layout, which describes everyone
who edits the gateway, and the environment variable covers the rest. `userConfig` would give a
nicer install-time prompt; adopt it only if implementation confirms those values reach skill bodies.

**Helper script location.** `CLAUDE_PLUGIN_ROOT` is not exported into Bash tool calls, so a skill
cannot use it to find its own script. Plugin `bin/` directories are prepended to `PATH` instead, so
the script moves to `bin/cash-track-dependabot-alerts` (executable, no extension) and the skill
invokes it bare:

```bash
cash-track-dependabot-alerts cash-track/<repo>
```

No path appears anywhere, so the CI path guard cannot be tripped by this call site. This is exactly
how `agent-browser` is callable from any session.

**RTK terminal block.** The Playwright JSON-reporter workaround at `frontend/SKILL.md:684-696`
exists because the RTK terminal wrapper mangles stdout. It is not the standard way to run specs.
Gate it explicitly as "if you are in an RTK terminal" so teammates on ordinary terminals are not
misled.

## Root CLAUDE.md consolidation

The file is dissolved and deleted. Content is redistributed:

| Section | Destination |
|---|---|
| Repo Layout, Project Overview, Request flow, Active migrations | `cash-track-base` |
| Commands (gateway, api, frontend, website) | `cash-track-base` |
| Testing: stack start order, URLs, login workaround | `cash-track-base` |
| Code Standards, Conventional Commits | `cash-track-base` |
| Architecture subsections | Already in the per-component skills. Verify coverage, then delete |
| API Documentation, API Key Facts | `cash-track-api` |
| Infra Ansible local checks | `cash-track-infra` |
| Frontend Testing (Vitest) | Delete. Already duplicated in `cash-track-frontend` |
| Browser Testing (agent-browser) | `cash-track-frontend` |

Audited before writing this spec: the Vitest block is genuinely redundant (`UIcon`/`icon-stub`,
`inline-flex`, `rrggbbaa`, and `UDropdownMenu` all already appear in `cash-track-frontend/SKILL.md`).
The Ansible block and the agent-browser block appear in no skill at all, so they are content that
currently exists only in an untracked file. Losing them silently is the exact failure this project
prevents. Both must be moved, not deleted.

## Installation and updates

README documents two paths.

Imperative:

```bash
claude plugin marketplace add cash-track/claude-plugin
claude plugin install cash-track@cash-track
```

Declarative, in `~/.claude/settings.json`:

```json
"extraKnownMarketplaces": {
  "cash-track": { "source": { "source": "github", "repo": "cash-track/claude-plugin" } }
},
"enabledPlugins": { "cash-track@cash-track": true }
```

This must be user-level. Project-level `.claude/settings.json` still triggers an install-consent
prompt on every loader path, and `pluginConfigs` are not read from it. The point is moot for this
project anyway, since the monorepo root has no git repository through which to share such a file.

**Auto-update requires an explicit step.** The README must instruct users to enable the
per-marketplace auto-update toggle in `/plugin`. Without it they remain on whatever commit they
installed, with no signal that they are stale. Implementation resolves the corresponding
`known_marketplaces.json` key and documents both the toggle and the key, so the declarative install
path above is complete rather than half-configured.

## CI

`.github/workflows/validate.yml`, on every pull request and every push to `main`:

1. `npm i -g @anthropic-ai/claude-code && claude plugin validate .`
2. A guard that fails the build if `/Users/`, `~/projects/`, or `~/go/src/` appears anywhere under
   `skills/`, `agents/`, or `commands/`.

Step 2 is the highest-value test in the design. It makes the specific bug class this project exists
to fix impossible to reintroduce, and it costs three lines of `grep -r`.

Both checks are required by branch protection on `main`. Combined with `git revert`, that is the
entire safety story for tracking `main`, which is proportionate for an internal plugin with one
committer.

`claude plugin eval` supports scored behavioural testing of plugins. Out of scope for v1. Revisit
if a skill starts misfiring in practice.

## Cutover

Performed in a single session so that no window exists in which the skills are neither installed nor
backed up.

1. `gh repo create cash-track/claude-plugin --public`
2. Port the skills, apply the nine path fixes, add manifests, agents, commands, hook, README, and
   CI. Push to `main`.
3. `claude plugin marketplace add cash-track/claude-plugin && claude plugin install cash-track@cash-track`
4. Restart. Run `claude plugin details cash-track` and confirm 7 skills, 3 agents, 1 hook, and an
   always-on cost under 2,000 tokens.
5. `mkdir -p .claude-backup && mv .claude/skills .claude-backup/skills-2026-08-04`
6. Delete the root `CLAUDE.md`, only after confirming `cash-track-base` covers it.
7. Restart. Confirm no duplicate skill names, and that the SessionStart hook fires both in the
   monorepo and in the gateway repo at `$(go env GOPATH)/src/github.com/cash-track/gateway`.
8. Enable marketplace auto-update.

Step 5 is mandatory rather than optional cleanup. Claude Code auto-loads plugins from
`.claude/skills` directories, so leaving the originals in place after installing the plugin
registers every skill twice, once from `skills-dir` and once from `cash-track@cash-track`. Renaming
the directory to `.claude-backup/` is sufficient, because only `.claude/skills` is scanned.

Rollback at any point: `mv .claude-backup/skills-2026-08-04 .claude/skills` and
`claude plugin uninstall cash-track@cash-track`.

## Acceptance criteria

- `claude plugin validate .` passes.
- CI fails on a commit that introduces an absolute `/Users/` path under `skills/`.
- `claude plugin details cash-track` reports 7 skills, 3 agents, 1 hook, and an always-on cost under
  2,000 tokens.
- No skill name is registered twice after cutover.
- The SessionStart hook fires in the monorepo and in the gateway repo, and not in an unrelated repo.
- Every content block from the root `CLAUDE.md` is either present in a skill or explicitly recorded
  as redundant in the table above.
- A clean machine can reach a working setup using only the README.
- No file under `skills/`, `agents/`, or `commands/` contains a path specific to one machine.
- `cash-track-dependabot-alerts` resolves as a bare command in a Bash tool call after install.
