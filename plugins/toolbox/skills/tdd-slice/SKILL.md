---
name: tdd-slice
description: Use when implementing one selected scenario slice that requires test-first delivery and revision-bound verification evidence.
---

# TDD Slice

Deliver the smallest observable behavior across the real boundary. Report
reader-facing progress in `profile.language`.

## Red, Green, Refactor

1. Confirm one scenario, its acceptance criterion, repository owner, deliverable
   ID, and current run-plan check IDs.
2. Declare missing checks with `workbench task required-check declare --id
   <check-id> --owner <owner> --deliverable-id <deliverable-id> --format json`.
3. Write one behavioral test and run its exact command. Preserve the observed failing test
   output; a compile error or unrelated failure is not valid red.
4. Implement a minimal vertical slice that makes that test pass. Avoid adjacent
   features and speculative abstractions.
5. Run the focused command and required regression checks. Refactor only after green,
   then rerun all affected checks.
6. Commit the tested state. Update the deliverable to that immutable commit SHA,
   then record each result:

   ```text
   workbench task evidence record --id <evidence-id> --owner <owner> \
     --subject-ref workbench:deliverable/<deliverable-id> \
     --subject-revision <commit-sha> --check-id <check-id> \
     --result passed --source local --command <exact-command> --format json
   ```

Evidence belongs to the exact command and commit SHA. A later revision makes old
evidence stale; rerun and record new evidence. Never mark a PR accepted, complete
the task, merge, or deploy from this skill.
