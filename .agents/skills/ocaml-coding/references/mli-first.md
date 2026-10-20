# 8. API 를 바꿀 때는 .mli 먼저

`ocaml-coding` Skill 8절의 전체 점검표다. 공통 규칙은 그 Skill 의 SKILL.md 를 따른다.


- `Keeper_tool_plan`은 생성자의 canonicalization·중복 ID/이름·compiled operand 확인 후
  원래 노드/계약을 plan 안의 불변 index로 결속한다. 검증 단계와 첫 오류 선택은 원래
  목록 순서를 지키고, 결속도 첫 unknown/off-surface 오류에서 멈춘다. 실행 조회는 보관한
  원래 계약을 쓴다. parameter 바인딩·재구성은
  새 plan과 index를 만들며, 이전 plan/run의 출력은 새 입력에 넘기지 않는다. 실패한
  생성자의 선행 결속 비용도 Before/After에 남기고, lookup 수를 실행 시간으로 환산하지 않는다.

- Composition 파일 준비의 노드·계약·선행조건은 원래 plan 안의 불변 index를 재사용한다.
  `prepare_inputs`의 원래 노드 순서와 ID를 함께 확인하고, capability 조회는 typed ID를
  찾은 뒤에도 원래 노드의 물리 identity와 입력을 검사한다. Ready binding은 원래 멤버를
  확인한 뒤 보관한 계약을 쓰며, 동적 입력의 실제 해석·검증과 consumer의 owner·경로 검사는
  유지한다. 충돌·실패·해제 순서를 map 순서로 바꾸거나 이 lookup 감소를 실행 시간으로
  환산하지 않는다. index는 해당 plan의 수명에만 속하며 재개·재구성한 plan에 넘기지 않는다.
  Ready producer가 성공한 준비에서 만든 불변 의존 계층은 같은 원래 plan인지 물리 확인한
  executor가 재사용한다. 일반 plan의 `dependency_layers` 호출 계약은 바꾸지 않는다.
  보관한 그래프를 동적 입력·binding·결과·실행 허가로 쓰거나 다른 plan에 넘기지 않는다.
  aggregate 파일의 `resource_ordering`은 원래 plan/member 확인 뒤 이미 만든 의존 계층과
  원래 선행조건 목록을 읽기 전용 결과로 함께 전달한다. executor에서 그래프를 다시
  만들지 않고, 호출자가 그래프를 주입하는 옵션이나 별도 캐시/구 API 래퍼를 두지 않는다.
  executor의 descriptor·준비된 파일·Ready 순서는 닫힌 타입으로 구분한다. Ready의 원래
  병렬 정적 그룹을 만들려고 빈 자원 선행조건 표나 pending 전체 탐색을 만들지 않는다.
  일반 descriptor 스케줄로 대신 보내면 공유가 달라진다. 실제 binding의 충돌·배타 실행과
  Require_success 선행 settlement의 실패/ticket 반영은 Ready runner에 그대로 둔다.
  실제 준비된 파일의 선행조건 목록은 실행별 typed-ID index에서 원래 목록 그대로 찾는다.
  정적 wave의 pending-ID 집합은 원래 계층에서 만들고 ready partition만 제거한다.
  노드·그룹·선행 결과를 순회하는 원래 목록을 집합/인덱스 순서로 대체하지 않으며,
  이 자료구조의 생성·갱신 비용과 준비 후 거절된 실행도 Before/After 분모에 남긴다.
  파일 scope 값은 producer의 불변 원본을 쓴다. aggregate 순서 계산 안에서 leaf별로,
  Ready에서는 실제 입력·준비 뒤 원래 binding별로 보관해 pair 비교에 재사용한다.
  binding 전으로 캡처를 앞당기거나 다른 실행에 넘기지 않는다. 해제·owner·입력·물리 경로의
  소비 검사는 유지하고, 싼 Write getter와 비교 없이 끝난 binding의 추가 보관 비용도 기록한다.
  Ready 실행의 선행 binding 순회는 같은 실행의 원래 위상 목록을 직접 방문한다.
  typed ID로 보관한 suffix의 물리 비교는 그 불변 목록 안의 정지 위치만 뜻한다.
  선언 순서의 index로 대체하거나 다른 목록·실행에 넘기지 않고, 실제 선행 binding 대기와
  resource 분류는 모두 유지한다. prefix 할당 감소와 새 index의 선행 비용을 함께 기록한다.

- Keeper 실행 setup·effective surface·Composition 재개는 `(selection, preparation)`을 함께 사용한다.
  기존 선택은 `Keeper_task_skill_turn.bind_surface`로 검증하고, 새 exact 참조는
  `resolve_surface`에서 해석과 준비를 함께 받는다. fresh 결과를 곧바로 다시 바인딩하지 않는다.
  이미 검증한 불변 입력의 준비를 바로 다시 검사하거나 optional 필드에서 추정해 꺼내지 않는다.
  정확한 snapshot/descriptor 객체와 선택 authority 검증, 오류·Task 출처·retained-surface 관측을
  유지한다. 표시용 `prepare_surface`는 Task 참조를 재해석하지 않는 별도 관측 경계다.
  검사 호출 수의 감소를 준비 시간·모델 왕복·실제 실행 개선으로 바꾸어 말하지 않는다.
  Task별 exact surface는 한 호출 안에서 원래 선택 행을 한 번 판정해 관측된 Task 소유자에게
  나눈다. 빈 Task도 유지하고, 관측되지 않은 소유자나 뒤늦게 관측한 Task가 frozen 선택을
  빌리지 않도록 한다. 공유 availability/실패 설명은 불변 결과이며 실행 허가나 전역 캐시가 아니다.
  exact 참조를 합칠 때는 identity와 content revision을 함께 구분하는 `Skill_reference.Exact_map`을
  쓴다. 첫 원래 행과 Task 출처를 유지하고, identity만 같다는 이유로 다른 pin을 합치지 않는다.
  반복 pin의 Task ID는 불변 집합에 누적해 정렬된 목록을 마지막에 한 번 만든다. 유일한 행은
  원래 객체를 유지하고, 중간 합집합을 외부로 노출하거나 전역 캐시로 넘기지 않는다.

- `.mli` 가 있으면 `.mli` 를 먼저 고치고 `.ml` 을 맞춘다. `.ml` 에만 인자를 더하면 인터페이스와
  안 맞아 컴파일이 실패한다.
- 레코드 필드를 늘리면 그 레코드를 만드는 자리를 `rg -c` 로 전부 세고 모두 고친다.
  `type t = Other.t = { ... }` 로 다시 적은 `.ml`/`.mli` 짝도 같이 고친다.
- 선택 인자 뒤에 위치 인자가 없으면 `()` 를 받는다. 없으면 경고 16(지울 수 없는 선택 인자)이다.

  ```ocaml
  let submit ~title ?(refs = []) () = ...
  ```

- 루트 `dune` 이 모든 프로파일에 `-w +4+32+69 -warn-error +a` 를 건다. 합타입의 포괄 분기(4), 안 쓰는 값(32)과 안 읽는
  레코드 필드(69)도 오류다. 값이나 필드의 마지막 사용처를 지웠으면 그 값·필드도 같은 커밋에서 지운다.
