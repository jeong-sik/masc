type prefix_mismatch =
  | Prefix_longer_than_messages
  | Prefix_message_mismatch

type restore_error =
  | Projected_checkpoint_prefix_mismatch of
      { canonical_mismatch : prefix_mismatch
      ; dispatch_mismatch : prefix_mismatch
      }
  | Projected_checkpoint_current_input_mismatch

type current_input =
  { canonical_input : Agent_core.Types.message
  ; dispatch_input : Agent_core.Types.message
  }

type projection =
  | Unchanged
  | Media_degraded of
      { canonical_prefix : Agent_core.Types.message list
      ; dispatch_prefix : Agent_core.Types.message list
      ; current_input : current_input option
      }

let unchanged = Unchanged

(* TEL-OK: pure typed projection constructor; provider dispatch and checkpoint
   persistence callers own telemetry at their action boundaries. *)
let media_degraded ~canonical_prefix ~dispatch_prefix =
  Media_degraded { canonical_prefix; dispatch_prefix; current_input = None }
;;

let media_degraded_with_current_input
    ~canonical_prefix ~dispatch_prefix ~canonical_input ~dispatch_input =
  Media_degraded
    { canonical_prefix; dispatch_prefix
    ; current_input = Some { canonical_input; dispatch_input }
    }
;;

let rec split ~(prefix : Agent_core.Types.message list) messages =
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
  | Media_degraded { canonical_prefix; dispatch_prefix; current_input } ->
    let restore_input suffix =
      match current_input, suffix with
      | None, _ -> Ok suffix
      | Some { canonical_input; dispatch_input }, actual :: rest
        when actual = canonical_input || actual = dispatch_input ->
        Ok (canonical_input :: rest)
      | Some _, _ -> Error Projected_checkpoint_current_input_mismatch
    in
    let canonical = split ~prefix:canonical_prefix checkpoint_messages in
    let dispatch = split ~prefix:dispatch_prefix checkpoint_messages in
    let restore suffix = Result.map (fun suffix -> canonical_prefix @ suffix) (restore_input suffix) in
    (match canonical, dispatch with
     | Ok suffix, _ ->
       (match restore suffix with
        | Ok _ as restored -> restored
        | Error _ as error ->
          (match dispatch with
           | Ok suffix -> restore suffix
           | Error _ -> error))
     | Error _, Ok suffix -> restore suffix
     | Error canonical_mismatch, Error dispatch_mismatch ->
       Error
         (Projected_checkpoint_prefix_mismatch
            { canonical_mismatch; dispatch_mismatch }))
;;

let restore_checkpoint projection (checkpoint : Agent_core.Checkpoint.t) =
  match restore_messages projection checkpoint.messages with
  | Error error -> Error error
  | Ok messages -> Ok { checkpoint with messages }
;;

let prefix_mismatch_to_string = function
  | Prefix_longer_than_messages -> "prefix_longer_than_messages"
  | Prefix_message_mismatch -> "prefix_message_mismatch"
;;

let restore_error_to_string = function
  | Projected_checkpoint_current_input_mismatch ->
    "media-degraded checkpoint current User input is missing or differs from the exact canonical and dispatch input"
  | Projected_checkpoint_prefix_mismatch
      { canonical_mismatch; dispatch_mismatch } ->
    Printf.sprintf
      "media-degraded checkpoint preserves neither canonical nor typed dispatch history prefix (canonical=%s, dispatch=%s)"
      (prefix_mismatch_to_string canonical_mismatch)
      (prefix_mismatch_to_string dispatch_mismatch)
;;
