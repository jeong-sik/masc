### Fixed

- Adopting a running Keeper container no longer replaces the gitconfig that
  its `GIT_CONFIG_GLOBAL` names through the read-only mount when that file
  already holds the wiring the current `hosts.yml` derives, with mode 0400.
  Every turn adopts the container, and a token rotation rewrites `hosts.yml`
  without changing its hosts, so the mounted file was swapped for an
  identical one under any git reading it. It is now replaced only when the
  logged-in hosts change or the file has drifted (#31874, #PENDING).
