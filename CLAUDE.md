# cash-track/claude-plugin

The Cash-Track Claude Code plugin: skills (`skills/`), agents (`agents/`), commands (`commands/`),
a SessionStart hook (`hooks/`), and helper executables (`bin/`). `.claude-plugin/plugin.json` is the
plugin manifest and `.claude-plugin/marketplace.json` the marketplace (one entry, `source: "./"`).
This file is for working on the repo itself. The plugin cannot ship a `CLAUDE.md` to its users.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<scope>): <summary>`.
The type decides the release, so pick it for what users get, not for which file changed.

| Type | Use for | Release |
|---|---|---|
| `feat` | New skill, agent, command, hook behaviour, or new capability in one | minor |
| `fix` | Wrong instructions, broken hook or script | patch |
| `docs` | Skill content edits, new knowledge in an existing skill, README | patch |
| `perf` | Smaller always-on token cost, faster hook | patch |
| `revert` | Reverting a released change | patch |
| `refactor`, `chore`, `ci`, `test`, `build` | Changes users never see | none |

- Add `!` after the scope (`feat(skills)!: ...`) or a `BREAKING CHANGE:` footer when users must act:
  a renamed or removed skill, agent, or command, or a new required setting. It produces a major release.
- Scopes in use: `skills`, `agents`, `commands`, `hooks`, `plugin`, `ci`. Name the skill when the
  change touches one only, e.g. `docs(skills): ...` with the skill named in the summary.
- Summary in imperative mood, lowercase, no trailing period, under ~72 characters.
- PRs are squash-merged, so **the PR title becomes the commit on `main`** and is what the release
  tooling parses. Keep the PR title a valid conventional commit.

## Releasing

Releases are automated by release-please (`.github/workflows/release.yml`,
`release-please-config.json`, `.release-please-manifest.json`).

1. Every push to `main` updates an open release PR (`chore(main): release ...`). It bumps
   `.claude-plugin/plugin.json` `version`, `.release-please-manifest.json`, and `CHANGELOG.md`.
2. Merge the release PR when you want to ship. That creates the tag `cash-track--vX.Y.Z` and the
   GitHub release.

Rules:

- **Never edit `version` in `plugin.json`, the manifest, or `CHANGELOG.md` by hand**, and do not add
  a `version` to the marketplace entry. Users stay on the manifest version until it changes, so
  unreleased commits on `main` do not reach them.
- Tags must stay `cash-track--vX.Y.Z`: Claude Code resolves plugin dependency version ranges against
  that format. Do not create plain `vX.Y.Z` tags.
- The release PR runs the required `validate` check only if the `RELEASE_PLEASE_TOKEN` secret is
  set (a PAT or App token). Without it, `GITHUB_TOKEN`-created PRs trigger no workflows and the
  merge needs an admin bypass.
- Wrong version computed? Fix the commit type in the next PR title, or force one with a
  `Release-As: X.Y.Z` footer in a commit body. Do not edit the release PR's files.

## Maintaining

Run before every PR (CI runs the same):

```bash
claude plugin validate .
./scripts/check-paths.sh
./hooks/test-session-start.sh
```

- **No absolute or machine-specific paths** in `skills/`, `agents/`, `commands/`, `hooks/`, `bin/`.
  `${CLAUDE_PLUGIN_ROOT}` is not available in Bash tool calls; ship executables in `bin/` (on `PATH`)
  instead. The gateway path is `${CASHTRACK_GATEWAY_PATH:-$(go env GOPATH)/src/github.com/cash-track/gateway}`.
- **Always-on budget:** every `name` and `description` of skills, agents, and commands loads in every
  session. Keep the total under 2,000 tokens; check with `claude plugin details cash-track` after any
  description change. Bodies load on invoke, so put detail there.
- A command must never share a name with a skill, or the command shadows it.
- Adding or removing a skill, agent, or command: update the counts and tables in `README.md`.
- Skills hold reusable knowledge only. One-off incident write-ups go to GitHub issues in the
  component repo (e.g. `cash-track/infra` with the `incident` label), not into skill bodies.
- Keep `README.md` user-facing (install, update, what ships); repo workflow belongs here.
- Design rationale lives in `docs/`. Update it when a decision there changes.
