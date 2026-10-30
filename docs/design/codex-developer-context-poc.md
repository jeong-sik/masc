# Codex developer context 배치 PoC

## 구현 범위

`Runtime_codex_app_server.run_turn`에 명시적 `developer_context:string list` 입력을 추가한다. 기본은 빈 목록이다. 기존 Keeper는 이 값을 전달하지 않으므로 운영 프롬프트의 역할·본문·전달 경로가 바뀌지 않는다.

- Start: 기존 history 뒤에 developer context를 추가한다.
- Resume: 기존 history는 재주입하지 않고 전달받은 developer context만 추가한다.
- native `thread/inject_items`를 사용하고, `role=developer`, `content.type=input_text`로 직렬화한다.
- `developerInstructions`를 다시 쓰거나 User 입력으로 강등하지 않는다.
- inject 응답이 실패하면 turn/start로 넘어가지 않는다.

이는 **지속되는 이력 추가** API다. 턴이 끝나면 사라지는 문맥도, 이전 snapshot을 교체하는 API도 아니다. 과거 문맥이 계속 쌓이면 input 총량이 증가할 수 있다. 캐시 이득을 실측하기 전에는 Keeper 기본 경로에 연결하지 않는다.

## 결정론과 SSOT

분류 모델·keyword·regex·score threshold를 추가하지 않는다. 호출자가 전달할 developer context를 명시하고 어댑터는 프로토콜 변환만 수행한다. protocol method/role의 정확한 wire spelling과 fixture의 기대값 비교는 자연어 내용으로 정책을 추정하는 휴리스틱이 아니다.

기존 `extra_system_context`의 typed provenance는 출처이지 권한을 낮춰도 된다는 증명이 아니다. 그 본문에는 동적 사실뿐 아니라 turn instructions와 operator note도 포함된다. 따라서 이 필드를 자동으로 옮기지 않는다. prompt registry·keeper.instructions·Memory OS·operator note의 원천과 조립은 그대로 유지하며 복제 정책·새 환경변수·설정 knob를 만들지 않는다.

## 검증 코드

`test_runtime_codex_app_server.ml`의 fixture는 Start/Resume 각각에서 고정 지시, developer role, context 원문, history 재주입 여부, 사용자 prompt를 확인한다. 기존 history-only 동작도 유지된다.

같은 파일의 `developer context placement comparison (10 turns per arm)` live 실험은 기존 `MASC_CODEX_APP_SERVER_LIVE` opt-in을 따른다. 두 독립 thread에서:

1. Rewrite arm: 고정 지시 + 최신 fact를 developerInstructions로 전달한다.
2. Append arm: 고정 지시를 유지하고 최신 fact를 developer item으로 추가한다.
3. 각 arm은 10턴을 실행하며 최신 marker를 정확히 답하는지 확인한다.
4. 두 arm 전체의 실제 model ID가 같은지 검사하고 매 턴 input/cache read/output/reasoning usage, thread/turn ID를 JSON으로 출력한다. 미보고 usage는 null이다.

이 synthetic smoke는 role/연속성 확인용이며 48KB Memory recall이나 70KB schema를 재현하는 benchmark가 아니다. 실행 순서·provider 캐시 온도·작업 크기의 효과를 통제한 반복 A/B는 별도로 필요하다. token 감소를 테스트의 고정 기대값으로 두지 않는다.

## 주입과 재시도

inject가 성공한 뒤 turn/start가 실패하면 developer item은 이미 thread에 남는다. 현재 이 추가 API에는 독립적인 주입 receipt나 idempotency key가 없다. 자동 재주입은 중복을 만들 수 있다. production 연결 전에는 동일 thread의 주입·turn dispatch·실패 복구를 durable하게 연결하고, snapshot 변경/무효화/compaction 이후 의미를 검증해야 한다. 이 PoC는 해당 문제를 해결했다고 주장하지 않는다.

## 근거와 현재 상태

- [OpenAI app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md): thread/inject_items는 raw Responses items를 loaded thread의 모델 가시 이력에 추가하며 별도의 user turn을 시작하지 않는다. 항목은 rollout에 보존된다.
- 로컬 읽기 전용 확인: `codex --version` → `codex-cli 0.153.4` (2026-09-09). 버전 조회 중 PATH alias 생성 권한 경고는 있었으며 설치 변경은 수행하지 않았다. 이는 API 호출 성공 증거가 아니다.
- 소스 리뷰 완료. fixture/live test, 빌드, 설치, 실제 token 절감 실측, 브라우저 검증은 미실행이다.
- Claude Code는 같은 권한을 유지하는 경로를 별도 검증해야 한다. 이 변경을 provider 공통 최적화라고 간주하지 않는다.
