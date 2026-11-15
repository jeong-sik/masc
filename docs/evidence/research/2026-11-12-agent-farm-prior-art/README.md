# 에이전트 Farm 선행 사례의 출처 확인 · 2026-11-12

[선행 사례 조사](../../../research/2026-11-12-agent-farm-prior-art.md)와 [에이전트 Farm 계획](../../../reports/2026-11-12-agent-farm-plan.md)이 인용한 외부 근거가 여기서 나왔다.

## 출처와 환경

- 조사는 2026-11-12 19:20~22:26 KST 에 돌았다. 웹 문서·논문·저장소는 그 시각에 열어 본 판이다.
- 주제는 12개다. 주제마다 agent 둘이 돌았다. 조사 agent 가 주장과 출처를 적는다. 확인 agent 가 출처를 다시 열어 주장마다 판정한다.
- MASC 쪽 좌표(`apply` 칸)는 조사할 때의 `main` 에서 읽었다. 감사 묶음과 같은 시간대다.

## 파일

| 파일 | 주제 |
| --- | --- |
| `karpathy.digest.json` | Andrej Karpathy 의 글·발표에서 에이전트 시스템 설계에 닿는 주장 |
| `multi-agent-orchestration.digest.json` | 여러 agent 의 조정 구조, 실패 분류, 프로토콜 |
| `memory-graph.digest.json` | 에이전트 기억과 지식 그래프 |
| `ocaml-oxcaml.digest.json` | OCaml 대규모 코드베이스 실무와 OxCaml |
| `sandbox-microvm-ssh.digest.json` | microVM, RemoteSSH, 한 기기 여러 사용자 |
| `agent-economy.digest.json` | 에이전트 경제와 mechanism design, 게임 경제 설계 |
| `observability-self-improvement.digest.json` | 사용량 관측과 스스로 나아지는 고리 |
| `system12-hooks-proactive.digest.json` | System-One·System-Two, hook 과 판정, proactive 와 주의력 |
| `tui-music.digest.json` | TUI 조작 문법과 터미널 음악 도구 |
| `product-prior-art.digest.json` | 당대 에이전트 제품의 강점과 약점 |
| `storage-sync.digest.json` | 에이전트 상태 저장: 파일 I/O, 잠금, 백업, 동기화 |
| `portability-text-multimodal.digest.json` | 세계관·설정의 이식 형식, 글의 외부화, MultiModal 외부 해석 |
| `counts.py` | 위 파일에서 판정 수를 다시 센다 |

## 칸의 뜻

- `findings`: 주장 하나마다 `claim`, `src`(출처와 주소), `depth`, `kind`, `apply`(MASC 에 붙일 자리), `caveat`, `check` 가 있다.
- `depth` 는 출처를 어디까지 읽었는지다. 전문 54건, 일부 112건, 초록만 2건이다.
- `kind` 는 주장의 성격이다. 문서에 적힌 동작 76건, 측정 57건, 경험담 21건, 의견 10건, 증명 4건이다.
- `check` 는 확인 agent 의 판정과 이유다. `verified` 는 원문과 맞는다. `overstated` 는 원문보다 세게 말했다. `misquoted` 는 원문 문장과 다르다. `outdated` 는 더 새 판이 있다.
- `not_applicable` 은 받지 않은 생각과 그 이유다. `unknowns` 는 확인하지 못한 것이다. `conflicts_with_brief` 는 사용자 결정이나 헌법과 부딪히는 것이다.

## 명령

```sh
python3 counts.py .
```

주장 168건 가운데 원문과 맞음 136건, 세게 말함 26건, 잘못 인용 5건, 옛 버전 1건이다. 받지 않은 생각은 177건, 확인하지 못한 것은 170건, 사용자 결정과 부딪히는 것은 26건이다. [조사 문서](../../../research/2026-11-12-agent-farm-prior-art.md)는 `verified` 가 아닌 주장 32건을 모두 원문에 맞게 고쳐 썼다. 뺀 주장은 없다. 원래 문장이 무엇을 틀렸는지는 표 아래 「고친 것」 에 있다.

## 가린 것

- 이 묶음은 원본의 파생본이다. 조사 보고서 원문과 확인 보고서 원문은 길어서 넣지 않았다. 원본은 이 저장소에 없고, sha256 은 [감사 근거 README](../../2026-11-12-agent-farm-plan/README.md)에 있다.
- 경로는 감사 묶음과 같은 규칙으로 일반화했다.
- `agent-economy.digest.json` 에서 MASC 의 Candle 지급 경로, Candle 코드 좌표, Candle 설계 문서 위치를 적은 문장 24곳은 종류만 남기고 고쳐 썼다. Keeper 는 Candle 지급 규칙을 모른다(운영자 결정 10). 이 저장소의 PR 은 Keeper 가 읽는다. 고친 칸은 `apply`, `not_applicable`, `unknowns`, `conflicts_with_brief` 다. 외부 자료를 적은 `claim`, `src`, `caveat`, `check` 는 그대로다. 이 문장들의 원문은 나중에도 싣지 않는다.
- `karpathy.digest.json` 의 문장 3곳도 같은 이유로 고쳐 썼다.
- `sandbox-microvm-ssh.digest.json` 의 문장 8곳, `multi-agent-orchestration.digest.json` 의 문장 3곳, `product-prior-art.digest.json` 의 문장 1곳은 아직 고치지 않은 접근 경계 문제의 좌표나 세부를 적어서 종류만 남겼다. 수리가 `main` 에 들어간 뒤 세부를 싣는다.
- `multi-agent-orchestration.digest.json` 의 문장 1곳은 조사 세션의 사정을 적어서 그 부분을 뺐다.
- 고쳐 쓴 수는 이 묶음을 만든 스크립트가 센 값이고, 이 묶음만으로는 다시 셀 수 없다. 가린 이유는 [감사 근거 README](../../2026-11-12-agent-farm-plan/README.md)의 「가린 것」 과 같다.

## 검증하지 않은 것

- 측정 주장은 출처가 적은 조건의 값이다. MASC 에서 다시 재지 않았다.
- 확인 agent 도 출처 전문을 다 읽지 못한 경우가 있다. 그 경우는 `depth` 가 `partial` 이거나 `abstract_only` 다.
