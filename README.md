# Cash-Track Claude Code plugin

Skills, agents, and workflows for developing Cash-Track, distributed as a Claude Code plugin.

## Install

```bash
claude plugin marketplace add cash-track/claude-plugin
claude plugin install cash-track@cash-track
```

Restart Claude Code, then confirm:

```bash
claude plugin details cash-track
```

You should see 3 agents, 1 hook, and an always-on cost of roughly 1,700 tokens. The inventory line
reads `Skills (9)` because it counts the 2 commands alongside the 7 skills. All 9 names are distinct;
a command must never share a name with a skill, or the command shadows the skill and any delegation
from the command back to "the skill" resolves to itself.

## Turn on auto-update

**This is required.** Marketplace auto-update is off by default, and without it you will silently sit
on whatever commit you installed. Open `/plugin`, select the `cash-track` marketplace, and enable the
auto-update toggle.

To update by hand at any time:

```bash
claude plugin marketplace update cash-track
```

## Declarative install

Add to `~/.claude/settings.json`. It must be user-level: project-level `.claude/settings.json`
triggers an install-consent prompt on every load and does not read plugin config.

```json
"extraKnownMarketplaces": {
  "cash-track": { "source": { "source": "github", "repo": "cash-track/claude-plugin" } }
},
"enabledPlugins": { "cash-track@cash-track": true }
```

## What ships

| Skill | Covers |
|---|---|
| `cash-track-base` | Monorepo layout, request flow, commands, local dev stack, commit conventions |
| `cash-track-api` | Spiral, RoadRunner, Cycle ORM backend |
| `cash-track-frontend` | Vue 3 SPA, Nuxt UI, Vitest, Playwright, agent-browser |
| `cash-track-gateway` | Go / FastHTTP gateway |
| `cash-track-infra` | Production debugging, Ansible and Terraform local checks |
| `cash-track-agentic-dev` | Orchestrated build workflow |
| `cash-track-security-upgrade` | Dependency CVE remediation |

Agents: `cash-track-developer`, `cash-track-reviewer`, `cash-track-tester`.
Commands: `/cash-track-feature`, `/cash-track-cve`.

Load `cash-track-base` first in any Cash-Track repo, then the skill for the component you are
editing. A SessionStart hook injects that pointer automatically when it detects a Cash-Track
checkout, and stays silent everywhere else.

## Working on the gateway

The gateway lives in its own repo. Skills resolve it as
`${CASHTRACK_GATEWAY_PATH:-$(go env GOPATH)/src/github.com/cash-track/gateway}`. If you keep it
elsewhere, export `CASHTRACK_GATEWAY_PATH`.

## Contributing

`main` is protected. Open a PR; CI runs manifest validation, the machine-specific path guard, and the
hook tests. Run them locally first:

```bash
claude plugin validate .
./scripts/check-paths.sh
./hooks/test-session-start.sh
```

**Never commit an absolute path** such as `/Users/you/...` into `skills/`, `agents/`, `commands/`,
`hooks/`, or `bin/`. The guard will reject it. That bug class is why this repo exists.

Skill descriptions are the always-on cost: every session pays for the `name` and `description` of
every skill, agent, and command, whether or not it fires. Bodies are on-invoke only. Keep the total
under 2,000 tokens, and check it with `claude plugin details cash-track` after any description edit.

The design rationale is in [`docs/`](docs/2026-08-04-cash-track-claude-plugin-design.md).
