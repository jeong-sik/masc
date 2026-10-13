---
name: verify-before-claiming-done
description: "Checks whether recorded evidence supports a completion claim and its exact scope. Use before saying done, fixed, passing, merged or ready, or submitting a task for verification. Reuse evidence whose source, inputs and conditions still match; inspect changed or missing evidence rather than restarting every check. Separates source review, process success, tests, merge, installed binary and visible runtime behavior. Read command exit status and identify any unverified scope. Follow the repository contract for required checks; ordinary MASC PR review does not require a build, while Release/Tag requires full CI for that head."
---

# 완료를 말하기 전에 검증

주장하려는 범위와 그 범위를 확인한 증거를 맞춘다. 예상은 결과가 아니다.
준비와 검증을 반복하는 대신, 이미 확인한 것과 아직 확인할 것을 구분한다.

## 확인 순서

1. **주장의 범위를 정한다.** 소스 수정, 명령 성공, 테스트 통과, 머지, 설치,
   실제 화면 확인은 각각 다른 주장이다. Task의 완료 조건도 함께 읽는다.
2. **기존 증거를 확인한다.** 대상 커밋, 입력, 환경, 검사 범위가 여전히 맞으면
   기록한 결과를 재사용한다. 바뀐 부분이나 증거가 없는 부분에 필요한 검사만 고른다.
   exact-head 승인이 필요한 리뷰나 Release/Tag CI는 해당 head의 증거가 있어야 한다.
3. **실행 결과를 읽는다.** 종료 코드와 실패 내용을 확인한다. 도구 호출의 완료가
   명령 성공을 뜻하지 않는다. 파이프라인은 앞 단계 실패를 보존하도록 실행한다.
   실행 중이거나 결과가 불확실하면 그 상태를 기록하고 먼저 결과를 조회한다.
4. **저장소 계약을 따른다.** MASC 일반 PR은 현재 head의 독립 소스 리뷰가 기준이다.
   검증이 필요하면 변경에 맞는 검사를 고른다. Release/Tag는 해당 head의 full CI가
   필요하다. 캐시 사용 자체가 실패는 아니다. 입력 일치와 검사 범위를 확인한다.
5. **확인한 만큼 말한다.** 증거의 위치와 아직 확인하지 않은 범위를 함께 적는다.
   화면 동작을 요구한 Task는 소스 리뷰나 빌드 성공만으로 끝내지 않는다.

## 마지막 Execute가 실제로 돌았나

`keeper_lane_status`의 `last_dispatch`는 microvm·원격 SSH 엔드포인트의 마지막
Execute 결과다. `outcome=payload_finished`면 `status`가 명령 종료 상태이고,
`lane_failed`면 실행 레인이 실패한 것이다. `at_unix`와 대상 엔드포인트를 확인한다.
다른 Execute가 실행되면 이 기록은 바뀌므로 해당 작업의 출력 참조도 보존한다.
Docker 레인이나 서버 재시작 뒤에는 `last_dispatch=null`일 수 있다.
null만으로 미실행을 단정하지 않는다. 이 기록은 명령 실행 여부를 보여줄 뿐,
출력이 완료 조건을 충족하는지는 따로 판단한다.

## 자주 생기는 착각

- HTTP 200, 목록의 성공 표시, 마지막 요약 한 줄만으로 실제 내용을 확인했다고 한다.
- 소스 검사나 목업 결과를 설치된 제품의 동작 증거로 쓴다.
- head나 입력이 바뀌었는데 이전 결과를 그대로 현재 결과라고 쓴다.
- 증거가 하나 부족하다는 이유로 이미 인정된 다른 검사까지 모두 반복한다.
- push나 병합 요청의 접수를 머지 완료로 쓴다. PR의 merged 상태와 결과를 읽는다.
