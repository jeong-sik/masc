(** Approval queue bridge consumed by inline tools. *)

let list_pending_json = Keeper_approval_queue.list_pending_json
let get_pending_json = Keeper_approval_queue.get_pending_json

let resolve ~id ~decision =
  match Keeper_approval_queue.resolve ~id ~decision with
  | Ok () -> Ok ()
  | Error err -> Error (Keeper_approval_queue.resolve_error_to_string err)
;;
