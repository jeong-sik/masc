---
status: audit
---

# 2026-09-12~19 생명주기 감사

## 공통 헤더

- 날짜(ISO8601): 2026-09-19T08:54:32Z
- 작성자: Codex
- 결정 ID: masc-weekly-lifecycle-20260919
- 적용 대상: MASC 소스, 해당 배포의 `.masc`, TUI, Terminal-Bench 어댑터
- 결정 상태: 추적 필요
- Delta: 최근 변경을 현재 실행 경로와 대조해 작은 수정 PR들과 운영 설정 회귀를 찾았다. 전체 기능과 벤치마크의 완료 증명은 아직 없다.

## 근거 (Evidence)

- 항목: 날짜별 변경과 현재 실행 경로의 연결
- 출처: 아래 Git 구간, PR·이슈, `GET /health?full=1`, 저장소의 실제 producer/store/consumer
- 확인일시: 2026-09-19T08:54:32Z
- 신뢰도: High — 커밋·응답·재현 결과. 전 기능의 정상 동작으로 일반화하지 않는다.
- 제한조건: 최초 감사의 기준 커밋은 `2ebdcccfa264078e4f7f2e54b7d98e5b9e16f467`이다. 동시 작업으로 main이 이동하므로 아래 스냅샷을 고정한다. 9/12~18의 일곱 완결된 날짜와 9/19 당시 코드를 비교했다.

### 날짜별 구간

각 날짜의 KST 자정 직전 first-parent 커밋을 경계로 잡았다. 단순 `%cs` 집계는 UTC와 KST 작성 커밋을 섞으므로 사용하지 않았다. 시작은 `c99919fb7d5386197be80818d256377e70173534`이다.

| 날짜(KST) | 끝 커밋 | first-parent 변경 수 | 변경 흐름의 중심 |
|---|---|---:|---|
| 9/12 | `f3b3705214331a0ff4cf23e47cc92cd9a1b940a8` | 141 | runtime 로드 실패의 타입화, yielded tool과 stall 구분, Schedule 기록 도구와 관측 표면 |
| 9/13 | `de1a9c73468f0dadc6429de4040918562d2e3414` | 323 | official-client failover/continuation, Lane 편집, Goal 행동 키의 phase 연결, Board/Fusion 입력 검증 |
| 9/14 | `20cc8a689c7b7de154b169ead89e1661719b2b39` | 299 | first-token/admission/watchdog 경계, Goal store unavailable 전파, Schedule 자체 clock, TUI 표시 수정 |
| 9/15 | `72683cf4e8fa526804889deaba325f5a68f4249d` | 294 | 경로별 rate-limit 관측과 전송창, memory write 뒤 턴 연속성, Board paging, Task unroutable 처리 |
| 9/16 | `7dcc9f72c6e2331f8fd4cbc27bba27dee42a2110` | 75 | binding별 전송창과 carried blocks, 로컬 body cap 제거, checkpoint·memory·schedule 쓰기 비용 축소 |
| 9/17 | `9505be4f3dbfb370baa67064065f11bede6088fb` | 62 | Lane 선언 순서와 실패 후보 이동, history에 속한 front, composition의 실제 tool surface 확인, TB 4.0 어댑터 |
| 9/18 | `45b4db68a94fcd93a0762070f498873f1ea81e6c` | 46 | front digest·후보 간 공유·중단된 생성 잇기, 흡수 원문 보존과 검색, exact deadline admission |
| 9/19 당시 | `2ebdcccfa264078e4f7f2e54b7d98e5b9e16f467` | 8 | History restart/boundary/read-position, 카탈로그 통합과 overlay 제거 |

총 1,248 first-parent 변경, 두 끝점 사이 4,255개 파일이다. 이 수는 검토를 완료한 파일 수가 아니다. 재현 가능한 구간 비교:

```sh
git log --first-parent --reverse --format='%H %cI %s' <base>..<head>
git diff --stat <base> <head>
git diff <base> <head> -- lib/keeper lib/runtime lib/runtime_model docs/spec
```

9/19의 이후 main `8021c64ac303bdc8e7f3ac815f29b6ce38e1912f`에는 #37031의 Librarian 범위 선택 순수 함수가 추가됐다. 함수가 존재한다는 사실과 런타임에서 읽은 위치를 전진시키는 사실은 별도로 확인해야 한다.

### 소유권과 시간 순서

| 경계 | 사실을 소유하는 곳 | 다음 회차에 보존해야 할 것 | 이번 확인 범위 |
|---|---|---|---|
| Runtime Attempt → 다음 후보 | 실제 요청 범위와 후보별 provider usage | 거절 후 좁힌 History가 후보를 바꿔 다시 넓어지지 않음 | #37073 재현·수정, CI 추적 |
| Keeper Turn → 다음 Turn | checkpoint와 turn boundary | message/tool-result Atom 경계, trace와 digest의 일치 | 읽기 실패 수정 #37089; clear 경합은 #37021 잔여 |
| History → Librarian | History/boundary와 read position | 읽지 않은 구간 보존, 실패를 읽기 성공으로 처리하지 않음 | #37031 및 #37061 추적; 완결된 runtime loop 증거 없음 |
| Librarian → Memory | current snapshot의 잠금된 disposition 적용 | 동시 explicit write 보존, 흡수 원문 기록 실패 시 commit 거절 | 소스 대조, 문서의 옛 retain/CAS 계약 정정 |
| Memory → Recall | current facts, absorbed archive | current premise와 archived provenance 구분 | search schema와 writer 대조; 반복 재주입 억제 실측 미완료 |
| Memory/행동 → Skill | Skill 문서·composition과 실행 evidence | 반복한 문장을 검증된 절차로 오인하지 않음 | composition 노드 도구 가용성 #36930 확인; 자동 action absorption은 #36925 제안 |
| Goal → 사람의 확인 | Goal criterion와 verifier binding | 읽은 request/run에 대한 확인만 commit | #37076 TUI 연결; 기존 설치본 PTY에서 부재 재현 |
| Task ↔ Goal | Task 소유권과 Goal 참조 | goalless Task 허용, 증거가 다음 행동을 강제하지 않음 | 변화·관련 경로 대조; 전 상태 조합 미검증 |
| Board → Keeper | Board 원문과 attention candidate | 대화를 지시·승인으로 승격하지 않음 | 변화·기존 이슈 대조; 전체 가시성/권한 조합 미검증 |
| Schedule → Keeper | Schedule signal과 Keeper queue | wake가 외부 효과를 승인하지 않음 | runner 관측; seen-key 보존/CI는 #36859 추적 |
| HITL/Access → 효과 | 기존 인증·승인·effect receipt | TUI 편의가 CanAdmin 또는 정확한 승인 binding을 우회하지 않음 | Goal 확인 API 재사용 확인; 전체 효과 재실행 검증 미완료 |

한 Tick의 성공이 N Tick의 닫힌 순환을 증명하지 않는다. 특히 checkpoint 읽기 실패, `clear`와 진행 중인 턴, Librarian commit 실패 후 read position, provider 변경 뒤 전송창, 흡수 archive 뒤 snapshot 실패는 서로 다른 중단 지점이다. 관측 표면을 별도 행동 제어 장치로 저장하지 않는다.

### 실제 발견과 작업 단위

- [#37070](https://github.com/jeong-sik/masc/pull/37070): Librarian API 후보가 모두 projection에서 거절되면 declared CLI를 시도하지 않던 분기. 동일 domain validation을 거친 CLI 답만 받도록 연결했다. exact deadline 설정 문제까지 이 패치가 해결한다고 주장하지 않는다.
- [#37073](https://github.com/jeong-sik/masc/pull/37073): 원장이 있는 후보의 overflow 축소가 다음 warm/cold 후보로 전달되지 않던 경로. halving·block eviction·오래된 원장 범위를 한 불변식으로 수정했다.
- [#37076](https://github.com/jeong-sik/masc/pull/37076): TUI에서 검증된 Goal의 최종 확인을 보낼 수 없던 연결. 먼저 exact proof를 읽고 같은 binding을 기존 admin API로 확인한다. 이 누락은 9/10에 도입되어 이번 주에도 남아 있던 happy-path gap이다.
- [#37077](https://github.com/jeong-sik/masc/pull/37077): Harbor의 per-agent key를 무시하고 host key만 읽던 설치 경로. 세 어댑터 × 두 환경 조합을 재현하고 Harbor resolver를 사용했다.
- [#37089](https://github.com/jeong-sik/masc/pull/37089): checkpoint 읽기 실패를 빈 Context로 바꾸던 경로. 실패 원인을 보존해 턴 시작 전에 반환하고, 파일 없음·명시적 버전 교체·승인된 continuation을 구분한다. 다음 Tick에서 원래 이력을 다시 읽는 회귀를 포함한다.
- [#37090](https://github.com/jeong-sik/masc/pull/37090): 병렬 호출을 끈 벤치 arm의 설정이 catalog 모델에 적용되지 않던 경로. 모델의 능력과 binding의 요청 정책을 분리해 실제 serializer까지 전달한다. 전달할 수 없는 runtime은 거절한다. arm 사이에는 spawn·concurrency 차이도 있으므로 단일 변수 실험이라고 해석하지 않는다.
- [#37074](https://github.com/jeong-sik/masc/issues/37074): overlay 제거 뒤 live `deepseek-v4.1-flash:cloud`가 exact catalog lookup에서 제외됨. 공식 `/api/tags`는 `deepseek-v4.1-flash`를 반환했다. 08:57Z 기존 admin 설정 API로 해당 `api-name` 한 줄을 교정하고 reload했다. Librarian/HITL/Board 슬롯 복귀는 확인했으나, 후속 Librarian 종단 4건은 provider rate limit으로 실패했다. 설정 복구와 실제 기억 생산 성공은 다르다.
- 기존 [#37063](https://github.com/jeong-sik/masc/pull/37063), #37064, #37066, #37069는 각각 Claude overflow와 Lane 밖 후보 선택을 다룬다. 중복 PR을 만들지 않고 검토 대상으로 유지했다.

### 런타임 관측

배포의 `connection.toml`이 선언한 포트는 **55594**다. 8935 연결 실패는 이 서버의 장애 증거가 아니었다. `/health?full=1`은 base path와 `.masc` root, 실행 커밋 `2ebdcccfa2…`, executable SHA-256 `51d8cd1f5df85cb00c8ba0d58d8e154bce373f41b9754b52c3790a54c33ac413`를 반환했다.

08:36Z 표본: bootable 17, running 8, recovering 9, overall degraded. 오늘 로그의 08:42Z까지 표본에서 cycle FAILED는 10 Keeper에 426줄이었다. 마지막 실패들에는 Claude `blocking_limit`, Antigravity의 cleared trajectory, Kimi/Ollama 사용량 제한이 섞여 있다. 이 로그 수는 고유 incident 수나 패치의 효과 측정이 아니다. 08:54Z 응답은 `warming`이며 세부 fleet 값이 없어서 회복으로 해석하지 않았다.

기존 Keeper `critic`에게 관측을 요청했고 operation `kmsg-b29e444510413e5e89a94b11859f6edb`는 Succeeded, turn `trace-1788609342544-00000#2964`로 응답했다. 반복 기록·Memory Recall 재주입·Fusion 실패라는 제보는 후속 조사 입력이다. Keeper의 설명만으로 원인 관계를 확정하지 않았다.

10:43Z 추가 확인: `.masc/exact-lane-runs-v6.jsonl`의 register/complete를 ID로 결합했다. Librarian 완료 2,102건 중 성공 701건이고, 실패 detail에 `wire_admission_rejected:missing_deadline`이 기록된 것은 1,288건이다. 해당 실패의 시작 시각은 9/18 06:17:01~9/19 08:57:44 UTC에 걸친다. reload 완료 응답(08:57:55.759Z) 이후 시작하고 완료한 26건은 성공 11, 실패 15였다. 성공 슬롯은 모두 `glm-coding.glm-5.3-flash`이며, 실패 중 HTTP 429는 13건, domain validation은 1건, missing_deadline은 0건이다. 초기 네 실패 표본만으로 기억 생산이 계속 멈췄다고 판단할 수 없다. exact execution 성공과 Memory snapshot·read position의 commit 완료도 구별해야 한다. 원본 집계 조건과 결과는 `/tmp/masc-week-audit/librarian-after-reload-counts.json`에 보관했다.

### Memory에서 Skill까지의 구현 경계

main `e50d28963b`의 실제 event producer를 확인했다. `Retrieved`는 검색, `Cited`는 성공한 Memory 철회, `Revised`는 Librarian commit에서 나온다. 특히 `Cited`를 좋은 기억의 강화 횟수로 읽으면 의미가 뒤집힌다. RFC-0418은 이 관측을 recall·소거·Librarian 판단에 넣지 않는다고 명시한다. 날짜·출처·관측 이력을 입력에 싣는 RFC-0456은 후속 제안이며 현재 renderer가 구현했다고 볼 수 없다.

현재 Skill 경로는 admin editor의 발행 → frozen instruction 읽기·activation 또는 composition 실행·evidence다. `keeper_skill_publish`, `keeper_compose_save`, 자동 분석·합성·sandbox 검증·발행 순환은 현재 handler가 없는 제안(#32369, #36925)이다. PR #36925의 Draft 정책 숫자나 옛 `dropped`/`supersedes` 흡수 설명을 현재 계약으로 옮기지 않는다. 흡수의 의미 손실과 원문 재검색은 기존 #37079에서 추적하며, 이번 감사가 그 이슈의 품질 측정을 재현한 것은 아니다.

### 벤치마크 현재성

[공식 실행 안내](https://www.tbench.ai/run)는 `terminal-bench/terminal-bench@4.0.0`, GPU sandbox와 `-k 5`를 제시한다. [공식 목록](https://www.tbench.ai/benchmarks)은 4.0 공개일을 2026-08-28로, Science 0.1을 2026-08-27로 적는다. [Harbor 환경 문서](https://docs.harborframework.com/core-concepts/jobs/environment-variables)는 `--agent-env`가 host credential보다 우선한다고 명시한다. 확인: 2026-09-19, 신뢰도 High.

현재 이 호스트의 `docker info`는 4 CPU, 16,748,879,872 bytes 메모리다. 저장소의 4.0 전체 실행 조건을 충족하지 못한다. 설치된 전역 Harbor는 0.22.0, 저장소 pin은 0.23.0이므로 재현은 별도 0.23.0 환경에서 했다. 기존 bench `dist/.version`은 0.35.12로 현재 floor 0.35.20보다 낮다. 읽어 본 `results/jobs`의 trial result 24개는 2.0 데이터셋을 가리켰다. 이를 4.0 결과로 재사용할 수 없다.

전체 4.0 실행에는 GPU를 포함한 적합한 환경, 일치하는 릴리스와 어댑터, task가 선언한 MCP/Skills 연결(#36908), 원본 verifier 결과가 필요하다. 작은 설치 테스트 통과, 내부 fixture 점수, 일부 task의 성공을 전체 벤치 통과로 부르지 않는다.

추가 검증에서는 0.35.20 릴리스 두 아키텍처를 내려받고 4.0 task 66개의 자원 선언을 읽었다. 이 Docker보다 큰 CPU/메모리를 요구하는 task 10개와 GPU task 3개가 있다. 전체 실행은 코드 검증 후 사용자가 Runpod에서 진행할 예정이다. 현재 호스트의 `openrouter.z-ai/glm-5.3-flash` 단일 Keeper 점검은 public MCP 제출 → `Execute ["touch", "/tmp/arm-k-keeper-was-here"]` → `remote_ssh`, `sandbox_applied`, exit 0과 파일 생성을 확인했다. 이는 도구 연결 증거이며 벤치 점수 또는 여러 Tick의 연속성 증거가 아니다. 기본 Anthropic arm의 provider/model 계약 해상 실패는 #37086으로 별도 기록했다.

## 검증 (Verification)

- 1차: Git 날짜별 고정 구간과 producer → store → consumer 코드를 대조했다.
- 2차: 실제 포트의 health, Keeper MCP 상태, exact lane 기록, pinned Harbor 구현과 공식 문서를 읽었다.
- 3차: Harbor 인증 6개 실패 재현 뒤 관련 67개 테스트 통과. GitHub의 #37077 `pytest`도 success. TUI 설치본은 새 확인 키를 찾지 못하는 PTY 실패를 재현했다. OCaml candidate는 로컬 빌드 없이 PR CI로 검증 중이다.
- 재현 결과: 여러 개의 좁은 수정 PR과 live catalog mismatch를 확인했다. 모든 PR이 통과·병합·배포됐다는 뜻은 아니다. 각 PR의 현재 head/check/review가 마무리 판정의 근거다.

## 불확실성 (Uncertainty)

- 미확인 항목: 모든 Runtime의 장기 N Tick 연속성, context reset의 전체 실패 조합, 자동 Skill 합성의 실제 완료, Board/Task/Access 전 조합, Terminal-Bench 4.0 전체 실행.
- 영향: 이번의 수정 몇 개로 전체 하네스의 올바름이나 점수를 주장할 수 없다.
- 추가 확인 필요: 각 수정의 exact-head CI와 리뷰 처리 → 병합 → 실행 바이너리 확인 → 해당 경로의 실제 turn/화면 증거. 다음 코드 우선순위는 #37021·#37029·#37061 및 반복되는 live 오류다. 희귀한 추측 분기보다 현재 반복 실패를 먼저 본다.
- 정적 검사 잔여: Harbor sidecar의 기존 Pyright 문제는 [#37078](https://github.com/jeong-sik/masc/issues/37078)에 재현 조건과 함께 남겼다.

## 적용범위 (Scope)

- 영향 받는 영역: Runtime/Keeper/Librarian/Memory/Goal TUI/benchmark 설치와 해당 문서.
- 제약/배제: paused Keeper 재가동, queue 삭제, 모델·quota 임의 교체, 자동 전 기능 성공 선언은 수행하지 않는다.
- 롤백 조건: 특정 수정이 현재 계약과 모순되거나 해당 경로를 회귀시키면 그 작은 PR 단위로 수정한다. 다른 작업의 변경을 덮어쓰지 않는다.
