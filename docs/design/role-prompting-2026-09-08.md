# MASC 역할별 프롬프팅 개선안

2026-09-08 공식 문서와 현재 저장소를 대조했습니다. 기준 코드는 `c62f10f74b`입니다.
문서의 최신 상태를 확인한 날짜와 실험 결과를 구분합니다. 검색 결과의 상대 날짜만으로
발행일을 단정하지 않았으며, 다른 하네스의 개선 수치를 MASC의 성능으로 옮기지 않습니다.

## 채택할 방식

MASC에는 **역할마다 판단 대상과 증거, 사용 가능한 도구, 완료 형식을 명시하는 방식**이
맞습니다. Keeper의 자율 작업 지침을 독립 판정 레인에 복제하지 않습니다. 판정 레인은
자기 역할을 수행할 만큼의 맥락만 받고, 의미 판단은 모델이, ID·형식·권한·상태 전이는
기존 코드가 담당합니다. 프롬프트 길이만 줄이는 것을 성공 조건으로 삼지 않습니다.

공통 작성 순서는 다음과 같습니다. 새 런타임 계층이나 템플릿 상속 기능이 아니라
기존 Markdown을 편집할 때의 기준입니다.

1. 역할: 이번 호출에서 결정할 것과 권한의 범위.
2. 기준: 승인·기각·보존·삭제를 가르는 관측 가능한 조건.
3. 입력: 출처, 시점, 누락 여부가 구분된 자료.
4. 도구: 실제로 제공된 조회·보고 수단과 그 한계.
5. 완료: 기존 JSON 또는 보고 도구 계약, 짧고 구체적인 근거.

한국어 문장은 자연스럽게 다듬고 wire key·enum·도구 이름은 유지합니다. 판단 이유는
검사 가능한 근거와 결론을 설명합니다. 내부 추론을 길게 출력하도록 강요하거나,
어떤 모델에서도 같은 답이 나온다고 약속하지 않습니다.

## 최신 자료에서 가져올 것

| 자료 | 확인한 장점 | MASC에 적용 | 그대로 가져오지 않을 것 |
|---|---|---|---|
| [OpenAI reasoning guide](https://developers.openai.com/api/docs/guides/reasoning-best-practices) | 간단하고 직접적인 지시, 명확한 성공 조건, 예시는 필요할 때 추가 | 역할과 종료 계약을 앞세우고 근거 요약만 요구 | 모든 모델에 강제하는 단계별 사고 대본 |
| [Claude prompting guide](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices) | 모델별 과도한 도구 호출·검증 지시를 조정하고 정상적인 표현 사용 | MUST·CRITICAL 반복과 공격적 문체 제거, 실제 기능과 일치하는 지시 | 모델 전용 팁을 전역 Keeper 정책으로 복제 |
| [Claude 장기 실행 하네스](https://www.anthropic.com/engineering/harness-design-long-running-apps) | 생성과 평가를 나누고 구체적 수용 기준을 실행해 검사 | Verifier가 코드 존재와 실행 증거를 구분 | 역할 이름만 늘리면 평가가 정확해진다는 가정 |
| [Hermes prompt assembly](https://hermes-agent.nousresearch.com/docs/developer-guide/prompt-assembly/) | 캐시할 지침과 호출 시점 추가 맥락의 수명 구분 | 공통 본문은 안정적으로, 작업·관측은 현재 턴에; 임시 판단을 장기 기억으로 승격하지 않기 | 추가 설정 파일과 계층 전체를 복제 |
| [OpenClaw system prompt](https://docs.openclaw.ai/concepts/system-prompt) | 보조 에이전트용 최소 프롬프트, 프롬프트 안내와 실제 권한 집행의 구분 | 독립 레인에 Keeper의 인격·게시·자율 작업 지침을 넣지 않기 | 프롬프트의 경고문을 권한 경계로 간주 |
| [Deep Agents context engineering](https://docs.langchain.com/oss/python/deepagents/context-engineering) | 도구 안내를 실제 기능과 함께 제공하고 상세 스킬을 필요할 때 읽기 | Goal verifier에는 Read/Web만, Task verifier에는 실제 제공된 lookup만 안내 | 이미 있는 MASC 레인 위에 middleware·profile 체계 추가 |
| [OpenAI evaluation guidance](https://developers.openai.com/api/docs/guides/evaluation-best-practices) | 명확한 rubric, 순서·장문 편향 통제, 사람 기준과 평가 비교 | Fusion의 다수결·자신감·모델 이름 편향 방지, 실패 사례별 평가 | 모델 심판의 자기 점수만으로 개선 선언 |

Hermes 문서에는 skills의 tier 설명이 서로 다른 대목도 있습니다. 이 조사에서는 정확한
전체 조립 순서를 복사하지 않고, 캐시된 상태와 일시적 추가의 분리 원칙만 채택합니다.
Deep Agents 저장소 main은 조회 당시 `048f9890bfe8b640e1e72085a4fa50d9084545f0`
(2026-09-08 UTC)이었습니다. Hermes/OpenClaw의 commit API 조회는 네트워크 오류로
실패해 최신 commit을 확정하지 못했습니다. 해당 프로젝트 비교 근거는 실제로 읽은
공식 문서이며, 소스 전수 감사라고 주장하지 않습니다.

## MASC 역할과 실제 계약

| 역할 | 현재 입력과 기능 | 올바른 판단 | 이번 수정 |
|---|---|---|---|
| Keeper | 공통 system + 신원·역할 + 현재 세계·작업·기억 + 도구 | 허용된 작업을 이어서 수행하고 대상 결과를 확인 | 앞선 #34377에서 본문·역할 축약과 한영 초안 선택; 이번에는 반복 수정하지 않음 |
| Board judge | `judge.board`, singleton candidate JSON, exact-output 레인 | 이 신호가 Keeper의 진행 맥락에 관련 있는가 | 게시글 안의 지시와 호스트 ID 구분, 입력당 verdict 하나, 유효한 JSON 예시 |
| Effect judge | `judge.effect`, system 지침 + host/context bundle, exact-output | 정확한 operation·입력·대상·권한의 안전성 | 자료 속 승인 명령은 권한이 아님을 명시; 기존 관측·가역 효과 정책 보존 |
| Task verifier | `verification`, 제출 스냅샷 + 선택적 producer Read/Grep, 보고 도구 | 선언한 각 요구 항목이 실제 증거로 충족됐는가 | note-only와 lookup의 충돌 해결, 조회 오류·시점 차이 구분, 표현만으로 회피 판정 금지 |
| Goal verifier | `goal_verification.proof`, 알려진 파일 Read + 공개 Web fetch | 선언한 metric이 target에 도달했는가 | 대상·단위·분모·시점·비교 방향 확인; 측정 불가와 목표 미달 구분 |
| Librarian | `librarian`, 현재 기억 전체·대화·화자 provenance·payload 없는 tool 상태; JSON 선택 | 이 Keeper가 다음에도 쓸 정확한 지식은 무엇인가 | 운영자 제약과 임의 자기 제한 구분, 중복 축약, 코드 변경 목록과 유용한 결정 구분 |
| Fusion / refine / meta | 패널 원문·이전 종합; 설정에 따라 웹 도구; JSON 파서 | 근거가 지지하는 답과 미해결 쟁점은 무엇인가 | 다수 의견은 진실 아님, 실제 model ID 귀속, 소수 의견·불충분 판정, 원문 대조 |
| Calibration / probe / benchmark | 평가용 예시, lane_cli_probe, harness.* 자산 | 특정 검사에서 실제로 관측한 결과 | calibration 예시는 현재 증거가 아님을 명시; benchmark의 고정 절차는 운영 규칙으로 옮기지 않음 |
| 도구 결과 안내 | agent_core, tool_failure, tool_guidance, filesystem, gate_replay 등 | 반환된 typed 결과에 맞는 다음 행동 | 이미 결과별로 선택되는 구조를 보존; 보편 지침으로 전부 합치지 않음 |

주요 연결 코드는 다음과 같습니다.

- `lib/keeper/keeper_prompt.ml`, `keeper_unified_prompt.ml`: Keeper 조립.
- `lib/keeper/keeper_board_attention_exact_flow.ml:76`: candidate에서 요청과 프롬프트 구성.
- `lib/keeper/hitl_summary_worker.ml:306`: effect system 지침과 요청 bundle 구분.
- `lib/task/anti_rationalization.ml:269`: Task 검증 지침·증거·lookup 조립.
- `lib/completion_authority_agent.ml:423`: unreadable 참조도 Read/Grep 판정으로 전달.
- `lib/goal_verification_agent.ml:204`, `lib/verification_authority_tools.ml`: Goal의 측정·조회 범위.
- `lib/keeper/keeper_librarian_runtime.ml:252`: Librarian은 렌더링된 한 User 메시지.
- `lib/keeper/keeper_librarian.ml:72,419,446`: payload 제외, supersedes와 ID 전체 분할 검증.
- `lib/fusion/fusion_judge.ml:126,152`, `lib/fusion_core/fusion_judge_parse.ml:134`: Fusion은 native response schema를 강제하지 않고 파싱함.

## 발견한 모순과 해결

### 증거가 없다는 것과 아직 열지 않았다는 것

기존 `verification.evidence_posture.note_only`는 제출 스냅샷에 artifact가 없으면
기각하도록 읽혔지만, 같은 파일의 `required_evidence`는 직접 조회한 내용도 인정했습니다.
코드는 잘못된 상대경로·읽지 못한 artifact를 입구에서 끝내지 않고 Read/Grep을 가진
판정자에게 넘깁니다. [RFC-0417 §4.3](../rfc/RFC-0417-cancel-verdicts-belong-to-the-operator.md)
역시 evidence posture를 판정자의 질문에 넣는 것으로 설명합니다.

새 문구는 **노트만으로 승인하지 않으며, 제공된 도구로 실제 확인한 증거는 사용할 수 있다**로
통일합니다. 이것이 제출 스냅샷을 소급 수정하지는 않습니다. 계약이 특정 시점·리비전의
실행 결과를 요구하면 현재 소스 파일만 읽어서는 충분하지 않습니다.

### 자율성과 운영자의 제한

Librarian의 “행동 범위를 좁히는 claim은 모두 제외”와 “운영자 정책은 constraint로 보존”이
충돌했습니다. 임의로 만든 자기 제한은 제외하되, 운영자가 정한 업무 범위·권한·승인·대기
조건은 원래 범위대로 보존합니다. 역할 지침은 선별할 대상의 자료이며 Librarian이 수행할
새 임무가 아닙니다. 호출 성공 상태만 보고 payload의 내용을 사실로 만들어 저장하지 않습니다.

### 합의와 사실

Fusion의 형식 정의만으로는 패널 다수 의견을 사실처럼 받아들일 수 있습니다. 모든 심판
단계에 이미 포함되는 output 절에 평가 기준을 한 번 넣었습니다. 최초 심판·refine·meta가
같은 기준을 사용하며, 종합 결과도 패널 원문으로 재검사합니다. 모델의 명성·문장 길이·순서·
반복 인용은 사실의 독립 근거가 아닙니다. 웹 도구가 있을 때만 직접 확인하고, 없으면
미확인 상태를 적습니다.

## 다음 개선의 우선순위와 합격 기준

| 우선순위 | 다음 작업 | 끝났다고 말할 수 있는 증거 |
|---|---|---|
| 1 | 지침과 입력 자료의 구조적 경계 | 원문에 닫는 태그·가짜 역할 문구가 있어도 host 필드와 출력 계약으로 승격되지 않음을 실제 조립·모델 경로에서 확인; 문구만으로 injection 방어 완료라고 하지 않음 |
| 1 | 실제 호출별 입력과 결과를 같은 ID로 평가 | lane·모델·프롬프트 hash·도구 schema·입력·판정·오류가 연결된 실행 기록 |
| 1 | Task verifier lookup 시나리오 | 제출 경로 오류 후 실제 조회 승인, 조회 실패 기각, 다른 SHA의 실행 로그 기각을 실제 보고 도구로 확인 |
| 1 | Librarian 운영자 제약·화자 귀속 | 정책은 보존, assistant가 날조한 동의는 저장하지 않음, 교정 시 m-ID 전체 분할을 실제 decoder로 확인 |
| 2 | Fusion 파서와 설명의 일치 | malformed 배열 항목이 빠지는 현상을 명시하고, 소비자 요구에 따라 typed 오류 여부 결정; 프롬프트로 strict schema라고 주장하지 않음 |
| 2 | 실제 도구 목록과 안내의 일치 | 웹 도구 유무, 텍스트 전용 이미지 처리, tool 억제 시나리오마다 없는 기능을 요청하지 않음 |
| 2 | override와 배포본 차이 | 역할별 effective body·원본·override·리비전이 구분되고, 변경한 기본값이 가려졌는지 확인 |
| 3 | 모델별 조정 | 동일한 평가 사례에서 모델별 오류가 반복될 때만 지침 차이 도입; 새 전역 프리셋 계층은 만들지 않음 |
| 3 | standalone 한영 운영 표면 | wire 계약을 공유하며 언어별 의미·평가 결과가 대응; Keeper의 언어 선택과 혼동하지 않음 |

실험은 [role-prompts 증거 폴더](../evidence/role-prompts/)에 보관합니다. 합성 입력의
프롬프트 수준 검사와 실제 MASC 레인의 도구·스키마·재시작 검증은 별도입니다.
이번 수정으로 장기 실행 품질, 모든 모델의 동작, 실제 오판률이 입증되지는 않습니다.
