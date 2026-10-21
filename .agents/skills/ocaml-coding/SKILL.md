---
name: ocaml-coding
description: "masc 저장소의 lib/·bin/·test/ OCaml 5.5 + Eio 코드를 작성·수정할 때 쓴다. typed 오류·취소와 자원 수명, 준비·Skill 권한, maintenance·결과 알림의 공유 비동기 발견, 실제 worker 정리, .mli 우선 변경과 검증 경계를 안내한다. 준비·예약·실행·UI 관측을 구분한다."
---

# masc OCaml 점검표

이 저장소는 OCaml 5.5 에 고정돼 있다(`dune-project` 의 `(ocaml (= 5.5.1))`).
표준 라이브러리와 Eio 의 사실은 공식 인터페이스로 확인한다.

- OCaml 매뉴얼: https://ocaml.org/manual/5.5/index.html
- API: `https://ocaml.org/manual/5.5/api/<Module>.html`
- Eio: opam 스위치의 `lib/eio/*.mli`, 또는 https://ocaml.org/p/eio/latest/doc/Eio/index.html

규칙의 원본은 `docs/constitution.xml` 이다. 이 문서와 헌법이 다르면 헌법이 맞다.

## 1. 상태와 오류는 닫힌 합타입

- 서로 배타적인 상태·판정·오류는 variant 로 쓴다. 문자열이나 부분 문자열을 비교해 다음 동작을
  고르지 않는다(헌법 `string_matching`). `String.starts_with ~prefix:"..."` 로 분기하고 싶어지면
  그 값을 만드는 쪽에 생성자를 하나 더 둔다.
- 파서는 모르는 입력에 `None` 이나 `Error` 를 준다. 편한 기본값으로 눌러 담지 않는다.
- `match` 는 경우를 다 적는다. 새 생성자를 넣었을 때 컴파일러가 빠진 자리를 알려 주게 한다.
  상태 전이표에 `| _ -> false` 를 두면 새 상태의 전이가 빠져도 컴파일된다.
- 실패할 수 있는 계산은 `Result` 로 돌려준다.

  ```ocaml
  let ( let* ) = Result.bind

  let process input =
    let* parsed = parse input in
    let* computed = compute parsed in
    Ok (render computed)
  ```

- `failwith "not implemented"` 같은 자리 채움을 두지 않는다. 컴파일은 되고 실행하면 터진다.
- `assert false` 는 타입으로 막을 수 없는, 정말 도달하지 않는 가지에만 둔다.
- `option` 의 `None` 이 무엇을 뜻하는지 `.mli` 문서 주석에 적는다.

## 2. 예외 잡기와 Eio 취소

Eio 는 취소를 `Eio.Cancel.Cancelled` 예외로 전한다. 모든 예외를 잡는 가지는 이 취소까지 삼킨다.
삼킨 fiber 는 멈추라는 요청을 받고도 계속 돈다.

- 잡을 예외의 생성자를 적는다.

  ```ocaml
  match Eio.Path.load path with
  | contents -> Ok contents
  | exception (Eio.Io _ as ex) -> Error (Format.asprintf "%a" Eio.Exn.pp ex)
  ```

- 전부 잡아야 하면 취소를 먼저 다시 던진다.

  ```ocaml
  match run () with
  | value -> Ok value
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex -> Error (Printexc.to_string ex)
  ```

## 3. 변경 검증

- 준비 중 파일을 직접 여는 코드도 확인한다. 이미지 카탈로그의 load/load_for_change는
  host 파일의 open/read/close만 공통 systhread guard로 보낸다. 순수 해석·factory 상태·
  이미지 선택은 원래 caller가 소유하고, 저장의 최신 byte 비교와 durable lock은 그대로 둔다.
  비동기 파일 관측을 권한 허가나 물리 실행 시작으로 바꾸어 쓰지 않는다. Non-Eio fallback과
  보호된 factory lock의 대기는 유지되므로 전체 준비나 취소가 즉시 끝난다고 주장하지 않는다.

- 세션·snapshot 영속화는 실제 owner 경로의 host I/O와 순수 해석을 공용 executor에 두고,
  취소·소유권 확인 뒤 owner가 상태를 적용한다. 준비 완료와 물리 I/O·caller·UI 관측을 구분한다.
  관련 필드는 한 불변 atomic registry로 게시하고 저장은 한 committed 상태를 캡처한다.
  profile-only와 초기화 권한, 원래 optional/default/중복 정책과 unrelated live key를 보존한다.
  CAS 안에는 순수 map 변환만 두고 clock·로그·외부 lifecycle 효과는 밖에 둔다. 별개 API 호출과
  외부 효과까지 transaction이라 부르지 않는다. 재시도·경합·준비 비용을 실측에서 빼지 않는다.
  파일 교체는 공용 `Fs_compat` atomic writer와 canonical 임시 이름을 재사용한다. 기존 host
  worker에서는 inline 경로를 쓰고 재생성 가능한 파일만 rename-only로 저장한다. 원래 예외와
  backtrace가 필요한 caller는 staged 결과를 사용해 예상 host 실패만 타입으로 처리하고,
  취소·예상 밖 오류는 전파한다. 새 임시 파일 프로토콜을 복제하지 않는다. 입력·목적지 종류,
  descriptor identity, 복원 거절의 최초 원인·token·경로 보존은 저장 완료와 별개로 확인한다.
  agent 세션의 디렉터리 발견은 worker에서 불변 이름만 만들고 owner에 dispatch한다.
  조회 중 들어온 실제 연결·대기 알림은 현재 state에서 보존하며 없는 이름만 복원한다.
  조회마다 수명을 묶어 열려 있는 동안 처리된 삭제(일시 등록 후 삭제 포함)를 적용 때 보존한다.
  성공·실패·취소에 정리하고 actor 종료는 미적용 조회도 무효화한다. 영구 tombstone은 두지 않는다.
  caller 취소 전 owner가 claim했는지 구분하며, 이후 취소를 publication 취소나 물리 I/O 종료로 부르지 않는다.
  실제 읽기 뒤 owner 적용 전의 테스트 경계는 실제 연결·삭제·알림·actor 수명만 순서 짓고
  storage 대체·private state 관측·호출 횟수 검사로 바꾸지 않는다.
  현재 protocol/resource 시나리오와 한계는 해당 audit에 두고 Skill에는 재사용할 규율을 적는다.

- Ask 답변 복구의 사전 증거는 같은 회차·Keeper·canonical answer의 UTC-day window에서만
  공유한다. 실제 첫 수요에서 캡처하고 원본 답변 행이 하나뿐인 window의 큰 proof 집합은 보관하지 않는다.
  기존 파일 cursor cache와 회차의 불변 snapshot을 구분하며, 실패한 window를 다른 날짜나
  Keeper에 빌리지 않는다. 순서·원래 답변/Task 연결은 유지하고 실제 enqueue는 owner lock의
  최신 증거·lifecycle fence를 다시 확인한다. window capture 수는 파일 I/O·작업 진척이 아니다.

- 서버 Ask 복구는 같은 수명의 `Keeper_ask_answer_wake` supervisor와 switch를 사용한다.
  `pulse` 반환은 discovery child 예약이며 실제 성공이 아니다. 원래 발견·owner 예약 결과는
  원래 base path와 함께 `on_discovery`로 전달하고 전체 읽기 실패도 같은 타입으로 남긴다.
  discovery는 observer·정리까지 하나만 활성화하며 실제 읽기 전에 yield한다. 미완료를
  `Ok`나 빈 목록으로 바꾸지 않고, 일부 불가 log의 진단과 정상 owner 복구를 함께 유지한다.
  발견한 원래 Keeper별로 active 작업을 한 번만 예약하고, worker는 양보한 뒤 원래 행 순서로
  복구한다. 다른 Keeper의 intake/파일 잠금을 maintenance나 독립 Keeper가 함께 기다리지 않는다.
  active 중 발견한 새 답변은 현재 batch를 덮지 않고 후속 pulse가 fresh하게 읽는다.
  예약·시작·batch 결과·중단을 구분하며, 취소 정리 전 active를 해제하거나 전달을 Task 진척으로
  부르지 않는다. discovery 자체·같은 Keeper의 직렬 대기·보호된 물리 I/O 정리는 여전히 남는다.

- Composition 완료 복구도 원래 server switch의 supervisor를 사용한다. `pulse` 반환은
  discovery 예약이며 원래 outbox 발견·owner 예약의 실제 결과만 `on_discovery`로 전달한다.
  전체 읽기 실패와 일부 손상 의무의 진단을 구분하고, discovery는 observer·정리까지 하나만
  활성화하며 읽기 전에 yield한다. 예약을 성공·전달·물리 종료로 바꾸어 기록하지 않는다.
  기본 복구 경고와 기존 단계·중단 관측에는 원래 supervisor 경로를 함께 남긴다.
  routine의 lazy 정책을 유지하고 추가 경로 바이트와 eager 로그의 형식화 비용도 센다.
  outbox에서 검증한 원래 root·요청·수신자를 Keeper별 worker로 전달하고,
  실제 전달 전 obligation을 다시 읽어
  identity 변경을 거절한다. 기존 canonical terminal·journal·waiting proof와 durable ACK는
  같은 core를 사용한다. 이미 ACK된 힌트는 권한이 아니며 active 중의 새 의무는 후속 pulse가
  다시 발견한다. 발견/재읽기 비용을 포함하고, batch 결과·observer·worker 정리를 구분한다.
  준비된 DAG의 waiting attempt를 logical 완료로 알리거나 물리 작업을 재실행하지 않는다.

- Goal·명시적 Broadcast outbox의 maintenance도 원래 drain을 server switch 소유
  worker에 예약한다. 종류별 active 예약은 observer·취소 정리까지 유지하고 실제 작업 전
  yield한다. 예약한 pulse의 workspace 설정만 쓰며 새 scope나 다음 pulse로 결과를 넘기지
  않는다. Goal의 원래 잠금·수신자 snapshot·ACK, Broadcast의 순서·대상별 선행 조건·ACK를
  유지한다. drain 반환·worker 정리·Keeper 소비·원본 Task 진척은 서로 다른 증거다.

- transition outbox maintenance는 기존 strict executor의 원래 발견·owner 페이지를
  server switch 소유 worker에서 실행한다. 실제 반환된 페이지의 cursor만 관측 콜백 전에
  갱신하고, 결과를 못 받으면 이전 cursor로 durable 상태를 다시 읽는다. active 페이지는
  observer·취소 정리까지 유지한다. 원래 owner claim·shutdown fence·target 선행 전달과
  source retirement·순회 순서·executor 미가용 결과를 보존하며 inline fallback을 만들지 않는다.

- 제공받은 switch로 자동 복구 fiber를 예약할 때는 discovery 전과 실제 예약 직전에
  `Eio.Switch.check`를 한다. `Cancel.protect`도 취소된 switch를 다시 켜지 않는다.
  `fork`가 callback 없이 반환하면 active 예약만 남을 수 있다. 취소를 저장소/저널 오류나
  정상 접수로 바꾸지 않고, 다음 정상 scope가 원래 durable owner를 다시 읽을 수 있게 한다.
  owned-job pending marker는 검증된 행부터 발견 child 문맥에서 예약하되, filesystem 오류
  변환 안에 예약 callback을 넣지 않는다. 뒤쪽 discovery 실패에도 먼저 예약한 worker의
  원래 owner 검증·취소 정리를 지키고, held hint는 전체 스캔 성공 뒤에만 정리한다.
  Composition은 원래 journal·종단 proof·의존 결과를 검증한 ready candidate부터
  발견 drain에 전달한다. callback 예약은 filesystem 오류 변환·marker transaction 밖에서
  수행하고, 캡처된 candidate를 실제 intake의 최신 권한 검사로 바꾸어 쓰지 않는다.
  선언 projection은 같은 pulse의 첫 실제 수요에서 공유하며 다음 pulse로 넘기지 않는다.
  두 controller의 child는 원래 `Fun.protect` 정리 안에서 먼저 yield한 뒤 owner 복구·held
  증거 검사·선언 읽기에 들어간다. 진입 취소도 active 예약을 해제한다. owned-job의 발견은
  예약된 발견 child에서, 준비된 Composition은 maintenance·결과 알림이 공유하는 drain에서 수행한다.
  발견 중 I/O가 job/intake child를 실행할 수 있으므로 전체 발견 뒤 실행을 보장한다고
  쓰지 않는다. owned-job 진입 취소로 제거된 process-local held hint는
  다음 회차에 전체 재검사를 요구할 수 있지만 원래 durable 결과와 전달 의무는 유지한다.

- owned-job maintenance `pulse`는 같은 server switch의 발견 child를 예약하고 반환한다.
  실제 marker 발견·job 예약 결과는 원래 base path와 typed `Store.error`를 유지한
  `on_discovery`에서 관측한다. `Ok ()`도 일부 손상 marker를 숨기거나 전달 완료를 뜻하지
  않는다. 발견 예약·시작·실제 반환·중단을 구분하고 observer·취소 정리까지 발견을 하나만
  유지한다. 활성 중 pulse는 합쳐지며 새 의무는 다음 maintenance가 fresh하게 읽는다.
  원래 marker 순서·부분 오류·완전 스캔 뒤 held hint 정리·회차별 backend presence를
  보존하고, 발견 실패나 observer 실패로 이미 예약한 원래 job을 취소하지 않는다.

- 준비된 Composition의 maintenance `pulse`와 원래 owned-job 결과가 durable해진 뒤의
  `notify_result_ready`는 같은 발견 drain에 수요를 남기고 반환한다. 첫 조회 전 수요는
  공유하고 조회·관측 중 수요는 후속 fresh pass로 남긴다. 알림에는 원래 canonical workspace·
  Keeper·typed result 의존성을 남긴다. 결과 알림 pass도 모든 marker·journal·terminal 권위를
  확인하고, 해당 원래 의존성을 가진 실행만 모든 결과의 readiness를 새로 읽는다. 의존성 없는
  Lost 복구는 보수적으로 포함한다. 정기 maintenance가 대기 알림을 전체 검사로 승격한다.
  선택 밖의 결과는 미조회 `unselected`로 관측하며 waiting·성공으로 바꾸지 않는다. 전체 marker
  탐색·회차별 typed-key index 구성/조회·중복 알림 보관 비용은 남는다. index 순서로 marker를
  재정렬하거나 다음 회차에 재사용하지 않고 전체 오류 관측은 maintenance에서 이어진다.
  실제 결과는 원래 base path와 typed `Journal.error`를 유지한 `on_discovery`에서 관측한다. 예외로 반환하지 못한 pass를
  정상/오류 반환 횟수에 넣지 않고 raised로 구분한다. observer의 일반 실패 뒤에도 새 수요를
  확인한다. 각 pass의 첫 실제 수요에서 선언 projection을 새로 공유하며 다음 pass에 빌리지
  않는다. 알림 도착을 intake·Task 재개·효과 허가로 기록하지 않는다. drain의 identity와
  순수한 예약 해제·취소 정리를 지키고 같은 lifetime switch를 사용한다. 유지보수/알림 횟수는
  관측일 뿐 제한값이 아니다. timer·재시도 간격·결과/프로필 cache를 만들지 않는다.

소스 패턴이나 임의 개수 상한으로 구현을 제한하지 않는다. 타입 검사와 실제 동작 테스트로 변경을 검증하고, 로컬 빌드와 CI 실행 시점은 헌법의 실행 프로토콜을 따른다.

## 4. Mutex 고르기

Eio 인터페이스(`eio_mutex.mli`)가 말하는 차이: `Stdlib.Mutex` 는 기다리는 동안 도메인 전체를 막고,
`Eio.Mutex` 는 기다리는 동안 다른 fiber 를 돌린다.

| 상황 | 선택 |
|---|---|
| 잠근 구간에서 I/O 를 하거나 fiber 가 바뀔 수 있다 | `Eio.Mutex` |
| 잠근 구간이 짧고 fiber 가 바뀌지 않는다 | `Stdlib.Mutex` |
| 모듈 초기화처럼 Eio 문맥 밖에서 잡힌다 | `Stdlib.Mutex` |
| `Eio_main.run` 없이 테스트에서 불린다 | `Stdlib.Mutex` |

- `Eio.Mutex.use_rw ~protect t fn`: `fn` 이 예외를 내면 mutex 가 못 쓰게 된다(`Poisoned`).
  `~protect:true` 는 잠근 구간을 취소에서 보호한다. 잠금을 기다리는 동안은 보호하지 않는다.
- 취소 중에도 반드시 끝내야 하는 짧은 등록 해제는 mutex를 잡기 전부터 보호한다.
  `keeper_msg_async`의 종료 경로는 terminal 저장·알림을 예외 안전한 정리로 감싸고,
  닫힌 request switch 등록을 제거한다. 실제 switch 해제, canonical terminal 저장,
  알림 callback의 취소와 등록 해제를 각각 구분한다. 알림 실패를 원래 결과의 실패나
  worker 중단으로 바꾸지 않고, 이 bookkeeping 수정을 실행 시간 개선으로 기록하지 않는다.
- `Eio.Mutex.use_ro t fn`: 읽기만 할 때. 예외가 나도 풀고 넘어간다.
- 한 도메인 안에서만 도는 코드는 막히는 연산을 하기 전에는 fiber 가 바뀌지 않는다. mutex 가 필요 없을 수 있다.
- mutex 로 감싸는 방식을 바꾸면 `rg -n '<함수 이름>' test/` 로 테스트 호출을 전부 센다.
  `Eio_main.run` 밖에서 부르는 테스트가 있으면 같이 고친다.

## 5. Lazy 고르기

- `Stdlib.Lazy.force` 는 동시에 안전하지 않다. 여러 fiber·systhread·도메인이 한 값을 동시에
  force 하면 `Lazy.Undefined` 가 날 수 있다(`lazy.mli`).
- Eio fiber 여럿이 force 하는 값은 `Eio.Lazy.from_fun ~cancel fn`.
  - `` `Restart ``: force 하던 fiber 가 취소되면 기다리던 다음 fiber 가 `fn` 을 다시 돌린다.
  - `` `Record ``: 취소를 기록하고 그 뒤로는 계속 취소로 답한다.
  - `` `Protect ``: force 하는 동안 취소를 막는다.
- 여러 도메인·systhread 가 쓰지만 Eio 밖인 값은 `Lazy.Mutexed`(5.5 부터). 내부에서 `Stdlib.Mutex` 로
  기다리므로 Eio fiber 에서 쓰면 도메인을 막는다.
- 테스트나 모듈 초기화에서만 force 되는 값은 `Stdlib.Lazy` 로 두고, 왜 괜찮은지 주석을 단다.

## 6. 자원 정리

```ocaml
Eio.Switch.run @@ fun sw ->
let flow = open_flow ~sw in
Eio.Switch.on_release sw (fun () -> Eio.Flow.close flow);
use flow
```

- `Switch.on_release` 의 정리 함수는 `Cancel.protect` 안에서 돈다. 스위치가 이미 취소됐어도
  정리가 끊기지 않는다. 등록 역순으로 하나씩 돌고, 정리 함수의 예외는 스위치 실패로 넘어간다.
- `Fun.protect ~finally work`: `finally` 가 예외를 내면 `Fun.Finally_raised` 로 바뀌고 `work` 의 원래
  예외는 사라진다(`fun.mli`). 취소된 fiber 의 `finally` 에서 취소될 수 있는 Eio 연산을 부르면 그 연산이
  다시 `Cancelled` 를 내고, 원래 오류가 묻힌다.
- 막히거나 fiber를 바꾸는 정리는 `Switch.on_release`로 옮긴다. 순수 동기 정리(`close_in ic` 등)만 `Fun.protect`에 둔다.

## 7. 막히는 I/O 와 무거운 계산

Eio 는 협력형 스케줄러다. 취소와 시간 초과는 fiber 가 멈추는 지점에서만 먹힌다.

- `Eio.Time.with_timeout clock d fn` 은 `fn` 을 `d` 초 뒤 취소한다. `fn` 이 `Sys.readdir`,
  `Unix.read`, CPU 루프처럼 Eio 로 양보하지 않으면 끝날 때까지 안 끊긴다.
- Keeper 런타임과 제품 흐름에는 없어도 되는 시간 초과를 두지 않는다(헌법 `budget_gate`).
  시간 초과를 넣기 전에 그 대기가 끝나지 않는 경우가 실제로 무엇인지부터 적는다.
- 막히는 표준 라이브러리 호출: `Eio_unix.run_in_systhread (fun () -> ...)`
- 파일: `Eio.Path` (Eio 로 양보한다)
- 무거운 순수 계산: `Domain_pool_ref.submit_cpu_or_inline (fun () -> ...)`
- MASC의 실제 pool 제출은 `Domain_pool.submit_io`·`submit_cpu` 또는
  `Executor_pool_ref.submit_*`를 사용한다. 공통 제출 구현은 caller 취소를 실제
  worker에 전달하고 진입한 작업의 정리를 기다린다. raw `Eio.Executor_pool`의
  결과 대기 취소만으로 worker가 끝났다고 판단하지 않는다.
- worker가 effect 이후 예외를 던졌으면 그 함수를 caller에서 다시 실행하지
  않는다. inline 실행은 pool 부재·Eio 밖·기존 worker 정책이 정하는 진입 경로다.
  비동기 제출의 소유 Switch 취소와 그 promise를 관측하던 fiber의 취소도 구분한다.
- HTTP 핸들러 안에서 무거운 계산을 직접 하지 않는다. 핸들러가 멈추면 같은 도메인의 다른 요청도 멈춘다.
  대시보드 스냅샷처럼 뒤에서 미리 계산해 두고 핸들러는 마지막 값만 읽게 한다. 계산 실패는 삼키지
  않고 알린 뒤 마지막 값을 유지한다.

  ```ocaml
  let start_refresh ~sw ~clock ~interval ~compute ~on_error latest =
    Eio.Fiber.fork ~sw (fun () ->
        let rec loop () =
          (match compute () with
           | Ok snapshot -> latest := Some snapshot
           | Error err -> on_error err);
          Eio.Time.sleep clock interval;
          loop ()
        in
        loop ())
  ```

  `compute` 가 예외 대신 `Result` 를 돌려주게 만든다. 여기서 `try ... with _ -> ()` 로 감싸면
  계산 실패도 취소도 조용히 사라진다(2절).

## 8. API 를 바꿀 때는 .mli 먼저

인터페이스·생성자·인자를 바꾸거나 `.mli` 와 `.ml` 짝을 고칠 때 이 절의 전체 점검표를 연다.
Keeper 는 `keeper_skill` 을 같은 `identity` 에 `file = "references/mli-first.md"` 로 부른다.
파일: [references/mli-first.md](references/mli-first.md)

## 9. 표준 라이브러리 — 있을 거라고 착각하기 쉬운 것

다른 언어의 짝을 떠올려 호출을 지어내기 쉽다. 헷갈리면 5.5 API 문서를 먼저 연다.

| 호출 | 5.5 에서 | 비고 |
|---|---|---|
| `Unix.unsetenv` | 있다 (5.5 부터) | 이 저장소 테스트가 이미 쓴다 |
| `Sys.unsetenv` | 없다 | `Unix.unsetenv` 를 쓴다 |
| `Unix.putenv k ""` | 있다 | 지우는 게 아니다. `Sys.getenv_opt k` 는 `Some ""` 을 준다 |
| `List.take` / `List.drop` | 있다 (5.3 부터) | 음수면 `Invalid_argument` |
| `String.starts_with ~prefix` | 있다 (4.13 부터) | 분기 판단에 쓰지 않는다(1절) |
| `Option.get_or` | 없다 | `match` 로 쓴다(3절) |
| `Lazy.Mutexed` | 있다 (5.5 부터) | 5절 |

같은 함수에서 "Unbound value" 가 두 번 나오면 그 함수가 있는지부터 의심하고 인터페이스를 연다.

## 쓰고 나서 훑어보기

```sh
rg -n 'with _ ->|\| exception _ ->|with [a-z_]+ ->' <file>   # 2절
rg -n 'Option\.value.*~default:|\| *_ *-> *Some' <file>       # 3절
rg -n 'Fun\.protect' <file>                                    # 6절: finally 안에 Eio 연산이 있나
rg -n 'Stdlib\.Lazy|lazy \(' <file>                            # 5절: 여러 fiber 가 force 하나
rg -n 'failwith|assert false' <file>                           # 1절
rg -n 'Sys\.readdir|Unix\.(read|write|sleep)' <file>           # 7절: Eio 문맥에서 막히나
```
