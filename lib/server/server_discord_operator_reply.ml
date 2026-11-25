module Http = Http_server_eio

type request = {
  operation_id : Keeper_operation_id.t;
  keeper_name : string;
  chat_id : string;
  content : string;
}

type origin = {
  channel_id : string;
  message_id : string;
  parent_channel_id : string option;
}

type refusal = Binding_changed | Discord_unconfigured | Discord_rejected
type outcome = Delivered of string | Refused of refusal | Unknown

type admission = {
  actor : string;
  keeper_name : string;
  chat_id : string;
  digest : string;
  worker : string;
  origin : origin;
}

type receipt = { admission : admission; outcome : outcome option }

let ( let* ) = Result.bind
let unavailable = "Discord reply receipt is unavailable"
let invalid_receipt = Error unavailable
let sha256 text = Agent_core_sha256.(digest_string text |> to_hex)

let canonical_snowflake value =
  not (String.starts_with ~prefix:"0" value)
  && Result.is_ok (Discord_rest_client.snowflake_of_string value)

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> Error ("missing or invalid " ^ name)

let body_fields ~expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = expected -> Ok fields
  | _ -> Error "invalid Discord reply request fields"

let request_of_json json =
  let* fields = body_fields ~expected:["chat_id"; "content"; "keeper_name"; "operation_id"] json in
  let* raw_id = string_field "operation_id" fields in
  let* operation_id = Keeper_operation_id.of_string raw_id in
  let* keeper_name = string_field "keeper_name" fields in
  let* chat_id = string_field "chat_id" fields in
  let* content = string_field "content" fields in
  if not (Keeper_config.validate_name keeper_name) then Error "invalid Keeper name"
  else
    let _, tail = Discord_rest_client.split_at_codepoint ~limit:Discord_rest_client.message_content_limit content in
    if tail <> "" then Error "Discord reply exceeds its message length limit"
    else Ok { operation_id; keeper_name; chat_id; content }

let external_speaker = function
  | Some { Keeper_chat_store.speaker_authority = External; _ } -> true
  | Some { speaker_authority = (Owner | Keeper); _ } | None -> false

let origin_from_chat ~chat_id (row : Keeper_chat_store.chat_message) =
  if row.id <> chat_id || not (Keeper_chat_store.Role.equal row.role User)
     || not (external_speaker row.speaker)
  then None
  else
    match row.surface, row.external_message_id with
    | Some (Surface_ref.Discord { channel_id; parent_channel_id; thread_id; _ }), Some message_id ->
      let valid_thread =
        match parent_channel_id with
        | None -> thread_id = None
        | Some parent -> canonical_snowflake parent && parent <> channel_id && thread_id = Some channel_id
      in
      if canonical_snowflake channel_id && canonical_snowflake message_id && valid_thread
      then Some { channel_id; message_id; parent_channel_id }
      else None
    | None, _ | _, None
    | Some (Dashboard _ | Slack _ | Webhook _ | Agent | Broadcast | Gate _), _ -> None

let observe_origin ~(config : Workspace.config) (request : request) =
  match Keeper_chat_store.load_captured_result ~base_dir:config.base_path
          ~keeper_name:request.keeper_name ~select:(fun row -> String.equal row.id request.chat_id) with
  | Error _ -> Error "The original chat record could not be read"
  | Ok [ captured ] ->
    (match origin_from_chat ~chat_id:request.chat_id
             (Keeper_chat_store.captured_row_message captured) with
     | Some origin -> Ok origin
     | None -> Error "The selected record has no verified Discord reply address")
  | Ok ([] | _ :: _ :: _) -> Error "The original chat record is missing or ambiguous"

let binding_allows ~(config : Workspace.config) ~keeper_name origin =
  let same_workspace =
    try String.equal (Unix.realpath config.base_path) (Unix.realpath (Env_config_core.base_path ()))
    with Unix.Unix_error _ -> false
  in
  same_workspace
  && match Channel_gate_discord_state.resolve_keeper_for_recorded_channel_result
             ~channel_id:origin.channel_id ~parent_channel_id:origin.parent_channel_id with
     | Ok (Some binding) -> String.equal binding.keeper_name keeper_name
     | Ok None | Error _ -> false

let field name value = name, `String value
let line fields = Yojson.Safe.to_string (`Assoc fields) ^ "\n"

let admission_line admitted =
  line
    [ field "actor" admitted.actor; field "keeper_name" admitted.keeper_name
    ; field "chat_id" admitted.chat_id; field "digest" admitted.digest; field "worker" admitted.worker
    ; field "channel_id" admitted.origin.channel_id; field "original_message_id" admitted.origin.message_id
    ; "parent_channel_id", (match admitted.origin.parent_channel_id with
      | None -> `Null | Some id -> `String id) ]

let refusal_code = function
  | Binding_changed -> "binding_changed"
  | Discord_unconfigured -> "discord_unconfigured"
  | Discord_rejected -> "discord_rejected"

let terminal_line = function
  | Delivered message_id -> line [ field "state" "delivered"; field "message_id" message_id ]
  | Refused reason -> line [ field "state" "refused"; field "reason" (refusal_code reason) ]
  | Unknown -> line [ field "state" "outcome_unknown" ]

let decode_admission json =
  let* fields =
    body_fields
      ~expected:["actor"; "channel_id"; "chat_id"; "digest"; "keeper_name";
                 "original_message_id"; "parent_channel_id"; "worker"] json
  in
  let* actor = string_field "actor" fields in
  let* keeper_name = string_field "keeper_name" fields in
  let* chat_id = string_field "chat_id" fields in
  let* digest = string_field "digest" fields in
  let* worker = string_field "worker" fields in
  let* channel_id = string_field "channel_id" fields in
  let* message_id = string_field "original_message_id" fields in
  let* parent_channel_id =
    match List.assoc_opt "parent_channel_id" fields with
    | Some `Null -> Ok None
    | Some (`String id) when canonical_snowflake id -> Ok (Some id)
    | Some _ | None -> invalid_receipt
  in
  if canonical_snowflake channel_id && canonical_snowflake message_id then
    Ok { actor; keeper_name; chat_id; digest; worker; origin = { channel_id; message_id; parent_channel_id } }
  else invalid_receipt

let decode_outcome = function
  | `Assoc [ "state", `String "delivered"; "message_id", `String id ] when canonical_snowflake id ->
    Ok (Delivered id)
  | `Assoc [ "state", `String "refused"; "reason", `String "binding_changed" ] ->
    Ok (Refused Binding_changed)
  | `Assoc [ "state", `String "refused"; "reason", `String "discord_unconfigured" ] ->
    Ok (Refused Discord_unconfigured)
  | `Assoc [ "state", `String "refused"; "reason", `String "discord_rejected" ] ->
    Ok (Refused Discord_rejected)
  | `Assoc [ "state", `String "outcome_unknown" ] -> Ok Unknown
  | _ -> invalid_receipt

let decode_receipt contents =
  try
    match String.split_on_char '\n' contents with
    | [""] -> Ok None
    | [ admitted; "" ] ->
      let* admission = decode_admission (Yojson.Safe.from_string admitted) in
      Ok (Some { admission; outcome = None })
    | [ admitted; terminal; "" ] ->
      let* admission = decode_admission (Yojson.Safe.from_string admitted) in
      let* outcome = decode_outcome (Yojson.Safe.from_string terminal) in
      Ok (Some { admission; outcome = Some outcome })
    | _ -> invalid_receipt
  with Yojson.Json_error _ -> invalid_receipt

let receipt_path ~root operation_id =
  Filename.concat (Filename.concat root "discord-operator-replies")
    (sha256 (Keeper_operation_id.to_string operation_id) ^ ".jsonl")

let update ~root ~path decide =
  try
    match Fs_compat.update_owned_private_file_durable_locked_result
            ~owner_uid:(Unix.geteuid ()) ~ownership_root:root path
            (fun file -> decide (decode_receipt file.content)) with
    | Private_file_succeeded result -> result
    | Private_file_failed _ | Private_file_failed_with_cleanup_failure _
    | Private_file_succeeded_with_cleanup_failure _ -> invalid_receipt
  with Unix.Unix_error _ | Sys_error _ -> invalid_receipt

let same_request ~actor (request : request) admission =
  String.equal actor admission.actor && request.keeper_name = admission.keeper_name
  && request.chat_id = admission.chat_id && sha256 request.content = admission.digest

(* The server holds its workspace's writer lease for its lifetime. A
   worker missing from this process after restart is therefore unresolved. *)
let workers = Hashtbl.create 8
let workers_mu = Mutex.create ()
let register worker = Mutex.protect workers_mu (fun () -> Hashtbl.replace workers worker ())
let unregister worker = Mutex.protect workers_mu (fun () -> Hashtbl.remove workers worker)
let running worker = Mutex.protect workers_mu (fun () -> Hashtbl.mem workers worker)

(* The writer settles the receipt before it removes the live worker. Observe
   both facts while holding the receipt lock so a terminal result cannot be
   mistaken for an abandoned admission. *)
let observe_receipt receipt =
  match receipt.outcome with
  | None when not (running receipt.admission.worker) -> { receipt with outcome = Some Unknown }
  | Some _ | None -> receipt

let inspect ~root ~path =
  try
    match Fs_compat.update_existing_owned_private_file_durable_locked_result
            ~owner_uid:(Unix.geteuid ()) ~ownership_root:root path
            (fun file -> None, Result.map (Option.map observe_receipt) (decode_receipt file.content)) with
    | Private_file_succeeded None -> Ok None
    | Private_file_succeeded (Some result) -> result
    | Private_file_failed _ | Private_file_failed_with_cleanup_failure _
    | Private_file_succeeded_with_cleanup_failure _ -> invalid_receipt
  with Unix.Unix_error _ | Sys_error _ -> invalid_receipt

let public_receipt operation_id { admission; outcome } =
  let state, fields =
    match outcome with
    | Some (Delivered id) -> "delivered", [ field "message_id" id ]
    | Some (Refused reason) -> "refused", [ field "reason" (refusal_code reason) ]
    | None -> "sending", []
    | Some Unknown -> "outcome_unknown", []
  in
  `Assoc
    ([ field "operation_id" (Keeper_operation_id.to_string operation_id)
     ; field "state" state; field "keeper_name" admission.keeper_name
     ; field "chat_id" admission.chat_id; field "channel_id" admission.origin.channel_id
     ; field "original_message_id" admission.origin.message_id ] @ fields)

let outcome_of_send = function
  | Ok id when canonical_snowflake id -> Delivered id
  | Error (Discord_rest_client.Discord_api { http_status; _ })
    when http_status >= 400 && http_status < 500 && http_status <> 408 -> Refused Discord_rejected
  | Ok _ | Error (Discord_api _ | Http_status _ | Network _ | Other _) -> Unknown

let settle ~root ~path worker outcome =
  update ~root ~path (function
    | Ok (Some { admission; outcome = None }) when admission.worker = worker ->
      Some (terminal_line outcome), Ok ()
    | Ok (Some _ | None) | Error _ -> None, invalid_receipt)

let send_once ~clock ~content origin =
  match Env_config_discord.bot_token_opt () with
    | None -> Refused Discord_unconfigured
    | Some token ->
      Discord_rest_client.send_message ~clock ~token ~channel_id:origin.channel_id
        ~reply_to_message_id:origin.message_id ~content ~nonce:(Discord_rest_client.fresh_nonce ()) ()
      |> outcome_of_send

let dispatch ~sw ~root ~path admission send =
  let worker = admission.worker in
  let store outcome =
    match settle ~root ~path worker outcome with
    | Ok () -> ()
    | Error _ -> Log.Server.warn "Discord operator reply terminal receipt unavailable"
  in
  try
    Eio.Fiber.fork ~sw (fun () ->
      Fun.protect ~finally:(fun () -> unregister worker) (fun () ->
        match send () with
        | outcome -> Eio.Cancel.protect (fun () -> store outcome)
        | exception (Eio.Cancel.Cancelled _ as cancel) ->
          Eio.Cancel.protect (fun () -> store Unknown);
          raise cancel
        | exception _ -> Eio.Cancel.protect (fun () -> store Unknown)))
  with exn ->
    unregister worker;
    raise exn

let error status detail = status, `Assoc [field "error" detail]
let storage_error = error `Service_unavailable unavailable
let conflict = error `Conflict "The operation ID belongs to a different Discord reply"

let send_response ~sw ~root ~actor ~resolve_origin ~is_current ~send json =
  match request_of_json json with
  | Error detail -> error `Bad_request detail
  | Ok request ->
    let path = receipt_path ~root request.operation_id in
    let existing receipt =
      if same_request ~actor request receipt.admission
      then `OK, public_receipt request.operation_id receipt
      else conflict
    in
    match inspect ~root ~path with
    | Error _ -> storage_error
    | Ok (Some receipt) -> existing receipt
    | Ok None ->
      (match resolve_origin request with
       | Error detail -> error `Conflict detail
       | Ok origin when not (is_current ~keeper_name:request.keeper_name origin) ->
         error `Conflict "The original Discord conversation is no longer bound to this Keeper"
       | Ok origin ->
         let admission =
           { actor; keeper_name = request.keeper_name; chat_id = request.chat_id
           ; digest = sha256 request.content; worker = Random_id.uuid_v7 (); origin }
         in
         let receipt = { admission; outcome = None } in
         match Keeper_fs_durable_directory.ensure
                 ~before_prepare:(fun () -> ()) ~before_directory_fsync:(fun _ -> ())
                 ~ownership_root:root (Filename.dirname path) with
         | Error _ -> storage_error
         | Ok lease when not (Keeper_fs_durable_directory.lease_is_current lease) -> storage_error
         | Ok _ ->
           (* Once admitted, the worker belongs to the server switch. Request
              cancellation must not leave a live-worker marker without a worker. *)
           Eio.Cancel.protect (fun () ->
             register admission.worker;
             let admitted =
               try update ~root ~path (function
                 | Ok None -> Some (admission_line admission), Ok None
                 | Ok (Some prior) -> None, Ok (Some (observe_receipt prior))
                 | Error _ -> None, invalid_receipt)
               with exn ->
                 unregister admission.worker;
                 raise exn
             in
             match admitted with
             | Error _ -> unregister admission.worker; storage_error
             | Ok (Some prior) -> unregister admission.worker; existing prior
             | Ok None ->
               dispatch ~sw ~root ~path admission (fun () ->
                 if is_current ~keeper_name:request.keeper_name origin
                 then send ~content:request.content origin
                 else Refused Binding_changed);
               `Accepted, public_receipt request.operation_id receipt))

let status_response ~root ~actor json =
  let operation_id =
    let* fields = body_fields ~expected:["operation_id"] json in
    let* value = string_field "operation_id" fields in
    Keeper_operation_id.of_string value
  in
  match operation_id with
  | Error detail -> error `Bad_request detail
  | Ok operation_id ->
    match inspect ~root ~path:(receipt_path ~root operation_id) with
    | Ok (Some receipt) when String.equal actor receipt.admission.actor ->
      `OK, public_receipt operation_id receipt
    | Ok (Some _ | None) -> error `Not_found "Discord reply operation was not observed"
    | Error _ -> storage_error

let handle ~state request reqd make_response =
  let respond (status, json) =
    Http.Response.with_scoped_headers
      [ "cache-control", "no-store"; "referrer-policy", "no-referrer" ]
      (fun () -> Http.Response.json_value ~status ~compress:false ~request json reqd)
  in
  let allow_origin =
    match Server_auth.classify_request_origin
            ~request_authority:(Server_request_authority.current_exn ()) request with
    | Single_origin { admission = Same_origin; _ } -> true
    | Missing_origin -> Httpun.Headers.get_multi request.headers "sec-fetch-site" = []
    | Single_origin { admission = (Allowed_dev_origin | Rejected); _ }
    | Multiple_origins | Malformed_origin -> false
  in
  if not allow_origin then respond (error `Forbidden "Discord reply requires a private operator origin")
  else
    Http.Request.read_body_async_with_limit reqd
      (* One Discord text message plus its JSON encoding and the workspace address. *)
      ~max_bytes:(32 * 1024)
      ~on_error:(function
        | Http.Request.Too_large _ -> respond (error `Payload_too_large "Discord reply request is too large")
        | Http.Request.Internal _ -> respond (error `Internal_server_error "Discord reply request was not read"))
      ~on_body:(fun body ->
        let config = Mcp_server.workspace_config state in
        let response =
          try
            match Yojson.Safe.from_string body with
            | `Assoc fields as json when List.mem_assoc "expected_workspace" fields ->
              (match Workspace.validate_expected_workspace ~config json with
               | Ok json -> make_response config json
               | Error reason -> error `Conflict (Workspace.expected_workspace_error_message reason))
            | _ -> error `Bad_request "expected_workspace is required"
          with
          | Yojson.Json_error _ -> error `Bad_request "invalid JSON body"
          | Unix.Unix_error _ | Sys_error _ -> storage_error
        in
        respond response)

let handle_send ~sw ~clock ~state ~actor request reqd =
  handle ~state request reqd (fun config json ->
    send_response ~sw ~root:(Workspace.masc_dir config) ~actor
      ~resolve_origin:(observe_origin ~config) ~is_current:(binding_allows ~config)
      ~send:(send_once ~clock) json)

let handle_status ~state ~actor request reqd =
  handle ~state request reqd (fun config json ->
    status_response ~root:(Workspace.masc_dir config) ~actor json)

module For_testing = struct
  let origin_from_chat ~chat_id row =
    Option.map (fun origin -> origin.channel_id, origin.message_id, origin.parent_channel_id)
      (origin_from_chat ~chat_id row)

  let submit ~sw ~root ~actor ~resolve_origin ~binding_allows ~send =
    let resolve_origin (request : request) =
      resolve_origin ~keeper_name:request.keeper_name ~chat_id:request.chat_id
      |> Result.map (fun (channel_id, message_id, parent_channel_id) ->
        { channel_id; message_id; parent_channel_id })
    in
    let is_current ~keeper_name origin = binding_allows ~keeper_name ~channel_id:origin.channel_id in
    let send ~content origin =
      send ~channel_id:origin.channel_id ~message_id:origin.message_id ~content |> outcome_of_send
    in
    send_response ~sw ~root ~actor ~resolve_origin ~is_current ~send

  let status = status_response
end
