module Machine = Librarian_machine
module Store = Librarian_store
module Memory_lane = Librarian_memory_lane
module Digest = Agent_core.Checkpoint_objects

type alarm =
  | E1
  | E2
  | E3
  | E4
  | E5
  | W1
  | W3

type writer =
  | Booting
  | Running of
      { machine : Machine.t
      ; unread : bool
      }
  | Retired

type level =
  | Ok
  | Warn
  | Error

(* The snapshot the store's last line names: what a verdict is compared
   with. A stopped store has none, and no verdict holds for it. *)
let snapshot_now : Machine.state -> Digest.digest option = function
  | Idle { store; seen_length = (_ : int option) }
  | Asking { store; asking = (_ : Machine.asking) }
  | Resting store
  | Refused_at_bottom store -> Some (Librarian_log.snapshot_after (Store.tail store))
  | Stopped (_ : Store.stop) -> None
;;

let snapshot_held_now (t : Machine.t) (basis : Digest.digest) =
  match snapshot_now t.state with
  | Some (now : Digest.digest) -> String.equal (now :> string) (basis :> string)
  | None -> false
;;

(* A writer without a lane value holds none, and no verdict holds for it. *)
let lane_value_held_now (t : Machine.t) (value : Memory_lane.t) =
  match t.lane with
  | Some (declared : Machine.declared) -> Memory_lane.equal value declared.value
  | None -> false
;;

let running (t : Machine.t) ~unread =
  let e1 =
    match t.state with
    | Stopped (_ : Store.stop) -> true
    | Idle _ | Asking _ | Resting _ | Refused_at_bottom _ -> false
  in
  let e2 =
    match t.state with
    | Refused_at_bottom (_ : Store.t) -> true
    | Idle _ | Asking _ | Resting _ | Stopped _ -> false
  in
  let e3 =
    unread
    &&
    match t.last_read with
    | Some (Input_fault (_ : Librarian_unit.input_fault) | Ask_failed (_ : Librarian_read_result.failed)) ->
      true
    | Some (Committed | Refused_not_all_sized _ | Lane _) | None -> false
  in
  (* The model's E4 under [E4Rule = "held_now"]: the verdict the last ask
     left, about the snapshot and the lane value held now. The writer's
     state is not read, so the ask a pulse starts from the rest leaves it
     on. A write since then, or another lane value, is another question, so
     the old verdict is off. *)
  let e4 =
    unread
    &&
    match t.last_read with
    | Some (Refused_not_all_sized { basis; lane; slots = _ }) ->
      snapshot_held_now t basis && lane_value_held_now t lane
    | Some (Committed | Lane _ | Input_fault _ | Ask_failed _) | None -> false
  in
  let e5 =
    match t.last_room with
    | Some (Fits_none { memory; lane }) -> snapshot_held_now t memory && lane_value_held_now t lane
    | Some (Made | Unchanged | Stale | Not_judged) | None -> false
  in
  let w1 =
    unread
    &&
    match t.lane, t.last_read with
    | None, (Some _ | None) -> true
    | Some (_ : Machine.declared), (None | Some (Refused_not_all_sized _ | Lane _)) -> true
    | Some _, Some (Committed | Input_fault _ | Ask_failed _) -> false
  in
  List.filter_map
    (fun (on, alarm) -> if on then Some alarm else None)
    [ e1, E1; e2, E2; e3, E3; e4, E4; e5, E5; w1, W1; t.read_alone, W3 ]
;;

let alarms = function
  | Booting -> [ W1 ]
  | Running { machine; unread } -> running machine ~unread
  | Retired -> []
;;

let level alarms =
  let error = function
    | E1 | E2 | E3 | E4 | E5 -> true
    | W1 | W3 -> false
  in
  match alarms with
  | [] -> Ok
  | _ :: _ -> if List.exists error alarms then Error else Warn
;;
