### Fixed

- Voice session restore no longer turns a persisted realtime session into a live turn-based one when its bridge endpoint is no longer configured; it restores as `suspended` with its turn history. A session file with a blank `session_id` or an `agent_id` that differs from its file name is rejected instead of adopted (#PR_NUMBER).
