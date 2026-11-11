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

(* What every unfinished receipt says about the command itself. *)
let effect_unknown =
  "The command may not have started, may have run to its end, or may have \
   stopped partway. Inspect the state it changes before running it again."

let restart_cause =
  "The server restarted before this run was recorded as finished. " ^ effect_unknown
;;

let cancelled_cause = function
  | Keeper_msg_async.Operator_request ->
    "An operator cancelled the run before its exit status was recorded. "
    ^ effect_unknown
  | Keeper_msg_async.Runtime_cancellation ->
    "The server runtime cancelled the run before its exit status was recorded. "
    ^ effect_unknown
;;

let raised_cause ~detail =
  Printf.sprintf
    "Execute raised before it returned a result (%s). Its exit status was not \
     recorded. %s"
    detail
    effect_unknown
;;

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

(* The request controls of the composition surface take any [Keeper_msg_async]
   request id and the caller that submitted it: [poll] and [cancel] do not look
   at what produced the request. A background run is such a request, so the
   start result names them. They are held back like the other deferred tools
   and need the loader first. *)
let delivery_text =
  Printf.sprintf
    "async: the command runs on the server until it exits or reaches \
     timeout_sec. Its result arrives as a tool-result receipt that wakes you, \
     and the receipt carries this request_id. With this request_id, %s reads \
     the run and %s asks to stop it; %s loads either."
    Keeper_tool_composition_catalog.status_tool_name
    Keeper_tool_composition_catalog.cancel_tool_name
    Keeper_identity_tool_search.tool_name
;;

(* An Execute payload, so that a composition plan node which sets
   [run_in_background] passes the output schema the executor validates against:
   [status] is an object with a [kind], and [typed] and the call time are
   present. [kind] is [started] where a finished call has [exit]. *)
let started_json ~request_id ~elapsed_ms =
  `Assoc
    [ "ok", `Bool true
    ; "status", `Assoc [ "kind", `String "started" ]
    ; "request_id", `String request_id
    ; "delivery", `String delivery_text
    ; "typed", `Bool true
    ; Keeper_tool_execute_runtime.execution_time_field, `Int elapsed_ms
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

(* The Keeper holds a receipt for the run when the end of the command was
   written before the request was settled. An [unfinished] receipt after that
   would tell the model the command ended and also that it may not have
   started. An execution that owns the receipt still holds it, so the read
   sees every receipt. *)
let holds_receipt ~base_path ~keeper_name ~request_id =
  Result.map
    (fun snapshot -> Outbox.contains_call snapshot ~call_id:request_id)
    (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt)
;;

let deliver_unfinished_unless_held ~base_path ~keeper_name ~request_id ~arguments ~cause =
  match holds_receipt ~base_path ~keeper_name ~request_id with
  | Error detail -> Error detail
  | Ok true -> Ok ()
  | Ok false ->
    deliver ~base_path ~keeper_name ~request_id ~arguments (Unfinished { cause })
;;

let record_unfinished ~base_path ~keeper_name ~request_id ~arguments ~cause =
  match
    deliver_unfinished_unless_held ~base_path ~keeper_name ~request_id ~arguments ~cause
  with
  | Ok () -> ()
  | Error detail ->
    Log.Keeper.warn
      ~keeper_name
      "execute background %s: receipt not written: %s"
      request_id
      detail
;;

(* A cancellation that cuts the worker while the command runs is not caught
   here. [Keeper_msg_async] calls the abort callback of [defer] for it, before
   it records the request as cancelled, and that callback writes the receipt.
   The two writes below happen after the command's end is known, so each is
   protected: a cancellation that arrives during them must not drop the
   receipt. *)
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
    (match
       Eio.Cancel.protect (fun () ->
         deliver ~base_path ~keeper_name ~request_id ~arguments (Finished execution))
     with
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
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    let cause = raised_cause ~detail:(Printexc.to_string exn) in
    Eio.Cancel.protect (fun () ->
      record_unfinished ~base_path ~keeper_name ~request_id ~arguments ~cause);
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Runtime_failure
      ~start_time
      ~effect_disposition:Tool_result.Effect_outcome_unknown
      cause
;;

(* [Keeper_msg_async] calls this inside its own cancellation guard for a worker
   it cut off, whether the command was running or had not started. The request
   id is the one [on_accepted] stored. *)
let abort_receipt ~base_path ~keeper_name ~arguments ~accepted
  (Keeper_msg_async.Worker_cancelled { cancelled_by; reason = _ })
  =
  match Atomic.get accepted with
  | None -> Error "the request id of the background run was not recorded at acceptance"
  | Some request_id ->
    deliver_unfinished_unless_held
      ~base_path
      ~keeper_name
      ~request_id
      ~arguments
      ~cause:(cancelled_cause cancelled_by)
;;

let refusal ~class_ ?(effect_disposition = Tool_result.Proven_pre_effect) fields message =
  Keeper_tool_execution.failure
    ~class_
    ~effect_disposition
    (Yojson.Safe.to_string
       (`Assoc ([ "ok", `Bool false; "message", `String message ] @ fields)))
;;

let defer ~config ~meta ~args run =
  let started = Tool_timing.start () in
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
      (* The request record and the receipts are files on disk. They keep the
         arguments with credential patterns masked, as the tool-call ledger
         does; [run] has the arguments as the model sent them. *)
      let shown = Observability_redact.redact_json_value args in
      let accepted = Atomic.make None in
      (match
         Keeper_msg_async.submit_with_request_id
           ~request_context:[ context_key, `Assoc [ arguments_field, shown ] ]
           ~on_accepted:(fun request_id ->
             Atomic.set accepted (Some request_id);
             Ok ())
           ~on_worker_aborted:
             (abort_receipt ~base_path ~keeper_name ~arguments:shown ~accepted)
           ~background_sw
           ~base_path
           ~caller:keeper_name
           ~f:(fun ~request_id request_sw ->
             worker ~config ~meta ~arguments:shown ~run ~request_id request_sw)
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
         Keeper_tool_execution.success_data
           (started_json
              ~request_id
              ~elapsed_ms:(Float.to_int (Tool_timing.elapsed_ms started)))
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

let request_arguments entry = Option.map snd (unfinished_entry entry)

type lost_source =
  | Recorded_run of Yojson.Safe.t
  | Arguments_unknown

let source_lost_cause = function
  | Recorded_run _ ->
    "The run has no worker and left no receipt. " ^ effect_unknown
  | Arguments_unknown ->
    "The command of this run is not known, the run has no worker, and it left \
     no receipt. "
    ^ effect_unknown
;;

(* The wait that asked for this run is resolved by the caller afterwards, so
   this does not wake the Keeper: a wake before the wait is resolved would
   find the receipt owned and read nothing. *)
let retain_source_lost_receipt ~base_path ~keeper_name ~request_id lost =
  let arguments =
    match lost with
    | Recorded_run arguments -> arguments
    | Arguments_unknown -> `Assoc []
  in
  match holds_receipt ~base_path ~keeper_name ~request_id with
  | Error detail -> Error detail
  | Ok true -> Ok ()
  | Ok false ->
    Outbox.retain
      ~base_path
      ~keeper_name
      (receipt ~request_id ~arguments (Unfinished { cause = source_lost_cause lost }))
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
  let holds_receipt = holds_receipt
end
