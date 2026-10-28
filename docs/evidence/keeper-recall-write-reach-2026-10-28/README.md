# 쓰기 도달 측정: Keeper 40명, 2026-10-28

[RFC-keeper-recall-reaches-the-turn](../../rfc/RFC-keeper-recall-reaches-the-turn.md) 층 0 의 측정 4(쓰기 도달)를 처음 해 본 결과다. 측정 5(호출 결과 유실)는 일부만 된다. 아래 "못 잰 것"에 적었다.

## 한눈에 보기

수치는 모두 [report.txt](report.txt)에서 왔다. 2026-10-28T06:06:31Z 에 라이브 base path 를 읽었고, 10-02 이후 기록이다.

| 질문 | 값 |
|---|---|
| Librarian 이 처리한 후보 | 734건, Keeper 40명 |
| 대상 사실에 붙인 것 | 485건 (66.1%) |
| 그중 commit 이 대상을 새로 쓴 것 / 이미 있던 사실에 붙인 것 | 296건 (40.3%) / 189건 (25.7%) |
| 대상 없이 닫은 것 | 249건 (33.9%) |
| 대상이 Keeper 가 쓴 문장 그대로(같은 memory id) | 12건 (대상이 있는 485건의 2.5%) |
| 대상이 지금도 현재 사실 | 172건 (대상이 있는 485건의 35.5%, 후보 734건의 23.4%) |
| 대상이 개정 / 철회 / 다른 사실에 흡수 / 기록 없이 사라짐 | 118건 / 6건 / 136건 / 53건 |
| 쓴 뒤 commit 까지 걸린 시간 (485건) | 중앙값 22분, 90퍼센타일 15.8시간, 최대 2.7일 |
| 쓰기 호출 422건 (Keeper 24명) | 영수증 ok 343건, 거절 52건, 도구 오류 15건, 결과가 trace 에 없음 12건 |
| 대기열에 들어간 쓰기 227건 | 대상에 붙임 183건, 대상 없이 닫음 38건, 대기 중 1건, 기록 없음 5건 |
| 거절 52건의 이유 | `supersedes_*` 31건, `source_read_failed` 9건, `derivation_invalid` 등 파생 오류 8건, `board_*` 4건 |

읽을 수 있는 것은 이렇다.

- 대기열이 막혀서 안 보이는 것이 아니다. 대기열에 들어간 쓰기 227건 중 대기 중은 1건이다.
- Keeper 가 쓴 문장이 그대로 남는 일은 드물다. 대상이 있는 후보의 97.5%는 Librarian 이 다른 문장(다른 memory id)으로 붙였다. #46507 의 "썼는데 검색에 안 나온다"는 보고와 맞는 수치이지만, 그것이 원인이라고 확인한 것은 아니다.
- 후보 3건 중 1건은 대상 없이 닫혔다.
- 대상에 붙은 뒤에도 사실이 바뀐다. 대상의 35.5%만 지금 현재 사실이다. 개정과 흡수로 간 254건은 내용이 다른 사실에 이어졌을 수 있다. 이 스크립트는 내용을 읽지 않아서 이어졌는지 모른다. 철회 6건과 기록 없이 사라진 53건(10.9%)은 이어진 곳이 없다.

원인은 모른다. 왜 대상 없이 닫는지는 영수증에 판정 이유가 남지 않아서 이 측정으로는 볼 수 없다.

## 무엇을 했나

`scripts/keeper-recall-write-reach.py`(읽기 전용)를 돌렸다. 명령은 이렇다.

```bash
python3 -I scripts/keeper-recall-write-reach.py <base-path>/.masc/keepers \
  --memory-dir <base-path>/.masc/config/keepers --since 2026-10-02 \
  --now 2026-10-28T06:06:31Z \
  --exclude lab-sangsu --exclude taskmaster --exclude microvm-probe-829
```

`--now` 는 출력 맨 위의 읽은 시각에만 쓴다. 제외한 셋은 기준선과 같은 시험·실험 Keeper 다. 카나리 Keeper 가 아직 없어서 전체를 쟀다. `--only <Keeper>` 로 좁힐 수 있다.

읽은 파일은 이렇다.

| 파일 | 쓰는 곳 |
|---|---|
| `<keepers-dir>/<keeper>/raw-traces/*.jsonl` | 쓰기 호출과 영수증. `tool_execution_finished` 기록의 첫 줄이 영수증 JSON 이다. |
| `<memory-dir>/<keeper>.librarian-range-commit.json` | Librarian 이 처리한 후보마다 영수증 하나. `admission_recall_binding` 이 있으면 대상 사실에 붙인 것이고, `explicit_candidate_id` 만 있으면 대상 없이 닫은 것이다. |
| `<memory-dir>/<keeper>.memory-admission.json` | 아직 대기열에 있는 후보. |
| `<memory-dir>/<keeper>.memory-journal.jsonl` | 영수증의 `snapshot_revision` 에 해당하는 commit 행. 시각과 그 commit 이 더한 사실을 얻는다. |
| `.memory-current.json`, `.memory-events.jsonl`, `.memory-absorbed.jsonl` | 대상이 지금 현재 사실인지, 개정·철회·흡수됐는지. |

수치를 센 방법은 이렇다.

- 후보를 "대상 없이 닫은 것"이라 부르는 근거는 코드다. Librarian 런타임은 `Incorporated` 와 `Already_represented` 에만 대상 binding 을 만들고 `Not_durable` 에는 만들지 않는다(`lib/keeper/keeper_librarian_runtime.ml:920-933`). `Deferred` 는 처리된 것이 아니라서 영수증이 없다(`lib/keeper/keeper_memory_admission_judgment.ml:104`). 영수증에는 판정 이름이 없다.
- "commit 이 대상을 새로 썼다"는 commit 행의 `added` 목록에 대상 memory id 가 있다는 뜻이다. 없으면 대상은 이미 있던 사실이다.
- memory id 는 claim 의 SHA-256 이다. Librarian 이 문장을 바꾸면 id 가 달라진다. 그래서 "쓴 문장 그대로"는 영수증이 가진 Keeper 의 원문 claim 과 대상의 id 가 같은 경우만 센다.
- 대상의 상태는 읽은 시각 기준이다. 현재 사실, 개정 사건, 철회 사건, 흡수 기록 순으로 보고 어디에도 없으면 "기록 없이 사라짐"이다.
- 시간은 영수증이 가진 Keeper 의 원문 사실의 `first_seen` 부터 commit 행의 `recorded_at` 까지다. 원문 사실이 없는 영수증(대상 없이 닫은 것)은 시간이 없다.
- 표에서 뺀 영수증 103건은 후보가 아니다. Librarian 이 자기 읽기 범위에 쓴 `range_id` 66건, `official_range_id` 37건이다.
- 호출 하나는 한 칸에만 들어간다. 호출 표의 합이 호출 수와, 대기열 표의 합이 대기열 쓰기 수와 같은지 시험이 확인한다.

같은 값이 나오는지 스크립트와 다른 코드로 다시 셌다. 대상의 상태(현재 172, 개정 118, 흡수 136, 사라짐 53, 철회 6)와 시간(485건, 중앙값 1343초, 90퍼센타일 56889초, 최대 232138초)이 같았다.

시험은 `scripts/tests/test_keeper_recall_write_reach.py` 32개다. 스크립트를 14곳 바꿔 보았을 때(우선순위 뒤집기, 경계값, 중복 제거 삭제, `--since`·`--exclude` 무시 등) 모두 시험이 실패했다. 처음에는 한 곳이 살아남아서, 커밋이 아닌 행이 커밋과 같은 revision 을 가진 경우를 시험에 더했다.

## 못 잰 것

- **카나리 Keeper 한정 값.** 카나리가 정해지지 않았다. Keeper 별 표는 `report.txt` 맨 아래에 있다.
- **호출 결과 유실(RFC §5 의 5).** 시작 기록만 있고 끝 기록이 없는 쓰기 호출은 0건이다. "적용됐는데 결과를 못 받은" 호출은 trace 의 영수증과 원장의 후보를 맞대야 한다. 공식 클라이언트의 호출 12건은 trace 에 결과가 없어서 맞댈 수 없고, 맞대면 그 호출이 만든 후보가 모두 "영수증 없는 후보"로 보인다. 재시도로 생긴 중복도 재지 않았다.
- **오래된 기록.** raw trace 는 돌아가며 지워져서 첫 쓰기 호출이 2026-10-05 이다. 영수증이 남은 기간도 Keeper 마다 가장 오래된 것이 9.1일 전까지다. 그 앞의 쓰기는 호출 표에서 "기록 없음"으로 센다.
- **판정 이유.** 대상 없이 닫은 249건이 왜 닫혔는지.
- **직접 쓰는 경로.** `persisted_current_snapshot` 81건과 `persisted_source_bound_current` 35건은 대기열을 거치지 않는다. 이 사실이 이후에 남는지는 따라가지 않았다.
