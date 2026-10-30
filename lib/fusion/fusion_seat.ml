(* Fusion 자리 (구현). 계약: fusion_seat.mli *)

type route_failure =
  | Unknown_route of string
  | Route_unavailable of string

type candidates =
  { first : string
  ; rest : string list
  }

let resolve route =
  match Runtime.resolve_assignment (String.trim route) with
  | `Lane lane ->
    (match Runtime_lane.ordered_candidates lane with
     | first :: rest -> Ok { first; rest }
     (* 설정 로드가 후보 없는 lane 을 거절한다. 그래도 이 갈래가 닿으면 적힌 이름으로
        실패를 남긴다 — 기본 런타임으로 대신하지 않는다. *)
     | [] -> Error (Unknown_route route))
  | `Unavailable missing ->
    Error (Route_unavailable (Runtime.missing_catalog_model_to_string missing))
  | `Missing -> Error (Unknown_route route)
;;

type ('answer, 'failure) walk =
  | Answered of
      { answer : 'answer
      ; runtime : string
      ; failed : (string * 'failure) list
      }
  | Exhausted of
      { last : 'failure
      ; failed : (string * 'failure) list
      }

let walk { first; rest } ~attempt =
  let rec go runtime rest failed_rev =
    match attempt runtime with
    | Ok answer -> Answered { answer; runtime; failed = List.rev failed_rev }
    | Error failure ->
      let failed_rev = (runtime, failure) :: failed_rev in
      (match rest with
       | next :: rest -> go next rest failed_rev
       | [] -> Exhausted { last = failure; failed = List.rev failed_rev })
  in
  go first rest []
;;

let seat_attempts ~to_attempt_failure failed =
  List.map
    (fun (runtime, failure) ->
       { Fusion_types.attempt_runtime = runtime
       ; attempt_failure = to_attempt_failure failure
       })
    failed
;;

let seat_route ~seat ~route ~to_attempt_failure walk : Fusion_types.seat_route =
  match walk with
  | Answered { runtime; failed; answer = _ } ->
    { Fusion_types.seat
    ; route
    ; answered_by = Some runtime
    ; failed_attempts = seat_attempts ~to_attempt_failure failed
    }
  | Exhausted { failed; last = _ } ->
    { Fusion_types.seat
    ; route
    ; answered_by = None
    ; failed_attempts = seat_attempts ~to_attempt_failure failed
    }
;;

let unresolved_seat_route ~seat ~route : Fusion_types.seat_route =
  { Fusion_types.seat; route; answered_by = None; failed_attempts = [] }
;;
