# Candle 지급 설정

Candle은 설정 폴더의 `candle.toml`을 매번 읽는다. 파일이 없으면 Off다. 파일이 있지만 필수 값이 없거나 잘못되면 이유를 포함한 Disabled가 된다. 서버는 계속 동작하며 이 상태에서는 Snapshot과 지급 의무를 기록하지 않는다.

설정과 원장이 유효한 상태에서 appraiser lane이 없거나 registry가 아직 게시되지 않았거나 교체 게시 중이면 지급 가용성은 그 이유로 Disabled가 된다. 이때도 검증 통과의 Snapshot과 확정의 지급 의무는 기록한다. lane이 다시 사용 가능해지면 같은 의무에서 지급을 재개한다.

필수 구조:

- `[payout]`: `weight_max`, `deduction_rate`, `deduction_floor`
- `[payout.grades_milli]`: `trivial`, `small`, `medium`, `large`, `epic`

모든 값은 정수다. 금액은 0 이상의 milli-Candle, 가중치 상한은 1 이상이다. 감액률과 바닥은 0..1000 천분율이다. 각 금액에 가중치 상한과 1000을 각각 곱한 결과가 OCaml 정수 범위 안에 있어야 한다. 코드에는 경제 기본값이 없다. 알 수 없는 키와 누락된 등급은 거절한다.

등급은 운영자가 확정한 Trivial, Small, Medium, Large, Epic이다. 설정이 유효하다는 사실만으로 모델 평가나 실제 지급이 실행되는 것은 아니다. 이 변경은 기존 Snapshot·지급 의무·후보 기록의 설정 경계를 연결한다. 평가 모델, Paid 기록, 구매, 착용은 후속 구현이다.

설정 키를 읽는 바이너리를 먼저 배포한 뒤 값을 설정한다. 테스트의 금액은 테스트 입력이며 운영 금액 권고가 아니다.
