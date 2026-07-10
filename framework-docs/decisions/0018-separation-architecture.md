# Decision: Separate framework, profile, and knowledge

- **Status:** Superseded as the sole classification by [[0024-workbench-v2-governance]]
- **Choice:** Separate a workbench into `framework` (fixed mechanics and procedures),
  `profile` (caller-supplied policy, format, terminology, and language), and `knowledge`
  (empty-start accumulated documentation). Use the mechanical-invariant versus cognitive-
  judgment boundary from ADR 0016 as the initial separation rule.
- **Context:** Reusable core behavior and caller-specific rules were mixed in the same files,
  especially `AGENTS.md`, so the core could not be distributed independently and user
  knowledge could not reliably begin empty.
- **Rationale:** Mechanical state transitions and common procedures can ship as framework;
  preference and convention values belong to the caller profile; accumulated decisions,
  lessons, and runbooks have a different lifetime and consumption path from setup values.
- **Rejected alternatives:**
  1. Use only `framework` and `user`. This mixes profile values with accumulated knowledge
     and prevents an empty-start knowledge policy.
  2. Describe the split as percentages without moving ownership boundaries. This leaves the
     original coupling in place.
  3. Keep one mixed `AGENTS.md` and annotate sections. Comments do not create an executable
     distribution boundary.
- **Supersession note:** The ownership distinctions remain valid, but the three names mix a
  responsibility classification with a data-lifetime classification. ADR 0024 retains the
  valid ownership intent as `kernel / capability pack / profile` and introduces the
  independent `task work / living state / knowledge` lifetime axis.
- **Source:** workbench#49 / 2026-06-16; translated into framework-docs by workbench-kit#25
- **Relations:**
  - extends [[0016-mechanical-invariant-enforcement]]
- **Reference:** [[0024-workbench-v2-governance]]
