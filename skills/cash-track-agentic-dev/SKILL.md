---
name: cash-track-agentic-dev
description: |
  Multi-agent workflow for building features and fixing bugs in the Cash-Track monorepo
  (`api`, `frontend`, `website`, `infra`, `gateway`, and the cashtrack-owned images). The
  current session becomes an ORCHESTRATOR that drives three specialised subagents in
  sequence — a developer (Sonnet), a code reviewer (Haiku), and a tester (Haiku) — looping
  until the work is correct, then walks the user through review → commit → push → PR.
  ALWAYS use this skill when the user asks to implement a feature, build something, add an
  endpoint/component/page, fix a bug, or address a ticket/issue in any cash-track component,
  AND wants it carried through to a reviewed, tested, committed change or a pull request.
  Trigger on phrases like "implement", "build this feature", "add support for", "fix this
  bug", "work on this ticket", "take this from requirements to PR", "do the full workflow",
  "develop and open a PR", or any request that spans implementation + review + testing +
  delivery rather than a single quick edit. Skip it for trivial one-line edits, pure
  questions, or read-only investigation where no implementation/PR is wanted.
---

# Cash-Track Agentic Development Workflow

You are the **orchestrator**. You do not write the feature code yourself — you dispatch
specialised subagents, relay their output between each other, decide when each phase is
done, and own the human-facing delivery steps (review, commit, push, PR). Keep your own
model (whatever the session started with); the subagents get explicit model overrides.

The whole point of this workflow is **separation of concerns**: a developer who is close
to the code, a reviewer who is deliberately a fresh pair of eyes, and a tester who proves
the change actually works. Quality comes from the loops between them, not from any single
pass.

## Why subagents, and how they share state

- Subagents run in the **same working tree** as you — they edit the real files, so changes
  hand off naturally (the reviewer reads what the developer wrote; the tester runs against
  it). Do **not** use worktree isolation here.
- Keep the **developer agent alive** across the whole workflow. Dispatch it once, capture
  its agent ID/name, and use `SendMessage` to send it review findings or test failures so
  it fixes them **with its original context intact**. Spawning a fresh `Agent` each round
  throws away that context and makes the developer re-derive everything — slow and lossy.
- The **reviewer and tester are spawned fresh each round.** Their value is independence; a
  reviewer that remembers writing the code is no longer a fresh pair of eyes.
- A subagent's final message comes back to you as the tool result — it is **not** shown to
  the user. Relay what matters.

`Agent`, `SendMessage`, and `EnterWorktree` are deferred tools. Load their schemas first
with `ToolSearch` (e.g. `select:Agent,SendMessage`) before calling them.

## The pipeline at a glance

```
Phase 0  Orchestrator: gather requirements → cut feature branch from latest main/master
Phase 1  Developer agent (Sonnet): implement + tests, self-review, run tests + linters
Phase 2  Reviewer agent (Haiku):   review → findings? → SendMessage to developer → repeat
                                    until reviewer has nothing material → continue
Phase 3  Tester agent (Haiku):     run the project's tests (browser / E2E / API) →
                                    failures? → SendMessage to developer → back through
                                    Phase 2/3 → repeat until green
Phase 4  Orchestrator + user:       summary → user reviews diff → ACK → commit → ask Push
                                    → ask PR → open PR with full description
```

Drive this as a loop. You are done with a phase only when its exit condition is met — do
not advance on a half-finished phase to "save time".

---

## Phase 0 — Requirements and branch

**1. Establish requirements.** In priority order:
1. If the user pointed at a requirements doc / issue / ticket, read it.
2. If the conversation already contains the requirements, use them.
3. Otherwise infer from context and **state your understanding back to the user in one or
   two sentences**, then proceed. Only ask the user if something material is genuinely
   ambiguous and you cannot pick a sensible default — don't interrogate.

Write a short, concrete **requirements brief** (a handful of bullet points: what to build,
acceptance criteria, which component(s) it touches). You will pass this verbatim to the
developer agent and reuse it for self-review and the PR.

**2. Identify the target component(s)** and cut the branch in the **correct repo**. The
cash-track components are **separate git repos** — `api`, `frontend`, `website`, `infra`,
and the gateway repo (resolve with `${CASHTRACK_GATEWAY_PATH:-$(go env GOPATH)/src/github.com/cash-track/gateway}`) each have their own `.git`. The
top-level `cash-track` dir is *not* a git repo. Branch in whichever repo will hold the
change (a cross-cutting change may need a branch in more than one repo).

For each target repo:
```bash
cd <repo>
git fetch origin
# detect default branch (main or master):
DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT=${DEFAULT:-$(git remote show origin | sed -n 's/.*HEAD branch: //p')}
git switch -c <type>/<slug> origin/$DEFAULT
```
Branch naming: `feat/<slug>` for features, `fix/<slug>` for bugfixes (conventional, matches
the project's commit scope convention). Cutting from `origin/$DEFAULT` guarantees you start
from the **latest** default branch, not stale local state.

Tell the user which branch(es) you created and in which repo before moving on.

---

## Phase 1 — Developer agent (Sonnet)

Dispatch one `Agent` with `subagent_type: "general-purpose"` and `model: "sonnet"`. This
agent does the real implementation. **Capture its ID/name** — you will keep talking to it.

The developer's contract (encode this in the dispatch prompt — full template in
`references/agent-prompts.md`):
- Load the **project skills for the target component** (mapping in
  `references/component-playbooks.md`) and follow them plus `cash-track-base`. These
  skills are not optional — they carry the project's conventions.
- Implement the requirements brief using project best practices.
- **Write tests** (unit and/or E2E/feature) for the new behaviour where the component
  supports it. A feature without tests is not finished.
- **Self-review** before handing off: go back through the requirements brief item by item
  and confirm each is implemented and implemented *correctly* — not just present.
- **Run the component's tests and linters** (commands in `component-playbooks.md`) and fix
  what it broke. Hand off only when its own tests and linters pass.
- Report back: what changed (file list + summary), which requirements are covered, what
  tests were added, and the test/lint results.

If the developer reports it could not satisfy a requirement (genuine blocker, missing
decision), surface that to the user rather than letting the pipeline limp forward.

---

## Phase 2 — Reviewer agent (Haiku), with feedback loop

Dispatch a **fresh** `Agent`, `subagent_type: "general-purpose"`, `model: "haiku"`. Give it
the requirements brief and the developer's change summary. Its job is to review the diff
against project conventions, the relevant project skills, and general best practices — and
to be **specific and material**: real correctness bugs, convention violations, missing
tests, security issues. It should *not* invent nitpicks to look busy; "nothing material to
raise" is a valid and common outcome.

The reviewer outputs a structured list of findings (severity + file:line + what + why), or
an explicit "no material findings".

**Loop:**
- **Findings exist** → `SendMessage` to the **developer agent** with the findings. The
  developer evaluates each (it may push back with reasoning if a finding is wrong — relay
  that), implements the accepted ones, re-runs tests + linters, and reports back. Then
  spawn a **fresh** reviewer to re-review. Repeat.
- **No material findings** → Phase 2 is complete; continue to testing.

Cap the loop at a sensible number of rounds (≈3). If the reviewer and developer are stuck
disagreeing, stop and bring the disagreement to the user with both positions — don't spin.

---

## Phase 3 — Tester agent (Haiku)

Dispatch a **fresh** `Agent`, `subagent_type: "general-purpose"`, `model: "haiku"`. The
tester runs the kind(s) of tests the **target component actually supports** and that prove
the change works end-to-end — not just the unit tests the developer already ran. See
`references/component-playbooks.md` for per-component test types and how to run them:

- **frontend** → Vitest unit, Playwright E2E, and (for user-visible changes) the
  `agent-browser` skill against the running stack.
- **api** → `composer phpunit` feature/unit tests; for endpoint changes, exercise the API.
- **gateway** → `make test` (`go test -race`).
- **website** → build + lint; `agent-browser` for visible changes.
- **infra** → offline syntax/lint paths (`ansible-playbook --syntax-check`, `ansible-lint`,
  `terraform validate`) — never production actions.

Browser / live-stack testing requires the full local stack running (see the
`cash-track-base` skill, `## Local dev stack` section). If the stack is not up and the change
needs browser verification, ask the user to start it (they can use `! <command>` in the prompt)
rather than guessing.

**Loop:** test failures → `SendMessage` to the developer to fix → re-run the relevant tests
→ if the fix is non-trivial, send it back through a quick Phase 2 review → repeat until
green. Real failures that reveal a requirements gap go back to the user.

The tester reports: what was run, the results, and (for browser tests) what was observed.

---

## Phase 4 — Human handoff: summary → commit → push → PR

This phase is **yours**, and every outward step is **gated on explicit user approval**. Do
not commit, push, or open a PR without it.

**1. Summary + diff review.** Present the user a concise summary: the requirements, what
changed (per repo), tests added, and the verification done (review outcome + test results).
Then let them review the actual changes (`git diff` / `git status` in the target repo).
**Wait for their ACK.** If they ask for changes, route those back through the developer
(and re-review/re-test as needed) — the pipeline is still live.

**2. Commit (only after ACK).** Commit on the feature branch you cut in Phase 0. Use
**Conventional Commits** with the scope matching the directory: `feat(api):`,
`fix(gateway):`, `chore(frontend):`, `feat(infra):`, `docs(website):`. Keep commit-message
trailers per the harness defaults (the `Co-Authored-By` / `Claude-Session` lines).

**3. Ask to Push.** After committing, **ask** whether to push. On yes: `git push -u origin
<branch>`.

**4. Ask to open a PR.** After pushing, **ask** whether to open a PR. On yes, create it with
`gh pr create`. The description must include:
- **Problem statement** — what need/bug this addresses.
- **Changes** — a short, readable description of what was done.
- **Verification** — the review outcome and the tests run (what was checked and the result).

PR constraints for this project (from the user's global instructions — these override the
harness PR defaults):
- **Do not mention Claude Code** anywhere in the PR description or comments.
- **Do not include a "Test plan" section** (the Verification section covers proof of
  testing instead).

---

## Orchestrator discipline

- **Relay, don't ghost-write.** When you pass output between agents, pass the substance.
  Don't paraphrase a code review into vagueness.
- **Models are defaults, not dogma.** Sonnet/Haiku/Haiku is the baseline. If the task is
  genuinely complex, or the user asks, you may upgrade the reviewer or tester to Sonnet/Opus
  — note when you do and why. Don't downgrade the developer below Sonnet.
- **Keep the user oriented at phase boundaries** with one-line status updates ("Developer
  done, 4 files changed, 6 tests added — handing to review"). They can't see subagent
  output; short signposts keep them in the loop without noise.
- **Run independent dispatches in parallel only when they're truly independent.** The phases
  here are sequential by nature (each depends on the previous), so dispatch one at a time.
- Read `references/agent-prompts.md` for the exact dispatch prompt templates, and
  `references/component-playbooks.md` for the per-component skills, test commands, and
  linters before dispatching.
