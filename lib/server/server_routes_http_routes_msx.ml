(** HTTP routes for the workspace MSX machine (RFC-0439 §3.7, RFC #38695).

    Spectating the machine goes through
    [GET /api/v1/lane-addons/live?source_kind=msx_capture] (RFC #38695);
    the legacy per-machine frame route has been removed.

    [POST /api/v1/msx/press] lets the human at the TUI press keys on the same
    machine a keeper is playing (RFC-0439 §3.3): [{keys:[..], hold_frames?,
    frames?, sequence?}] goes to the attached worker under the identity
    [with_tool_actor_auth] resolved for the request, so its edges land in the
    shared ledger next to the keeper's under the name the credential carries.
    It is a write, gated like the mutating MSX tools. A field of the wrong
    type is a 400 naming the field, never a silent default. *)

open Server_auth
module Http = Http_server_eio

(* The body of a refused MSX write, from the codec the terminal decodes with.
   The caller names the code, not the HTTP status: 409 is also the activity
   gate's answer, under its own codes. *)
let write_error_json ?code message : Yojson.Safe.t = Msx_wire.encode ?code message
;;

(* Request-owned workspace admission precedes every MSX effect. The shared
   validator strips the binding so strict operation decoders retain their
   existing field contracts. The handler uses this same captured config. A
   refusal is the finished answer; only the failed precondition carries the
   [code] the terminal reads to tell a changed workspace from the activity
   refusals. *)
let decode_write_body ~config ~body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message ->
      Error (`Bad_request, write_error_json ("invalid JSON: " ^ message))
  | args -> match Workspace.validate_expected_workspace ~config args with
      | Ok args -> Ok args
      | Error Workspace.Invalid_workspace_precondition ->
          Error (`Bad_request, write_error_json "invalid expected_workspace precondition")
      | Error Workspace.Workspace_precondition_failed ->
          Error (`Conflict,
                 write_error_json ~code:Msx_wire.Workspace_precondition_failed
                   "workspace precondition failed")
;;

(* Frames a press holds its keys down, and the frames the call advances in
   all, when the body names neither (RFC-0439 §3.3): a tap. *)
let press_default_hold_frames = 5
let press_default_step_frames = 15

let press_result_json ~ok ?message (obs : Yojson.Safe.t option) =
  let fields = ["ok", `Bool ok] @ (match message with None -> [] | Some message -> ["message", `String message]) in
  let observation = match obs with
    | Some (`Assoc fields) -> List.filter (fun (name, _) -> List.mem name ["frame";"mode";"cartridge";"disk"]) fields
    | None | Some _ -> [] in
  `Assoc (fields @ observation)
;;

(* What a worker call proves about the effect it was asked for. A refusal the
   host or the worker raised before the effect began is [Proven_pre_effect]; a
   transport loss after dispatch, or a worker that cannot say, is
   [Effect_outcome_unknown]. The receipt settles from this, never from the
   message text. *)
type outcome =
  | Succeeded
  | Failed of Tool_result.failure_effect_disposition

type worker_response = {
  status : [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ];
  outcome : outcome;
  message : string;
  data : Yojson.Safe.t;
  code : Msx_wire.code option;
  machine_absent : bool;
      (** The worker answered that no machine is loaded. Typed: read from the
          worker's [errorCode] metadata, never from the message text. *)
}

let succeeded (response : worker_response) =
  match response.outcome with Succeeded -> true | Failed _ -> false

(* A worker call that returned no result. [Unavailable] and a host refusal
   precede the dispatch, so nothing ran and the caller may ask again;
   [Outcome_unknown] follows it, so the effect may have happened. Both are HTTP
   503, told apart by their code: a client that retries or stops reads the
   code, never the status or the message. *)
let call_error_response (error : Lane_addon_runtime.tool_call_error) : worker_response =
  let refused code status message =
    {status;outcome=Failed Tool_result.Proven_pre_effect;message;data=`Null;code;machine_absent=false} in
  match error with
  | Lane_addon_runtime.Unavailable message
  | Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Unavailable message) ->
      refused (Some Msx_wire.Worker_unavailable) `Service_unavailable message
  | Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Rejected message) ->
      refused None `Bad_request message
  | Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Activity_disabled message) ->
      refused (Some Msx_wire.Activity_disabled) `Conflict message
  | Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Activity_unobserved message) ->
      refused (Some Msx_wire.Activity_unobserved) `Conflict message
  | Lane_addon_runtime.Outcome_unknown message ->
      {(refused (Some Msx_wire.Outcome_unknown) `Service_unavailable
          (message ^ "; inspect the current machine before retrying"))
       with outcome=Failed Tool_result.Effect_outcome_unknown}

(* The body of a worker call that did not succeed: the shared refusal body with
   the call's typed code. *)
let failure_json (response : worker_response) =
  Msx_wire.encode ?code:response.code response.message

let call_error_answer error =
  let response = call_error_response error in
  response.status, failure_json response

let worker_response ~config ~principal ~(schema : Masc_domain.tool_schema) ~arguments =
  match Tool_input_validation.validate_args ~schema:schema.input_schema ~name:schema.name ~args:arguments () with
  | Error refusal ->
      {status=`Bad_request;outcome=Failed Tool_result.Proven_pre_effect;
       message=Tool_result.message refusal;data=`Null;code=None;machine_absent=false}
  | Ok arguments ->
      match Machine_addon_host.call_shared ~config ~principal ~name:schema.name ~arguments with
      | Error error -> call_error_response error
      | Ok result ->
          let field name = match result.Mcp_protocol.Mcp_types._meta with
            | Some (`Assoc fields) -> List.assoc_opt name fields | _ -> None in
          let ok = result.is_error <> Some true in
          let outcome =
            if ok then Succeeded
            else Failed (snd (Lane_addon_tool_result.failure result)) in
          let code = match field "io.github.jeong-sik/masc.machine.errorCode" with
            | Some (`String "activity_disabled") -> Some Msx_wire.Activity_disabled
            | Some (`String "activity_unobserved") -> Some Msx_wire.Activity_unobserved
            | _ -> None in
          let machine_absent =
            (not ok) && field "io.github.jeong-sik/masc.machine.errorCode" = Some (`String "no_machine") in
          let status = if ok then `OK else match code with
            | Some _ -> `Conflict
            | None -> match field "io.github.jeong-sik/masc.machine.failure" with
              | Some (`String "rejected") -> `Bad_request
              | _ -> `Internal_server_error in
          {status;outcome;code;machine_absent;message=Agent_core.Mcp.text_of_tool_result result;
           data=Option.value ~default:`Null result.structured_content}

let press_response ~config ~who ~body =
  let error message = `Bad_request, press_result_json ~ok:false ~message None in
  match decode_write_body ~config ~body with
  | Error refusal -> refusal
  | Ok json -> (
    match json with
    | `Assoc fields ->
      (* HTTP taps retain their shorter default; the model-facing tool uses 30. *)
      let fields = if List.mem_assoc "frames" fields then fields
        else ("frames", `Int press_default_step_frames) :: fields in
      let fields = if List.mem_assoc "hold_frames" fields then fields
        else ("hold_frames", `Int press_default_hold_frames) :: fields in
      let result = worker_response ~config ~principal:(Lane_addon_call_context.Host_actor who)
        ~schema:(Tool_schemas_misc_toml.msx_schema Msx_tool.Press) ~arguments:(`Assoc fields) in
      let fields = ["ok", `Bool (succeeded result); "message", `String result.message] in
      let fields = match result.code with
        | None -> fields
        | Some code -> ("code", `String (Msx_wire.code_to_wire code))::fields in
      let observation = if succeeded result then match result.data with
        | `Assoc data -> List.filter (fun (name,_) -> List.mem name ["frame";"mode";"cartridge";"disk"]) data
        | _ -> [] else [] in
      result.status, `Assoc (fields @ observation)
    | _ -> error "body must be a JSON object")
;;

let handle_press ~state ~who request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let config = Mcp_server.workspace_config state in
      let status, json = press_response ~config ~who ~body in
      respond_json_value_with_cors ~status:(status :> Httpun.Status.t) request reqd json)
;;

let carts_response ~config =
  let result = worker_response ~config ~principal:Lane_addon_call_context.Anonymous
    ~schema:(Tool_schemas_misc_toml.msx_schema Msx_tool.Meta) ~arguments:(`Assoc ["include_inventory", `Bool true]) in
  if not (succeeded result) then result.status, failure_json result
  else match result.data with
    | `Assoc fields -> (match List.assoc_opt "inventory" fields with
        | Some (`Assoc _ as inventory) -> `OK, inventory
        | _ -> `Internal_server_error, `Assoc ["ok", `Bool false;
            "message", `String "MSX worker omitted its cartridge inventory"])
    | _ -> `Internal_server_error, `Assoc ["ok", `Bool false;
        "message", `String "invalid MSX worker inventory response"]
;;

let load_result_json ~ok ~message : Yojson.Safe.t =
  `Assoc [ ("ok", `Bool ok); ("message", `String message) ]
;;

(* The answer to a load, disk change or unbound checkpoint: [{ok, message}] on
   success, and on failure the shared refusal body, which carries the call's
   typed code. *)
let answer_json (result : worker_response) =
  if succeeded result then load_result_json ~ok:true ~message:result.message
  else failure_json result
;;

(* The worker resolves inventory names against its persistent storage. *)
let load_response ~(config : Workspace.config) ~agent_name ~body =
  match decode_write_body ~config ~body with
  | Error refusal -> refusal
  | Ok arguments ->
      let result = worker_response ~config ~principal:(Lane_addon_call_context.Host_actor agent_name)
        ~schema:(Tool_schemas_misc_toml.msx_schema Msx_tool.Load) ~arguments in
      result.status, answer_json result
;;

let handle_load ~state ~agent_name request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let config = Mcp_server.workspace_config state in
      let status, json = load_response ~config ~agent_name ~body in
      respond_json_value_with_cors ~status:(status :> Httpun.Status.t) request reqd json)
;;

(* Frames per poll-cadence tick (RFC-0439 §3.2). At the TUI's ~3 Hz spectator
   poll this advances ~54 frames a second, close enough to the machine's 60 Hz
   that a game reads as live without a server-side ticker. *)
let msx_tick_default_frames = 18

let clamp_tick_frames requested =
  let schema = (Tool_schemas_misc_toml.msx_schema Msx_tool.Step).Masc_domain.input_schema in
  let maximum = Yojson.Safe.Util.(schema |> member "properties" |> member "frames" |> member "maximum" |> to_int) in
  max 1 (min maximum requested)

(* The terminal's frame count is bounded here, not refused: a tick that asks
   for more than a call may run advances by the most it may. *)
let decode_tick json =
  Result.map (fun (tick : Msx_wire.tick) ->
    (match tick.frames with
     | None -> msx_tick_default_frames
     | Some requested -> clamp_tick_frames requested),
    tick.pixel_response)
    (Msx_wire.decode_tick json)
;;

let tick_response ~config ~body =
  match decode_write_body ~config ~body with
  | Error refusal -> refusal
  | Ok args ->
  match decode_tick args with
  | Error message -> `Bad_request, `Assoc ["ok", `Bool false; "message", `String message]
  | Ok (frames, pixel_response) ->
      let pixels = match pixel_response with
        | Msx_wire.Full_frame -> []
        | Msx_wire.Retained_pixels known -> ["pixel_response", `String "retained"] @
            (match known with
             | None -> []
             | Some (p : Msx_wire.pixel_reference) -> ["known_pixels", `Assoc [
                 "revision", `String p.revision; "width", `Int p.width; "height", `Int p.height]]) in
      let result = worker_response ~config ~principal:Lane_addon_call_context.Operator
        ~schema:(Tool_schemas_misc_toml.msx_schema Msx_tool.Step)
        ~arguments:(`Assoc (["frames", `Int frames; "include_frame", `Bool true] @ pixels)) in
      if succeeded result then result.status, result.data
      else if result.machine_absent then
        (* The spectator polls before anything is loaded: an absent machine is
           an empty observation the poller can draw, not a failed request. *)
        `OK, `Assoc ["loaded", `Bool false]
      else result.status, Msx_wire.encode ?code:result.code result.message
;;

(* The realtime driver (RFC-0439 §2, poll-cadence tick). The spectating TUI
   posts this a few times a second to advance the shared machine, so a game
   flows even when no keeper is pressing a key. Body: {frames:N}, clamped to
   1..max_frames_per_call; the answer is the advanced frame, so one call both
   steps and reads. A write, gated like press. *)
let handle_tick ~config request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let status, json = tick_response ~config ~body in
      Http.Response.json_value_on_cpu ~status:(status :> Httpun.Status.t) ~request
        ~extra_headers:(Server_auth.cors_headers (Server_auth.get_origin request)) json reqd)
;;

let activity_json ~config:_ =
  let activity, message = match Runtime.machine_configuration () with
    | None -> Machine_configuration.Unobserved, Some "Machine activity configuration is unavailable"
    | Some configuration ->
        (if configuration.Machine_configuration.msx_enabled then Machine_configuration.Enabled else Disabled), None in
  `Assoc (["schema", `String "masc.msx-activity/v1";
    "activity", `String (Machine_configuration.activity_to_wire activity)]
    @ match message with None -> [] | Some message -> ["message", `String message])

(* A restore replaces the machine every watcher shows, so this route never
   picks its slot. The tool reads a restore that names no slot as a request
   to list the saved slots; a restore route has no listing to answer with, and
   its receipt binds one slot. *)
let restore_names_no_slot ~restore = function
  | `Assoc [] -> restore
  | `Assoc (_ :: _) | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false

let checkpoint_legacy_response ~(config : Workspace.config) ~restore ~body =
  match decode_write_body ~config ~body with
  | Error refusal -> refusal
  | Ok (`Assoc fields)
    when List.length fields <> List.length (List.sort_uniq String.compare (List.map fst fields)) ->
      `Bad_request, load_result_json ~ok:false ~message:"checkpoint has duplicate fields"
  | Ok arguments when restore_names_no_slot ~restore arguments ->
      `Bad_request, load_result_json ~ok:false ~message:"restore requires a slot"
  | Ok arguments ->
      let schema = Tool_schemas_misc_toml.msx_schema (if restore then Msx_tool.Restore else Msx_tool.Save) in
      let result = worker_response ~config ~principal:Lane_addon_call_context.Operator ~schema ~arguments in
      result.status, answer_json result
;;
;;

module Checkpoint_receipt = Server_msx_checkpoint_receipt
let checkpoint_epoch = Random_id.uuid_v7 ()
let checkpoint_receipt_path (config : Workspace.config) =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path:config.base_path) "msx")
    "checkpoint-operations.sqlite3"

(* Slot validation the receipt binds on: pure, no machine. *)
let checkpoint_slot ~restore args =
  if restore_names_no_slot ~restore args then Error "restore requires a slot"
  else
    Result.map Machine_checkpoint.slot_to_string
      (Machine_checkpoint.slot_of_arguments ~default:Msx_tool.default_checkpoint_slot args)

let checkpoint_binding ~restore args =
  match args with
  | `Assoc fields ->
      (match List.filter (fun (key,_) -> key="operation_id") fields with
       | [_, `String raw] ->
           (match Keeper_operation_id.of_string raw,
                  checkpoint_slot ~restore (`Assoc (List.remove_assoc "operation_id" fields)) with
            | Ok operation_id, Ok slot -> Ok {Checkpoint_receipt.operation_id;
                action=(if restore then Restore else Save);slot}
            | Error message, _ | _, Error message -> Error message)
       | _ -> Error "checkpoint operation_id must be one canonical string")
  | _ -> Error "checkpoint request must be an object"

(* The completion fields the checkpoint worker reports with its observation
   (change_count, incarnation, checkpoint_sha256). Missing or malformed fields
   are not a completion; the receipt settles as unknown rather than guessing. *)
let worker_completion (result : worker_response) : Checkpoint_receipt.completion option =
  match result.data with
  | `Assoc fields ->
      (match List.assoc_opt "change_count" fields,
             List.assoc_opt "incarnation" fields,
             List.assoc_opt "checkpoint_sha256" fields with
       | Some (`Int count), Some (`String incarnation), Some (`String checkpoint_sha256)
         when count >= 0 && incarnation <> "" ->
           Some {Checkpoint_receipt.mark = {incarnation; count}; checkpoint_sha256}
       | _ -> None)
  | _ -> None

(* What a finished worker call lets the receipt claim. Only a failure proven to
   precede the effect is a refusal: the operator may then act again, since the
   slot and the machine are as they were. A failure the worker reports as
   having happened leaves no completion mark to record, and one it cannot
   classify is unknown, so neither frees the operator to retry blind. *)
let worker_settlement (result : worker_response) : Checkpoint_receipt.state =
  match result.outcome with
  | Succeeded ->
      (match worker_completion result with
       | Some completion -> Checkpoint_receipt.Committed completion
       | None -> Checkpoint_receipt.Unknown "MSX worker omitted its checkpoint completion")
  | Failed Tool_result.Proven_pre_effect -> Checkpoint_receipt.Refused result.message
  | Failed Tool_result.Proven_post_effect ->
      Checkpoint_receipt.Unknown ("MSX worker reported a failure after the checkpoint took effect: " ^ result.message)
  | Failed Tool_result.Effect_outcome_unknown -> Checkpoint_receipt.Unknown result.message

let receipt_json ~(config : Workspace.config) (receipt : Checkpoint_receipt.receipt) =
  let binding = receipt.binding in
  let status, extra = match receipt.state with
    | Pending when receipt.epoch=checkpoint_epoch -> "pending", []
    | Pending -> "unknown", ["message",`String "checkpoint belongs to an earlier server instance"]
    | Unknown detail -> "unknown", ["message",`String detail]
    | Refused detail -> "refused", ["message",`String detail;
        "effect_disposition",`String "proven_pre_effect"]
    | Committed completed -> "committed", ["effect",`Assoc [
        "change_count",`Int completed.mark.count; "incarnation",`String completed.mark.incarnation;
        "checkpoint_sha256",`String completed.checkpoint_sha256]] in
  ["ok",`Bool (status="committed");
   "workspace",`Assoc ["base_path",`String (Unix.realpath config.base_path);
                         "masc_root",`String (Unix.realpath (Workspace.masc_dir config))];
   "operation_id",`String (Keeper_operation_id.to_string binding.operation_id);
   "checkpoint",`String (match binding.action with Save -> "save" | Restore -> "restore");
   "slot",`String binding.slot;"epoch",`String receipt.epoch;"status",`String status] @ extra

let checkpoint_request_with_workspace ~config ~body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message -> Error (`Bad_request,write_error_json message)
  | `Assoc fields when List.mem_assoc "expected_workspace" fields -> decode_write_body ~config ~body
  | _ -> Error (`Bad_request,write_error_json "checkpoint operation requires expected_workspace")

let settle_checkpoint_effect ~restore ~persist ~notify settled =
  let persisted = persist settled in
  let notify_needed = match settled with
    | Checkpoint_receipt.Committed _ | Unknown _ -> restore
    | Pending | Refused _ -> false in
  if not notify_needed then persisted else
  match notify () with
  | () -> persisted
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
      let message = "MSX restore observer notification failed: " ^ Printexc.to_string exn in
      Error (match persisted with Ok () -> message | Error cause -> cause ^ "; " ^ message)

let checkpoint_operation_response ~(config : Workspace.config) ~restore ~body =
  let refused binding message =
    `Service_unavailable, `Assoc (receipt_json ~config
      {Checkpoint_receipt.binding;epoch=checkpoint_epoch;state=Refused message}) in
  match checkpoint_request_with_workspace ~config ~body with
  | Error response -> response
  | Ok args -> match checkpoint_binding ~restore args with
    | Error message -> `Bad_request,write_error_json message
    | Ok binding ->
        let path = checkpoint_receipt_path config in
        (* Admission is durably committed before the effect job is submitted.
           A cancelled HTTP waiter cannot turn a pending record into permission
           to dispatch the same operation again. *)
        match Executor_pool_ref.submit_strict (fun () ->
          Workspace.mkdir_p (Filename.dirname path);
          Checkpoint_receipt.admit ~path ~epoch:checkpoint_epoch binding) with
        | Error failure ->
            `Service_unavailable, `Assoc (receipt_json ~config
              {Checkpoint_receipt.binding;epoch=checkpoint_epoch;
               state=Unknown (Executor_pool_ref.strict_submit_error_to_string failure)})
        | Ok (Error Checkpoint_receipt.Binding_conflict) ->
            `Conflict,write_error_json "checkpoint operation identity is bound to another action or slot"
        | Ok (Error ((Invalid_binding _ | Store_unavailable _) as error)) ->
            (* A failed lookup may hide an already-running duplicate. Failure
               to acquire admission is not proof this operation had no effect. *)
            `Service_unavailable, `Assoc (receipt_json ~config
              {Checkpoint_receipt.binding;epoch=checkpoint_epoch;
               state=Unknown (Checkpoint_receipt.error_to_string error)})
        | Ok (Ok (Existing receipt)) -> `OK, `Assoc (receipt_json ~config receipt)
        | Ok (Ok Accepted) ->
            let run () =
              Eio.Cancel.protect (fun () ->
                    (* The worker runs the checkpoint and reports the completion
                       mark with its observation; only it can name the change it
                       made. Admission stays here, ahead of the dispatch. *)
                    let settled =
                      try
                        let schema = Tool_schemas_misc_toml.msx_schema (if restore then Msx_tool.Restore else Msx_tool.Save) in
                        let arguments = match args with
                          | `Assoc fields -> `Assoc (List.remove_assoc "operation_id" fields)
                          | other -> other in
                        let result = worker_response ~config ~principal:Lane_addon_call_context.Operator
                          ~schema ~arguments in
                        worker_settlement result
                      with
                      | Eio.Cancel.Cancelled _ as exn -> Checkpoint_receipt.Unknown (Printexc.to_string exn)
                      | exn -> Checkpoint_receipt.Unknown (Printexc.to_string exn) in
                (* Publish from the worker, even when its HTTP caller stopped
                   waiting. A failed store write must never manufacture success. *)
                match settle_checkpoint_effect ~restore
                  ~persist:(fun state ->
                    Checkpoint_receipt.settle ~path ~epoch:checkpoint_epoch binding state
                    |> Result.map_error Checkpoint_receipt.error_to_string)
                  (* The worker publishes the machine; the server no
                     longer wakes lane instances itself. *)
                  ~notify:(fun () -> ()) settled with
                | Error message -> Error message
                | Ok () -> Ok {Checkpoint_receipt.binding;epoch=checkpoint_epoch;state=settled}) in
            (match Executor_pool_ref.submit_strict run with
             | Ok (Ok receipt) ->
                 `OK, `Assoc (receipt_json ~config receipt)
             | Ok (Error message) -> `Internal_server_error,write_error_json message
             | Error (Executor_pool_ref.Pool_unavailable | Caller_not_in_eio) ->
                 (* The admitted job never started. A receipt-store failure here
                    leaves pending evidence; the direct answer still proves this
                    request did not dispatch its effect. *)
                 refused binding "MSX checkpoint worker is unavailable"
             | Error ((Work_failed _ | Submission_failed _) as failure) ->
                 `Internal_server_error,write_error_json (Executor_pool_ref.strict_submit_error_to_string failure))

let checkpoint_status_response ~(config : Workspace.config) ~body =
  match checkpoint_request_with_workspace ~config ~body with
  | Error response -> response
  | Ok (`Assoc fields) ->
      (match List.filter (fun (key,_) -> key="checkpoint") fields with
       | [_, `String ("save" | "restore" as action)] ->
           (match checkpoint_binding ~restore:(action="restore") (`Assoc (List.remove_assoc "checkpoint" fields)) with
            | Error message -> `Bad_request,write_error_json message
            | Ok binding ->
                (match Executor_pool_ref.submit_strict (fun () ->
                  let path = checkpoint_receipt_path config in
                  let recovered = Checkpoint_receipt.retry_settlement ~path ~epoch:checkpoint_epoch binding in
                  match Result.bind recovered (fun () -> Checkpoint_receipt.inspect ~path binding) with
                  | Error error -> Error (Checkpoint_receipt.error_to_string error)
                  | Ok receipt ->
                      let receipt = Option.value receipt ~default:{Checkpoint_receipt.binding;
                        epoch=checkpoint_epoch;state=Unknown "checkpoint operation has not been observed"} in
                      let fields = receipt_json ~config receipt in
                      (* The live screen after a committed restore is the
                         worker's published evidence, read through the same
                         answer the live route serves: the server no longer
                         touches the machine itself. *)
                      let fields = match binding.action, Server_routes_http_routes_lane_addons.live_json
                        ~config Machine_lane.Msx ~since:None with
                        | Restore, Ok live ->
                            ("live",live)::("live_relation",`String "observed_after_completion")::fields
                        | Restore, Error _ | Save, _ -> fields in
                      Ok (`Assoc fields)) with
                 | Ok (Ok json) -> `OK,json
                 | Ok (Error message) -> `Internal_server_error,write_error_json message
                 | Error failure -> `Service_unavailable,write_error_json (Executor_pool_ref.strict_submit_error_to_string failure)))
       | _ -> `Bad_request,write_error_json "checkpoint must name save or restore")
  | Ok _ -> `Bad_request,write_error_json "checkpoint status request must be an object"

let checkpoint_response ~config ~restore ~body =
  match Yojson.Safe.from_string body with
  | `Assoc fields when List.mem_assoc "operation_id" fields -> checkpoint_operation_response ~config ~restore ~body
  | _ | exception Yojson.Json_error _ -> checkpoint_legacy_response ~config ~restore ~body
;;

let change_disk_response ~(config : Workspace.config) ~body =
  match decode_write_body ~config ~body with
  | Error refusal -> refusal
  | Ok arguments ->
      let result = worker_response ~config ~principal:Lane_addon_call_context.Operator
        ~schema:(Tool_schemas_misc_toml.msx_schema Msx_tool.Change_disk) ~arguments in
      result.status, answer_json result
;;

let handle_change_disk ~state request reqd =
  Http.Request.read_body_async reqd (fun body ->
    let config = Mcp_server.workspace_config state in
    let status, json = change_disk_response ~config ~body in
    respond_json_value_with_cors ~status:(status :> Httpun.Status.t) request reqd json)
;;

let handle_checkpoint ~state ~restore request reqd =
  Http.Request.read_body_async reqd (fun body ->
    let config = Mcp_server.workspace_config state in
    let status, json = checkpoint_response ~config ~restore ~body in
    respond_json_value_with_cors ~status:(status :> Httpun.Status.t) request reqd json)
;;

let add_routes router =
  router
  |> Http.Router.get "/api/v1/msx/activity" (fun request reqd ->
       with_public_read
         (fun state req reqd -> Http.Response.json_value ~compress:true ~request:req
           (activity_json ~config:(Mcp_server.workspace_config state)) reqd)
         request reqd)
  |> Http.Router.get "/api/v1/msx/carts" (fun request reqd ->
       with_public_read
         (fun state req reqd ->
           let status, json = carts_response ~config:(Mcp_server.workspace_config state) in
           respond_json_value_with_cors ~status:(status :> Httpun.Status.t) req reqd json)
         request reqd)
  |> Http.Router.post "/api/v1/msx/checkpoint-operation" (fun request reqd ->
       with_read_auth (fun state request reqd ->
         Http.Request.read_body_async reqd (fun body ->
           let config = Mcp_server.workspace_config state in
           let status,json = checkpoint_status_response ~config ~body in
           respond_json_value_with_cors ~status request reqd json)) request reqd)
  |> Http.Router.post "/api/v1/msx/press" (fun request reqd ->
       with_tool_actor_auth ~tool_name:(Msx_tool.name Msx_tool.Press)
         (fun state who _req reqd ->
           handle_press ~state ~who request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/load" (fun request reqd ->
       with_tool_actor_auth ~tool_name:(Msx_tool.name Msx_tool.Load)
         (fun state agent_name _req reqd ->
           handle_load ~state ~agent_name request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/save" (fun request reqd ->
       with_tool_auth ~tool_name:(Msx_tool.name Msx_tool.Save)
         (fun state _req reqd ->
           handle_checkpoint ~state ~restore:false
             request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/restore" (fun request reqd ->
       with_tool_auth ~tool_name:(Msx_tool.name Msx_tool.Restore)
         (fun state _req reqd ->
           handle_checkpoint ~state ~restore:true
             request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/disk" (fun request reqd ->
       with_tool_auth ~tool_name:(Msx_tool.name Msx_tool.Change_disk)
         (fun state _req reqd ->
           handle_change_disk ~state request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/tick" (fun request reqd ->
       with_tool_auth ~tool_name:(Msx_tool.name Msx_tool.Step)
         (fun state _req reqd -> handle_tick ~config:(Mcp_server.workspace_config state) request reqd)
         request reqd)
;;
