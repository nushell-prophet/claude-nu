---
name: git-intent-squash-archive
description: Squash every commit on the current branch into one, keeping the original commit stream recoverable in an `archive/<branch>` git tag. Use this whenever a working branch is finished and its step-by-step history should stop being noise for whoever reads the trunk — "squash branch", "squash and archive", "сверни ветку", "finalize this branch", "collapse these commits", "archive the history before merging" — even when the user never names the skill. For gi working branches; when the branch also needs merging and `todo/`/`gi/` kept off the trunk, use `/land-branch` instead.
allowed-tools: Bash(git *)
---

A working branch's commits are rollback points while the work runs, and noise the moment it is done: an agent that later reads `git log` on the trunk wades through abandoned attempts and reversed decisions instead of history. So the branch lands as one commit. But those abandoned attempts are the record of *why* the surviving shape won, so the original stream is kept in a tag rather than dropped — squash for the reader, archive for the record.

This rewrites the branch (`git reset --soft`, `git tag -f`). That is why steps 1 and 6 stop instead of warning: on a trunk the reset would rewrite history other people have, and once it has run there is nothing left to confirm.

Verify the working tree is clean (`git status --porcelain` returns empty). If not, stop and ask the user to commit or stash first.

Archive and squash all commits on the current branch:

1. Get branch name: `git branch --show-current`. If `master` or `main` — **STOP immediately**, inform the user this command cannot run on the main branch, do not proceed with any further steps
2. Find base: `git merge-base main <branch>` (fall back to `master` if `main` doesn't exist)
3. List all commits on the branch: `git log --oneline <base>..<branch>`
4. If no commits — report and exit
5. Check if tag `archive/<branch>` already exists (`git tag -l archive/<branch>`). If it does, show the user what it points to and warn that it will be overwritten
6. Show the user: commit list, total count, tag overwrite warning (if applicable). **STOP.** Wait for confirmation before proceeding
7. `git tag -f archive/<branch> HEAD`
8. `git reset --soft <base>`
9. Generate commit message:
   - **Subject**: one line — what the branch accomplished
   - **Body**: summarize the decisions made on this branch, preserving the user's reasoning from original commit bodies where present, then an `Archive: archive/<branch>` trailer
   - No diff restating; no listing of things you checked and didn't find
10. `git commit`
11. Show `git log --oneline -5` and remind about `git log archive/<branch>` for the full history

## Related

- `/git-intent` — process commits as instructions and propagate choices before squashing
- `/land-branch` — the general-development counterpart: same squash-and-archive, but it also merges to the trunk and drops `todo/`/`gi/`. Use it when the branch is not gi working material.
