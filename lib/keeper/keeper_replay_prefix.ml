type prefix_mismatch =
  | Prefix_longer_than_messages
  | Prefix_message_mismatch

type restore_error =
  | Projected_checkpoint_prefix_mismatch of
      { canonical_mismatch : prefix_mismatch
      ; dispatch_mismatch : prefix_mismatch
      }

type projection =
  | Unchanged
  | Media_degraded of
      { canonical_prefix : Agent_sdk.Types.message list
      ; dispatch_prefix : Agent_sdk.Types.message list
      }

let unchanged = Unchanged

(* TEL-OK: pure typed projection constructor; provider dispatch and checkpoint
   persistence callers own telemetry at their action boundaries. *)
let media_degraded ~canonical_prefix ~dispatch_prefix =
  Media_degraded { canonical_prefix; dispatch_prefix }
;;

let rec split ~(prefix : Agent_sdk.Types.message list) messages =
  match prefix, messages with
  | [], suffix -> Ok suffix
  | _ :: _, [] -> Error Prefix_longer_than_messages
  | expected :: prefix_rest, actual :: message_rest ->
    if expected = actual
    then split ~prefix:prefix_rest message_rest
    else Error Prefix_message_mismatch
;;

let restore_messages projection checkpoint_messages =
  match projection with
  | Unchanged -> Ok checkpoint_messages
  | Media_degraded { canonical_prefix; dispatch_prefix } ->
    (match split ~prefix:canonical_prefix checkpoint_messages with
     | Ok _already_canonical_suffix -> Ok checkpoint_messages
     | Error canonical_mismatch ->
       (match split ~prefix:dispatch_prefix checkpoint_messages with
        | Ok current_turn_suffix -> Ok (canonical_prefix @ current_turn_suffix)
        | Error dispatch_mismatch ->
          Error
            (Projected_checkpoint_prefix_mismatch
               { canonical_mismatch; dispatch_mismatch })))
;;

let restore_checkpoint projection (checkpoint : Agent_sdk.Checkpoint.t) =
  match restore_messages projection checkpoint.messages with
  | Error error -> Error error
  | Ok messages -> Ok { checkpoint with messages }
;;

let prefix_mismatch_to_string = function
  | Prefix_longer_than_messages -> "prefix_longer_than_messages"
  | Prefix_message_mismatch -> "prefix_message_mismatch"
;;

let restore_error_to_string = function
  | Projected_checkpoint_prefix_mismatch
      { canonical_mismatch; dispatch_mismatch } ->
    Printf.sprintf
      "media-degraded checkpoint preserves neither canonical nor typed dispatch history prefix (canonical=%s, dispatch=%s)"
      (prefix_mismatch_to_string canonical_mismatch)
      (prefix_mismatch_to_string dispatch_mismatch)
;;
