# Candle 지급 설정

Candle은 설정 폴더의 `candle.toml`을 매번 읽는다. 파일이 없으면 Off다. 파일이 있지만 필수 값이 없거나 잘못되면 이유를 포함한 Disabled가 된다. 서버는 계속 동작하며 이 상태에서는 Snapshot과 지급 의무를 기록하지 않는다.

필수 구조:

- `[payout]`: `weight_max`, `deduction_rate`, `deduction_floor`
- `[payout.grades_milli]`: `trivial`, `small`, `medium`, `large`, `epic`

모든 값은 정수다. 금액은 0 이상의 milli-Candle, 가중치 상한은 1 이상이다. 감액률과 바닥은 0..1000 천분율이다. 각 금액에 가중치 상한과 1000을 각각 곱한 결과가 OCaml 정수 범위 안에 있어야 한다. 코드에는 경제 기본값이 없다. 알 수 없는 키와 누락된 등급은 거절한다.

## 장신구 가격과 구매

가격은 같은 파일의 선택 표 `[shop.prices_milli]`에 적는다. 키는
`keeper_candle_catalog`가 반환하는 Item id이며, 값은 0 이상의 정수
milli-Candle이다. 표나 특정 아이템의 값이 없으면 그 아이템은 `Unpriced`다.
카탈로그에 없는 키, 음수, 실수나 문자열 가격은 Candle을 `Disabled`로 만든다.
0을 명시한 아이템은 무료이며 한 번만 살 수 있다.

Keeper 도구는 기본 도구 목록에 항상 포함된다.

- `keeper_candle_balance`: 본인의 잔액과 구매한 Item 목록을 읽는다.
- `keeper_candle_catalog`: 동일한 Portrait Item 카탈로그의 현재 가격을 읽는다.
- `keeper_candle_purchase`: `item` 하나를 받아 본인의 Candle로 산다.
- `keeper_candle_equip`: `slot`과 소유한 `item`을 받아 장착한다. `item = "default"`는 해당 슬롯을 이름 기반 기본 장신구로 돌린다.

Keeper 턴에서는 턴의 Keeper 이름, 인증된 MCP 호출에서는 bearer credential의
Keeper가 본인이다. 요청 인자로 구매자나 다른 지갑을 지정하지 않는다.
이름에서 정해진 시작 장신구와 구매한 장신구의 소유권은 별개다.

잔액과 소유권은 Candle 원장의 `Paid`와 `Purchased`를 순서대로 읽어 계산한다.
구매는 원장 cursor가 그대로일 때만 기록하며, 다른 기록이 먼저 생기면 새
잔액과 소유권으로 다시 판단한다. 잔액 부족이나 중복 구매는 차감 없이 거절한다.
가격이 바뀌어도 이전 구매는 기록 당시 낸 금액으로 복원한다.
읽기와 구매는 손상된 행이나 잘린 끝줄을 복구하지 않는다. 원장 복구는 서버
시작 경계가 담당한다.

장착도 같은 원장에 `Equipped`를 기록하며 현재 소유권과 슬롯을 다시 검사한다. 지급·구매는 장착 선택을 보존한다. 현재 장착 상태는 서버·웹·원격 TUI 초상화에 투영한다.

등급은 운영자가 확정한 Trivial, Small, Medium, Large, Epic이다. 설정이 유효하다는 사실만으로 모델 평가나 실제 지급이 실행됐다는 증거가 되지는 않는다. 지급 모델과 운영 설정, 원장의 실제 지급 기록을 따로 확인한다.

설정 키를 읽는 바이너리를 먼저 배포한 뒤 값을 설정한다. 테스트의 금액은 테스트 입력이며 운영 금액 권고가 아니다.
