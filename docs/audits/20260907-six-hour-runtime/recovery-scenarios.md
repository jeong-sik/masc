# 복구 시나리오와 확인 범위

2026-09-07 후속 수리. 테스트 통과, 병합, 운영에서 해당 경로 실행은 서로 다른 증거다. 원래 20개 로그 항목과 원문은 [보고서](report.md)에 유지한다.

| 상황 | 요구하는 동작 | 확인된 범위 | 남은 연결 |
|---|---|---|---|
| A가 승인·자식을 기다리는 동안 B가 도착 | A를 보존하고 B가 실행 가능 | #34021 journal114 PASS: Running만 실행 슬롯을 차지하고 대기·복구 행은 슬롯을 비움 | 실제 Owner의 공정한 선택, 자식의 부모 실행 identity |
| Direct 응답 전달이 끝났지만 의미상 작업은 미완료 | 원래 편집된 입력을 보존 | #34062 108 PASS: chat 입력 해제 후 A 입력 보존, B 완료, DB 재개방 뒤 A 재개, semantic 종결에서만 본문 해제 | native admission과 settlement 연결 |
| B가 공유 대화를 여러 번 갱신한 뒤 A 재개 | B의 대화는 유지하며 A의 실행 기록만 선택 | #34036 correctedbd0 55 PASS: rolling history 정리 뒤에도 A의 정확한 checkpoint bytes 유지 | 전체 A checkpoint 복원은 금지. scope 한정 projection 필요 |
| provider가 실제 도구 완료 경계에서 양보 | 중단과 완료 경계를 구분 | #34041 새 경계3건 및 Gate 보류 후 완료 사례 PASS; 전체117/118은 별도 output probe1건 실패 | 경계만으로 durable effect 확인이나 재실행 권한을 추정하지 않음 |
| GLM HTTP429가 발생하고 다른 후보가 있음 | 해당 후보 순서를 낮추되 모든 후보는 시도 가능 | #34059 139 PASS, 병합. 실제 Api 오류·같은 설정 reload·credential 교체·전체 후보 낮은 순위·성공 후 해제 검증 | 최신 운영 바이너리에서 candidate 선택과 완료 관측 |
| 한 provider/model의 접근권이 거절됨 | 효과와 caller 권한이 허용하면 다음 선언 후보 진행 | #34087 93 PASS: 401/403 후속 성공, 효과 attempted/unknown 차단, caller 거부, 소진·400 종결 보존 | 필수 검사 PASS·병합 확인. 운영 적용과 후속 성공은 별도 확인 |
| enum과 description이 함께 있는 도구 스키마 | 유효한 단일 description JSON 생성 | #34075 실제 codec46 PASS 및 필수 검사 PASS, 병합 | 운영 provider 수락 |
| GPT-5.5를 추론·도구와 함께 사용 | 기존 Responses 경로에 caller의 정확한 effort 전달 | #34055 catalog/header71 PASS. #34093은 실제 TOML→binding→HTTP와 supported effort 보강 중 | #34093 원격 테스트, 운영 설정 선택, 실제 계정 권한 |
| 설정 전환 중 취소 | 실제 Owner fence를 관측하고 정리 | #34012 115 PASS, 같은1초 deadline에서 이벤트 대기 통과, 병합 | 이 테스트 결과가 생산 writer 교착의 재현·수리 증거는 아님 |

추가로 확인해야 할 native 경계는 [독립 소스 리뷰](native-continuation-source-review.json)에 있다. 이전 provider의 늦은 callback은 정확한 execution/attempt 소유권으로 걸러야 한다. journal commit이 불확실하면 정확한 이전/다음 record를 재조회해 중복 관측을 막고, 이 한 작업의 충돌을 Keeper 전체 저장소 장애로 바꾸지 않아야 한다. 반복 감지의 historical baseline은 attempt 시작 시점에 고정해야 한다.

새로운 시간 만료, 반복 횟수 상한, 강제 cooldown, 후보 제외는 이 수리들에 추가하지 않았다. 테스트의 제한된 실행시간은 운영 작업을 만료시키는 정책이 아니다.
