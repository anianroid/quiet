# When fanning implementation out to parallel agents, assign exclusive file ownership and serialize every shared file into later phases

**Problem shape:** a multi-workstream implementation is being split across concurrent agents in the same working tree (no worktrees), and several workstreams touch the same files (a central state object, a shared models file).

**The procedure:**
1. Map every planned change to its file list before spawning anything.
2. Parallelize only workstreams whose file sets are fully disjoint; give each agent an explicit
   "files you own (exclusive)" list plus "do NOT touch X — another agent owns it."
3. For a shared types/models file, pick a single owner and have it add fields other agents need
   (tell the others: "write code assuming `MeetingSummary.title` exists").
4. Workstreams sharing a mutable hub file (e.g. AppState) run serially in a later phase, each
   receiving the prior agents' reports in its prompt.
5. Forbid implementation agents from building or running git; one integration agent afterward
   runs the build loop and reconciles seams, then adversarial reviewers diff against the base branch.

**Why this works / the trap it avoids:** two agents editing one file concurrently produce silent lost updates — the second Write wins and the first agent still reports success. Compile checks per-agent don't catch it because each agent's view was locally consistent. Ownership partitioning turns the merge problem into a prompt-contract problem, and the integration build catches the few cross-file seams left.

**Evidence:** Quiet PR #1 (2026-08-05) — 10-agent workflow (3 parallel + 2 serial + build + tests + 2 reviewers + fixer) landed 2,507 insertions with zero merge conflicts; integration agent found no cross-agent compile errors.
