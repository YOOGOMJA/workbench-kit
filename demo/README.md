# demo/

Recorded walkthroughs used in the top-level README.

| File | Shows |
|---|---|
| `workbench-engine.gif` | The engine: `/workbench:task-start 42` driven by a real Claude Code agent — it loads the `task-start` skill, runs the plumbing, does the `docs-query` preflight, writes the task summary, and commits. |
| `workbench-kit-bootstrap.gif` | The bootstrap: `/workbench-kit:interview-for-personalizing` → `/workbench-kit:generate-workbench` — a real agent draws out a persona and composes a fresh minimal workbench repo. |

## How they were made (honest notes)

- **Real agent, offline.** These are genuine Claude Code sessions invoking the plugin
  skills — the agent's reasoning, the skills, and the `utils/` plumbing are real. To keep
  them deterministic-ish and avoid spamming GitHub, the engine demo runs against a
  throwaway workbench with a **fake `gh`** on `PATH` (canned issue/PR) and a local
  `origin`; no real repository is touched.
- **Recorded with [vhs](https://github.com/charmbracelet/vhs)** from the `.tape` files
  here, then sped up / down-sampled with `ffmpeg` for size.
- **One-take.** The agent is non-deterministic, so re-recording produces different (but
  equivalent) output. The `.tape` + `setup*.sh` capture the harness, not an exact replay.

## Regenerate

The scripts assume scratch dirs under `/tmp` and this repo checked out at `/tmp/wbk`
(adjust the paths in `setup*.sh` / the `.tape` files for your machine). With `vhs`
installed and the `workbench-kit` marketplace added locally
(`claude plugin marketplace add <this repo>`):

```bash
vhs demo/workbench-engine.tape
vhs demo/workbench-kit-bootstrap.tape
```
