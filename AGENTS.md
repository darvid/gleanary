# Sink agent guidance

## Version control

This repository overrides the default GitButler tooling rule:

- In linked worktrees, including Superset workspaces, use ordinary Git
  for version-control operations. Use `gh` for GitHub pull requests.
- In the main checkout, use GitButler (`but`) for version-control
  writes.
- Do not run `but setup` in a linked worktree, route its writes through
  the main checkout, or enable experimental worktree settings as a
  workaround.
- Worktrees share repository hooks. Do not install, replace, or repair
  those hooks from workspace lifecycle scripts without explicit
  approval.
- Tool selection does not authorize commits, pushes, merges, history
  rewrites, or deployments. Keep existing approval requirements.

To identify a linked worktree, compare these absolute paths:

```bash
git rev-parse --path-format=absolute --git-dir --git-common-dir
```

Different paths indicate a linked worktree. Equal paths indicate the
main checkout. Keep this exception scoped to Sink.
