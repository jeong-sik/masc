### Fixed

- The dashboard's active inference count (`inference_inflight.active` in the
  operator snapshot, shown in Flow Control and the agent roster) now counts
  Keeper turns while Agent Core runs them. Nothing on the turn path entered
  the observation, so the count and the `masc_inference_inflight` and
  `masc_inference_started_total` metrics read 0 while turns ran. Turns run by
  an official client (Codex, Claude Code, Antigravity, Muse) are still not
  counted (#49820).
