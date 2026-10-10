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

(* The body of a refused MSX write: [{ok:false, message}], with [code] first
   when the caller names one. The caller names it, not the HTTP status: 409 is
   also the activity gate's answer, under its own codes. *)
let write_error_json ?code message : Yojson.Safe.t =
  let fields = ["ok", `Bool false; "message", `String message] in
  `Assoc (match code with
    | Some code -> ("code", `String code) :: fields
    | None -> fields)
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
                 write_error_json ~code:"workspace_precondition_failed"
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

type worker_response = {
  status : [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ];
  ok : bool;
  message : string;
  data : Yojson.Safe.t;
  code : string option;
}

let worker_response ~config ~principal ~(schema : Masc_domain.tool_schema) ~arguments =
  let failed status message = {status;ok=false;message;data=`Null;code=None} in
  match Tool_input_validation.validate_args ~schema:schema.input_schema ~name:schema.name ~args:arguments () with
  | Error refusal -> failed `Bad_request (Tool_result.message refusal)
  | Ok arguments ->
      match Machine_addon_host.call_shared ~config ~principal ~name:schema.name ~arguments with
      | Error (Lane_addon_runtime.Unavailable message
          | Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Unavailable message)) ->
          failed `Service_unavailable message
      | Error (Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Rejected message)) ->
          failed `Bad_request message
      | Error (Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Activity_disabled message)) ->
          {(failed `Conflict message) with code=Some "activity_disabled"}
      | Error (Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Activity_unobserved message)) ->
          {(failed `Conflict message) with code=Some "activity_unobserved"}
      | Error (Lane_addon_runtime.Outcome_unknown message) ->
          failed `Service_unavailable (message ^ "; inspect the current machine before retrying")
      | Ok result ->
          let field name = match result.Mcp_protocol.Mcp_types._meta with
            | Some (`Assoc fields) -> List.assoc_opt name fields | _ -> None in
          let ok = result.is_error <> Some true in
          let code = match field "io.github.jeong-sik/masc.machine.errorCode" with
            | Some (`String ("activity_disabled" | "activity_unobserved" as code)) -> Some code
            | _ -> None in
          let status = if ok then `OK else match code with
            | Some _ -> `Conflict
            | None -> match field "io.github.jeong-sik/masc.machine.failure" with
              | Some (`String "rejected") -> `Bad_request
              | _ -> `Internal_server_error in
          {status;ok;code;message=Agent_core.Mcp.text_of_tool_result result;
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
        ~schema:Tool_schemas_misc_toml.msx_press ~arguments:(`Assoc fields) in
      let fields = ["ok", `Bool result.ok; "message", `String result.message] in
      let fields = match result.code with None -> fields | Some code -> ("code", `String code)::fields in
      let observation = if result.ok then match result.data with
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
    ~schema:Tool_schemas_misc_toml.msx_meta ~arguments:(`Assoc ["include_inventory", `Bool true]) in
  if not result.ok then result.status, `Assoc ["ok", `Bool false; "message", `String result.message]
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

(* The worker resolves inventory names against its persistent storage. *)
let load_response ~(config : Workspace.config) ~agent_name ~body =
  match decode_write_body ~config ~body with
  | Error refusal -> refusal
  | Ok arguments ->
      let result = worker_response ~config ~principal:(Lane_addon_call_context.Host_actor agent_name)
        ~schema:Tool_schemas_misc_toml.msx_load ~arguments in
      result.status, load_result_json ~ok:result.ok ~message:result.message
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
  let schema = Tool_schemas_misc_toml.msx_step.Masc_domain.input_schema in
  let maximum = Yojson.Safe.Util.(schema |> member "properties" |> member "frames" |> member "maximum" |> to_int) in
  max 1 (min maximum requested)

type pixel_reference = { revision : string; width : int; height : int }
type pixel_response = Full_frame | Retained_pixels of pixel_reference option

let decode_pixel_reference = function
  | `Assoc fields when List.length fields = 3 ->
      (match List.assoc_opt "revision" fields, List.assoc_opt "width" fields,
             List.assoc_opt "height" fields with
       | Some (`String revision), Some (`Int width), Some (`Int height)
         when String.length revision = 64 && width > 0 && height > 0
              && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) revision ->
           Ok { revision; width; height }
       | _ -> Error "known_pixels requires a SHA256 revision and positive width/height")
  | _ -> Error "known_pixels requires exactly revision, width and height"

let decode_tick json =
  match json with
  | `Assoc fields ->
      let ( let* ) = Result.bind in
      let names = List.map fst fields in
      let* () =
        if List.length names <> List.length (List.sort_uniq String.compare names)
           || List.exists (fun name -> not (List.mem name ["frames"; "pixel_response"; "known_pixels"])) names
        then Error "tick has duplicate or unknown fields" else Ok () in
      let* frames = match List.assoc_opt "frames" fields with
        | None -> Ok msx_tick_default_frames
        | Some (`Int n) -> Ok (clamp_tick_frames n)
        | Some _ -> Error "frames must be an integer" in
      let* pixels = match List.assoc_opt "pixel_response" fields, List.assoc_opt "known_pixels" fields with
        | None, None -> Ok Full_frame
        | Some (`String "retained"), None -> Ok (Retained_pixels None)
        | Some (`String "retained"), Some value ->
            Result.map (fun reference -> Retained_pixels (Some reference)) (decode_pixel_reference value)
        | _ -> Error "known_pixels requires pixel_response=retained" in
      Ok (frames, pixels)
  | _ -> Error "tick body must be an object"
;;

let tick_response ~config ~body =
  match decode_write_body ~config ~body with
  | Error refusal -> refusal
  | Ok args ->
  match decode_tick args with
  | Error message -> `Bad_request, `Assoc ["ok", `Bool false; "message", `String message]
  | Ok (frames, pixel_response) ->
      let pixels = match pixel_response with
        | Full_frame -> []
        | Retained_pixels known -> ["pixel_response", `String "retained"] @
            (match known with None -> [] | Some p -> ["known_pixels", `Assoc [
              "revision", `String p.revision; "width", `Int p.width; "height", `Int p.height]]) in
      let result = worker_response ~config ~principal:Lane_addon_call_context.Operator
        ~schema:Tool_schemas_misc_toml.msx_step
        ~arguments:(`Assoc (["frames", `Int frames; "include_frame", `Bool true] @ pixels)) in
      if result.ok then result.status, result.data
      else result.status, `Assoc (["ok", `Bool false; "message", `String result.message]
        @ match result.code with None -> [] | Some code -> ["code", `String code])
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

let checkpoint_legacy_response ~(config : Workspace.config) ~restore ~body =
  match decode_write_body ~config ~body with
  | Error refusal -> refusal
  | Ok (`Assoc fields)
    when List.length fields <> List.length (List.sort_uniq String.compare (List.map fst fields)) ->
      `Bad_request, load_result_json ~ok:false ~message:"checkpoint has duplicate fields"
  | Ok arguments ->
      let schema = if restore then Tool_schemas_misc_toml.msx_restore else Tool_schemas_misc_toml.msx_save in
      let result = worker_response ~config ~principal:Lane_addon_call_context.Operator ~schema ~arguments in
      result.status, load_result_json ~ok:result.ok ~message:result.message
;;
;;

module Checkpoint_receipt = Server_msx_checkpoint_receipt
let checkpoint_epoch = Random_id.uuid_v7 ()
let checkpoint_receipt_path (config : Workspace.config) =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path:config.base_path) "msx")
    "checkpoint-operations.sqlite3"

(* Slot validation the receipt binds on: pure, no machine. *)
let checkpoint_slot args =
  let slot = match args with
    | `Assoc fields when List.for_all (fun (name, _) -> name = "slot") fields -> (
      match List.filter (fun (name, _) -> name = "slot") fields with
      | [] -> Ok "quick"
      | [(_, `String value)] -> Ok value
      | _ -> Error "slot must be one string")
    | _ -> Error "checkpoint arguments must be an object" in
  match slot with
  | Error _ as e -> e
  | Ok slot ->
    if String.length slot < 1 || String.length slot > 64
       || not (String.for_all (function
          | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '-' -> true | _ -> false) slot)
    then Error "slot must be 1..64 letters, digits, underscores or hyphens"
    else Ok slot

let checkpoint_binding ~restore args =
  match args with
  | `Assoc fields ->
      (match List.filter (fun (key,_) -> key="operation_id") fields with
       | [_, `String raw] ->
           (match Keeper_operation_id.of_string raw,
                  checkpoint_slot (`Assoc (List.remove_assoc "operation_id" fields)) with
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
                         "masc_root",`String (Unix.realpath (Workspace.masc_root_dir config))];
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
        | Ok (Error error) ->
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
                        let schema = if restore then Tool_schemas_misc_toml.msx_restore else Tool_schemas_misc_toml.msx_save in
                        let arguments = match args with
                          | `Assoc fields -> `Assoc (List.remove_assoc "operation_id" fields)
                          | other -> other in
                        let result = worker_response ~config ~principal:Lane_addon_call_context.Operator
                          ~schema ~arguments in
                        if not result.ok then Checkpoint_receipt.Unknown result.message
                        else match worker_completion result with
                          | Some completion -> Checkpoint_receipt.Committed completion
                          | None -> Checkpoint_receipt.Unknown "MSX worker omitted its checkpoint completion"
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
             | Error failure ->
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
        ~schema:Tool_schemas_misc_toml.msx_change_disk ~arguments in
      result.status, load_result_json ~ok:result.ok ~message:result.message
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
       with_tool_actor_auth ~tool_name:"masc_msx_press"
         (fun state who _req reqd ->
           handle_press ~state ~who request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/load" (fun request reqd ->
       with_tool_actor_auth ~tool_name:"masc_msx_load"
         (fun state agent_name _req reqd ->
           handle_load ~state ~agent_name request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/save" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_save"
         (fun state _req reqd ->
           handle_checkpoint ~state ~restore:false
             request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/restore" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_restore"
         (fun state _req reqd ->
           handle_checkpoint ~state ~restore:true
             request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/disk" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_change_disk"
         (fun state _req reqd ->
           handle_change_disk ~state request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/tick" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_step"
         (fun state _req reqd -> handle_tick ~config:(Mcp_server.workspace_config state) request reqd)
         request reqd)
;;
