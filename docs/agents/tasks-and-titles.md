# Tasks, PR status and on-device titles

## Tasks (Best-of-N)

`AppModel.startTask(_:)` (`AppModel+Tasks.swift`) works through these steps:

1. Checks that the folder is in a git repo and that the base exists. Without worktrees, it also
   checks that there's exactly one agent.
2. With worktrees, refuses to start when the base is the checked-out branch and has tracked
   uncommitted changes. New worktrees start from the base's last commit, so those changes
   would be invisible to the agents.
3. Creates one worktree per agent at `<repo>/../<repo>.worktrees/<slug>-<agent>[-N]` on the
   branch `mship/<slug>-<agent>[-N]`. If one fails, the ones already made are removed.
4. Opens one workspace per run, named `<title> · <Agent>`. Its startup command is the
   repo's setup script (when it has one) and then the agent's launch command:

       env MOTHERSHIP_REPO_ROOT=<repo> MOTHERSHIP_WORKTREE=<wt> /bin/sh <repo>/.mothership/setup.sh; <agent>

   The setup output shows in the pane first. The agent starts either way.
5. Appends the task to `model.tasks` and saves `<support>/tasks.json`, all before returning.

Once a task is running:

- **Diffs.** They are taken against the merge-base with the base and include untracked files.
  They refresh every 10 s while the run's agent works, right after it stops, and every 60 s
  otherwise.
- **Keep.** `keepRun` commits pending work with the task title as the message, then does
  one of three things:
  - merges into the base where the base is checked out (that tree must be clean; on conflict
    the merge is aborted);
  - pushes and runs `gh pr create`;
  - only keeps the branch.

  In every case it sets `.kept`. A merged run keeps the diff of what it merged.
- **Discard.** `discardRun` closes the workspace, removes the worktree and its branch, and sets
  `.discarded`. It never touches the main worktree, or a directory git doesn't know as a
  worktree.
- **Session binding.** The agent in a run's pane binds to that pane, through
  `MOTHERSHIP_SURFACE_ID` and the pane scan. This was verified end to end with
  `MOTHERSHIP_DEBUG_TASK`.

## PR status

`pullRequests[workspace.id]` is filled in (`AppModel+Git.swift`) for workspaces that are on
a non-default branch of a GitHub repo. Only these workspaces count:

- the selected one;
- those selected in the last 30 minutes;
- task runs.

It runs only while the app is active. `PullRequestMonitor` calls
`gh pr list --head <branch>`, at most once a minute per branch, and straight away for a new
branch. Without `gh`, or when not logged in, it is quietly off. `MOTHERSHIP_GH=none` turns it
off. Each call takes about 1 s on a real repo.

## On-device titles

`AgentEngineConfiguration.textGenerator` is wired to `Intelligence.SessionNamer` (Foundation
Models) in `AppDelegate`.

- **Input.** The session's opening: the first 3 prompts and the first 2 replies, as plain text.
- **When.** Once history has loaded and the opening has stayed unchanged for 3 s, the engine
  asks for a title. It also asks for a one-line summary when an idle session finishes a long
  reply (more than 160 characters).
- **Queue.** Generation runs one call at a time on its own actor and never blocks the
  engine. Results are cached by input fingerprint in `<support>/generated-titles.json`.
- **Title order.** The user's rename comes first. Then the generated title, then the agent's
  own title, then the cleaned first prompt.
- **Fallback.** Without Apple Intelligence (or before the model is ready) sessions keep the
  heuristic titles and summaries. `MOTHERSHIP_INTELLIGENCE=off` turns generation off.
