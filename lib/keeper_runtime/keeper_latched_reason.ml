(** Typed persisted lifecycle latch.

    Explicit operator pauses own the durable paused axis. Ordinary
    turn/provider/task failures remain observations and cannot manufacture a
    lifecycle state. *)

type operator_actor =
  | Grpc_directive
  | Keeper_down

type t = Operator_paused of { operator_actor : operator_actor }

let operator_actor_grpc_directive = Grpc_directive
let operator_actor_keeper_down = Keeper_down

let operator_actor_to_wire = function
  | Grpc_directive -> "grpc_directive"
  | Keeper_down -> "keeper_down"
;;

let operator_actor_of_wire = function
  | "grpc_directive" -> Ok Grpc_directive
  | "keeper_down" -> Ok Keeper_down
  | other ->
    Error (Printf.sprintf "Keeper_latched_reason: unknown operator actor %S" other)
;;

let equal left right =
  match left, right with
  | Operator_paused { operator_actor = Grpc_directive },
    Operator_paused { operator_actor = Grpc_directive }
  | Operator_paused { operator_actor = Keeper_down },
    Operator_paused { operator_actor = Keeper_down } ->
    true
  | Operator_paused _, Operator_paused _ -> false
;;

let hash = function
  | Operator_paused { operator_actor = Grpc_directive } -> 0
  | Operator_paused { operator_actor = Keeper_down } -> 1
;;

let pp formatter = function
  | Operator_paused { operator_actor } ->
    Format.fprintf
      formatter
      "Operator_paused{actor=%s}"
      (operator_actor_to_wire operator_actor)
;;

let to_wire = function
  | Operator_paused { operator_actor } ->
    "operator_paused:actor=" ^ operator_actor_to_wire operator_actor
;;

let of_wire = function
  | "operator_paused:actor=grpc_directive" ->
    Ok (Operator_paused { operator_actor = Grpc_directive })
  | "operator_paused:actor=keeper_down" ->
    Ok (Operator_paused { operator_actor = Keeper_down })
  | wire ->
    Error
      (Printf.sprintf
         "Keeper_latched_reason.of_wire: retired or unknown lifecycle latch %S"
         wire)
;;

module Stable = struct
  let to_yojson = function
    | Operator_paused { operator_actor } ->
      `Assoc
        [ "kind", `String "operator_paused"
        ; "actor", `String (operator_actor_to_wire operator_actor)
        ]
  ;;

  let of_yojson = function
    | `Assoc
        [ "kind", `String "operator_paused"; "actor", `String actor ] ->
      Result.map
        (fun operator_actor -> Operator_paused { operator_actor })
        (operator_actor_of_wire actor)
    | json ->
      Error
        (Printf.sprintf
           "Keeper_latched_reason.of_yojson: retired or unknown lifecycle latch: %s"
           (Yojson.Safe.to_string json))
  ;;
end
