# Repository Working Agreement

## Commit discipline

- After each completed and verified change, create a focused Git commit before starting unrelated work.
- Inspect `git status` and the staged diff before committing.
- Stage only the files that belong to the completed change; never include pre-existing or unrelated worktree changes.
- Run the smallest relevant verification for the change before committing, and record any verification that could not be run in the handoff.
- Use a concise imperative commit subject that describes the observable change.
- Report the resulting commit hash in the task handoff.
- If a focused commit cannot be made safely because changes overlap, leave the work uncommitted and explain the overlap instead of staging unrelated work.
