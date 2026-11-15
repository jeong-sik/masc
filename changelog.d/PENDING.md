### Upgrade notes

- `masc keeper-create` presents only the bearer `masc login` persisted for
  `--agent` under `--base-path`. The `--token TOKEN` option is gone because a
  value on the command line shows up in `ps` and shell history, and passing it
  now fails as an unknown option before any request is sent. To create a
  keeper as another identity, sign it in first:
  `masc login --base-path <dir> --agent <name> --client-env MASC_TOKEN`, then
  `masc keeper-create --base-path <dir> --agent <name> ...` (#38219, #PENDING).
