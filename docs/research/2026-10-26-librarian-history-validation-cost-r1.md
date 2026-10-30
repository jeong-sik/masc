# Librarian 완료 기록 검증 비용 — 실측, 외부 설계 대조, 선택지 (r1)

상태: 조사 r1. 여기 적은 방향은 제안이고 결정이 아니다.

- 실측 기록: [2026-10-26-librarian-history-validation-cost-r1](../evidence/research/2026-10-26-librarian-history-validation-cost-r1.md)
- 근거 기록: [2026-10-26-librarian-history-validation-cost-evidence-record](../evidence/research/2026-10-26-librarian-history-validation-cost-evidence-record.md)
- 관련 PR: [#46143](https://github.com/jeong-sik/masc/pull/46143) (pass마다 gate 목록을 한 번만 읽기, 2026-10-26 기준 OPEN)
- 기준 소스: main `6a2d8dd6171`

## 요약

- 2026-10-26 22:16 KST에 기동한 서버가 6~8코어를 계속 썼다. 기동 직후 잠깐이 아니라 1시간 11분 뒤에도 약 6코어였다.
- CPU 대부분은 completed-history Librarian이 `consume_one` 을 돌 때마다 보존된 original을 전부 다시 검증하는 데 쓰였다. 이미 끝난 original도 매번 다시 검증한다.
- 검증 한 번은 gate scope 전체와 부모 기록을 다시 읽는다. 읽을 때마다 본문 sha256, JSON 파싱, canonical 재직렬화 비교, fsync를 한다.
- 같은 요청 본문이 세 군데에 저장된다. history 본문, gate 본문의 `capture`, history 기록의 `preparation_intended` 이벤트다. Keeper별 합계가 세 곳 모두 같았다(예: 161 / 161 / 161 MB). 사본 두 벌은 같은지 비교하는 데만 쓰인다.
- 코드 경로대로 센 하한 추정으로, 모든 Keeper를 한 번씩 도는 데 CPU 약 1,237초가 든다. #46143을 넣으면 약 72초다. 둘 다 original이 늘수록 커진다.
- 끝난 original을 discovery가 읽는 scope 밖으로 옮기는 `Lane_addon_tool_request_owner.settle` 이 이미 있다. Workspace Curator는 쓰고 Librarian은 쓰지 않는다. 그래서 Librarian scope는 끝난 기록까지 계속 쌓인다.
- 외부 시스템들은 내용 전체 확인을 "들어올 때 한 번"과 "따로 돌리는 점검"으로 나눈다. 일상 경로에서 다시 보는 대상을 줄이거나, 바뀌었는지만 싸게 확인한다.
- 제안 순서는 (1) #46143과 pass 관측, (2) 끝난 Librarian original을 `settle` 로 옮기기, (3) 사본을 digest 참조로 바꾸기, (4) 상수배 개선이다. 캐시는 기존 설계 문서가 막고 있어 마지막에 둔다. 개수 상한이나 쿨다운으로 줄이는 방법은 쓰지 않는다.

## 1. 무엇이 반복되나

### 1.1 호출 경로

```
Keeper_librarian_queue_refresh.run_durable
└─ Keeper_librarian_durable_execution.consume_one        (Keeper마다, lane 신호가 올 때마다)
   ├─ Owner.discover                                     그 Keeper의 history original 전부 + 본문
   └─ original마다 Keeper_librarian_durable_commit.validate
      ├─ Journal.validate_chain ─┐
      ├─ Journal.root ───────────┤
      ├─ Journal.latest ─────────┼─ read_chain → Owner.load_scope   gate scope 전부 + 본문
      ├─ restore_size_evidence ──┘      └─ 맞는 gate 기록마다 restore_record → load_parent
      │                                     (부모 history 기록과 본문을 다시 읽음)
      └─ original_answer, confirm_final …
```

Finished original 하나에 `read_chain` 이 4번 돈다. `validate_chain`, `root`, `latest`, 그리고 `restore_size_evidence` 안의 `latest` 다.

기록 하나를 읽을 때 하는 일(`Lane_addon_store.read_owned_tool_request_bytes`, `Lane_addon_tool_request_owner.request_of_body`):

1. 파일 전체를 읽는다.
2. 파일과 부모 디렉터리를 fsync한다.
3. 파일 전체를 다시 읽어 1의 바이트와 비교한다.
4. 기록 JSON을 파싱한다.
5. 본문 파일도 같은 방식으로 읽고, sha256이 기록의 `request_digest` 와 같은지 본다.
6. 본문을 파싱하고 canonical로 재구성한 뒤 다시 직렬화해 원래 바이트와 같은지 본다.

### 1.2 측정

| 항목 | 값 |
| --- | --- |
| CPU (누적 CPU 시간 차이) | 기동 5분 뒤 약 8.1코어, 13분 뒤 약 5.7코어, 1시간 11분 뒤 약 6.0코어 |
| RSS | 26.4 GB (5분 뒤), 22.2 GB (1시간 11분 뒤) |
| 바쁜 leaf (`sample` 10초) | `caml_lex_engine` 32.9%, `sha256_do_chunk` 18.0%, Yojson 문자열 쓰기 8.4% |
| 할당 (memprof, 기동 후 약 6.7분) | 812 GB, 그중 63%가 `Lane_addon_*` / `Keeper_librarian_*` 경로 |
| lane 적체 (28분) | Keeper 23명에서 대기 중인 Librarian 작업이 새 작업으로 252번 대체됨 |
| pass 끝 시각 (340초, 60초 캐시) | Keeper 43명 중 18명이 pass를 한 번 이상 끝냄. 4명은 관측한 응답마다 새로 끝냄 |
| 처리 안 한 턴 | 938 → 947. pass를 계속 끝내는데도 84턴이 그대로인 Keeper가 있음 |

### 1.3 저장된 데이터

`<base-path>/.masc/lane-addons` 의 history-execution scope는 27개, 기록은 355개(1,400 MB), 본문은 1,376 MB다.
durable-gate scope는 26개, 기록은 349개(13 MB), 본문은 1,345 MB다.
모두 2026-10-26 11:19 KST 이후 11시간 동안 쌓였다.

같은 내용이 세 번 저장된다.

- history 본문: Librarian에게 보낸 요청 전체(중앙값 1.79 MB, 최대 30.67 MB)
- gate 본문의 `capture`: 위와 같은 요청
- history 기록의 `preparation_intended` 이벤트: gate 요청 전체를 다시 담는다. 그래서 `capture` 가 또 들어 있다.

한 기록에서 `preparation_intended.request.capture` 를 canonical로 직렬화한 3,370,525 바이트가 history 본문과 같았다.
본문 sha256은 기록의 `request_digest` 와 같았다.
gate 요청에는 이미 `execution_digest` 가 있다. 이 digest가 같은 본문을 가리킨다.

gate 평가(`Keeper_librarian_absorb_gate.continue_captured`)는 history 기록에서 복원한 요청으로 입력을 계산한다.
gate 요청의 `capture` 필드는 기록이 원래 요청과 같은지 비교할 때만 쓰인다(`keeper_librarian_original_gate.ml` 의 `load_parent`, `validate_successor_request`, `restore_record`, `root_preparation`).
worker에게 보내는 인자에는 들어가지 않는다.

### 1.4 한 번 읽는 비용 (마이크로 벤치)

3.38 MB 기록 하나, 서버가 같이 도는 상태에서 세 번 중 최솟값이다.

| 작업 | 1회 |
| --- | --- |
| `Unix.stat` | 0.0014 ms |
| `String.equal` 3.38 MB | 0.12 ms |
| sha256 (`digestif.c` 1.3.0) | 11.5 ms |
| sha256 (OpenSSL 3.6.4, 하드웨어 명령) | 약 1.2 ms (2.7 GB/s로 환산) |
| `Yojson.Safe.from_string` | 23.6 ms |
| `Yojson.Safe.skip_json` (값을 만들지 않음) | 19.4 ms |
| `Yojson.Safe.to_string` | 7.7 ms |
| `capture` 사본을 뺀 같은 기록(5.6 KB) 파싱 | 0.043 ms |

이 표에서 두 가지를 읽을 수 있다.

- "바뀌었나"를 stat으로 확인하는 비용(마이크로초)과 내용을 다시 확인하는 비용(수십 ms) 사이에 만 배 넘는 차이가 있다.
- 파싱을 게으르게 해도(`skip_json`) 18%만 줄어든다. 큰 문자열을 훑는 비용이 대부분이라서다. 기록 안의 사본을 빼면 파싱이 500배 넘게 줄어든다.

### 1.5 pass 비용 모델

측정한 pass 시간이 아니다. pass 시작과 끝을 남기는 로그가 없어서 1.4의 단가로 코드 경로를 따라 셌다.
`read_chain` 을 original당 3번으로 셌고, canonical 재구성, 큰 JSON끼리 비교, 두 번째 읽기, GC는 넣지 않았다. 그래서 하한이다.

| | original 51개 Keeper | 27 Keeper 한 바퀴 | 규모 |
| --- | --- | --- | --- |
| main | 약 325초 | 약 1,237초 | n × g × S |
| #46143 | 약 8.4초 | 약 72초 | (n + g) × S |
| #46143 + 끝난 original `settle` (4.1) | 추정 안 함 | 추정 안 함 | (진행 중인 n + g) × S |

n은 original 수, g는 gate 기록 수(지금은 n과 거의 같다), S는 요청 크기다.
pass는 새 기록이 생길 때마다 한 번 이상 돈다(lane 신호, 발행 뒤 `wake`). 그래서 하루 누적 비용은 표의 규모에 n을 한 번 더 곱한 만큼 자란다.
#46143은 차수를 하나 낮추지만, 기록이 쌓이면 다시 커진다. 4.1은 n을 "지금까지 쌓인 수"에서 "아직 끝나지 않은 수"로 바꾼다.

## 2. 지금 설계가 지키려는 것

### 2.1 설계 문서가 정한 것

- "Resume must strictly rediscover original work before capturing a new root." (`docs/design/librarian-addon-execution.md`)
- "It strictly inventories retained originals before fresh selection" (같은 문서, `run_durable` 절)
- "Neither unknown work nor a malformed inventory is absence." (같은 문서)
- "Blocking strict full-inventory validation." (`keeper_librarian_durable_commit.mli`, `validate`)
- "Any malformed old original fails the full inventory before fresh selection." (`consume_one` 주석)
- 읽기 쪽 fsync: "accepted only after strictly syncing the exact opened file and parent directory … A visible rename alone is not durable confirmation." (`lane_addon_store.mli`, `load_action`)
- 비용에 대해: "Known-ID reads currently enumerate the scope names as part of this common boundary, so they incur directory work proportional to namespace size, plus content verification and directory syncs. No new cache, size cap or retry loop hides that cost." (`docs/design/addon-original-request-discovery.md`)
- 같은 문서의 `settle` 절: "The caller settles only originals no pass needs again and whose body no other record names."

정리하면 이렇다.
새 작업을 고르기 전에, 남아 있는 original 목록 전체를 엄격하게 확인한다.
비용은 캐시나 상한으로 숨기지 않는다.
대신 다시 필요 없는 original은 `settle` 로 목록에서 빼게 되어 있다.
끝난 original의 gate 체인과 exact 증거를 매 pass 다시 확인하라고 정한 곳은 찾지 못했다.

### 2.2 검증이 읽는 것

- `discover`: 그 Keeper의 history 기록과 본문 전부. 기록마다 소유자를 관찰하며 memory epoch 파일과 workspace·keepers·runtime 디렉터리 신원을 읽는다.
- `read_chain`: gate scope의 목록과 그 안의 모든 gate 기록. 다른 execution의 기록도 header와 owner를 검사한 뒤에 execution_id로 거른다. 그래서 다른 original의 잘못된 gate 기록 하나가 이 original의 검증도 실패시킨다.
- 부모 history 기록과 본문, 선행 gate 기록
- `confirm_final`: exact 레인의 요청 기록과 host 결과 증거 링크
- 그 밖: 프로세스 uid, store root 경로, 바이너리에 든 출력 스키마. 시계와 설정은 읽지 않는다.

### 2.3 끝난 뒤에도 바뀌는 입력

- Conflicted history 기록에는 replacement 이벤트가 붙는다.
- exact 기록: `deny` 는 이미 결과가 있어도 `Delivery_refused` 를 덧붙인다(`lane_addon_exact.ml`). 그러면 Settled였던 original이 다음 검증에서 Error가 될 수 있다. Librarian 요청이 실제로 이 경로에 닿는지는 확인하지 않았다.
- memory epoch 파일은 memory reset과 snapshot 격리 때 바뀐다(`keeper_memory_os_current.ml` 의 `rotate_epoch`).
- gate scope에는 같은 Keeper의 다른 execution이 계속 gate 기록을 더한다.

2.2와 2.3은 같은 head에서 소스를 직접 읽은 독립 검토와 내 확인을 합친 것이다.

## 3. 외부 사례

| 사례 | 내용 전체를 언제 확인하나 | 평소에는 무엇으로 판단하나 |
| --- | --- | --- |
| Build Systems à la Carte (Mokhov·Mitchell·Peyton Jones, JFP 2020) | 의존성이 바뀐 작업만 다시 실행 | verifying trace: 지난번 의존성의 hash를 적어 두고 같으면 건너뜀 |
| Salsa (rust-analyzer) | 낮은 durability 입력이 바뀌었을 때 | 높은 durability 입력만 쓰는 계산은 의존성 탐색 자체를 건너뜀 |
| dune (OCaml 빌드 시스템) | stat이 다를 때 | `Fs_memo.Stats`(mtime, ctime, size, perm, dev, ino)로 키를 잡은 digest 캐시. rule cache는 동적 의존성 단계별 digest를 적어 둔다 |
| git index | stat이 다르거나 racily clean일 때 | `lstat` 결과(mtime, ctime, ino, size, uid, gid, mode) |
| Bazel | digest 캐시에 없을 때 | path, inode, mtime, size, ctime 키의 digest 캐시 |
| Nix | `nix-store --verify --check-contents` 를 돌릴 때 | 빌드 때 DB에 적은 hash |
| restic | `check --read-data` 를 돌릴 때 | 기본 `check` 는 구조만 확인 |
| OpenZFS | 매체에서 읽을 때, 주기 scrub | checksum |
| PostgreSQL (`recovery_init_sync_method`) | 비정상 종료 뒤 기동할 때, 복구 전에 데이터 디렉터리 전체를 한 번 fsync | — |
| Event Sourcing (Fowler 2005) | 처음부터 다시 만들 때 | 저장해 둔 현재 상태(snapshot) |
| Certificate Transparency (RFC 9162) | — | consistency proof: 두 크기·두 root hash·증명 노드만으로 "앞부분을 고치지 않고 뒤에 붙였다"를 확인. 잎을 다시 읽지 않는다 |

공통점은 셋이다.

1. 내용 전체 확인은 데이터가 들어올 때, 또는 운영자가 따로 돌리는 점검에서 한다. Nix 문서는 전체 재해시를 "obviously quite slow"라고 적고 일상 경로에 두지 않는다.
2. 일상 경로에서는 다시 볼 대상을 줄인다. 끝난 것은 snapshot이나 archive로 빼고, 남은 것은 stat이나 digest로 "바뀌었나"만 본다(빌드 시스템 논문의 minimality).
3. 위쪽 기록은 아래 기록의 사본이 아니라 digest를 가리킨다. 아래 기록을 한 번 확인했으면 위쪽은 digest 비교로 끝난다(git tree, CT의 Merkle tree).

stat으로 판단할 때의 함정도 알려져 있다.

- git은 파일이 index 기록과 같은 시각 안에 다시 바뀌면 stat이 같아 보이는 경우를 "racily clean"이라 부른다. 이런 파일은 mtime이 index 파일 시각 이상이면 내용을 비교한다.
- Bazel은 2023년에 digest 캐시 키에 ctime을 넣었다. tar로 고정 mtime 파일을 풀고 `mv` 로 바꾸면 inode와 mtime이 같은 다른 파일이 생기기 때문이다.
- dune도 같은 일을 겪었다. `touch -r` 로 mtime을 되돌린 소스 변경을 digest 캐시가 놓쳤고, ctime을 키에 넣어 고쳤다(#15495, 테스트 `digest-cache/stale-source-stats.t`). dune은 나노초 시각을 C stub(`stdune/src/time_stubs.c`)으로 읽는다.
- verifying trace는 계산이 읽은 입력을 하나라도 빠뜨리면 틀린 결과를 재사용한다.

masc 쪽 사정도 몇 가지 있다.

- masc 저장소 쓰기는 `Fs_compat.save_file_atomic_strict`(임시 파일 → fsync → rename → 부모 fsync)를 거친다. masc가 바꾼 기록은 inode와 ctime이 바뀐다. POSIX는 rename이 부모 디렉터리의 수정 시각도 갱신한다고 정한다.
- `Fs_compat.fold_private_jsonl_locked_result` 는 이미 "identity와 size/mtime/ctime이 읽기 전후로 같은가"로 읽기 스냅샷을 판단한다.
- 운영자가 배포 때 돌리는 `validate-stores`(`lane_addon_store_preflight.mli`)가 이미 tool-request 기록과 본문을 런타임 decoder로 전부 읽는다. "따로 돌리는 전체 점검" 자리가 이미 있다.
- macOS `fsync(2)` 는 드라이브 캐시까지 내리지 않는다. 그건 `F_FULLFSYNC` 가 한다. masc `atomic_replace.mli` 도 전원 손실 내구성은 주장하지 않는다고 적었다.
- APFS는 metadata만 checksum하고 사용자 데이터는 하지 않는다고 알려져 있다(2차 출처). 읽을 때마다 하는 sha256을 줄이면 디스크 손상은 일상 경로에서 덜 잡힌다. 필요하면 `validate-stores` 같은 점검에서 잡는다.

언어 수준 사례도 봤다.

- "Parse, don't validate"(King 2019): 경계에서 한 번 파싱하고, 알아낸 사실을 타입으로 들고 다닌다.
- simdjson On-Demand(Keiser·Lemire 2024): 필요한 값만 만든다. 다만 Yojson에서는 값을 만들지 않는 `skip_json` 도 전체 파싱의 82%였다. OCaml에서 게으른 파싱만으로는 효과가 작다.
- sha256: `digestif` 1.4.1(2026-10-16)의 C 구현은 하드웨어 명령을 쓰지 않는다. OCaml에서 ARM SHA 명령을 쓰는 `oxsha` 는 커밋 3개짜리 실험 저장소다. OpenSSL(EVP)이나 macOS CommonCrypto를 바인딩하면 약 9배 빠르다(1.4).

## 4. 선택지

### 4.1 끝난 Librarian original을 `settle` 로 scope 밖에 옮기기

- 장치는 이미 있다. `Lane_addon_tool_request_owner.settle` 은 기록과 본문을 `tool-request-owners-settled/<scope digest>/<날짜>/` 로 옮긴다. Workspace Curator가 쓴다(`server_workspace_memory_addon.ml` 의 `settle_original_with`).
- 설계 문서가 정한 비용 대책과 같다. 새 캐시나 상한을 만들지 않고, 다시 필요 없는 original을 목록에서 뺀다.
- 효과: discovery와 gate scope에 아직 끝나지 않은 일만 남는다. pass 비용이 쌓인 기록 수가 아니라 진행 중인 기록 수를 따른다. 옮긴 기록은 archive에 그대로 남는다.
- 정해야 할 것
  - 언제 "다시 필요 없는가". Finished 뒤 receipt까지 끝난 경우, Conflicted 뒤 replacement가 관측된 경우 등을 상태로 정확히 나눠야 한다.
  - 옮기는 단위. history original과 그 gate 기록들을 함께 옮겨야 한다. `read_chain` 은 gate scope 전체를 읽고, gate 기록은 부모를 history scope에서 찾는다.
  - 대체 관계. `validate_lineage` 는 replacement의 부모를 목록에서 찾는다. 부모만 먼저 옮기면 "predecessor is absent"가 된다. Curator처럼 체인을 잎부터 옮긴다.
  - 본문 규칙. 문서는 "whose body no other record names"를 요구한다. gate 요청이 부모 digest를 `execution_digest` 로 가리키므로 같은 단위로 옮겨야 한다.
- 헌법과의 관계: 새 상태 종류를 만들지 않는다. 이미 있는 archive와 이동 순서를 쓴다.

### 4.2 같은 내용을 세 번 저장하지 않기

- gate 요청의 `capture` 를 빼고 `execution_digest` 로 history 본문을 가리킨다.
- history 기록의 `preparation_intended` 에는 gate 요청 전체 대신 그 digest를 적는다. gate 요청 본문은 한 번만 저장한다.
- 큰 JSON끼리 비교하던 곳(`load_parent` 의 `equal parent.request (Capture.to_json capture)` 등)은 digest 비교로 바뀐다.
- 사본을 읽는 곳은 비교뿐이고 gate 평가와 worker 인자는 사본을 쓰지 않는다(1.3). 그래서 빼도 동작은 그대로다.
- 효과: 디스크가 약 3분의 1로 준다. history 기록 파싱이 3.37 MB에서 5.6 KB가 된다. 진행 중인 original의 pass 비용도 준다.
- 저장 형식이 바뀐다. 헌법 `legacy_residue` 와 `runtime_data` 규칙대로 옛 기록 변환기 없이 fresh state로 간다.

### 4.3 상수배 개선

| 항목 | 효과 | 비용 |
| --- | --- | --- |
| sha256을 OpenSSL EVP / CommonCrypto로 | 해시 약 9배 | 플랫폼별 C stub, 4개 플랫폼 설치 검증 |
| canonical 확인의 `to_string` 후 비교 제거 | 직렬화 비용 제거 | 쓸 때 canonical로 쓰고 digest가 맞으면 다시 볼 이유가 없다는 판단이 필요 |
| 두 번째 전체 읽기 대신 읽은 descriptor의 전후 stat 비교 | 읽기 I/O 절반 | `fold_private_jsonl_locked_result` 와 같은 기준 |
| 게으른 파싱 | 약 18% | 효과 작음 |

합쳐도 몇 배다. 기록 수에 따라 커지는 구조는 그대로라 혼자서는 답이 아니다.

### 4.4 캐시 (마지막 선택지)

후보는 둘이다. 하나는 `Lane_addon_tool_request_owner.load` 결과를 파일 신원으로 재사용하는 디코드 캐시다. 다른 하나는 original마다 검증 결과와 읽은 입력의 신원을 적어 두는 verifying trace다.
둘 다 설계 문서의 "No new cache … hides that cost"와 부딪친다. 하려면 그 문장부터 RFC로 바꿔야 한다.

독립 검토가 찾은 반례가 있다. 파일 stat만 키로 쓰면 결과가 달라진다.

- 디렉터리도 입력이다. keepers 디렉터리를 바꾸거나 상위 디렉터리에 group 쓰기 권한을 주면, 읽는 파일의 stat은 그대로인데 새 검증은 실패한다.
- scope에 새 파일이 생기면 결과가 달라질 수 있다(2.2). 디렉터리 시각을 키에 넣으면, 진행 중인 original이 gate 기록을 쓸 때마다 같은 scope의 끝난 original 캐시가 모두 무효가 된다.
- Error를 캐시하면 일시적인 경합 오류가 파일이 바뀔 때까지 남는다.
- 신원은 나중의 `stat` 이 아니라 읽은 descriptor에서 얻어야 한다. `Fs_compat` 의 `same_file_snapshot` 이 이미 그렇게 한다.
- 읽기 쪽 fsync를 파일 신원당 한 번으로 줄이는 것도 캐시다. 부모 디렉터리 신원까지 키에 넣고 성공한 sync만 기억하면 지금 보장을 유지한다는 의견이 있었다. 같은 설계 문장에 걸린다.

4.1과 4.2를 하면 캐시 없이도 효과 대부분을 얻는다. 그 뒤에도 부족할 때만 다시 본다.

### 4.5 권하지 않는 것

- 저장소를 SQLite로 바꾸기: masc는 이미 `sqlite3` 에 의존하고, 미완료 original을 인덱스로 찾을 수 있다. 하지만 파일 단위 소유 확인, fsync 계약, 증거 파일 구조를 모두 바꾼다. 이번 문제보다 범위가 크다.
- pass당 검증 개수 상한, 쿨다운, 오래된 기록 건너뛰기: 헌법 `budget_gate`, `no_wall_clock_death` 와 워크어라운드 거부 기준, 설계 문서의 "size cap" 금지에 걸린다. 비용 구조는 그대로 두고 증상만 숨긴다.
- 일부만 무작위로 검증하기(restic `--read-data-subset` 류): 일상 경로의 "깨지면 멈춘다" 보장이 확률이 된다. 따로 돌리는 점검에서만 의미가 있다.

## 5. 제안 순서

1. #46143을 병합하고 같은 방법(누적 CPU 시간 차이, memprof 비중)으로 다시 잰다. 이때 pass마다 시작·끝, 검증한 original 수, 읽은 바이트를 남기는 관측을 같이 넣는다. 지금은 pass 시간을 직접 잴 수 없다.
2. 4.1을 RFC로 쓴다. "다시 필요 없는 original"의 상태 조건, 옮기는 단위, 대체 관계의 순서를 정한다. → [RFC-librarian-history-settles-finished-originals](../rfc/RFC-librarian-history-settles-finished-originals.md)
3. 4.2를 같은 RFC나 바로 다음 RFC로 다룬다. 저장 형식이 바뀌므로 fresh state 단계를 함께 적는다.
4. 다시 재고, 남은 비용을 보고 4.3에서 고른다.
5. 4.4는 위 셋으로도 부족할 때만, 설계 문서를 고치는 RFC와 함께 다룬다.
6. 사용자 데이터 손상을 잡아야 하면 `validate-stores` 같은 따로 도는 점검에 맡긴다.

## 6. 불확실성

- pass 비용은 모델 추정이다. 실제 pass 시간은 재지 못했다. pass 끝 시각은 60초 캐시를 거친 하한만 봤다.
- 처리 안 한 턴이 줄지 않는 Keeper가 왜 그런지(`pending`, `stopped` 상태의 원인)는 확인하지 않았다. 검증 비용과 관련이 있는지도 모른다.
- 마이크로 벤치는 서버가 6코어 넘게 쓰는 중에 쟀다. 첫 실행은 두세 배 느렸다.
- memprof 비중은 할당량이다. CPU 시간 비중과 같지 않다.
- 4.1의 "다시 필요 없는 original" 조건은 아직 정하지 않았다. 대체 관계가 몇 단계까지 이어지는지도 재지 않았다.
- exact 기록의 `deny` 가 결과가 있는 Librarian 요청에 실제로 닿는지는 확인하지 않았다.
- APFS 사용자 데이터 checksum이 없다는 내용은 2차 출처다.

## 출처

모두 2026-10-26에 확인했다.

- Andrey Mokhov, Neil Mitchell, Simon Peyton Jones. *Build Systems à la Carte: Theory and Practice*. JFP 2020. §2.1 minimality, §5.2 verifying traces. <https://www.microsoft.com/en-us/research/uploads/prod/2020/04/build-systems-jfp.pdf>
- Salsa, Durability. <https://salsa-rs.github.io/salsa/reference/durability.html>
- dune, `src/dune_engine/workspace_cache.mli`, `doc/changes/fixed/15495.md`, `test/blackbox-tests/test-cases/digest-cache/stale-source-stats.t` (main, 2026-10-26 확인). <https://github.com/ocaml/dune>
- Git, racy-git. <https://git-scm.com/docs/racy-git>
- Bazel, "Use ctime in file digest cache key" (#18101, 6.1.2). <https://bazel.googlesource.com/bazel/+/refs/heads/release-6.1.2%5E%21/>
- Nix, `nix-store --verify`. <https://nix.dev/manual/nix/2.28/command-ref/nix-store/verify>
- restic, Working with repositories (`check`). <https://restic.readthedocs.io/en/stable/045_working_with_repos.html>
- OpenZFS, Checksums. <https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Checksums.html>
- PostgreSQL 18, `recovery_init_sync_method`. <https://www.postgresql.org/docs/current/runtime-config-error-handling.html>
- Martin Fowler, *Event Sourcing* (2005-12-12). <https://martinfowler.com/eaaDev/EventSourcing.html>
- RFC 9162, Certificate Transparency Version 2.0, §2.1.4. <https://www.rfc-editor.org/rfc/rfc9162.html>
- POSIX `rename()`. <https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html>
- Apple `fsync(2)`. <https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html>
- Adam Leventhal, *APFS in Detail: Data Integrity* (2016, 2차 출처). <https://ahl.dtrace.org/2016/06/19/apfs-part5/>
- Alexis King, *Parse, don't validate* (2019-11-05). <https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/>
- John Keiser, Daniel Lemire. *On-Demand JSON: A Better Way to Parse Documents?* SPE 54(6), 2024. <https://arxiv.org/abs/2312.17149>
- mirage/digestif v1.4.1 (2026-10-16), `src-c/native/sha256.c`. <https://github.com/mirage/digestif>
- oxsha. <https://tangled.org/anil.recoil.org/oxsha>
