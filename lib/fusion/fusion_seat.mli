(** Fusion 자리 — 경로 이름을 후보 목록으로 풀고, 후보를 차례로 시도한다.

    panel 한 명과 judge 하나가 각각 한 자리다. 자리에 적힌 값은 경로 이름이며
    Keeper 배정과 같은 규칙으로 푼다: [\[runtime.lanes.<이름>\]] 이 있으면 그 lane 의
    후보, 없고 런타임 id 이면 그 런타임 하나. 한 자리는 후보를 적힌 순서로 시도하고
    처음 쓸 수 있는 답에서 멈춘다. 실패는 종류와 상관없이 다음 후보로 넘어간다 —
    Fusion 자리는 답만 내고 밖에 효과를 남기지 않는다.

    설계: docs/rfc/RFC-fusion-seat-routes.md §2.1-2.3 *)

type route_failure =
  | Unknown_route of string  (** 적힌 이름이 lane 도 런타임도 아니다. *)
  | Route_unavailable of string
      (** 런타임의 카탈로그 행이 없다. payload 는
          [Runtime.missing_catalog_model_to_string] 이다. *)

(** 비어 있지 않은 후보 목록. 첫 후보와 나머지로 나눠, 시도가 한 번도 없는 walk 를
    타입으로 없앤다. *)
type candidates =
  { first : string
  ; rest : string list
  }

val resolve : string -> (candidates, route_failure) result
(** [Runtime.resolve_assignment] 로 푼다. 후보가 없는 lane 은 설정 로드가 거절하므로
    [`Lane] 은 항상 후보가 있다. *)

val candidate_list : candidates -> string list

type ('answer, 'failure) walk =
  | Answered of
      { answer : 'answer
      ; runtime : string  (** 답을 낸 후보 *)
      ; failed : (string * 'failure) list  (** 그 전에 실패한 후보, 순서대로 *)
      }
  | Exhausted of
      { last : 'failure  (** 마지막 후보의 실패 *)
      ; failed : (string * 'failure) list  (** 시도 전부, 순서대로. 마지막 포함 *)
      }

val walk
  :  candidates
  -> attempt:(string -> ('answer, 'failure) result)
  -> ('answer, 'failure) walk
(** 후보를 순서대로 [attempt] 에 넘기고 처음 [Ok] 에서 멈춘다. 그 뒤 후보는 부르지
    않는다. *)

val seat_route
  :  seat:Fusion_types.seat
  -> route:string
  -> to_attempt_failure:('failure -> Fusion_types.attempt_failure)
  -> ('answer, 'failure) walk
  -> Fusion_types.seat_route

val unresolved_seat_route : seat:Fusion_types.seat -> route:string -> Fusion_types.seat_route
(** 경로를 못 푼 자리의 기록. 시도가 없으므로 [failed_attempts] 는 비어 있다. *)
