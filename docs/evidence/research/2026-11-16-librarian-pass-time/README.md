# librarian 판정 시각·쓸 날 문장 초안의 측정 기록, 2026-11-16

[연구 문서](../../../research/2026-11-16-librarian-dated-records-and-pass-time.md)가 이 기록을 근거로 쓴다.
이 폴더에는 숫자, 라벨, ID 와 초안이 바꾼 글만 있다. 요청 본문, 기억 문장, 모델 답 원문, 판정자가 적은 이유는 넣지 않았다.

이 실행은 연구 실행이다. 초안을 들이는 근거가 아니다.
`prompt_compare.py compare` 는 이 실행을 받지 않는다. 실행 하네스가 사본이라 `pass_lines.json` sha256 이 다르다.

## 낱말

| 낱말 | 뜻 |
| --- | --- |
| E-synth | 라벨이 있는 합성 요청 90건 |
| E-real | 라이브 admission 기록 50건. 라벨이 없다 |
| 쓸 날이 남은 기억 | 정해진 날에 쓰려고 적어 둔 기억 중 쓸 날이 요청의 마지막 후보 날짜보다 뒤인 것(`scheduled_ahead`). 라벨은 남기라고 한다 |
| 쓸 날이 지난 기억 | 쓸 날이 요청의 첫 후보 날짜보다 앞인 것(`scheduled_past`). 라벨은 낡은 상태로 보고 지우라고 한다 |
| 판정 시각 | librarian 이 패스를 시작한 시각. 초안이 프롬프트에 더한 칸의 이름이다 |
| 기억 묶음 | 같은 기억 목록을 실은 요청들. 하네스의 `audit_decisions.memory_of` 가 이름 붙이는 단위와 같다 |
| 큰 답 | 기억 10개 이상을 흡수한 유효 답 |
| 이항 σ | 두 쪽을 합친 비율로 센 이항 표준오차. `prompt_compare.py` 의 식이다 |
| 묶음 단위 구간 | 기억 묶음을 복원 추출로 10,000번 다시 뽑아 본 차이의 2.5~97.5 백분위 |
| 고정 비교 | RFC-0517 §2.3 의 들이는 기준을 `prompt_compare.py compare` 가 고정한 기준선과 견줘 내는 결과. 나빠짐은 −2.5σ 아래, 좋아짐은 +2σ 위다 |
| 후보 판정 | 답이 후보마다 적는 `incorporated`, `already_represented` 같은 결과. 블라인드 판정자의 판정과 다른 것이다 |
| 빈 입력 칸을 뺀 초안 | admission 프롬프트에서 빈 대화·도구 입력 칸을 뺀 템플릿. 잰 실행은 #52347(RFC-0517 에 결과를 적는 Draft)의 것이다. 코드는 그 위에 쌓인 #52348(Draft)에 있다 |

## 무엇을 확인했나

- 판정 시각을 프롬프트에 넣으면 쓸 날이 남은 기억을 덜 지우는가.
- 쓸 날을 말하는 문장 둘을 더하면 어떤가.
- `admission_policy` 의 지지 문장을 RFC-0517 §7.1 이 정한 지지 규칙대로 쓴 초안과 같이 넣으면 어떤가.
- 요약을 시키는 문장을 빼면 큰 답이 주는가.

## 소스와 입력

| 항목 | 값 |
| --- | --- |
| 고정 템플릿 | `config/prompts/librarian.md` sha256 `575a6849…`, 47,654바이트. main `71a19f1c9030` 의 파일과 같다 |
| 채점 하네스 | main `71a19f1c9030` 의 `scripts/tinker/librarian`. `pass_lines.json` sha256 `9b62a255…` |
| 기준선 | 고정 템플릿으로 잰 Inkling 두 실행. 수는 main 의 `prompt_lines.json` 에 고정된 값이다(#52242 로 들어갔다) |
| 실행 하네스 | #52242 의 checkout `3f11de239676` 에 [`harness-pass-time.patch`](harness-pass-time.patch) 를 얹고 `pass_lines.json` 을 다시 고정한 사본. 사본의 `pass_lines.json` sha256 `b9963e77…`. main 과 다른 파일은 아래 「하네스 사본」에 있다 |
| E-synth | requests sha256 `8aa43fde…`, 판정 사례 seed 20261113 |
| E-real | manifest sha256 `8d87e880…`. 기록은 git 이 무시하는 snapshot 에만 있다 |
| 모델 | Tinker `thinkingmachines/Inkling-2-Small:peft:262144` |
| 판정자 | Claude Opus 하위 에이전트. 라벨, 대상 모델, 초안, 다른 판정자의 폴더는 보지 못한다 |

[2026-11-13 기준선 기록](../2026-11-13-librarian-pinned-baseline/README.md)의 수(168/180, 219/250, 40/162, 72/96, 22/44, 15/74)는 옛 검사기(`pass_lines.json` `94c12b79…`)로 센 값이다.
이 기록의 기준선은 같은 답을 지금 검사기로 다시 센 값이다(175/180, 226/250, 52/204, 82/111, 56/89, 19/88).
다시 센 기록은 [2026-11-13 다시 센 기준선 기록](../2026-11-13-librarian-rescored-baseline/README.md)에 있다.

### E-synth 는 기억 묶음 31개를 나눠 쓴다

| 센 것 | 요청마다 센 수 | 서로 다른 기억 | 그 기억이 든 묶음 |
| --- | --- | --- | --- |
| 기억 전체 | 5,545 | 1,983 | 31 |
| 쓸 날이 남은 기억 | 38 | 12 | 9 |
| 쓸 날이 지난 기억 | 17 | 7 | 7 |
| 심은 낡은 상태 | 102 | 34 | 22 |

- 묶음 하나에 요청이 2건인 묶음이 12개, 3건이 11개, 4건이 7개, 5건이 1개다.
- 같은 묶음의 요청은 기억 목록이 같고 후보만 다르다. 두 묶음에 같이 든 기억은 없다.
- 아래 표의 분모는 요청마다 센 수다. 두 실행을 더한 76, 34, 204 는 그 두 배다.
- 요청의 마지막 후보 시각은 90건 모두 2026-11-07(UTC)이다.
  쓸 날이 남은 기억의 쓸 시각은 그 시각보다 1.1~5.5일 뒤다. 쓸 날이 지난 기억은 0.7~9.4일 앞이다.
- 쓸 날이 요청과 같은 날인 기억은 없다. 생성기가 같은 날의 기억을 만들지 않는다(`synth_rows.scheduled_holds`).
- 쓸 날이 다음 날인 기억도 없다. 쓸 날이 남은 기억의 쓸 날은 달력으로 2일, 3일, 5일 뒤뿐이다.
  요청마다 세면 18번, 15번, 5번이고 서로 다른 기억으로는 5개, 5개, 2개다.
  생성기는 후보를 11-07 에 두고 쓸 날을 11-09 부터 잡는다(`synth_generate.py` 의 `USE_AHEAD_START`).

## 초안

고정 템플릿에서 아래 글만 바꿨다. 바꿀 자리의 글은 템플릿에 한 번씩만 나온다.

| 고침 | 바꾼 것 |
| --- | --- |
| T | front matter 의 변수 목록에 `pass_time` 을 더한다. 「오래 다시 기록되지 않은 기억도 그것만으로 불필요해지지 않습니다.」 뒤에 한 문장을 더한다. 현재 턴 도구 관측 칸 뒤에 `### 판정 시각` 칸(`{{pass_time}}`)을 더한다 |
| S | 「그 기억에만 있는 교훈·제약·결정은 낡지 않았으니 새 claim으로 먼저 옮깁니다.」 뒤에 두 문장을 더한다 |
| P | `admission_policy` 의 지지 문장 8줄을 RFC-0517 §7.1 이 정한 지지 규칙대로 바꾼다 |
| R | 「같은 대상을 다룬 기억이 여러 개 모이면 중심이 되는 말을 정하고, 그 대상에 대해 무엇이 중요한지를 정리합니다.」 를 뺀다 |

T 가 더한 문장:

```text
아래 `판정 시각`은 호스트가 이 판정을 시작한 UTC 시각입니다.
```

S 가 더한 문장:

```text
정해진 날에 쓰려고 미리 적어 둔 기억은 그날 한 번 쓰고 끝나는 내용이어도 쓸 날까지 기억에 남습니다.
쓸 날이 아래 판정 시각보다 뒤면 아직 쓰이지 않은 기억이고, 쓸 날이 지났으면 낡은 상태입니다.
```

P 가 넣은 글:

```text
change_support lists, each once, the request IDs of the candidates the Memory decision rests on.
Only incorporated or already_represented candidates can be listed.
A new claim is one whose text is not a current memory's claim copied unchanged. A new claim that
absorbs no current memory, and a claim that supersedes one, is the memory_claim of an incorporated
candidate listed in change_support.
Drops of current memories, and a new claim that absorbs current memories and supersedes none,
rest on current Memory and need no candidate. change_support can then be empty, also when every
candidate is deferred. Do not add other fields or put the wrapper inside memory.
```

| 초안 | 고침 | sha256 | 바이트 |
| --- | --- | --- | --- |
| P | P | `f1642c8fd8db…` | 47,671 |
| A | T | `f3b8b1ee38ca…` | 47,782 |
| B | P + T | `0c6eaf55ab57…` | 47,799 |
| F | T + S | `b4d5efb11ff8…` | 48,054 |
| E | P + T + S + R | `9a950110fc4c…` | 47,915 |

P 초안의 실행과 판정은 이 실험보다 먼저 한 것이다. 공개된 기록이 없어서 실행과 판정 폴더의 sha256 을 이 측정 기록에 같이 적는다.

## 하네스 사본

MASC 는 Librarian 프롬프트에 시각을 그리지 않는다. 고정 하네스도 그렇다. 그래서 사본에서 쟀다.

- 사본은 #52242 의 checkout `3f11de239676` 에서 만들었다. 두 파일에 [`harness-pass-time.patch`](harness-pass-time.patch) 를 얹고 `pass_lines.json` 을 다시 고정했다.
- 사본이 main `71a19f1c9030` 과 다른 파일은 넷이다.

| 파일 | 다른 까닭 | 채점에 쓰이나 |
| --- | --- | --- |
| `admission_template.py` | patch 가 문자열 변수 `pass_time` 을 더했다. 템플릿에 없어도 된다 | 쓰인다 |
| `admission_request.py` | patch 가 `pass_time` 을 요청의 마지막 후보 시각으로 그린다 | 쓰인다 |
| `pass_lines.json` | 위 두 파일의 sha256 만 다르다 | 쓰인다 |
| `synth_generate.py` | 그 checkout 의 E-synth 생성기다 | 이 실험은 요청을 새로 만들지 않았다 |

- main 의 두 파일에 patch 를 얹으면 사본의 두 파일과 바이트가 같다(`git apply --unidiff-zero harness-pass-time.patch`).
  patch 의 주석에 나오는 `time_harness_patch.py` 는 사본을 만든 스크립트다. git 이 무시하는 `artifacts/tinker/librarian/code/` 에만 있다.
- `pass_lines.json` 이 고정하는 채점 파일은 24개다. 그중 22개가 사본과 main 에서 바이트가 같다. 나머지 둘이 patch 의 두 파일이다.
  `synth_generate.py` 는 그 24개에 들지 않는다.
- `pass_time` 은 요청의 마지막 후보 시각을 RFC 3339 문자열로 적은 값이다.
  블라인드 판정자가 case 의 `now` 로 받는 값과 같다(`e_synth_audit.request_time`). E-synth 90건 모두 같았다.
- T 의 문장은 호스트가 패스를 시작한 시각이라고 말한다. 잰 값은 마지막 후보 시각이다. 라이브에서 패스는 그보다 늦게 시작한다.
- 고정 템플릿으로 그린 프롬프트 140건(E-synth 90, E-real 50)은 patch 를 얹기 전과 뒤의 하네스에서 바이트가 같다.

## 실행 전에 적은 기준

기준은 git 이 무시하는 `artifacts/tinker/librarian/exp-time/PLAN.md` 에 적었다.
커밋이 없어서 적은 때를 저장소로 확인할 수 없다. 아래 시각은 그 디스크의 파일 시각과 호출을 보낸 시각이다(KST).

| 시각 | 일 |
| --- | --- |
| 01:58:01 | A 와 B 의 첫 호출을 보냄 |
| 02:04:04 | A 의 마지막 호출을 보냄. 마지막 답은 02:04:16 에 왔다 |
| 02:07:17 | B 의 마지막 호출을 보냄. 마지막 답은 02:08:06 에 왔다 |
| 02:07:22 | 기준 파일의 마지막 저장 |
| 02:07:25 | F 와 E 의 첫 호출을 보냄 |

처음 적은 기준은 이렇다.

1. 유효 답이 85/90 아래인 초안은 뺀다.
2. P 가 든 초안 가운데 낡은 상태 지움이나 합침이 P 두 실행 합보다 2.5σ 넘게 낮은 초안은 뺀다.
3. 남은 초안 중 쓸 날이 남은 기억을 남긴 비율이 가장 높은 초안을 고른다. 차이가 1σ 안이면 문장을 덜 더한 초안을 고른다.
4. 고른 초안은 E-synth 를 한 번 더 돌리고 지우기와 흡수를 블라인드 판정자에게 맡긴다.
5. 선별은 한 번 실행이다. 2σ 를 넘는 차이만 달라졌다고 적는다.

A 의 결과를 본 뒤에 기준을 두 번 바꿨다. 둘 다 F 와 E 를 돌리기 전이다.
F 와 E 는 B 의 마지막 답이 오기 전에 띄웠다. E 를 넘기는 조건은 B 의 값을 쓰지만 B 가 끝나기 전에 적었다.

- 바꾼 것 1: S 의 글을 바꿨다. 옛 글은 「한 시점의 상태가 아닙니다」까지만 말했다. 새 글은 「그날 한 번 쓰고 끝나는 내용이어도 쓸 날까지 기억에 남습니다」를 말한다.
- 바꾼 것 2: P + T + R 초안 대신 F(T + S)를 돌렸다. S 의 효과는 F 대 A 로 읽는다. R 의 효과는 E 대 B 로 읽고, 그 비교에는 S 가 섞여 있다.
  - F 를 다음 단계로 넘기는 조건: 쓸 날이 남은 기억을 남긴 비율이 A 보다 2σ 넘게 높다. 다른 값은 기준선 두 실행 합보다 2.5σ 넘게 낮지 않다.
  - E 를 넘기는 조건: 그 비율이 B 보다 2σ 넘게 높다. 낡은 상태 지움과 합침은 P 두 실행 합보다 2.5σ 넘게 낮지 않다.

적어 둔 기준과 다르게 한 것은 이렇다.

- 기준은 이항 σ 로 적었다. 기억 묶음 단위로 다시 뽑는 셈은 결과를 본 뒤에 더했다.
- E 도 조건을 채웠다. 판정자에게는 F 만 맡겼다.
- E-real 은 F 만 한 번 돌렸다. 실행에 준 지출 한도에 닿아 50건 중 47건에서 멈췄다.

## 실행 파일

실행 폴더는 git 이 무시하는 `artifacts/tinker/librarian/` 아래에 있다. 모델 답은 `calls.jsonl` 에만 있다.
Tinker 실행은 요청마다 호출을 두 번 보낸다. 첫 호출은 프롬프트 캐시를 데우고 둘째 호출을 잰다(`eval_admission.py`).
그래서 E-synth 의 `calls.jsonl` 줄 수는 `rows.jsonl` 의 두 배다.
지출은 공개 단가로 스크립트가 센 값이다.

| 실행 폴더 | 초안 | 템플릿 | `rows.jsonl` 줄 | sha256 | `calls.jsonl` 줄 | sha256 | 지출 USD |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `rescore-a1/base-inkling-synth-1` | 기준선 | `575a6849…` | 90 | `263bbff6a5e2…` | 180 | `273463901a46…` | 0.6892 |
| `rescore-a1/base-inkling-synth-2` | 기준선 | `575a6849…` | 90 | `a801321a9862…` | 180 | `3f99f95d4a36…` | 0.5048 |
| `rescore-a1/base-glm-synth-1` | GLM 기준선 | `575a6849…` | 90 | `bcb0174ee929…` | 93 | `e738aa9f4d12…` | — |
| `a1p-inkling-synth-1` | P | `f1642c8f…` | 90 | `f0071131b3e9…` | 180 | `7c1cb5288710…` | 1.1345 |
| `a1p-inkling-synth-2` | P | `f1642c8f…` | 90 | `ff04d2d5a44e…` | 180 | `741f3d2548bd…` | 0.7065 |
| `xtA-inkling-synth-1` | A | `f3b8b1ee…` | 90 | `0fc01915dd15…` | 180 | `122978d4c5cb…` | 1.0060 |
| `xtB-inkling-synth-1` | B | `0c6eaf55…` | 90 | `161d6dfe1ce9…` | 180 | `b2b62ee69861…` | 0.7512 |
| `xtF-inkling-synth-1` | F | `b4d5efb1…` | 90 | `cf206f45d5a8…` | 180 | `c455edc159c3…` | 0.9844 |
| `xtF-inkling-synth-2` | F | `b4d5efb1…` | 90 | `11b5d17e76b6…` | 180 | `4621240d0247…` | 0.5411 |
| `xtE-inkling-synth-1` | E | `9a950110…` | 90 | `24b6ce6c03e9…` | 180 | `97ccfa1bc346…` | 1.0964 |
| `xtE-inkling-synth-2` | E | `9a950110…` | 90 | `06470245cc5f…` | 180 | `603aca977d52…` | 0.6935 |
| `xtF-inkling-real-1` | F | `b4d5efb1…` | 47 | `6e41961b02d2…` | 95 | `34854c41c648…` | 1.1261 |

- 이 실험이 새로 돌린 실행은 `xt` 로 시작하는 일곱 개다. 지출 합은 $6.199 다.
- GLM 기준선 실행은 #52242 가 고정한 실행이다. GLM 초안 실행은 없다.
- P 의 두 실행은 실행에 준 지출 한도에 닿아 한 번씩 멈췄다. 같은 폴더에서 이어 돌려 90건을 다 물었다.

판정은 블라인드다. 이 실험에서는 F 의 두 실행만 판정했다. 기준선과 P 의 판정은 먼저 한 것이다.

| 판정 폴더 | case | `judge/decisions.jsonl` 줄 | sha256 | 판정 |
| --- | --- | --- | --- | --- |
| `rescore-a1/opus/base-inkling-1-drops` | 8 | 8 | `5e3b256a1785…` | 라벨 밖 지우기 13개 모두 `keep` |
| `rescore-a1/opus/base-inkling-2-drops` | 9 | 9 | `fd6ce8d33f4a…` | 라벨 밖 지우기 15개 모두 `keep` |
| `rescore-a1/opus/base-inkling-1-merges` | 52 | 52 | `8a9039092f87…` | `mergeable` 31, `loses_knowledge` 21 |
| `rescore-a1/opus/base-inkling-2-merges` | 37 | 37 | `2f619e35e768…` | `mergeable` 25, `loses_knowledge` 12 |
| `rescore-a1/opus/additions-inkling-1` | 25 | 25 | `72949bab6fbc…` | `no_addition` 17, `adds_unsupported` 8 |
| `rescore-a1/opus/additions-inkling-2` | 24 | 24 | `d7425f11a53e…` | `no_addition` 19, `adds_unsupported` 5 |
| `a1p-inkling-drops-1` | 19 | 19 | `cc0fd12bd454…` | 라벨 밖 지우기 33개 모두 `keep` |
| `a1p-inkling-drops-2` | 17 | 17 | `3e8994c962f0…` | 라벨 밖 지우기 28개 모두 `keep` |
| `a1p-inkling-merges-1` | 279 | 279 | `ca401523e8ec…` | `mergeable` 128, `loses_knowledge` 151 |
| `a1p-inkling-merges-2` | 247 | 247 | `2fd2a2a0deb0…` | `mergeable` 113, `loses_knowledge` 133, `different_context` 1 |
| `a1p-inkling-additions-1` | 118 | 118 | `c651a923e631…` | `no_addition` 83, `adds_unsupported` 35 |
| `a1p-inkling-additions-2` | 86 | 86 | `a03fbfa3445a…` | `no_addition` 50, `adds_unsupported` 35, `uncertain` 1 |
| `xtF-inkling-drops-1` | 3 | 3 | `3a1c17b9c2da…` | 라벨 밖 지우기 3개 모두 `keep` |
| `xtF-inkling-drops-2` | 2 | 2 | `5a028b8d2b56…` | 라벨 밖 지우기 2개 모두 `keep` |
| `xtF-inkling-merges-1` | 32 | 32 | `daf8fbbf272b…` | `mergeable` 18, `loses_knowledge` 14 |
| `xtF-inkling-merges-2` | 97 | 97 | `73d1ca8019fe…` | `mergeable` 42, `loses_knowledge` 55 |
| `xtF-inkling-additions-1` | 13 | 13 | `586f69d77b24…` | `no_addition` 10, `adds_unsupported` 3 |
| `xtF-inkling-additions-2` | 43 | 43 | `386385cc0d50…` | `no_addition` 34, `adds_unsupported` 9 |

- 지우기 case 는 요청 하나다. 판정자는 그 요청의 기억마다 `keep`, `drop`, `restates`, `superseded` 중 하나를 고른다. `keep` 은 그 기억을 남겨야 한다는 뜻이다.
- 라벨 밖 지우기는 라벨이 지우라고도 합치라고도 하지 않은 기억을 답이 지운 것이다(`dropped_off_label`).
  판정자의 판정으로 채점에서 빠진 기억은 여섯 실행 모두 없다.
- 판정자는 case 의 `now` 와 쓸 날 규칙을 같이 받는다. 규칙은 「쓸 날이 `now` 의 날짜보다 뒤면 `keep`, 앞이면 `drop`」이다(`e_synth_audit.py` 의 `JUDGE`).
  라벨과 같은 규칙이다. 그래서 쓸 날이 남은 기억에 대한 `keep` 은 라벨과 독립된 확인이 아니다.
- 흡수 case 는 흡수된 기억과 합친 claim 의 짝이다. 같은 짝을 낸 흡수는 case 하나가 대신한다.
  F 1 은 case 32개가 흡수 36개를, F 2 는 case 97개가 흡수 98개를 대신한다.
  F 2 의 나머지 흡수 2개는 심은 낡은 상태를 흡수한 것이다. case 가 없고 `mergeable` 이 아닌 것으로 센다.
- 덧붙임 case 는 합친 claim 하나다. 판정자는 claim 이 재료에 없는 말을 더했는지 본다.
  `adds_unsupported` 는 기준선이 49건 중 13건, F 가 56건 중 12건, P 가 204건 중 70건이다. 폴더마다 `merge_additions.py count` 로 셌다.
  지지 후보가 그 claim 을 `incorporated` 로 가리킨 합침만 세면 기준선 8/30, F 7/27, P 8/37 이다.
  지지 후보가 없는 합침은 기준선 5/19, F 5/29, P 62/167 이다. 지지 후보가 없는 합침은 RFC-0517 §7.1 로만 받는 합침이다.

## 명령

저장소 루트에서 돌린다. 채점 하네스와 기준선 고정값은 main 의 것을 쓴다.

```sh
E=docs/evidence/research/2026-11-16-librarian-pass-time
R=artifacts/tinker/librarian
H=scripts/tinker/librarian
python3 $E/time_screen.py --runs $E/screen-runs.json --root $R --out "$TMPDIR/screen.json"
uv run --python 3.12 --with openai==3.46.0 $E/time_judged.py --scripts $H \
  --runs $E/judged-runs.json --root $R \
  --expect $H/prompt_lines.json --out "$TMPDIR/judged.json"
python3 $E/time_cluster.py --runs $E/judged-runs.json --requests $R/e-synth-pooled/requests.jsonl \
  --root $R --draft F --baseline base --judged "$TMPDIR/judged.json" --screen "$TMPDIR/screen.json" \
  --out "$TMPDIR/cluster-F-base.json"
uv run --python 3.12 --with openai==3.46.0 $E/time_absent.py --scripts $H \
  --runs $E/screen-runs.json --requests $R/e-synth-pooled/requests.jsonl --root $R --out "$TMPDIR/absent.json"
```

- `time_cluster.py` 는 `--draft` 와 `--baseline` 을 바꿔 가며 돌렸다: F·base, F·A, A·base, P·base, E·base, E·B, B·P.
- `time_judged.py` 는 `prompt_counts.measure` 의 E-synth 절반을 같은 함수로 센다.
  기준선 폴더에서 센 수가 `prompt_lines.json` 의 고정값과 다르면 멈춘다. 이번에는 같았다.
  기준선이 비어 있는(`null`) `prompt_lines.json` 을 주면 그렇다고 알리고 멈춘다.
- `time_cluster.py` 는 자기가 센 수가 `time_judged.py` 나 `time_screen.py` 가 쓴 수와 다르면 멈춘다. 이번에는 같았다.
- `time_absent.py` 는 `calls.jsonl` 의 답을 읽는다. 수만 낸다.
- [`outputs.jsonl`](outputs.jsonl) 은 위 명령이 쓴 JSON 열 개다. 한 줄이 출력 하나다.
  `output` 은 출력 이름(`screen`, `judged`, `cluster-<초안>-<견준 쪽>` 일곱, `absent`)이고 `content` 는 그 출력이다.
  아래 표의 수는 이 파일과 견줄 수 있다. 같은 명령을 다시 돌려 나온 열 개도 이 파일과 같았다.

## 결과

### 라벨만으로 센 값 (`time_screen.py`)

`a/b` 는 맞은 수와 기회 수다.

| 실행 | 고침 | 유효 답 | 쓸 날이 남은 기억을 남김 | 쓸 날이 지난 기억을 지움 | 낡은 상태 지움 | 합침 | 남는 기억 정확도 | 지우기 정밀도 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 기준선 1 | — | 89/90 | 27/38 | 2/17 | 31/102 | 15/44 | 114/125 | 46/60 |
| 기준선 2 | — | 86/90 | 25/38 | 3/17 | 21/102 | 12/44 | 112/125 | 36/51 |
| GLM 기준선 | — | 82/90 | 17/38 | 11/17 | 60/102 | 30/44 | 110/125 | 76/99 |
| P 1 | P | 89/90 | 10/38 | 6/17 | 62/102 | 25/44 | 119/125 | 78/111 |
| P 2 | P | 85/90 | 16/38 | 7/17 | 57/102 | 30/44 | 114/125 | 76/104 |
| A | T | 87/90 | 23/38 | 2/17 | 24/102 | 14/44 | 115/125 | 40/57 |
| B | P + T | 86/90 | 16/38 | 7/17 | 71/102 | 31/44 | 115/125 | 89/114 |
| F 1 | T + S | 87/90 | 36/38 | 7/17 | 35/102 | 17/44 | 114/125 | 52/55 |
| F 2 | T + S | 86/90 | 37/38 | 6/17 | 35/102 | 15/44 | 112/125 | 50/53 |
| E 1 | P + T + S + R | 85/90 | 37/38 | 10/17 | 68/102 | 26/44 | 114/125 | 84/87 |
| E 2 | P + T + S + R | 83/90 | 38/38 | 10/17 | 62/102 | 29/44 | 111/125 | 78/80 |

| 열 | 뜻 |
| --- | --- |
| 쓸 날이 남은 기억을 남김 | 쓸 날이 남은 기억 중 답이 `dropped` 로 지우지 않은 수. 무효 답은 기억을 바꾸지 않으므로 남긴 것으로 센다. 답이 새 claim 에 흡수한 기억도 남긴 것으로 센다(`memory_scores.score_synth`) |
| 쓸 날이 지난 기억을 지움 | 쓸 날이 지난 기억 중 답이 지운 수. 이 기억은 낡은 상태 102개에 든다 |
| 낡은 상태 지움 | 심은 낡은 상태 중 답이 지운 수(`stale_drop_recall`) |
| 합침 | 라벨이 바란 합침 중 답이 한 수. 판정자의 판정은 넣지 않았다 |
| 남는 기억 정확도 | 후보마다, 답을 적용한 뒤 남는 기억이 라벨과 같은 상태인 수(`memory_state_accuracy`) |
| 지우기 정밀도 | 답이 지운 기억 중 라벨이 지우라고 한 수(`drop_precision`) |

쓸 날이 남은 기억을 흡수한 답은 E 2 에 하나 있다. `eval-qa-coordinator-06` 의 요청 하나에서 기억 2개를 흡수했다.
E 2 의 38/38 과 E 의 75/76 은 흡수된 2개를 남긴 것으로 센 값이다. 2개를 빼면 36/38 과 73/76 이다. 다른 열 실행에는 흡수된 기억이 없다.
E 의 흡수는 판정하지 않았다. `rows.jsonl` 의 `absorbs` 에서 셌다.

차이를 이항 σ 로 나눈 값이다. 같은 초안의 실행은 더해서 견줬다. 고정 비교의 폭은 나빠짐 2.5σ, 좋아짐 2σ 다.

| 견준 것 | 달라진 고침 | 유효 답 | 쓸 날이 남은 기억을 남김 | 쓸 날이 지난 기억을 지움 | 낡은 상태 지움 | 합침 | 남는 기억 정확도 | 지우기 정밀도 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A − 기준선 | T | −0.3 | −0.8 | −0.3 | −0.4 | +0.1 | +0.5 | −0.5 |
| F − A | S | −0.2 | +4.9 | +2.0 | +1.9 | +0.5 | −0.5 | +4.3 |
| F − 기준선 | T + S | −0.6 | +4.5 | +2.2 | +1.9 | +0.8 | 0.0 | +4.2 |
| P − 기준선 | P | −0.3 | −4.2 | +2.2 | +6.7 | +4.2 | +1.1 | −0.4 |
| B − P | T | −0.5 | +0.8 | +0.2 | +1.9 | +0.9 | −0.4 | +1.3 |
| E − B | S + R | −0.7 | +7.1 | +1.2 | −1.0 | −0.9 | −0.6 | +5.0 |
| E − P | T + S + R | −1.5 | +8.4 | +1.7 | +1.1 | 0.0 | −1.3 | +6.5 |
| E − F | P + R | −1.2 | +1.0 | +1.7 | +5.9 | +3.5 | −0.2 | +1.1 |
| E − 기준선 | P + T + S + R | −1.7 | +5.0 | +3.8 | +7.8 | +4.2 | −0.2 | +5.8 |

- 이항 σ 는 지우기 하나하나를 따로 뽑은 것으로 센다. 같은 기억을 묶음의 요청마다 다시 세므로 이 σ 는 차이를 실제보다 크게 보이게 한다.
- 표는 9줄 7열이다. 2σ 언저리 칸은 우연으로도 몇 개 나온다.

라벨이 지우라고 하지 않은 기억을 지운 수다.

| 초안 | 지운 기억 | 라벨이 지우라고 하지 않은 것 | 그중 쓸 날이 남은 기억 |
| --- | --- | --- | --- |
| 기준선 (두 실행) | 111 | 29 | 24 |
| P (두 실행) | 215 | 61 | 50 |
| A | 57 | 17 | 15 |
| F (두 실행) | 108 | 6 | 3 |
| E (두 실행) | 167 | 5 | 1 |

- 둘째 열은 지우기 정밀도의 분모다. 셋째 열은 분모에서 분자를 뺀 수다.
- 넷째 열은 쓸 날이 남은 기억의 수에서 남긴 수를 뺀 값이다. 쓸 날이 남은 기억은 라벨의 지울 집합에도 합칠 집합에도 들지 않는다(`memory_scores.score_synth`).
- 셋째 열은 라벨 밖 지우기와, 라벨이 합치라고 한 기억을 답이 지운 것(`dropped_unmerged`)의 합이다.
  기준선은 28 + 1, F 는 5 + 1, P 는 61 + 0 이다(`time_judged.py`).

### 판정자의 판정을 넣어 센 값 (`time_judged.py`)

| 지표 | 기준선 (두 실행) | F 1 | F 2 | F (두 실행) | 이항 d/σ | P (두 실행) | 이항 d/σ |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `synth_valid_rate` | 175/180 | 87/90 | 86/90 | 173/180 | −0.6 | 174/180 | −0.3 |
| `memory_state_accuracy` | 226/250 | 114/125 | 112/125 | 226/250 | 0.0 | 233/250 | +1.1 |
| `stale_drop_recall` | 52/204 | 35/102 | 35/102 | 70/204 | +1.9 | 119/204 | +6.7 |
| `drop_precision` | 82/111 | 52/55 | 50/53 | 102/108 | +4.2 | 154/215 | −0.4 |
| `absorb_precision` | 56/89 | 21/36 | 43/100 | 64/136 | −2.3 | 242/529 | −3.0 |
| `judged_merge_recall` | 19/88 | 14/44 | 14/44 | 28/88 | +1.5 | 45/88 | +4.1 |

- `absorb_precision` 은 답이 흡수한 기억 중 판정자가 `mergeable` 로 본 수다.
- `judged_merge_recall` 은 라벨이 바란 합침 중 답이 했고 판정자가 `mergeable` 로 본 수다.
- F 2 만 보면 `absorb_precision` 은 −2.7σ 다.
- 고정 비교가 채택 근거로 보는 지표는 `memory_state_accuracy`, `stale_drop_recall`, `judged_merge_recall` 셋이다(`prompt_compare.py` 의 `QUALITY`).
  좋아짐은 Inkling 에서만 센다(`prompt_lines.json` 의 `better_from`).
  F 는 셋 다 +2σ 를 넘지 않는다. `drop_precision` 과 `absorb_precision` 은 나빠짐 검사에만 쓰인다.

### 기억 묶음 단위로 다시 뽑아 본 차이 (`time_cluster.py`)

두 쪽이 같은 요청에 답했으므로 뽑힌 묶음의 요청을 양쪽에서 같이 가져왔다. 10,000번 뽑았고 seed 는 20261116 이다.

| 견준 것 | 값 | 초안 | 견준 쪽 | 차이 | 묶음 단위 구간 | 초안이 낮은 뽑기 | 기회가 있는 묶음 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F − 기준선 | 쓸 날이 남은 기억을 남김 | 73/76 | 52/76 | +0.276 | −0.022 ~ +0.484 | 2.9% | 9 |
| F − 기준선 | 쓸 날이 지난 기억을 지움 | 13/34 | 5/34 | +0.235 | 0.000 ~ +0.500 | 0.0% | 7 |
| F − 기준선 | `drop_precision` | 102/108 | 82/111 | +0.206 | +0.006 ~ +0.388 | 2.1% | 24 |
| F − 기준선 | `absorb_precision` | 64/136 | 56/89 | −0.159 | −0.331 ~ +0.219 | 77.1% | 21 |
| F − 기준선 | `stale_drop_recall` | 70/204 | 52/204 | +0.088 | −0.013 ~ +0.196 | 3.9% | 22 |
| F − 기준선 | `memory_state_accuracy` | 226/250 | 226/250 | 0.000 | −0.052 ~ +0.052 | 47.4% | 31 |
| F − A | 쓸 날이 남은 기억을 남김 | 73/76 | 23/38 | +0.355 | +0.204 ~ +0.449 | 0.0% | 9 |
| F − A | `drop_precision` | 102/108 | 40/57 | +0.243 | +0.098 ~ +0.393 | 0.1% | 23 |
| A − 기준선 | 쓸 날이 남은 기억을 남김 | 23/38 | 52/76 | −0.079 | −0.250 ~ +0.048 | 85.1% | 9 |
| A − 기준선 | `drop_precision` | 40/57 | 82/111 | −0.037 | −0.141 ~ +0.056 | 79.5% | 23 |
| A − 기준선 | 쓸 날이 지난 기억을 지움 | 2/17 | 5/34 | −0.029 | −0.357 ~ +0.273 | 51.4% | 7 |
| P − 기준선 | 쓸 날이 남은 기억을 남김 | 26/76 | 52/76 | −0.342 | −0.488 ~ −0.200 | 99.9% | 9 |
| P − 기준선 | `absorb_precision` | 242/529 | 56/89 | −0.172 | −0.320 ~ +0.028 | 95.4% | 28 |
| P − 기준선 | `stale_drop_recall` | 119/204 | 52/204 | +0.328 | +0.237 ~ +0.406 | 0.0% | 22 |
| E − 기준선 | 쓸 날이 남은 기억을 남김 | 75/76 | 52/76 | +0.303 | +0.038 ~ +0.490 | 0.5% | 9 |
| E − 기준선 | `drop_precision` | 162/167 | 82/111 | +0.231 | +0.039 ~ +0.405 | 0.6% | 25 |
| E − 기준선 | `stale_drop_recall` | 130/204 | 52/204 | +0.382 | +0.279 ~ +0.490 | 0.0% | 22 |
| E − B | 쓸 날이 남은 기억을 남김 | 75/76 | 16/38 | +0.566 | +0.275 ~ +0.804 | 0.0% | 9 |
| B − P | 쓸 날이 남은 기억을 남김 | 16/38 | 26/76 | +0.079 | −0.071 ~ +0.200 | 10.5% | 9 |

- 쓸 날이 남은 기억이 든 묶음은 9개뿐이다. 묶음이 이만큼 적으면 백분위 구간은 실제보다 좁게 나오는 쪽으로 틀린다.
- 0 을 겨우 벗어난 구간이 둘 있다. `drop_precision` 의 F − 기준선(+0.006 ~ +0.388)과 쓸 날이 남은 기억의 E − 기준선(+0.038 ~ +0.490)이다.
  구간이 좁게 나오는 쪽으로 틀리므로 두 구간만으로 차이가 있다고 말하기는 어렵다.
- 「기회가 있는 묶음」은 그 값의 분모가 0 이 아닌 묶음의 수다. 차이가 난 묶음의 수가 아니다.
- 쓸 날이 지난 기억을 지움은 10,000번 중 5번이 쓸 날이 지난 기억을 하나도 뽑지 못해 빠졌다.

### 쓸 날이 남은 기억, 기억 묶음별 (`time_cluster.py`)

남긴 수와 기회 수다. 기회 수는 묶음의 요청 수에 기억 수와 실행 수를 곱한 값이다.

| 기억 묶음 | 요청 | 쓸 날이 남은 기억 | 기준선 | A | F | P | B | E |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `eval-docs-gardener-00` | 2 | 1 | 4/4 | 1/2 | 3/4 | 2/4 | 0/2 | 4/4 |
| `eval-docs-gardener-06` | 5 | 1 | 10/10 | 3/5 | 8/10 | 7/10 | 4/5 | 9/10 |
| `eval-infra-cost-watch-14` | 3 | 2 | 10/12 | 4/6 | 12/12 | 2/12 | 3/6 | 12/12 |
| `eval-infra-cost-watch-15` | 2 | 1 | 4/4 | 2/2 | 4/4 | 4/4 | 2/2 | 4/4 |
| `eval-qa-coordinator-06` | 4 | 2 | 6/16 | 4/8 | 16/16 | 0/16 | 0/8 | 16/16 |
| `eval-support-triage-02` | 4 | 2 | 7/16 | 4/8 | 16/16 | 4/16 | 3/8 | 16/16 |
| `eval-support-triage-08` | 2 | 1 | 2/4 | 1/2 | 4/4 | 1/4 | 0/2 | 4/4 |
| `eval-support-triage-11` | 2 | 1 | 4/4 | 2/2 | 4/4 | 4/4 | 2/2 | 4/4 |
| `eval-support-triage-17` | 3 | 1 | 5/6 | 2/3 | 6/6 | 2/6 | 2/3 | 6/6 |
| 합 | 27 | 12 | 52/76 | 23/38 | 73/76 | 26/76 | 16/38 | 75/76 |

| 견준 것 | 초안의 비율이 높은 묶음 | 낮은 묶음 | 같은 묶음 |
| --- | --- | --- | --- |
| F − 기준선 | 5 | 2 | 2 |
| F − A | 7 | 0 | 2 |
| A − 기준선 | 2 | 4 | 3 |
| P − 기준선 | 0 | 7 | 2 |
| E − 기준선 | 5 | 1 | 3 |
| E − B | 7 | 0 | 2 |
| B − P | 4 | 2 | 3 |

| 초안 | 서로 다른 기억 12개 중 모든 답이 남긴 기억 | 무효 답 | 무효 답에 든 기회 | 무효 답을 뺀 값 |
| --- | --- | --- | --- | --- |
| 기준선 | 4 | 1 | 1 | 51/75 |
| A | 2 | 1 | 1 | 22/37 |
| F | 10 | 3 | 5 | 68/71 |
| P | 2 | 4 | 4 | 22/72 |
| B | 2 | 1 | 1 | 15/37 |
| E | 11 | 6 | 6 | 69/70 |

- 기준선이 지운 24번 중 19번이 묶음 둘에서 나왔다. `eval-qa-coordinator-06` 이 10번, `eval-support-triage-02` 가 9번이다. 서로 다른 기억으로는 4개다.
  나머지 5번은 `eval-support-triage-08` 2번, `eval-infra-cost-watch-14` 2번, `eval-support-triage-17` 1번이다.
- F 가 지운 3번은 `eval-docs-gardener-00` 과 `eval-docs-gardener-06` 의 기억 둘에서 나왔다. Inkling 기준선은 두 기억을 14번 중 한 번도 지우지 않았다.
- 다른 실행은 같은 두 기억을 지웠다. A 는 7번 중 3번, B 는 7번 중 3번, P 는 14번 중 5번, E 는 14번 중 1번, GLM 기준선은 7번 중 2번이다.
- 묶음 31개는 Keeper 넷에서 나왔다. `docs-gardener` 6개, `infra-cost-watch` 10개, `qa-coordinator` 7개, `support-triage` 8개다.
  쓸 날이 남은 기억이 든 묶음은 Keeper 마다 2, 2, 1, 4개다.
  F 가 지운 3번은 `docs-gardener` 의 묶음에서만 나왔다. Inkling 기준선이 지운 24번은 나머지 세 Keeper 의 묶음에서만 나왔다.
  다시 뽑기는 묶음끼리 독립이라고 본다. 같은 Keeper 의 묶음이 같이 움직이면 구간은 더 넓어야 한다.

### 흡수와 큰 답 (`time_screen.py`, `time_cluster.py`)

| 실행 | 흡수 | 3개 이상 묶은 claim 의 흡수 | case 가 없는 흡수 | 큰 답 | 큰 답의 흡수 |
| --- | --- | --- | --- | --- | --- |
| 기준선 1 | 52 | 18 | 0 | 1 | 10 |
| 기준선 2 | 37 | 3 | 0 | 1 | 11 |
| GLM 기준선 | 55 | 0 | 1 | 0 | 0 |
| P 1 | 280 | 104 | 0 | 11 | 198 |
| P 2 | 249 | 118 | 1 | 9 | 148 |
| A | 39 | 17 | 0 | 1 | 11 |
| B | 323 | 141 | 0 | 11 | 227 |
| F 1 | 36 | 9 | 0 | 0 | 0 |
| F 2 | 100 | 46 | 2 | 2 | 73 |
| E 1 | 307 | 157 | 1 | 8 | 217 |
| E 2 | 292 | 144 | 0 | 8 | 183 |

- 「3개 이상 묶은 claim 의 흡수」는 판정 case 가 있는 흡수만 센다. 심은 낡은 상태를 흡수한 것은 case 가 없어 빠진다.
- P 가 든 초안은 큰 답이 실행마다 8~11개다. 유효 답의 9~13% 다. 큰 답의 흡수는 그 실행의 흡수의 59~71% 다.
- 둘째와 셋째 열은 흡수 case 폴더의 `key.jsonl` 과 `judge/cases.jsonl` 을 읽는다. 판정은 읽지 않는다.
  위 판정 표에 없는 폴더는 아래와 같다. A, B, E 의 폴더는 case 만 만들고 판정하지 않았다.

| 흡수 case 폴더 | case | `key.jsonl` sha256 | `judge/cases.jsonl` sha256 |
| --- | --- | --- | --- |
| `rescore-a1/opus/base-glm-1-merges` | 48 | `36908324cfd5…` | `c6d86496a329…` |
| `xtA-inkling-merges-1` | 38 | `3cd5e3a63c57…` | `a3db2a51530f…` |
| `xtB-inkling-merges-1` | 319 | `6a9072edcb4b…` | `ab9e7f215c06…` |
| `xtE-inkling-merges-1` | 302 | `534d6bc669ea…` | `9165bf6541f5…` |
| `xtE-inkling-merges-2` | 290 | `2f18eaf1bc87…` | `f9c1d5b5878a…` |

판정을 받은 초안의 흡수를 큰 답과 나머지로 나눈 `absorb_precision` 이다.

| 초안 | 전체 | 큰 답 수 | 큰 답의 흡수 | 나머지 흡수 |
| --- | --- | --- | --- | --- |
| 기준선 (두 실행) | 56/89 | 2 | 15/21 | 41/68 |
| F (두 실행) | 64/136 | 2 | 23/73 | 41/63 |
| P (두 실행) | 242/529 | 20 | 133/346 | 109/183 |

- F 의 흡수 136개 중 65개가 기억 묶음 하나(`eval-infra-cost-watch-11`, 요청 3건)에서 나왔다. 그중 63개가 F 2 의 답 하나다.
  그 답의 요청은 기억 90개와 후보 1개를 실었다. 답은 기억 63개를 새 claim 23개로 묶었다. 판정자는 63개 중 19개를 `mergeable` 로 봤다.
- 그 묶음의 흡수는 F 가 19/65 다. 그 묶음을 빼면 F 는 45/71 이다. 기준선은 그 묶음에서 하나도 흡수하지 않았다.
- 같은 요청에서 다른 실행이 흡수한 수: 기준선 0·0, GLM 기준선 1, A 0, F 1 은 0, P 5·15, B 2, E 45·8.
  큰 수(63, 45)는 S 가 든 실행에서만 나왔다. 요청 하나의 수다.
- B 와 E 의 흡수는 판정하지 않았다.

### E-real (F 한 번)

| 실행 | 템플릿 | 유효 답 | `new_claim_without_support` | 다른 무효 |
| --- | --- | --- | --- | --- |
| 기준선 Inkling 1 | `575a6849…` | 44/50 | 0 | 6 |
| 기준선 Inkling 2 | `575a6849…` | 46/50 | 0 | 4 |
| P Inkling 1 | `f1642c8f…` | 46/50 | 0 | 4 |
| P Inkling 2 | `f1642c8f…` | 46/50 | 2 | 2 |
| F Inkling | `b4d5efb1…` | 39/47 | 4 | 4 |

- F 의 무효 8건: `new_claim_without_support` 4, `no_answer` 2, `memory_claim_absent` 1, `evidence_not_in_input` 1.
- 유효 답 39/47 대 기준선 90/100 은 이항 σ 로 −1.2σ 다. 묻지 못한 3건을 무효로 세면 39/50 이고 −2.0σ 다.
- `new_claim_without_support` 4/47 대 기준선 0/100 은 +3.0σ 다. 한 실행의 결과를 본 뒤에 고른 비교다.
- 그 4건은 모두 후보가 하나인 요청이다. F 가 물은 47건 중 39건이 후보가 하나다.
- 4건 중 3건은 다른 실행에서도 `new_claim_without_support` 무효가 난 요청이다.
  그 실행은 P Inkling 2, GLM 기준선, 빈 입력 칸을 뺀 초안(#52347)의 Inkling 2 와 GLM 이다.
  Inkling 기준선에서는 그 3건 중 2건이 한 번씩 `memory_claim_absent` 로 무효였다.
- 라이브가 남긴 기억을 지운 수는 1개다. 기준선 두 실행은 3개와 1개다. 수가 작아 차이를 말할 수 없다.
- E-real 아홉 실행에서 유효한 답 하나가 뺀 기억은 4개 이하다. 큰 답은 없다.
  아홉 실행은 기준선(Inkling 2, GLM 1), 빈 입력 칸을 뺀 초안(#52347, Inkling 2, GLM 1), P(Inkling 2), F(Inkling 1)다.
- E-real 의 수는 실행의 `rows.jsonl` 에서 셌다. 이 폴더의 스크립트는 E-real 을 읽지 않는다.

### 무효 답 (E-synth 의 Inkling 열 실행)

| 종류 | 수 |
| --- | --- |
| `memory_claim_absent` | 26 |
| `missing_required_key` | 3 |
| `duplicate_member` | 2 |
| `invalid_json` | 2 |
| `no_answer` | 2 |
| `claim_board_invalid` | 1 |
| `new_claim_without_support` | 1 |

무효 답은 900건 중 37건이다. 답마다 종류는 하나였다. GLM 기준선 실행은 8건이다(`no_answer` 7, `memory_claim_absent` 1).

`memory_claim_absent` 는 후보 판정이 가리킨 `memory_claim` 이 최종 기억의 claim 과 글자까지 같지 않을 때 난다.
26건에서 최종 기억에 없는 글을 가리킨 후보 판정은 27개다(`time_absent.py`).

| 후보 판정 | 가리킨 글 | 수 |
| --- | --- | --- |
| `already_represented` | 답이 남긴 입력 기억과 가깝다 | 18 |
| `already_represented` | 가까운 최종 claim 이 없다 | 3 |
| `already_represented` | 답이 지운 입력 기억의 글이다 | 1 |
| `incorporated` | 가까운 최종 claim 이 없다 | 3 |
| `incorporated` | 답이 쓴 새 claim 과 가깝다 | 1 |
| `incorporated` | 후보의 글 그대로다 | 1 |

- 「가깝다」는 `difflib.SequenceMatcher` 의 ratio 가 0.9 이상이라는 뜻이다. 27개의 ratio 는 0.07~0.53 이 7개, 0.89 가 1개, 0.99 이상이 19개다.
- 가까운 19개는 가장 가까운 최종 claim 과 1~19자가 다르다.

## 재지 않은 것

- 초안은 Inkling 에서만 쟀다. GLM 은 기준선 한 실행의 수만 있다.
- B 와 E 의 흡수는 판정하지 않았다. E-real 은 F 만 한 번 돌렸고 3건이 남았다.
- 초안은 고정 템플릿 `575a6849…` 위에 만들었다. 빈 입력 칸을 뺀 템플릿(#52348) 위에서는 재지 않았다.
- 같은 E-synth 90건에서 S 의 글을 고쳤고 같은 90건으로 쟀다. 둘째 실행도 같은 요청을 다시 물은 것이다.
- S 는 E-synth 가 심은 기억과 같은 종류를 말한다. 쓸 날을 다르게 적은 기억에 듣는지는 재지 않았다.
- 판정 시각 없이 S 의 첫 문장만 넣은 초안은 재지 않았다.
- `pass_time` 은 하네스 사본이 그린 값이다. MASC 는 아직 그 변수를 그리지 않는다.
- 실행 폴더와 판정 폴더는 한 대의 디스크에만 있다. 저장소에는 스크립트 출력(`outputs.jsonl`)만 있다.
