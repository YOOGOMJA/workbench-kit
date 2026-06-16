<p align="center">
  <img src="assets/workbench-kit.png" width="160" alt="workbench-kit" />
</p>

<h1 align="center">workbench-kit</h1>

<p align="center">
  A tool-neutral framework for agent workbenches.<br/>
  <em>Disposable tasks, durable knowledge. Bring your own rules.</em>
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

## What is this?

**workbench-kit** is the reusable mechanism behind an agent "workbench" —
a way for AI coding agents to do real work without polluting your main history.

- **Tasks are disposable, knowledge accumulates.** Every task lives on its own
  branch and workspace, then collapses into a single squash-merged increment.
- **Two layers.** Judgment stays with the agent; plumbing (git state
  transitions) is handled by scripts.
- **Bring your own rules.** The framework ships the *mechanism* — you fill in
  your own naming rules, policies, and knowledge base.

## Three layers

| Layer | What it holds |
|-------|---------------|
| **framework** | The fixed mechanism: worktree/task/codebases, increments, skills |
| **profile** | Your rules and data: naming conventions, templates, manifests |
| **knowledge** | What your work leaves behind: decisions, lessons, runbooks |

## Status

🚧 Early / design stage. The separation architecture is being settled in an ADR
before extraction. Expect things to move.

## License

[MIT](LICENSE)
