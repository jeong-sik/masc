## 실패 좌표

`test_keeper_memory_write` — suite `persistence` 케이스 7·8.

```
run 42720948231 (head b9d9b809, suite=test_keeper_memory_write, minimal=true)
[FAIL] persistence 7  recall snapshots survive GC until history retention releases them
FAIL expired historical snapshot becomes collectable
       Expected: `false'  Received: `true'
[FAIL] persistence 8  superseded recall pins keep history then permit collection
FAIL normal history retention makes retired artifact collectable
```

같은 좌표를 이슈 #50977 이 추적 중이고, 원인 칸이 비어 있었습니다.

## 진단 (PROBE 직독)

진단 브랜치에서 스윕 보고를 찍었습니다(run 42819084869, head e5a916470253).

```
PROBE sweep deleted=0 candidates=0 observed=2
  unclassified=[config-keepers/recall-retention.memory-current.json;
                config-keepers/recall-retention.memory-current.json.lock;
                config-keepers/recall-retention.memory-epoch.json;
                config-keepers/recall-retention.memory-journal.jsonl;
                config-keepers/recall-retention.memory-journal.jsonl.lock;
                config-keepers/recall-retention.memory-os-aggregate.lock;
                config-keepers/recall-retention.memory-source-current.json.lock]
PROBE sweep deleted=0 candidates=1 observed=2   (unclassified 목록 동일)
```

- `lib/tool_blob_store/tool_blob_maintenance.ml` 의 `Delete_previous_candidates` 는 `unclassified = []` 일 때만 후보를 지웁니다. 그 게이트는 #49436 이 넣은 안전장치입니다.
- `lib/server/server_tool_blob_scope.ml` 의 `config_keepers` 는 `keeper.toml`·vision store·librarian context·librarian recall 네 접미만 분류합니다. keeper 메모리 파일은 목록에 없어 `classify` 가 `None` 을 돌려주고 미분류로 남습니다.
- 그래서 후보는 기록되지만(candidates 0→1) 삭제는 항상 0 입니다. **keeper 메모리가 있는 워크스페이스에서는 오프라인 blob 스윕이 한 건도 삭제하지 못합니다.** 시험만의 문제가 아니라 운영 회수 경로가 막힌 것입니다.

## 닫는 변경

`lib/server/server_tool_blob_scope.ml`, `lib/keeper/keeper_memory_os_current_layout.ml`, `...mlie`:

- `config_keepers` 에 keeper 메모리 접미 다섯을 `M.Writes_no_reference` 로 분류: `.memory-current.json`, `.memory-journal.jsonl`, `.memory-source-current.json`, `.memory-epoch.json`, `.memory-os-aggregate`.
- 근거: `Keeper_memory_os_types.fact`(claim·category·first_seen·last_seen·origin·basis), `Keeper_memory_os_current_types.journal_entry`, `Keeper_memory_source_current.fact`(claim·first_seen·`file_source` = 원본 `path`+`sha256`) 어디에도 tool blob 참조 필드가 없습니다. `.memory-source-current.json` 의 sha256 은 원본 파일 해시이지 blob 해시가 아닙니다.
- blob 참조를 실제로 담는 recall pin 은 `keepers_runtime/<keeper>/memory-recall-current.json` 이고 그 경로는 이미 `tree Common.keepers_runtime_dirname`(In_scope Tree)이 읽습니다. 분류를 좁혀도 그 참조는 그대로 살아 있습니다.
- `.lock` 들은 `derived` 의 `M.Suffix File_lock_eio.lock_suffix` 가 처리하지만 기준 이름이 분류돼야 파생이 풀립니다. 접미 분류가 그것을 함께 정리합니다.
- `.memory-epoch.json` 문자열을 `Keeper_memory_os_current_layout` 에 상수(`epoch_suffix`)로 올려 범위와 writer 가 같은 값을 씁니다.

## 검증

- 표적 분리 dispatch: run 42821819564, head 871b905d0bbc, suite `test_keeper_memory_write`, minimal=true — **conclusion=success**.
- 수리 전 같은 suite 에서 실패하던 `persistence 7`·`8` 이 같은 head 에서 통과했습니다.

## 남은 것

`test_keeper_store_boot_reconcile` 2건(#50977 의 나머지)은 다른 좌표라 이 PR 범위 밖입니다.
