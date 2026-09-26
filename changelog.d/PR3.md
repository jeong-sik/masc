### Changed

- Boot refuses to start while a keeper's event queue snapshot or transition
  WAL (`keepers/<name>/event-queue-v19.json`,
  `event-queue-transitions-v9.jsonl`) does not decode with this build, and
  names the file; `--accept-store-quarantine` moves both aside under the
  queue's owner lock so the keeper starts the empty queue. Before, only the
  deploy preflight read them (`scripts/deploy.sh`, `scripts/install.sh` and
  the container entrypoint run it), so a server started without it
  (`scripts/install-local-build.sh`, `scripts/start-masc-supervised.sh`)
  came up with a keeper that selected no stimulus and took no turn. The
  preflight now reads the queue through `validate-stores`; the helper's
  `validate-current-queue` and `validate-current-wal` subcommands are
  removed.
