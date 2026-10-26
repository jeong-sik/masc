# Librarian 완료 기록 검증 비용 실측 기록 (r1)

분석과 선택지는 [연구 문서](../../research/2026-10-26-librarian-history-validation-cost-r1.md)에 있다.
이 파일은 무엇을 어떻게 쟀는지만 적는다.

## 대상

- 바이너리: `~/.local/bin/masc`, commit `6a2d8dd6171e1d732ca15f918fb084e462e4d371`
- 서버: `masc start`, 기동 `2026-10-26T13:16:17Z`(22:16:17 KST)
- base path: `~/me`, 런타임 저장소 `~/me/.masc`
- 장비: MacBook M3 Max, 16 코어(`sysctl -n hw.ncpu`), Darwin 25.6.0
- 측정하는 동안 같은 장비의 load average는 약 28~38이었다.

## 1. CPU

`ps -o %cpu`는 프로세스 수명 평균이라 쓰지 않았다. 누적 CPU 시간의 차이를 쟀다.

```sh
A=$(ps -o time= -p $PID); sleep 15; B=$(ps -o time= -p $PID)
```

| 기동 후 | 구간 | 누적 CPU 시간 | 사용 코어 |
| --- | --- | --- | --- |
| 5분 3초 | 15초 | 27:40.18 → 29:41.02 (120.8초) | 약 8.1 |
| 13분 38초 | 20초 | 85:06.71 → 87:01.58 (114.9초) | 약 5.7 |
| 1시간 11분 | 20초 | 376:12.91 → 378:12.68 (119.8초) | 약 6.0 |

기동 5분 뒤 RSS는 26.4 GB, 1시간 11분 뒤에는 22.2 GB였다(`ps -o rss=`). `ps -M`에서 실행 중(R) 스레드가 9개였고 각각 60~83% CPU였다.

## 2. `sample` 10초

```sh
sample $PID 10 -mayDie -file s1.txt
```

호출 그래프의 leaf만 세고(자기 재귀가 중복으로 세지지 않게), 대기 leaf(`__psynch_cvwait`, `__semwait_signal`, `poll`, `kevent` 등)는 뺐다.
바쁜 leaf 합계 55,119 샘플 중 상위:

| leaf | 샘플 | 비중 |
| --- | --- | --- |
| `caml_lex_engine` | 18,142 | 32.9% |
| `sha256_do_chunk` | 9,929 | 18.0% |
| `camlYojson__Safe$write_string_body` | 4,633 | 8.4% |
| `_platform_memmove` | 3,612 | 6.6% |
| `__getdirentries64` | 1,172 | 2.1% |
| `do_some_marking` (GC) | 910 | 1.7% |
| `fsync` | 431 | 0.8% |

domain pool 스레드의 스택은 `domain_thread_func → caml_callback_exn → Fun.protect → Yojson` 에서 끊겨 masc 호출자가 보이지 않았다. 호출자는 3절의 memprof로 찾았다.

## 3. 할당 프로파일 (memprof)

```sh
curl -H "Authorization: Bearer $MASC_ADMIN_TOKEN" http://127.0.0.1:8935/api/v1/diagnostics/memprof
```

기동 후 약 6.7분에 읽었다. 이 엔드포인트는 부팅 때 켜진 `Alloc_profile`(rate 1e-5)의 누적 표를 준다.

- `allocated_bytes` 812.4 GB, `major_bytes` 654.5 GB, `live_bytes` 3.1 GB
- 호출 스택에 `Lane_addon` 또는 `Keeper_librarian` 이 들어 있는 항목: 508 GB(전체 할당의 63%, 상위 목록의 91%)

바깥 호출자로 묶은 상위 항목:

| 할당 | 비중 | 바깥 호출자 |
| --- | --- | --- |
| 108.8 GB | 13.4% | `Owner.load_scope.restore ← original_gate.read_chain ← latest` |
| 62.4 GB | 7.7% | `Lane_addon_store.record_bytes ← read_owned_tool_request_bytes` |
| 62.3 GB | 7.7% | `settle_verified_record ← read_owned_tool_request_bytes` (두 번째 전체 읽기) |
| 60.7 GB | 7.5% | `load_scope.restore ← read_chain ← validate_chain` |
| 59.2 GB | 7.3% | `load_scope.restore ← read_chain ← root` |
| 52.1 GB | 6.4% | `tool_request_owner_record ← read_tool_request_scope` |
| 28.2 GB | 3.5% | `restore_record ← read_chain` (`load_parent`) |
| 20.1 GB | 2.5% | `Dated_jsonl.find_latest_entry_result` |
| 18.8 GB | 2.3% | `Keeper_chat_store.provenance_index_of_existing ← append_lines_once` |

할당량은 CPU 시간과 같지 않다. 비중은 방향을 정하는 데만 쓴다.

## 4. 저장 데이터

`~/me/.masc/lane-addons` 를 읽기만 했다(22:30~22:45 KST).
scope 종류는 각 디렉터리 첫 기록의 `scope` 접두어로 나눴다.

| scope 종류 | scope 수 | 기록 수 | 기록 크기 | 본문 수 | 본문 크기 | 본문 중앙값 / 최대 |
| --- | --- | --- | --- | --- | --- | --- |
| `keeper-librarian-history-execution` | 27 | 355 | 1,400 MB | 359 | 1,376 MB | 1.79 / 30.67 MB |
| `keeper-librarian-durable-gate` | 26 | 349 | 13 MB | 354 | 1,345 MB | 1.79 / 30.67 MB |
| `keeper-librarian-execution` | 12 | 45 | 91 MB | 46 | 92 MB | 2.17 / 3.31 MB |
| `keeper-librarian-admission-gate` | 12 | 45 | 0 MB | 46 | 92 MB | 2.17 / 3.32 MB |
| 그 밖(`parts`, `workspace-curator`, `verifier-reviews`) | 14 | 62 | 10 MB | 63 | 33 MB | — |

모든 기록의 수정 시각은 2026-10-26 11:19~22:30 KST 사이다.

history scope와 gate scope는 코드의 규칙대로 짝지었다.
history scope 디렉터리 이름은 `sha256(scope)` 이고, gate scope는 `"keeper-librarian-durable-gate/" ^ sha256(history scope)` 이다(`keeper_librarian_durable_gate.ml` 6행).
Keeper 27명 중 original이 많은 순서:

| original | gate 기록 | history 기록 | history 본문 | gate 본문 |
| --- | --- | --- | --- | --- |
| 51 | 51 | 161 MB | 161 MB | 161 MB |
| 35 | 35 | 10 MB | 10 MB | 10 MB |
| 34 | 34 | 236 MB | 236 MB | 236 MB |
| 31 | 31 | 15 MB | 15 MB | 15 MB |
| 29 | 29 | 39 MB | 39 MB | 39 MB |

한 history 기록(3.2 MB)의 `progress` 이벤트 7개 중 하나가 3,761,573 바이트였다.
이벤트 이름은 `preparation_intended` 이고, 안의 `request.capture` 가 3,760,474 바이트다.
이 `capture` 를 canonical JSON으로 직렬화하면 3,370,525 바이트이고, history 본문 파일과 JSON으로 같았다.
본문 파일의 sha256은 기록의 `request_digest` 와 같았다.
gate 기록 하나의 본문에도 `capture` 필드가 있었다(394,164 바이트).

## 5. 마이크로 벤치

3.38 MB history 기록 파일 하나로 쟀다. OCaml 5.5.1, `ocamlfind ocamlopt`, digestif 1.3.0(`digestif.c`), yojson 3.0.0.
서버가 6코어 넘게 쓰는 중이라 같은 프로그램을 세 번 돌려 최솟값을 적었다.
첫 실행은 sha256 30 ms, 파싱 68 ms로 두세 배 느렸다.

| 작업 | 1회 |
| --- | --- |
| `Unix.stat` | 0.0014 ms |
| `String.equal` 3.38 MB (서로 다른 복사본, memcmp) | 0.12 ms |
| `Digestif.SHA256.digest_string` | 11.5 ms (약 290 MB/s) |
| `Yojson.Safe.from_string` | 23.6 ms (약 140 MB/s) |
| `Yojson.Safe.skip_json` (값을 만들지 않고 건너뜀) | 19.4 ms |
| `Yojson.Safe.to_string` (파싱한 값) | 7.7 ms |
| 같은 기록에서 `capture` 를 64자 문자열로 바꾼 5,604 바이트 파싱 | 0.043 ms |
| `openssl speed -evp sha256 -bytes 1048576` (OpenSSL 3.6.4) | 약 2.7 GB/s |

벤치 소스:

```ocaml
let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in close_in ic; s
let time name iters f =
  let t0 = Unix.gettimeofday () in
  for _ = 1 to iters do ignore (Sys.opaque_identity (f ())) done;
  Printf.printf "%-34s %10.4f ms/op\n%!" name
    ((Unix.gettimeofday () -. t0) /. float iters *. 1000.)
let () =
  let path = Sys.argv.(1) in
  let s = read_file path in
  time "Unix.stat" 2000 (fun () -> Unix.stat path);
  let copy = Bytes.to_string (Bytes.of_string s) in
  time "String.equal" 50 (fun () -> String.equal s copy);
  time "sha256" 20 (fun () -> Digestif.SHA256.digest_string s);
  time "from_string" 20 (fun () -> Yojson.Safe.from_string s);
  time "skip_json" 20 (fun () ->
    Yojson.Safe.skip_json (Yojson.Safe.init_lexer ()) (Lexing.from_string s));
  let j = Yojson.Safe.from_string s in
  time "to_string" 20 (fun () -> Yojson.Safe.to_string j)
```

```sh
ocamlfind ocamlopt -package yojson,digestif.c,unix -linkpkg bench.ml -o bench.exe
```

## 6. pass 비용 모델

측정한 pass 시간이 아니다. pass 시작과 끝을 남기는 로그가 없어 직접 재지 못했다.
5절의 1 MB당 비용(파싱 7.0 ms, sha256 3.4 ms, 직렬화 2.3 ms)으로 코드 경로를 따라 셌다.

- 기록 하나를 읽는 비용 = 기록 파싱 + 본문(sha256 + 파싱 + 직렬화)
- main: `discover` 로 original n개를 읽고, original마다 `read_chain` 3번이 gate scope의 기록 g개와 본문을 읽고, 맞는 gate 기록의 부모를 다시 읽는다.
- #46143: `discover` 한 번, gate scope 한 번, original마다 부모 한 번.
- canonical 재구성, 큰 JSON 비교, 두 번째 전체 읽기, GC는 넣지 않았다. 그래서 하한이다.

| | original 51개 Keeper | 27 Keeper 한 바퀴 |
| --- | --- | --- |
| main `6a2d8dd6171` | 약 325초 | 약 1,237초 |
| #46143 | 약 8.4초 | 약 72초 |

## 7. lane 적체

`~/me/.masc/logs/system_log_2026-10-26.jsonl` 에서 `13:18:56Z`부터 `13:46:51Z`까지
`memory lane coalesced latest snapshot (lane=librarian): replacing superseded post-turn memory unit` 가 252번 나왔다.
Keeper 23명에서 나왔고 한 Keeper가 최대 36번이었다.
앞 작업이 끝나기 전에 같은 Keeper의 새 작업이 들어와 대기 중인 작업을 대체했다는 뜻이다.

## 8. pass가 끝난 시각

`GET /api/v1/dashboard/keeper-memory-health` 는 Keeper마다 마지막 Librarian pass의 끝 시각(`librarian.measured_at`)과 아직 처리하지 않은 턴 수(`unread_atom_turns`)를 준다.
`14:27:15Z`부터 `14:33:28Z`까지 62초 간격으로 7번 읽었다.
서버가 이 응답을 60초 동안 캐시해서, 서로 다른 응답(`generated_at`)은 4개였다(340초 범위).

- Keeper 43명 중 18명이 이 동안 pass를 한 번 이상 끝냈다. 4개 응답에서 끝 시각이 매번 바뀐 Keeper가 4명이다.
- 캐시 때문에 이 숫자는 pass 수의 하한이다.
- 처리하지 않은 턴 합계는 938에서 947로 늘었다. 이 중 pass를 매번 끝낸 Keeper 하나는 84턴이 그대로였다.

pass가 1~2분마다 끝나는데도 쌓인 턴이 줄지 않는 Keeper가 있다.
이 Keeper들의 상태는 `pending` 또는 `stopped` 였다. 왜 줄지 않는지는 이 조사에서 확인하지 않았다.

## 확인하지 못한 것

- 실제 pass 한 번의 시간(8절은 60초 캐시를 거친 끝 시각만 봤다)
- #46143 적용 뒤 같은 측정
- canonical 재구성과 큰 JSON 비교의 비용
- 6절 모델은 Finished original의 `read_chain` 을 3번으로 셌다. 코드에서는 4번이다(`restore_size_evidence` 가 `latest` 를 한 번 더 부른다). 그래서 모델은 더 낮게 잡힌 하한이다.
