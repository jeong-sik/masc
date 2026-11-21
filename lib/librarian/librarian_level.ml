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

let held_now ~now (basis : Digest.digest) =
  match now with
  | Some (now : Digest.digest) -> String.equal (now :> string) (basis :> string)
  | None -> false
;;

let running (t : Machine.t) ~unread =
  let now = snapshot_now t.state in
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
    | Some (Committed | Lane _) | None -> false
  in
  (* The model's OneItemRefusal with no silent slot, about the snapshot now:
     a write since then is another question, so the old verdict is off. *)
  let e4 =
    match t.state with
    | Resting (_ : Store.t) ->
      (match t.last_read with
       | Some (Lane { one_item; silent; basis; slots = _ }) ->
         one_item && (not silent) && held_now ~now basis
       | Some (Committed | Input_fault _ | Ask_failed _) | None -> false)
    | Idle _ | Asking _ | Refused_at_bottom _ | Stopped _ -> false
  in
  let e5 =
    match t.last_room, t.lane with
    | Some (Fits_none { memory; lane }), Some (declared : Machine.declared) ->
      held_now ~now memory && Memory_lane.equal lane declared.value
    | Some (Fits_none _), None -> false
    | Some (Made | Unchanged | Stale | Not_judged), (Some _ | None) | None, (Some _ | None) -> false
  in
  let w1 =
    unread
    &&
    match t.lane, t.last_read with
    | None, (Some _ | None) -> true
    | Some (_ : Machine.declared), (None | Some (Lane _)) -> true
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
