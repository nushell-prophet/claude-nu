---
name: git-intent-squash-archive
version: 0.4.0
description: Squash all commits on the current branch into one, preserving the original history in a git tag. Use when the user says "squash branch" or "git-intent-squash-archive".
allowed-tools: Bash
---

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
