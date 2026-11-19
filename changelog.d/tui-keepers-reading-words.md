### Changed

- The TUI Keepers screen says why a value is missing in the reading words
  (`미조회`, `조회 실패`, `일부 관측`, `이전 관측`) or `보고 안 됨` where the
  server read gave no value, instead of `미관측`, `미확인` and `미기록`. An
  idle Keeper no longer adds `작업 이름 미관측`, and a turn end time that does
  not read as an age is left out.
