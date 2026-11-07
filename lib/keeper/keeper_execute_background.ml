module Outbox = Keeper_client_tool_outbox

let tool_name = "tool_execute"

(* The outbox format keeps a vendor session id in [thread_id] and a vendor turn
   id in [turn_id]. A background run has neither, so the first names the
   producer and the second repeats the request id. [call_id] is the request id
   the start result gave the model. *)
let producer_label = "execute_background"

(* Key of the producer context kept in the request record. *)
let context_key = "execute_background"

let arguments_field = "arguments"

type ending =
  | Finished of Keeper_tool_execution.t
  | Unfinished of { cause : string }

let restart_cause =
  "The server restarted before this run was recorded as finished. The command \
   may not have started, may have run to its end, or may have stopped partway. \
   Inspect the state it changes before running it again."

let cancelled_cause =
  "The run was cancelled before the command finished, by an operator or by a \
   server stop. Its exit status was not recorded. Inspect the state the \
   command changes before running it again."

let raised_cause ~detail =
  Printf.sprintf
    "Execute raised before it returned a result (%s). Its exit status was not \
     recorded. Inspect the state the command changes before running it again."
    detail

let response_json ~request_id = function
  | Finished (execution : Keeper_tool_execution.t) ->
    `Assoc
      [ "request_id", `String request_id
      ; ( "outcome"
        , `String
            (Tool_result.string_of_disposition execution.Keeper_tool_execution.disposition) )
      ; ( "result"
        , match execution.Keeper_tool_execution.data with
          | Some data -> data
          | None -> `String execution.Keeper_tool_execution.raw_output )
      ]
  | Unfinished { cause } ->
    `Assoc
      [ "request_id", `String request_id
      ; "outcome", `String "unfinished"
      ; "result", `Assoc [ "ok", `Bool false; "message", `String cause ]
      ]
;;

let receipt ~request_id ~arguments ending : Outbox.receipt =
  { thread_id = producer_label
  ; turn_id = request_id
  ; call_id = request_id
  ; tool_name
  ; arguments
  ; response = response_json ~request_id ending
  }
;;

let started_json ~request_id =
  `Assoc
    [ "ok", `Bool true
    ; "status", `String "started"
    ; "request_id", `String request_id
    ; ( "delivery"
      , `String
          "async: the command runs on the server until it exits or reaches \
           timeout_sec. Its result arrives as a tool-result receipt that wakes \
           you, and the receipt carries this request_id." )
    ]
;;

(* The receipt is committed even when the wake cannot be: the maintenance
   pulse finds a retained receipt on its next pass. *)
let deliver ~base_path ~keeper_name ~request_id ~arguments ending =
  match Outbox.retain ~base_path ~keeper_name (receipt ~request_id ~arguments ending) with
  | Error detail -> Error detail
  | Ok () ->
    (match Keeper_client_tool_outbox_wake.notify ~base_path ~keeper_name with
     | Ok () -> ()
     | Error detail ->
       Log.Keeper.warn
         ~keeper_name
         "execute background %s: wake deferred: %s"
         request_id
         detail
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn ->
       Log.Keeper.warn
         ~keeper_name
         "execute background %s: wake raised: %s"
         request_id
         (Printexc.to_string exn));
    Ok ()
;;

(* What [Keeper_msg_async] keeps as the request's own result, for a poller. The
   receipt is the model's copy. *)
let async_result ~start_time (execution : Keeper_tool_execution.t) =
  match execution.Keeper_tool_execution.disposition with
  | Tool_result.Completed () | Tool_result.Deferred () ->
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ?data:execution.Keeper_tool_execution.data
      ()
  | Tool_result.Failed class_ ->
    Tool_result.make_err
      ~tool_name
      ~class_
      ~start_time
      ?data:execution.Keeper_tool_execution.data
      ~effect_disposition:execution.Keeper_tool_execution.failure_effect_disposition
      execution.Keeper_tool_execution.raw_output
;;

let record_unfinished ~base_path ~keeper_name ~request_id ~arguments ~cause =
  match deliver ~base_path ~keeper_name ~request_id ~arguments (Unfinished { cause }) with
  | Ok () -> ()
  | Error detail ->
    Log.Keeper.warn
      ~keeper_name
      "execute background %s: receipt not written: %s"
      request_id
      detail
;;

(* The cancellation arm writes its receipt before it re-raises, so the receipt
   exists before [Keeper_msg_async] records the request as cancelled. *)
let worker ~config ~meta ~arguments ~run ~request_id request_sw =
  let start_time = Tool_timing.start () in
  let keeper_name = meta.Keeper_meta_contract.name in
  let base_path = config.Workspace.base_path in
  Eio_context.with_turn_switch request_sw
  @@ fun () ->
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Eio.Switch.on_release request_sw (fun () -> Keeper_sandbox_factory.cleanup factory);
  match run ~turn_sandbox_factory:(Some factory) with
  | execution ->
    (match deliver ~base_path ~keeper_name ~request_id ~arguments (Finished execution) with
     | Ok () -> async_result ~start_time execution
     | Error detail ->
       Log.Keeper.warn
         ~keeper_name
         "execute background %s: receipt not written: %s"
         request_id
         detail;
       Tool_result.make_err
         ~tool_name
         ~class_:Tool_result.Runtime_failure
         ~start_time
         ~effect_disposition:Tool_result.Proven_post_effect
         (Printf.sprintf "The command ended but its receipt was not written: %s" detail))
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    Eio.Cancel.protect (fun () ->
      record_unfinished
        ~base_path
        ~keeper_name
        ~request_id
        ~arguments
        ~cause:cancelled_cause);
    raise exn
  | exception exn ->
    let cause = raised_cause ~detail:(Printexc.to_string exn) in
    record_unfinished ~base_path ~keeper_name ~request_id ~arguments ~cause;
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Runtime_failure
      ~start_time
      ~effect_disposition:Tool_result.Effect_outcome_unknown
      cause
;;

let refusal ~class_ ?(effect_disposition = Tool_result.Proven_pre_effect) fields message =
  Keeper_tool_execution.failure
    ~class_
    ~effect_disposition
    (Yojson.Safe.to_string
       (`Assoc ([ "ok", `Bool false; "message", `String message ] @ fields)))
;;

let defer ~config ~meta ~args run =
  let keeper_name = meta.Keeper_meta_contract.name in
  let base_path = config.Workspace.base_path in
  if not (Keeper_client_tool_outbox_wake.route_can_consume meta)
  then
    refusal
      ~class_:Tool_result.Dependency_unavailable
      []
      "run_in_background needs a runtime route that can receive tool-result \
       receipts, and this Keeper's route cannot. Nothing was started."
  else (
    match Keeper_msg_async.server_background_switch () with
    | Error error ->
      refusal
        ~class_:Tool_result.Dependency_unavailable
        [ "error", Keeper_msg_async.submit_error_to_json error ]
        "The server-lifetime switch is not available. Nothing was started."
    | Ok background_sw ->
      (match
         Keeper_msg_async.submit_with_request_id
           ~request_context:[ context_key, `Assoc [ arguments_field, args ] ]
           ~background_sw
           ~base_path
           ~caller:keeper_name
           ~f:(fun ~request_id request_sw ->
             worker ~config ~meta ~arguments:args ~run ~request_id request_sw)
           ~keeper_name
           ()
       with
       | Error error ->
         refusal
           ~class_:Tool_result.Runtime_failure
           [ "error", Keeper_msg_async.submit_error_to_json error ]
           "The background run was not accepted. Nothing was started."
       | Ok { Keeper_msg_async.request_id; acceptance = Durably_accepted } ->
         Log.Keeper.info ~keeper_name "execute background %s durably accepted" request_id;
         Keeper_tool_execution.success_data (started_json ~request_id)
       | Ok
           { Keeper_msg_async.request_id
           ; acceptance = Reconciliation_required { reason }
           } ->
         Log.Keeper.warn
           ~keeper_name
           "execute background %s acceptance uncertain: %s"
           request_id
           reason;
         refusal
           ~class_:Tool_result.Runtime_failure
           ~effect_disposition:Tool_result.Effect_outcome_unknown
           [ "request_id", `String request_id; "reason", `String reason ]
           "The background run may have started. Its acceptance could not be \
            confirmed. Inspect the state the command changes before running it \
            again."))
;;

let unfinished_entry (entry : Keeper_msg_async.entry) =
  match entry.Keeper_msg_async.request_context with
  | None -> None
  | Some context ->
    (match List.assoc_opt context_key context with
     | Some (`Assoc fields) ->
       Option.map
         (fun arguments -> entry, arguments)
         (List.assoc_opt arguments_field fields)
     | Some _ | None -> None)
;;

let deliver_unfinished_runs ~base_path =
  match Keeper_msg_async.read_durable_active_inventory ~base_path with
  | Error _ ->
    Log.Server.warn
      "execute background: active request inventory not readable; unfinished runs \
       get no receipt"
  | Ok inventory ->
    List.iter
      (fun (entry : Keeper_msg_async.entry) ->
         match unfinished_entry entry with
         | None -> ()
         | Some (entry, arguments) ->
           record_unfinished
             ~base_path
             ~keeper_name:entry.Keeper_msg_async.keeper_name
             ~request_id:entry.Keeper_msg_async.request_id
             ~arguments
             ~cause:restart_cause)
      inventory.Keeper_msg_async.entries
;;

module For_testing = struct
  let receipt_of_unfinished ~request_id ~arguments ~cause =
    receipt ~request_id ~arguments (Unfinished { cause })
  ;;

  let receipt_of_execution ~request_id ~arguments execution =
    receipt ~request_id ~arguments (Finished execution)
  ;;

  let started_json = started_json
  let restart_cause = restart_cause
end
