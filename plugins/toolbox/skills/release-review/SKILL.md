---
name: release-review
description: Use when assessing whether a delivered toolbox scenario has sufficient current evidence and owner acceptance for human adoption.
---

# Release Review

Review facts; do not manufacture adoption. Present the conclusion in
`profile.language` while preserving canonical refs, IDs, states, and blockers.

## Review

1. Read the selected scenario and verify every acceptance criteria item against
   observable behavior. Review required design states, including responsive and
   accessibility behavior.
2. Run `workbench task evidence list --format json`. Require current passing
   evidence for every non-waived required check and exact deliverable revision.
3. Run `workbench task deliverable acceptance list --format json`. A submitted or
   open PR is not accepted; require a kernel or registered owner receipt.
4. Run `workbench task harvest show --format json`. Identify reusable decisions,
   lessons, runbooks, or framework changes. Declare and dispose candidates through
   the public harvest commands, then seal the inventory; never infer value in
   plumbing.
5. Run `workbench task verify --format json`. Treat every returned blocker as
   unresolved. Do not suppress failed or stale evidence.
6. Report ready only when acceptance criteria, design states, evidence,
   acceptance receipts, and harvest disposition agree. Hand completion and merge
   decisions to their explicit human or policy gates.

Do not deploy, do not merge, do not accept a deliverable, and do not complete or
clean the task from this review skill.
