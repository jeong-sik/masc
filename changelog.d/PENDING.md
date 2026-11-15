### Fixed

- A failed official-client Gate continuation ends its operation with the
  run's own failure, such as the Codex app-server refusing the resumed input
  for size. It used to end as `Turn_continuation_unpersisted` at the Gate
  suspend stage, which reported a persistence failure that never happened:
  an official-client attempt never returns an Agent Core checkpoint, and the
  failed resume leaves its session unsettled, so the Gate has nothing to be
  suspended from. A session recorded full still ends as `Gate_session_full`
  (#50398, #PENDING).
