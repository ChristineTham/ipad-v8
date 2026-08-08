---
name: verify-step
description: Resolve a VERIFY marker in a runbook (e.g. docs/spike-a0.md) — execute or confirm the step, record evidence, correct the doc, and drop the marker. Argument = which step or marker.
---

The repo's runbooks mark unexecuted, research-derived steps with **VERIFY**. Resolving one
means replacing an assumption with evidence. Never delete a marker without having run the
step.

1. Locate the marker the user means (grep `VERIFY` across docs/ if the argument is vague).
2. Execute or directly confirm the step in the live environment (work/ directory, running
   emulator, etc.). Capture the exact command used and the relevant output.
3. Edit the runbook: replace the assumed command/claim with what actually worked, remove the
   VERIFY marker, and — where the reality differed from the assumption — add a one-line note
   of the difference (that delta is the valuable part).
4. If a results file exists for the phase (e.g. docs/spike-a0-results.md), append the
   evidence there: command, outcome, measurement if any.
5. Report in the session: marker resolved, what changed in the doc, remaining VERIFY count
   in that runbook.
