### Fixed

- `scripts/build-dashboard-if-needed.sh` builds the dashboard again when any
  file of the dashboard workspace is newer than the last build, apart from
  `node_modules` and hidden tool scratch. It looked only at four file
  extensions under `src`, `index.html` and `package.json`, so a change to
  `vite.accounts.config.ts`, the lockfile, `public/` or `design-system/` left
  the output of the old inputs in place (#51664, #PENDING).
