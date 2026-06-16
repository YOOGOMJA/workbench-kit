<p align="center">
  <img src="assets/workbench-kit.png" width="160" alt="workbench-kit" />
</p>

<h1 align="center">workbench-kit</h1>

<p align="center">
  <em>You do the work. It keeps the one part worth keeping, and throws out the rest.</em>
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-early%20stage-orange" alt="status" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="license" /></a>
  <img src="https://img.shields.io/github/last-commit/YOOGOMJA/workbench-kit" alt="last commit" />
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen" alt="PRs welcome" />
</p>

---

Every workshop has one. The bench in the corner that's older than the building.
You finish a job and walk off; it stays behind, wipes itself down, hangs the one
jig worth keeping on the wall, and bins the scrap. Next time, the bench is
already set.

workbench-kit puts that bench inside your AI agent.

## How a job goes

You hand it a task — any task. It gets its own corner to make a mess in: a
branch, a workspace, scratch notes nobody else has to see. When the work is
done, one clean thing survives — a decision, a lesson, a fix — and the mess is
swept out. Your main history only ever sees the keepers.

Need a whole new workshop? Spinning up a new repo is just another job you hand it.

## Under the hood

The bench has three drawers. You only ever fill two of them.

| Drawer | What's in it |
|--------|--------------|
| **framework** | The bench itself — the parts that never change |
| **profile** | Your rules — how you name things, your templates |
| **knowledge** | What every job leaves behind — decisions, lessons, runbooks |

## Install

This repo is a marketplace shipping two plugins:

- **`workbench`** — the engine (task lifecycle, knowledge harvest). Use it inside a workbench.
- **`workbench-kit`** — the bootstrap (interview → generate a personalized workbench). Use it once to set one up.

**Claude Code**

```
/plugin marketplace add YOOGOMJA/workbench-kit
/plugin install workbench-kit@workbench-kit   # bootstrap
/plugin install workbench@workbench-kit        # engine
```

**Codex**

```
codex plugin marketplace add YOOGOMJA/workbench-kit
codex plugin add workbench-kit@workbench-kit
codex plugin add workbench@workbench-kit
```

Then set up your bench: run `workbench-kit:interview-for-personalizing` (Claude Code:
`/…`, Codex: `@…`) and it walks you through your persona, then `generate-workbench`
creates a minimal workbench repo. From there, `workbench:task-start <issue>` begins work.

## Status

🚧 It's still setting up the shop. The blueprint for the bench is being settled
before the tools go in — expect things to move. (Install above works once a release
lands on the default branch — see [RELEASING.md](RELEASING.md).)

## License

[MIT](LICENSE).
