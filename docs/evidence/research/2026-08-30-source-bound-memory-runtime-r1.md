# Source-bound Memory OS runtime R1

## 결과

`keeper_memory_write`에 `source_path`를 추가했다. 이 값을 넣은 claim은
ordinary Memory OS에 쓰지 않는다. 별도 current store에 source 경로와 exact
bytes SHA-256을 함께 기록한다.

recall, memory search, context status는 이 store를 읽기 전에 source를 다시
읽는다. bytes가 바뀌거나 파일을 읽을 수 없으면 이전 claim을 prompt와
검색 결과에서 뺀다. 대신 typed invalidation을 남긴다. 같은 경로로 새
claim을 쓰면 live digest로 fact를 다시 만들고 invalidation을 지운다.

기존 `*.memory-current.json` 10개는 바꾸지 않았다. 기존 fact schema에
필드를 더하면 live state가 전부 unreadable이 되기 때문이다.

## 왜 이 구조인가

Lemmalog 글은 관찰이 바뀌면 그 관찰에 기대던 결론을 모델의 재판단에
맡기지 말고 자동으로 무효화해야 한다고 설명한다. 구현 저장소도 fact
provenance, retraction, incremental update를 핵심 기능으로 적고 있다.

STALE은 오래된 state를 찾는 것뿐 아니라 false premise 거부와 이후
행동 수정까지 따로 측정한다. StateAuditor는 LLM이 후보 전이를 찾더라도
provenance와 시간 순서는 결정적 코드로 확인한다. 이 PR도 같은 경계를
택했다. 모델은 claim을 쓴다. source 경로 제한, bytes hash, 철회 여부는
코드가 결정한다.

이것은 Lemmalog 전체를 MASC에 옮긴 구현이 아니다. 한 파일에 의존하는
explicit claim의 철회·재생성만 다룬다.

## 구현 계약

- `source_path`는 Keeper sandbox 안의 regular file이어야 한다.
- source는 최대 1 MiB까지 읽는다.
- 한 source path에는 current claim 하나만 둔다.
- persisted JSON은 closed current-only shape이다.
- old shape, migration, compatibility reader는 없다.
- source write가 ordinary + source-bound recall byte budget을 넘기면 저장
  전에 실패한다.
- recall 시 합산 payload가 budget을 넘으면 부분 주입하지 않고 전체를
  뺀다.
- source가 바뀌면 fact를 지우고 `source_changed` invalidation을 남긴다.
- source가 없거나 읽히지 않으면 `source_unavailable`을 남긴다.
- invalidation은 새 source-bound write가 성공할 때까지 다음 turn에도
  남는다.

## exact-head runtime

- source commit: `1a74490e82642805af249c496c3947b026a54428`
- binary SHA-256:
  `0f163ad23d6e2e07f234e9a9092aa2d7e06e8fad7c667862f02714efef5d4897`
- provider/model: `ollama` /
  `hf.co/unsloth/gemma-4-31B-it-qat-GGUF:UD-Q4_K_XL`
- isolated port: `9500`
- duration: `36000 ms`
- workspace verifier: `0`
- tool sequence: `Read, Read, Execute, Write, Execute, keeper_memory_write`

첫 prompt의 `memory_os_recall` block에는 stale claim이 0번 나타났다.
`reason=source_changed`는 2번 나타났다. block text와 source path가 각각
block projection과 전체 JSON에 한 번씩 들어가기 때문이다.

선언한 stale source bytes의 seed SHA-256은
`8e2e7e55dc8858471232e070c9cf7645af83775487a4e9b0eef7fce9dde508ab`
였다. 마지막 newline을 포함한 값이다.

최종 snapshot은 revision 3이었다. fact는 1개, invalidation은 0개였다.
live `service.toml`과 fact의 source digest는 모두
`0b79c1f7c5218e6a6bfa92266b0de96e7f506a9edc8eeb8b3ef91ecd4115abce`
였다.

원시 artifact SHA-256:

- `evidence.json`: `d22e19cb…63cdd5`
- `last-prompt.json`: `e9de10ee…6261f`
- `memory-source-seed.json`: `4b73d89c…9292ae3`
- `memory-source-final.json`: `e8260234…68d2ed`

전체 값과 exact prompt block은
`benchmarks/context_recovery/results/20260830-source-r1/summary.json`에 있다.

## 모델을 바꿔 본 결과

| run | stale 제거 | workspace | source 재생성 | 결과 |
|---|---:|---:|---:|---|
| exact Gemma 4 31B | 성공 | 성공 | 성공 | pass |
| Qwen3.8 27B, current case | 성공 | 성공 | 성공 | pass |
| Gemma 4 31B, pre-final guard | 성공 | 성공 | 성공 | pass |
| qwen3:8b, ambiguous target | 성공 | 실패 | 성공 | fail |
| qwen3:8b, current case | 성공 | 성공 | 실패 | fail |

추가 탐색 run까지 합치면 모델이 첫 토큰을 받기 전 stale claim 제거는
9/9이었다. 이는 SHA 비교가 model call 전에 끝났기 때문이다. 하지만
자동 재생성은 deterministic하지 않다. 8B는 한 번은 권위 원본을 잘못
고쳤고, 다음 번에는 workspace를 고친 뒤 `keeper_memory_write`를 호출하지
않았다. invalidation이 남아 다음 turn에 false claim이 돌아오지 않은 것이
안전장치다.

표본이 작고 engine별 repeat가 부족하다. 성능 향상은 주장하지 않는다.

## 검증

다음 focused checks를 통과했다.

- `test_keeper_memory_write`: 12/12
- `test_keeper_memory_os_current`: 22/22
- `test_coding_eval_cases`: 17/17
- `test_base_tool_toml_parity`: 3/3
- `test_keeper_tool_schema_bytes`: 3/3
- `test_keeper_prompt_capture`: 6/6
- `lib/masc.cmxa`, `bin/main_eio.exe` focused build
- `bash -n scripts/harness_coding_eval.sh`
- `ocamlformat --check`와 `git diff --check`

`test_keeper_tool_descriptor_registry_integrity` 전체 실행에는 이번 diff와
관계없는 기존 Board projection 실패가 있었다:
`masc_board_sub_board_create is the single Keeper model projection`.
같은 실행에서 Memory write의 closed schema와 terminal boundary 검사는
통과했다.

`shellcheck scripts/harness_coding_eval.sh`는 기존 경고 때문에 exit 1이다.
이번에 추가한 줄에서 새 경고는 없었다.

테스트 통과를 runtime proof로 사용하지 않았다. runtime 판정은
`last-prompt.json`, final snapshot, live file digest, verifier exit를 함께
사용했다.

## 남은 경계

- digest는 source bytes와 claim의 연결 시점만 증명한다. claim이 source를
  올바르게 요약했는지는 증명하지 않는다.
- ordinary Memory OS fact에는 source가 없다. 이 PR은 기존 claim을
  자동으로 source-bound로 바꾸지 않는다.
- source write 시 합산 budget을 확인하지만, 그 뒤 ordinary store가 커질
  수 있다. recall은 이 경우 전체 block을 빼므로 false context는 넣지
  않지만 memory가 일시적으로 안 보일 수 있다. 후속은 issue #31915에
  기록했다.
- weak model은 invalidation을 읽고도 새 claim을 쓰지 않을 수 있다.
  tombstone은 남지만 자동 복구 완료 시간은 보장하지 않는다.
- n<5 per model이다. pass rate 비교나 일반화는 금지한다.

## 실행 종료

격리 포트 `9491`–`9500` 가운데 사용한 포트에는 listener가 남지 않았다.
운영 `8935`는
`status=ok`였다. `effective_base_path=/Users/dancer/me`,
`effective_masc_root=/Users/dancer/me/.masc`, `roots_diverge=false`도 다시
확인했다.

## 근거

- [근거] [원문](https://pwning.systems/posts/llm-memory-program-analysis/),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. 관찰이 바뀌면 의존 결론을
  자동으로 무효화해야 한다는 설계 근거다.
- [근거] [Lemmalog 저장소](https://github.com/JordyZomer/lemmalog),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. provenance, retraction,
  incremental update의 현재 구현 범위를 확인했다.
- [근거] [STALE 논문](https://arxiv.org/abs/2605.06527),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. 400개 scenario와 state
  resolution, premise resistance, implicit policy adaptation 축을 확인했다.
- [근거] [StateAuditor 논문](https://arxiv.org/abs/2608.01619),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. provenance·chronology는
  결정적 코드가 검증하고 semantic supersession은 증명하지 않는 경계를
  확인했다.
- [근거] `git rev-parse HEAD`, `shasum -a 256
  _build/default/bin/main_eio.exe`, isolated runtime artifacts,
  2026-08-30T13:15:42+09:00 확인, 신뢰도 High.
