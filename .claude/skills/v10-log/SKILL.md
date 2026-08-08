---
name: v10-log
description: Create or append today's Track B (V10 restoration) lab-notebook entry in docs/v10-log/. Use when starting a restoration work session or recording findings mid-session. Argument = short session goal.
---

Maintain the Track B lab notebook per the conventions in docs/v10-restoration.md.

1. Determine today's date (YYYY-MM-DD) from the environment. The entry lives at
   `docs/v10-log/<date>.md` (create the directory on first use).
2. If the file does not exist, create it from this template, filling in the goal from the
   invocation arguments (or ask what the session goal is if none given):

   ```markdown
   # V10 restoration log — <date>

   ## Goal
   <goal>

   ## Tried
   -

   ## Errors (verbatim)
   ```text
   ```

   ## Outcome

   ## Next
   -
   ```

3. If the file exists, append a new `## Session: <goal>` section with the same
   Tried/Errors/Outcome/Next structure.
4. Rules while logging: paste error text **verbatim** (it must be searchable and citable on
   TUHS later); reference patch-series numbers for any source change; if a step of the
   success ladder in docs/v10-restoration.md was completed, update the corresponding
   checkbox in docs/roadmap.md in the same session.
