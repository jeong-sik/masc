# Librarian 선언 교체 후 미소비 입력 이어가기

연결: #51278, 병합된 RFC #51317, [Farm 계획](2026-11-12-agent-farm-plan.md)의 E8/TLJ-S02 선행 작업.
기준 소스는 `606e16f5ce8b5c69ad9d18e82f6bf076aaf7f13d`다. 별도 native stack에서 작업한다.

2026-11-16 사용자는 이전 요청을 끝내고 미소비 입력을 새 설정에서 다시 만드는 방식을 선택했다.
읽기 위치를 그대로 두고 다음 pass가 입력을 다시 고른다. 새로 도착한 자료가 함께 포함될 수 있다.
이 선택은 실행 여부가 불확실한 요청을 다시 보내라는 뜻이 아니다.

## 첫 단위: host가 아직 시작하지 않은 요청

- 설정 파일만 바뀐 상태는 `Not_now`다. 설치·package·tool이 같은 새 선언과 정확히 하나의 준비된 worker를 확인한 경우에만 `Declaration_replaced`가 된다.
- Exact의 원본 identity·기존 terminal·실행 proof 복구가 먼저다. 확정된 답과 시작 표시가 있는 요청의 결과는 그대로 보존한다.
- 현재 실행할 시도가 아직 시작되지 않았고 새 선언이 준비됐으면 host가 `Not_allowed`를 저장한다. host 기록에는 `Dispatch_veto_replaced`를 마지막 determining attempt로 남긴다. 그 앞에는 요청을 끝내지 않은 `Deferred` 기록만 올 수 있다.
- 소비자는 `Retained_declaration_replaced`라는 host 전용 사유를 읽는다. worker가 돌려주는 final에는 이 사유를 넣지 않는다. 같은 설명 문자열의 일반 `Not_allowed`는 교체 권한이 아니다.
- worker 응답과 host 복구가 같은 사유를 남긴다. 원본 request·schema·digest에 묶인 host 기록과 소비자 progress의 사유를 확인한다. 그 뒤 worker가 사라지거나 설정이 되돌아가도 일반 입력 실패로 바뀌지 않는다.
- history와 floor는 교체로 끝난 요청의 source·Memory·외부 ACK를 옮기지 않는다. 새 실패 범위를 만들지 않고 다음 pass를 깨운다. 앞서 실제 입력 실패로 좁혀 놓은 범위는 보존한다.
- floor의 교체 step은 기존 정리 경로로 옮긴 뒤 다음 pass를 깨운다. 알 수 없는 결과를 교체 사유로 만들지 않는다.

독립 리뷰에서 발견한 두 항목을 반영했다. `Memory_replaced`를 받는 실제 capacity callback fixture의 닫힌 match를 추가했고,
종결 직후 worker 재조회 실패가 일반 refusal로 바뀌던 경계를 host의 저장된 사유로 바꿨다.

## 확인한 범위

변경 OCaml 파일의 `ocamlc -stop-after parsing -c`와 `git diff --check`를 확인한다.
파일별 해시와 결과는 `artifacts/farm-librarian-replacement-20261116/`에 둔다.
독립 소스 리뷰는 그 리뷰가 지정한 head와 diff에만 적용한다.

회귀 코드를 추가했다. 실제 Runtime·Server Exact fixture의 새 worker 준비 전후, 종결 뒤 worker 비활성화·rollback,
입력·읽기 위치·외부 ACK 보존, 같은 RPC에서 받은 사유, worker final과 host 기록 불일치,
typed marker의 순서와 codec, 이전 입력 실패 유무를 다룬다.
**타입 검사·Dune 빌드·회귀 실행·CI·설치·운영 복구는 미실행이다.** 문법과 소스 검토로 동작 성공을 주장하지 않는다.

## 남은 범위

- 접수 전 `Captured`·`Admission_wait`를 본문을 읽지 않고 끝내는 progress evidence와 inventory 경로는 다음 단위다.
- preAdmission floor 처리는 다음 단위다. CLI가 전송 직전 guard에서 멈추는 L1b는 이미 #51343에 있으므로 중복 구현하지 않는다.
- `cut`·`raised`와 이미 받은 `Judged` 결과·admission part는 별도 상태다. 이번 단위는 불확실한 외부 실행을 자동 재전송하지 않는다.
- 따라서 #51278 전체, TLJ-S02와 Farm 전체가 끝났다고 판정하지 않는다.
- native stack 발행은 이전 시도에서 GitHub CLI 인증을 얻지 못했다. 연결된 GitHub 읽기 도구의 인증과 CLI/native stack 발행 인증은 다르다.
