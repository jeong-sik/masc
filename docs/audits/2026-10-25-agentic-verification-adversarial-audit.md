# MASC 적대적 감사: 실제 결과와 성공 선언 사이

[원문](https://productmindset.substack.com/p/mental-models-in-the-agentic-era)의 관점 중 실제 해결된 결과, 지표 조작, 맥락과 검증의 책임을 MASC의 실행 증거에 적용했다. 아래 판정은 원문 주장의 요약이 아니라 저장소·통제 실험·실제 Keeper·대시보드에서 얻은 별도의 감사 결과다.

**가장 위험했던 것은 성공을 만드는 검사와 성공을 보고하는 경로가 오염될 수 있었다는 점이다.** 샌드박스 이름, Task Done, 관측값3/3 중 어느 하나도 전체 완료의 증명이 아니었다.

## 확인한 일곱 취약 지점과 수리 범위

| 항목 | 공격·실패 | 수리와 확인한 범위 |
| --- | --- | --- |
| A1 실행 경계 | Docker 안에서 작성한 후보를 채점할 때 호스트로 가져와 실행했다. | verify/regression/build를 지원하는 Docker 경계 안에서 동일 캡처 바이트로 실행. [실제 컨테이너 기록](../evidence/2026-10-24-coding-boundary/README.md). |
| A2 검사기 조작 | 구현을 고치지 않고 Node 검사기만 항상 성공하도록 바꿀 수 있었다. | check.sh와 check.js를 정본에서 복구. 망가진 구현을 그대로 둔 두 공격 모두 거절, 각 정답 대조군은 성공. |
| A3 증거 교체 | 저장된 이미지 identity와 전달하는 실제 바이트가 달라질 수 있었다. | 길이·해시·symlink 경계와 소비자의 typed mismatch 전달을 native에서 검사. [고정 사례 기록](../evidence/2026-10-24-goal-outcome-campaign/README.md). |
| A4 집계 오염 | 모델 별칭·run/cohort identity 충돌과 비용 미관측이 성공률·비용 해석을 왜곡했다. | 원본 identity별 cohort, 실패 비용, unknown/null coverage와 중복 JSON 검사를 보존. [집계 identity](../evidence/2026-10-24-coding-cohort-identities/README.md). 실제 클라우드 모델 비교 비용은 미측정. |
| A5 낡은 재개 증거 | 입력이 바뀌어도 예전 resume 결과를 재사용할 수 있었다. | 소스·스크립트·프롬프트·corpus·설정·실행파일·모델·메모리·이미지 identity에 결속하고 다른 cohort 영수증을 거절. 전체 live-provider 재개 실험을 뜻하지 않는다. |
| A6 독립성 과장 | 요청한 모델 별칭이나 response ID를 실제 생산자·독립 judge의 증거로 오해할 여지가 있었다. | 실제 reported model과 admitted Tool source를 host-owned provenance로 보존. 미관측은 unknown이며 서로 다른 weights를 증명했다고 부르지 않는다. |
| A7 완료 과장 | Task의 lifecycle 승인과 외부 수용·Goal 검증·사람 확인이 같은 성공처럼 보일 수 있었다. | 상태·관측·외부 수용 미관측·사람 확인을 별도로 표시. [실제 API/지표](../evidence/2026-10-24-outcome-api-runtime/README.md), [실제 대시보드](../evidence/2026-10-24-outcome-dashboard-runtime/README.md). |

## 실제 Keeper에서 추가로 드러난 결함

승인 통지는 첫 요청에 있었지만 후속 Tool 요청에서 사라졌다. typed Goal/Completion Authority 관측을 현재 turn에 보존하도록 수리했다. Official Start에 같은 이벤트를 고정 System으로 넣은 첫 수리는 독립 리뷰에서 거절됐다. 후속 수리는 현재 이벤트를 Start/Resume User 운반층으로 투영한다. [실패·수리·native 범위](../evidence/2026-10-25-completion-authority-retention/README.md)는 구분돼 있다. 실제 vendor 세션 성공은 미검증이다.

거절 후 첫 재제출에서는 이전 handoff의 bare verification ID가 새 증거에 다시 섞였다. 실제 Qwen의 동일 인수 두 제출이 다른 진단을 낸 사례를 출발점으로, 하나의 현재 Task snapshot을 캡처·commit·알림·review scheduling에 넘기도록 고쳤다. 상관 ID는 기존 typed verdict/outbox/event에 남는다. [후속 수리](../evidence/2026-10-25-submission-evidence-snapshot/README.md)의 실제 첫 재제출 native 사례는 be9a 후보에서 통과했다. 같은 실행의 다른 실패 4건과 GLM328 실측은 별도로 남긴다.

검사도 공격 대상이었다. 기존 Claude fixture는 오래된 unread 기대, Owner child 경계를 건너뛴 호출, provider terminal 부재와 제거된 반복 횟수 중단 가정을 품고 있었다. 잘린 auth probe 검사에는 timeout 에러도 성공으로 인정하는 가지가 있었다. 추가 scheduling 검사도 콜백 예외 격리에 assertion이 삼켜질 수 있어, 관측값을 밖에서 검사하도록 수정했다. [원본 실패와 fixture 수리](../evidence/2026-10-25-native-lifecycle-fixtures/README.md)를 보존한다.

## 실측 판정

고정 사례 G1–G4/A1–A7은 **각 명시한 범위에서11/11**이다. 같은 head에서 전체 회귀를 통과했다는 뜻이 아니다. G1/G4/A1–A7은 이전 source/native/runtime 범위이며, 최신 G2/G3는 source328의 단일 GLM-5.3 일반 HTTP 실험이다.

- 모델이 스스로 matching Goal Task를 만들고 alpha만 바꾸었다. Goal 없는 독립 Task도 별도 정상 사례로 유지된다.
- 승인 뒤 실제 Read →1/3 측정 → beta/gamma Edit → Read →3/3 측정 → Task2 제출 → Goal 검증 요청 순서를 관측했다.
- 다만 request29에서는 Read와 함께 다음 Task도 생성했다. 1/3 측정은 request30이다. 남은 artifact 수정 전 측정은 충족하지만, 모든 계획·상태 변경이 측정 뒤였다는 주장은 하지 않는다.
- 측정 영수증은 reported_only/unchanged이고, 마지막 Goal은 Verifying/proof_pending, Task2는 AwaitingVerification이다. 최종 응답도 증명·사람 확인 대기를 구분했다.
- 새 TaskSpace의 [실제 화면과 API/저장/DOM 대조](../evidence/2026-10-25-goal-continuation-glm/ui/README.md)가 같은 상태를 보인다.

[독립 진단과 호출 영수증](../evidence/2026-10-25-goal-continuation-glm/README.md)은 Gate sleep20 권한1건, inspected Task 승인1건을 통제한 실험임을 밝힌다. 추가 Keeper 지시·운영자 Goal 연결·파일 수정은 없었다. 처음 계획한 midflight 승인 허용과 달리 실제 승인은 원래 operation 완료 뒤에 일어났으며, 이 차이도 보존했다.

이전 Qwen 실패를 삭제하지 않았다. 54 계열은 실제3/3을 만들었어도 Goal 완료 보고와 요구 순서를 틀렸다. 3014는 association/continuation을 실패했다. 2be는 association을 회복했지만 승인 전에 모두 true로 만들었고, 거절 후 복구했어도 최종 승인 뒤에는 아무 Tool도 호출하지 않았다. GLM과 Qwen은 소스·모델·실험 조건 차이가 있어 단일 원인이나 모집단 성공률을 추정할 수 없다.

## 잘하는 지점

Goal 상태 기계는 측정3/3만으로 Completed가 되지 않는다. 이번 실제 화면과 영수증에서도 관측·Task 승인·Goal 증명·사람 확인이 분리돼 있었다. 낡은 verification ID가 새 Task 제출을 승인하지 못하도록 하는 경계도 유지한다.

모델 교체가 같은 Goal/Task 도구 경로를 이용한다. 특정 모델 문구를 해석하는 종료 규칙이나 반복 횟수 게이트를 추가하지 않고도, 모델별 실제 행동을 같은 증거 체계로 관측했다. 모르는 비용·identity·외부 수용은 성공이나0으로 바꾸지 않는다.

실패 데이터가 남는다. 첫 수리의 P2, 중간 캡처 진단, 틀린 최종 보고, 네이티브의 일부 성공과 미완료가 모두 원본 scope로 유지된다. 이것이 다음 모델과 다음 변경에도 재사용할 수 있는 자산이다.

## 개선 우선순위

1. **평가의 무결성부터 확보한다.** 호스트 실행·검사기 변조·증거 교체를 막은 후보와 실제 실행 결과를 결속한다. 콜백 안의 assertion처럼 오류 격리가 검사 실패까지 숨기는 경로를 함께 점검한다. 이번 native 실패를 fixture만 고쳐 재실행하는 이유다.
2. **통지 전달과 자율 수행의 신뢰성을 따로 측정한다.** 승인 이벤트가 정확히 도착해도 Qwen은 남은 일을 하지 않은 사례가 있다. GLM 한 번의 성공으로 이를 일반 해결이라 부를 수 없다. 같은 입력·승인 조건을 고정한 반복 실험에서 모델별 실제 변경, 중간 측정, 최종 보고를 각각 집계해야 한다. Task 개수나 연결 비율로 대체하지 않는다.
3. **격리 실행의 증거를 운영 성공으로 확장하지 않는다.** main API의 timeout·connection refusal과 proof_pending은 현재 관측된 경계다. 실제 Official 세션, microVM grader, 운영 설치와 연속 실행은 각각 직접 확인할 후속 범위다. 모델을 더 오래 돌리거나 임의 횟수 제한을 추가하는 것으로 이 증거를 대신할 수 없다.

## Docker와 microVM

이 캠페인의 재현된 호스트 채점 결함과 구현된 grading driver는 Docker 범위다. microVM 실행은 별도 guest/shim 경로이며 같은 호스트 채점 경로로 확인되지 않았다. microVM end-to-end grader는 실행하지 않았다. guest에서 내보낸 후보를 호스트에서 실행한다면 같은 경계 결함이 생긴다. microVM 이름만으로 검사기·artifact·실험 identity의 무결성이 확보되지는 않는다.

## 남아 있는 경계

메인8935가 응답하지 않던 기록 이후 서비스가 복구됐다. 2026-10-25 00:41:14 UTC에 main Goal 측정11/11이 reported_only로 등록됐고, 00:44:50에 task-2620은 AwaitingVerification으로 제출됐다. 00:45:12에 main Goal의 검증 요청이 수락돼 Verifying/proof_pending이 됐다. [원본 API 영수증과 01:01:45의 별도 저장소 재조회](../evidence/2026-10-25-goal-main-registration/README.md)를 보존한다. 이후 읽기에서 ConnectionRefused도 관측했으므로 서비스 가용성 회복을 지속 보장했다고 부르지 않는다. Goal 증명·사람 확인은 아직 없다.

be9a 후보의 [최소 native 실행](../evidence/2026-10-25-native-verification-followup/README.md)은 5개 suite, 251건 중247 PASS/4 FAIL로 끝났으며 suite timeout은 없었다. 두 suite만 전체 통과했다. 남은 실패는 volatile Registry를 쓴 fixture 2건, bare verification ID를 증거로 기대한 fixture 1건, measured assistant 없는 Claude terminal fixture 1건이었다. 제품의 durable publication·model identity 검사는 유지하고 fixture를 수리했다. 후속 고정 코드17583의 실행40149490208에서는 변경한 세 suite **239건 전부 통과**했다. 이것과 원본 실패, 이전 두 suite의 통과 범위를 각각 보존한다. 전체 회귀 결과로 합산하지 않는다.

후속 소스는 기존16개 Native Stack을 다른 세션이 재배치하는 동안 별도 exact candidate로 보존한다. source review, 최소 native 검사, 실제328 runtime, UI, 현재 원격 PR head/base와 전체 스택 승인은 각각 따로 확인해야 한다. microVM grader·실제 Official vendor 세션·전체 회귀·운영 설치·배포·병합·최종 사람 Goal 확인은 이 감사의 성공 주장에 포함되지 않는다.

후속 PR: [현재 제출 snapshot 수리 #45861](https://github.com/jeong-sik/masc/pull/45861), [native/콜백 검사 수리 #45867](https://github.com/jeong-sik/masc/pull/45867), [durable publication·terminal fixture 수리 #45874](https://github.com/jeong-sik/masc/pull/45874). 최소 native 실행 결과는 PR 본문의 frozen candidate/run 결속을 따르며, 이 문서의 원래328 실패 기록을 덮어쓰지 않는다.
