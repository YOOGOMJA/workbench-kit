# Workbench Knowledge Ecosystem

> 한국어: [workbench-knowledge-ecosystem.ko.md](workbench-knowledge-ecosystem.ko.md)

The big-picture page for how the `docs/` wiki is structured and how it is
consumed, produced, and tidied. The detailed operating procedures are delegated
to skills.

## The 2×2 frame + the seams

|              | Structure (static · nouns)   | Lifecycle (dynamic · verbs)      |
|--------------|------------------------------|----------------------------------|
| **task**     | ① the `task/` folder + genres | ② the task micro-cycle           |
| **workbench**| ③ the `docs/` wiki layout     | ④ the three operations (Query/Ingest/Lint) |

①③ are structure, ②④ are flow. The **seams** that join them are first-class:

- **Query** — docs/ → task (inbound): a starting task pulls in prior knowledge.
- **Ingest** — task → docs/ (outbound): a submitting task weaves its harvest into the wiki.

## The two fates inside a task

Content inside `task/` splits into two fates:

1. **Disposable work context** — status, log, plans, researches. It is *meant* to
   vanish at cleanup.
2. **Harvest** — the survivors among decisions/lessons/runbooks. They are ingested
   into `docs/` before cleanup, and persist.

Discipline per genre:

| Genre | task/docs/ | workbench docs/ |
|-------|-----------|-----------------|
| researches/, plans/ | volatile | none |
| decisions/ | staging → harvest | permanent (immut+supersede) |
| lessons/ | staging → harvest | permanent (immut+supersede) |
| runbooks/ | staging → harvest | living-edit |
| synthesis/topic | none | cross-task big picture |

The workbench is a **knowledge layer, not a workshop**. All work happens only
inside a task worktree, and `docs/` holds neither plans/ nor superpowers/.

## The three layers

- **`docs/`** — knowledge (harvest + synthesis). Tasks fill it.
- **`utils/`** — plumbing scripts (git state transitions).
- **`templates/`** — format specs (data). The harvest-entry formats (`*.tmpl.md`) and
  the canonical `task-AGENTS.md` live here. Authoring (deferred-referenced from
  task/AGENTS.md), validation (`docs-lint`), and ingestion (`docs-ingest` index
  derivation) all reference this single source.

## Harvest folders and anchor tables

```
docs/
  decisions/
    index.md   # anchor table — topic | one-line choice | status | →page
    NNNN-<slug>.md
  lessons/
    index.md   # anchor table — approach | one-liner | →page
    <slug>.md
  runbooks/
    index.md   # anchor table — task | one-liner | →page
    <slug>.md
```

Each folder's `index.md` is the **consumption surface**. Individual pages preserve
the full context; the index stays an anchor table for fast scanning.

## Consumption model

| Page type | Consumption mechanism | When |
|-----------|-----------------------|------|
| decisions/ | guard: scan index anchors → on a hit, follow it or supersede explicitly | just before deciding |
| lessons/ | guard: scan index anchors → avoid, or work around the constraint | just before an approach |
| runbooks/ | `@` deferred-reference from task/AGENTS.md (progressive disclosure) | when doing that task |
| synthesis | [[workbench-query]] preflight read | task-start |

**The guard sits at three checkpoints**: task-start (preflight) / mid-work (triggered
by a `decide` log event) / task-submit (Ingest backstop). No hooks needed — the guard
rides the already-mandated event flow and is closed by agent judgment. Zero harness
dependency.

## The three operations

| Operation | Direction | Skill | When |
|-----------|-----------|-------|------|
| **Query** | docs/ → task (read) | `/docs-query` | task-start + ad-hoc mid-work |
| **Ingest** | task → docs/ (weave in) | `/docs-ingest` | task-submit |
| **Lint** | within docs/ (grooming) | `/docs-lint` | maintenance tasks + opportunistically during Ingest |

**The seam contract — the three interlock**:
- Ingest weaves, it doesn't pile: update existing first, no duplicates or orphans, apply supersede.
- Lint is periodic grooming: clean up contradictions, orphans, broken cross-references, and supersede buildup so the index stays scannable.
- Query is guaranteed discovery: only if Ingest puts things in cleanly and Lint keeps them tidy will Query reliably find the relevant prior knowledge.

The three operations' contracts interlock, and the workbench lifecycle closes.

## Related

- [[workbench-query]] — the Query operation in detail
