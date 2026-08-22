(** Workspace Broadcast - Message broadcasting and activity emission.

    Extracted from workspace_state.ml. Depends on Workspace_state for
    next_seq and normalized_string_list. *)

open Masc_domain
open Workspace_utils

type broadcast_error =
  | Broadcast_not_persisted of string
  | Broadcast_policy_rejected of string
  | Broadcast_dependency_unavailable of string

let broadcast_error_to_string = function
  | Broadcast_not_persisted detail
  | Broadcast_policy_rejected detail
  | Broadcast_dependency_unavailable detail -> detail
;;

type mention_delivery_deferred =
  | Handler_unavailable
  | Target_state_unavailable
  | Intake_store_unavailable
  | Workspace_status_unavailable
  | Handler_failed
  | Predecessor_pending
  | Recovery_unavailable

type mention_delivery_rejected =
  | Target_not_configured
  | Invalid_target
  | Invalid_request

type mention_delivery =
  | Passive
  | Pending
  | Accepted
  | Already_accepted
  | Deferred of mention_delivery_deferred
  | Rejected of mention_delivery_rejected

(* Whether a committed message is conversation the fleet should see in its
   Keeper windows, or a record of something the system did. The producer
   declares it and nothing derives it from the text. A producer that declares
   nothing is a record, so a new call site cannot silently fan a machine
   announcement out to every Keeper's transcript — and the task FSM's
   per-transition announcements, 17 of the 18 retained messages, stay out of
   conversation windows they would only crowd. *)
type audience =
  | Fleet_conversation
  | System_record

type task_cache_signal = Workspace_task_cache_invariant.signal =
  { subject_agent : string
  ; task_id : string
  }

let task_cache_signal_partial_error =
  "task_cache_subject_agent and task_cache_task_id must be supplied together"
;;

let task_cache_signal_of_args args =
  let field name = Safe_ops.json_string_opt name args |> String_util.option_trim in
  match field "task_cache_subject_agent", field "task_cache_task_id" with
  | None, None -> Ok None
  | Some subject_agent, Some task_id -> Ok (Some { subject_agent; task_id })
  | Some _, None | None, Some _ -> Error task_cache_signal_partial_error
;;

type broadcast_delivery =
  { request_id : string
  ; seq : int
  ; rendered : string
  ; from_agent : string
  ; content : string
  ; mention : string option
  ; msg_type : string
  ; mention_delivery : mention_delivery
  ; audience : audience
  }

type mention_outbox_quarantine_reason =
  | Malformed_filename
  | Malformed_json
  | Invalid_current_schema
  | Request_identity_mismatch

type mention_outbox_quarantine_receipt =
  { source_name : string
  ; quarantine_name : string
  ; reason : mention_outbox_quarantine_reason
  ; detail : string
  ; raw_sha256 : string
  }

type message_schema_rejection_kind =
  | Message_row_unreadable
  | Message_row_malformed_json
  | Message_row_incompatible

type message_schema_rejection =
  { source_name : string
  ; kind : message_schema_rejection_kind
  ; detail : string
  }

exception Current_message_schema_rejected of message_schema_rejection list

type reconciliation_report =
  { outbox_rows : int
  ; pending_rows : int
  ; accepted : int
  ; already_accepted : int
  ; deferred : int
  ; rejected : int
  ; corrupt_rows : int
  ; quarantine_receipts : mention_outbox_quarantine_receipt list
  ; blocked_targets : string list
  ; global_barrier : bool
  }

let mention_outbox_quarantine_reason_to_string = function
  | Malformed_filename -> "malformed_filename"
  | Malformed_json -> "malformed_json"
  | Invalid_current_schema -> "invalid_current_schema"
  | Request_identity_mismatch -> "request_identity_mismatch"
;;

let message_schema_rejection_kind_to_string = function
  | Message_row_unreadable -> "unreadable"
  | Message_row_malformed_json -> "malformed_json"
  | Message_row_incompatible -> "incompatible_current_schema"
;;

let message_schema_rejection_to_string rejection =
  Printf.sprintf
    "%s:%s:%s"
    rejection.source_name
    (message_schema_rejection_kind_to_string rejection.kind)
    rejection.detail
;;

let () =
  Printexc.register_printer (function
    | Current_message_schema_rejected rejections ->
      Some
        ("workspace message current-schema preflight rejected: "
         ^ String.concat "; " (List.map message_schema_rejection_to_string rejections))
    | _ -> None)
;;

let mention_delivery_kind = function
  | Passive -> "passive"
  | Pending -> "pending"
  | Accepted -> "accepted"
  | Already_accepted -> "already_accepted"
  | Deferred _ -> "deferred"
  | Rejected _ -> "rejected"

let mention_delivery_reason = function
  | Passive | Pending | Accepted | Already_accepted -> None
  | Deferred reason ->
    Some
      (match reason with
       | Handler_unavailable -> "handler_unavailable"
       | Target_state_unavailable -> "target_state_unavailable"
       | Intake_store_unavailable -> "intake_store_unavailable"
       | Workspace_status_unavailable -> "workspace_status_unavailable"
       | Handler_failed -> "handler_failed"
       | Predecessor_pending -> "predecessor_pending"
       | Recovery_unavailable -> "recovery_unavailable")
  | Rejected reason ->
    Some
      (match reason with
       | Target_not_configured -> "target_not_configured"
       | Invalid_target -> "invalid_target"
       | Invalid_request -> "invalid_request")

let mention_delivery_to_yojson delivery =
  `Assoc
    ([ "kind", `String (mention_delivery_kind delivery) ]
     @ match mention_delivery_reason delivery with
       | None -> []
       | Some reason -> [ "reason", `String reason ])

let broadcast_delivery_to_yojson delivery =
  let ok =
    match delivery.mention_delivery with
    | Passive | Accepted | Already_accepted -> true
    | Pending | Deferred _ | Rejected _ -> false
  in
  `Assoc
    [ "ok", `Bool ok
    ; "request_id", `String delivery.request_id
    ; "seq", `Int delivery.seq
    ; "rendered", `String delivery.rendered
    ; "from_agent", `String delivery.from_agent
    ; "content", `String delivery.content
    ; "mention", Json_util.string_opt_to_json delivery.mention
    ; "msg_type", `String delivery.msg_type
    ; "mention_delivery", mention_delivery_to_yojson delivery.mention_delivery
    ]

let emit_message_activity config ~from_agent ~content ~mention
    ?session_id ?operation_id ?worker_run_id ?(evidence_refs = []) () =
  let evidence_refs = Workspace_state.normalized_string_list evidence_refs in
  let payload =
    `Assoc
      [
        ("content", `String content);
        ( "mention", Json_util.string_opt_to_json mention );
        ( "session_id", Json_util.string_opt_to_json_trimmed session_id );
        ( "operation_id", Json_util.string_opt_to_json_trimmed operation_id );
        ( "worker_run_id", Json_util.string_opt_to_json_trimmed worker_run_id );
        ( "evidence_refs",
          `List (List.map (fun value -> `String value) evidence_refs) );
      ]
  in
  let actor = Workspace_hooks.{ kind = "agent"; id = from_agent } in
  let emit ?subject ~kind ~tags () =
    try
      (Atomic.get Workspace_hooks.activity_emit_fn) config
        ~actor ?subject ~kind ~payload ~tags ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Misc.warn "message activity emit failed (%s): %s" kind
          (Printexc.to_string exn)
  in
  emit
    ~kind:(Event_kind.Message.to_string Event_kind.Message.Broadcast)
    ~tags:[ "message"; "broadcast" ] ();
  match mention with
  | Some target when String.trim target <> "" ->
      emit
        ~subject:Workspace_hooks.{ kind = "agent"; id = target }
        ~kind:(Event_kind.Message.to_string Event_kind.Message.Mentioned)
        ~tags:[ "message"; "mention" ] ()
  | None | Some _ -> ()

let broadcast_channel config =
  Printf.sprintf "broadcast:%s:default" (project_prefix config)

type mention_handler = broadcast_delivery -> mention_delivery

let on_broadcast_mention : mention_handler Atomic.t =
  Atomic.make (fun delivery ->
    match delivery.mention with
    | None -> Passive
    | Some _ -> Deferred Handler_unavailable)

let set_on_broadcast_mention handler =
  Atomic.set on_broadcast_mention handler

let write_json_commit = Atomic.make write_json_commit_result

let delivery_of_message ~audience (message : Masc_domain.message) =
  { request_id = message.request_id
  ; seq = message.seq
  ; rendered =
      Printf.sprintf "\xF0\x9F\x93\xA2 [%s] %s" message.from_agent message.content
  ; from_agent = message.from_agent
  ; content = message.content
  ; mention = message.mention
  ; msg_type = message.msg_type
  ; mention_delivery =
      (match message.mention with None -> Passive | Some _ -> Pending)
    (* The persisted row carries no audience: the declaration belongs to the
       live call, and the projection commits at first delivery. Startup
       reconciliation exists for the mention obligation, so a replay defaults
       to [System_record] rather than re-projecting. *)
  ; audience
  }

(* Every committed message reaches the handler, not only the ones carrying a
   mention. Delivery is more than the named wake: an unmentioned broadcast is
   still conversation the fleet sits in, and the handler is the only place
   that sees a committed message. The installed handler decides what an
   absent mention means and the default answers [Passive], so short-circuiting
   here only hid the message from whoever is installed. *)
let deliver_delivery delivery =
  try (Atomic.get on_broadcast_mention) delivery with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Misc.warn
      "on_broadcast_mention callback failed request_id=%s: %s"
      delivery.request_id
      (Printexc.to_string exn);
    Deferred Handler_failed

let message_file config (message : Masc_domain.message) =
  Filename.concat (messages_dir config)
    (Printf.sprintf
       "%09d_%s_%s_broadcast.json"
       message.seq
       (safe_filename message.from_agent)
       message.request_id)

let mention_outbox_dir config =
  Filename.concat (masc_dir config) "message-mention-outbox"

let mention_outbox_quarantine_dir config =
  Filename.concat (masc_dir config) "message-mention-outbox-quarantine"

let mention_outbox_file config request_id =
  Filename.concat (mention_outbox_dir config) (request_id ^ ".json")

let delete_outbox_marker config request_id =
  let path = mention_outbox_file config request_id in
  match key_of_path config path with
  | Some key ->
    (match backend_delete config ~key with
     | Error error -> Error (Backend_types.show_error error)
     | Ok _ ->
       (try
          if should_dual_write_local config && Sys.file_exists path
          then Sys.remove path;
          Ok ()
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn)))
  | None ->
    (try
       if Sys.file_exists path then Sys.remove path;
       Ok ()
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Printexc.to_string exn))

let delete_outbox_source config name =
  let path = Filename.concat (mention_outbox_dir config) name in
  match key_of_path config path with
  | Some key ->
    (match backend_delete config ~key with
     | Error error -> Error (Backend_types.show_error error)
     | Ok _ ->
       (try
          if should_dual_write_local config && Sys.file_exists path
          then Sys.remove path;
          Ok ()
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn)))
  | None ->
    (try
       if Sys.file_exists path then Sys.remove path;
       Ok ()
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Printexc.to_string exn))

let write_outbox_marker config message =
  let path = mention_outbox_file config message.Masc_domain.request_id in
  write_json_commit_result config path (message_to_yojson message)
  |> Result.map (fun { mirror_error } ->
    Option.iter
      (fun detail ->
         Log.Misc.warn
           "workspace mention outbox mirror write failed request_id=%s: %s"
           message.request_id detail)
      mirror_error)

let durable_delivery_status = function
  | Passive -> Mention_passive
  | Pending | Deferred _ -> Mention_pending
  | Accepted | Already_accepted -> Mention_accepted
  | Rejected _ -> Mention_rejected

let notify_workspace_message_mutation config message =
  (Atomic.get Workspace_hooks.on_workspace_message_mutation_fn)
    config
    ~request_id:message.Masc_domain.request_id
    ~mention_delivery:message.mention_delivery

let persist_delivery_status config message mention_delivery =
  let status = durable_delivery_status mention_delivery in
  if status = message.Masc_domain.mention_delivery
  then mention_delivery
  else (
    let settled = { message with Masc_domain.mention_delivery = status } in
    match
      write_json_commit_result config (message_file config message)
        (message_to_yojson settled)
    with
    | Ok { mirror_error } ->
      Option.iter
        (fun detail ->
           Log.Misc.warn
             "workspace mention status mirror write failed request_id=%s: %s"
             message.request_id detail)
        mirror_error;
      notify_workspace_message_mutation config settled;
      (match status with
       | Mention_accepted | Mention_rejected ->
         delete_outbox_marker config message.request_id
         |> Result.iter_error (fun detail ->
           Log.Misc.warn
             "workspace mention terminal outbox cleanup failed request_id=%s: %s"
             message.request_id detail)
       | Mention_passive | Mention_pending -> ());
      mention_delivery
    | Error detail ->
      Log.Misc.error
        "workspace mention status write failed request_id=%s: %s"
        message.request_id detail;
      Deferred Workspace_status_unavailable)

let deliver_committed_mention ~audience config message =
  delivery_of_message ~audience message
  |> deliver_delivery
  |> persist_delivery_status config message

let reconcile_persisted_mention config message =
  match message.Masc_domain.mention_delivery with
  (* A replayed row cannot recover the live declaration, so reconciliation
     redelivers the mention obligation only. *)
  | Mention_pending ->
    Some (deliver_committed_mention ~audience:System_record config message)
  | Mention_passive | Mention_accepted | Mention_rejected ->
    delete_outbox_marker config message.request_id
    |> Result.iter_error (fun detail ->
      Log.Misc.warn
        "workspace mention settled outbox cleanup failed request_id=%s: %s"
        message.request_id detail);
    None

let outbox_filename_suffix = ".json"
let workspace_request_prefix = "wmsg-"
let workspace_request_hex_length = 32

let current_request_id_of_filename name =
  let is_safe_filename_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> true
    | _ -> false
  in
  let is_lower_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  in
  if not (String.for_all is_safe_filename_char name)
     || not (Filename.check_suffix name outbox_filename_suffix)
  then None
  else
    let request_id = Filename.chop_suffix name outbox_filename_suffix in
      let prefix_length = String.length workspace_request_prefix in
      let expected_length = prefix_length + workspace_request_hex_length in
      if String.length request_id <> expected_length
         || not (String.starts_with ~prefix:workspace_request_prefix request_id)
      then None
      else
        let rec valid_hex index =
          if index = expected_length
          then true
          else if is_lower_hex request_id.[index]
          then valid_hex (index + 1)
          else false
        in
      if valid_hex prefix_length then Some request_id else None

let authoritative_directory_names config directory =
  match key_of_path config directory with
  | None ->
    (try
       if Sys.file_exists directory && Sys.is_directory directory
       then Ok (Sys.readdir directory |> Array.to_list)
       else Ok []
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Printexc.to_string exn))
  | Some _ when backend_supports_local_dir config.backend ->
    (try
       if Sys.file_exists directory && Sys.is_directory directory
       then Ok (Sys.readdir directory |> Array.to_list)
       else Ok []
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Printexc.to_string exn))
  | Some key_prefix ->
    let prefix = key_prefix ^ ":" in
    backend_list_keys config ~prefix
    |> Result.map_error Backend_types.show_error
    |> Result.map (List.map (strip_prefix prefix))

let authoritative_outbox_names config =
  authoritative_directory_names config (mention_outbox_dir config)

let read_source_raw config path =
  match key_of_path config path with
  | Some key ->
    (match config.backend with
     | FileSystem _ when Sys.file_exists path ->
       (try Ok (Fs_compat.load_file path) with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn))
     | Memory _ | FileSystem _ ->
       (match backend_get config ~key with
        | Error error -> Error (Backend_types.show_error error)
        | Ok (Some raw) -> Ok raw
        | Ok None -> Error "authoritative row is missing"))
  | None ->
    (try
       if Sys.file_exists path
       then Ok (Fs_compat.load_file path)
       else Error "local row is missing"
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Printexc.to_string exn))

let quarantine_outbox_source config ~name ~reason ~detail ~raw =
  let raw_sha256 = Digestif.SHA256.(digest_string raw |> to_hex) in
  let evidence_sha256 =
    Digestif.SHA256.(digest_string (name ^ "\000" ^ raw) |> to_hex)
  in
  let quarantine_name = "q-" ^ evidence_sha256 ^ ".json" in
  let quarantine_path =
    Filename.concat (mention_outbox_quarantine_dir config) quarantine_name
  in
  let evidence =
    `Assoc
      [ "schema", `String "masc.workspace_mention_outbox_quarantine.v1"
      ; "source_name", `String name
      ; "reason", `String (mention_outbox_quarantine_reason_to_string reason)
      ; "detail", `String detail
      ; "raw_sha256", `String raw_sha256
      ; "raw_base64", `String (Base64.encode_string raw)
      ; "quarantined_at", `Float (Time_compat.now ())
      ]
  in
  match write_json_commit_result config quarantine_path evidence with
  | Error error -> Error ("quarantine evidence write failed: " ^ error)
  | Ok { mirror_error } ->
    Option.iter
      (fun error ->
         Log.Misc.warn
           "workspace mention quarantine mirror failed source=%s quarantine=%s: %s"
           name quarantine_name error)
      mirror_error;
    delete_outbox_source config name
    |> Result.map_error (fun error -> "quarantine source delete failed: " ^ error)
    |> Result.map (fun () ->
      { source_name = name; quarantine_name; reason; detail; raw_sha256 })

let validate_current_message_schema config =
  match authoritative_directory_names config (messages_dir config) with
  | Error detail ->
    Error
      [ { source_name = "<message-store>"
        ; kind = Message_row_unreadable
        ; detail
        }
      ]
  | Ok names ->
    let rejections =
      names
      |> List.filter (fun name -> Filename.check_suffix name ".json")
      |> List.filter_map (fun name ->
        let path = Filename.concat (messages_dir config) name in
        match read_source_raw config path with
        | Error detail -> Some { source_name = name; kind = Message_row_unreadable; detail }
        | Ok raw ->
          (match Safe_ops.parse_json_safe ~context:"workspace message schema preflight" raw with
           | Error detail ->
             Some { source_name = name; kind = Message_row_malformed_json; detail }
           | Ok json ->
             (match message_of_yojson json with
              | Ok _ -> None
              | Error detail ->
                Some { source_name = name; kind = Message_row_incompatible; detail })))
    in
    if rejections = [] then Ok () else Error rejections

let empty_reconciliation_report =
  { outbox_rows = 0
  ; pending_rows = 0
  ; accepted = 0
  ; already_accepted = 0
  ; deferred = 0
  ; rejected = 0
  ; corrupt_rows = 0
  ; quarantine_receipts = []
  ; blocked_targets = []
  ; global_barrier = false
  }

let mention_delivery_mutex = Cross_context_mutex.create ()

type committed_message_read =
  | Committed_message of Masc_domain.message
  | Committed_message_absent
  | Committed_message_unavailable of string
  | Committed_message_corrupt of string

let read_committed_message config path =
  match key_of_path config path with
  | Some key ->
    (match backend_get config ~key with
     | Error error ->
       Committed_message_unavailable (Backend_types.show_error error)
     | Ok None -> Committed_message_absent
     | Ok (Some content) ->
       (match Safe_ops.parse_json_safe ~context:"workspace mention committed row" content with
        | Error detail -> Committed_message_corrupt detail
        | Ok json ->
          (match message_of_yojson json with
           | Ok message -> Committed_message message
           | Error detail -> Committed_message_corrupt detail)))
  | None ->
    (try
       if not (Sys.file_exists path)
       then Committed_message_absent
       else
         match read_json_local_result path with
         | Error detail -> Committed_message_unavailable detail
         | Ok json ->
           (match message_of_yojson json with
            | Ok message -> Committed_message message
            | Error detail -> Committed_message_corrupt detail)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Committed_message_unavailable (Printexc.to_string exn))

let rematerialize_committed_message config message =
  match
    write_json_commit_result config (message_file config message)
      (message_to_yojson message)
  with
  | Error detail -> Error detail
  | Ok { mirror_error } ->
    Option.iter
      (fun detail ->
         Log.Misc.warn
           "workspace mention recovery rematerialization mirror failed request_id=%s: %s"
           message.request_id detail)
      mirror_error;
    notify_workspace_message_mutation config message;
    Ok message

let reconcile_pending_mentions_unlocked config =
  let open Result.Syntax in
  let* names = authoritative_outbox_names config in
  let* current, quarantine_receipts =
    names
    |> List.filter (fun name -> Filename.check_suffix name outbox_filename_suffix)
    |> List.fold_left
         (fun result name ->
            let* messages, receipts = result in
            let path = Filename.concat (mention_outbox_dir config) name in
            let* raw =
              read_source_raw config path
              |> Result.map_error (fun detail ->
                Printf.sprintf "workspace mention outbox read failed file=%s: %s" name detail)
            in
            let quarantine reason detail =
              Log.Misc.error
                "workspace mention recovery quarantining file=%s reason=%s detail=%s"
                name
                (mention_outbox_quarantine_reason_to_string reason)
                detail;
              let* receipt =
                quarantine_outbox_source config ~name ~reason ~detail ~raw
              in
              Ok (messages, receipt :: receipts)
            in
            match current_request_id_of_filename name with
            | None -> quarantine Malformed_filename "filename is not a current request id"
            | Some filename_request_id ->
              (match Safe_ops.parse_json_safe ~context:"workspace mention outbox" raw with
               | Error detail -> quarantine Malformed_json detail
               | Ok json ->
                 (match message_of_yojson json with
                  | Error detail -> quarantine Invalid_current_schema detail
                  | Ok (message : Masc_domain.message) when
                      not (String.equal message.request_id filename_request_id) ->
                    quarantine
                      Request_identity_mismatch
                      (Printf.sprintf
                         "filename_request_id=%s payload_request_id=%s"
                         filename_request_id message.request_id)
                  | Ok (message : Masc_domain.message) ->
                    Ok ((message, name) :: messages, receipts))))
         (Ok ([], []))
    |> Result.map (fun (messages, receipts) ->
      ( List.sort
          (fun ((left : Masc_domain.message), left_name)
               ((right : Masc_domain.message), right_name) ->
             let by_seq = Int.compare left.seq right.seq in
             if by_seq <> 0 then by_seq else String.compare left_name right_name)
          messages
      , List.rev receipts ))
  in
  let initial_report =
    { empty_reconciliation_report with
      outbox_rows = List.length current + List.length quarantine_receipts
    ; corrupt_rows = List.length quarantine_receipts
    ; quarantine_receipts
    }
  in
  let report, blocked_targets =
    List.fold_left
      (fun (report, blocked_targets)
           ((outbox_message : Masc_domain.message), _name) ->
           let target = outbox_message.mention in
           let target_is_blocked =
             Option.fold
               ~none:false
               ~some:(fun value -> List.mem value blocked_targets)
               target
           in
           if target_is_blocked
           then
             ( { report with
                 pending_rows = report.pending_rows + 1
               ; deferred = report.deferred + 1
               }
             , blocked_targets )
           else
           let committed_path = message_file config outbox_message in
             let committed = read_committed_message config committed_path in
             let committed =
               match committed with
               | Committed_message_absent ->
                 (match rematerialize_committed_message config outbox_message with
                  | Ok message -> Committed_message message
                  | Error detail -> Committed_message_unavailable detail)
               | ( Committed_message _
                 | Committed_message_unavailable _
                 | Committed_message_corrupt _ ) as other ->
                 other
             in
             (match committed with
              | Committed_message_unavailable detail ->
                Log.Misc.error
                  "workspace mention recovery committed read failed request_id=%s: %s"
                  outbox_message.request_id detail;
                ( { report with corrupt_rows = report.corrupt_rows + 1 }
                , Option.fold
                    ~none:blocked_targets
                    ~some:(fun value -> value :: blocked_targets)
                    target )
              | Committed_message_corrupt detail ->
                   Log.Misc.error
                     "workspace mention recovery committed decode failed request_id=%s: %s"
                     outbox_message.request_id detail;
                   ( { report with corrupt_rows = report.corrupt_rows + 1 }
                   , Option.fold
                       ~none:blocked_targets
                       ~some:(fun value -> value :: blocked_targets)
                       target )
              | Committed_message message when
                     not (String.equal message.request_id outbox_message.request_id) ->
                   Log.Misc.error
                     "workspace mention recovery committed identity mismatch outbox_request_id=%s request_id=%s"
                     outbox_message.request_id message.request_id;
                   ( { report with corrupt_rows = report.corrupt_rows + 1 }
                   , Option.fold
                       ~none:blocked_targets
                       ~some:(fun value -> value :: blocked_targets)
                       target )
              | Committed_message message ->
                (match reconcile_persisted_mention config message with
                 | None -> report, blocked_targets
                 | Some delivery ->
                   let report =
                     { report with pending_rows = report.pending_rows + 1 }
                   in
                   (match delivery with
                    | Accepted ->
                      { report with accepted = report.accepted + 1 }, blocked_targets
                    | Already_accepted ->
                      ( { report with already_accepted = report.already_accepted + 1 }
                      , blocked_targets )
                    | Deferred _ | Pending ->
                      ( { report with deferred = report.deferred + 1 }
                      , Option.fold
                          ~none:blocked_targets
                          ~some:(fun value -> value :: blocked_targets)
                          target )
                    | Rejected _ ->
                      { report with rejected = report.rejected + 1 }, blocked_targets
                    | Passive -> report, blocked_targets))
              | Committed_message_absent -> assert false))
      (initial_report, [])
      current
  in
  Ok
    { report with
      blocked_targets = List.rev blocked_targets
    ; global_barrier = false
    }

let reconcile_pending_mentions config =
  Cross_context_mutex.with_lock mention_delivery_mutex (fun () ->
    reconcile_pending_mentions_unlocked config)

let rewrite_task_cache_signal config ~msg_type ~task_cache_signal ~content =
  match task_cache_signal with
  | None -> Ok (content, msg_type)
  | Some signal ->
    if not (String.equal msg_type "broadcast")
    then
      (* Only a broadcast carries the invalidation replacement, so accepting a
         signal here would drop it after the caller was told it was applied. *)
      Error
        (Broadcast_policy_rejected
           (Printf.sprintf
              "task cache signal is carried by a broadcast, not by %s"
              msg_type))
    else (
      match
        Workspace_task_cache_invariant.rewrite_signal
          ~config
          ~module_name:"workspace_broadcast"
          ~signal
          ~content
      with
      | Unchanged content -> Ok (content, msg_type)
      | Invalidated content -> Ok (content, "cache_invalidated")
      | Rejected detail -> Error (Broadcast_policy_rejected detail)
      | Dependency_unavailable detail ->
        Error (Broadcast_dependency_unavailable detail))
;;

let broadcast_with_mention ?trace_context ~msg_type ~audience
    config ~from_agent ~content ~pre_extract_mention ~deferred_by_predecessor =
  let started_at = Time_compat.now () in
  let observe final_msg_type =
    let elapsed_s = Float.max 0.0 (Time_compat.now () -. started_at) in
    try (Atomic.get Workspace_hooks.workspace_broadcast_observed_fn)
          ~msg_type:final_msg_type ~elapsed_s
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ()
  in
  ensure_initialized config;

  let seq = Workspace_state.next_seq config in
  let request_id = Random_id.prefixed ~prefix:"wmsg-" ~bytes:16 in
  let mention = pre_extract_mention in
  let safe_content = sanitize_message content in
  let safe_agent = sanitize_agent_name from_agent in
  let safe_msg_type =
    match String.trim msg_type with
    | "" -> "broadcast"
    | value -> sanitize_message value
  in
  let msg = {
    request_id;
    seq;
    from_agent = safe_agent;
    msg_type = safe_msg_type;
    content = safe_content;
    mention;
    mention_delivery =
      (match mention with None -> Mention_passive | Some _ -> Mention_pending);
    timestamp = now_iso ();
    trace_context;
    expires_at = None;
  } in
  let msg_file = message_file config msg in
  let delivery =
    { request_id
    ; seq
    ; rendered = Printf.sprintf "\xF0\x9F\x93\xA2 [%s] %s" safe_agent safe_content
    ; from_agent = safe_agent
    ; content = safe_content
    ; mention
    ; msg_type = safe_msg_type
    ; mention_delivery =
        (match mention with None -> Passive | Some _ -> Pending)
    ; audience
    }
  in
  let outbox_result =
    match mention with
    | None -> Ok ()
    | Some _ -> write_outbox_marker config msg
  in
  (match outbox_result with
   | Error message ->
     Log.Misc.error
       "workspace broadcast mention outbox write failed request_id=%s seq=%d: %s"
       request_id seq message;
     Error (Broadcast_not_persisted message)
   | Ok () ->
  match (Atomic.get write_json_commit) config msg_file (message_to_yojson msg) with
   | Error message ->
     Log.Misc.error
       "workspace broadcast authoritative write failed request_id=%s seq=%d: %s"
       request_id seq message;
     (match mention with
      | None -> Error (Broadcast_not_persisted message)
      | Some _ ->
        (* The outbox commit above is already the durable acceptance point for
           an explicit mention. Report a typed deferred outcome and retain it
           for reconciliation; deleting it and raising made a failed cleanup
           capable of resurrecting an effect the caller was told did not
           persist. *)
         Ok
           { delivery with
             mention_delivery = Deferred Workspace_status_unavailable
           })
   | Ok { mirror_error } ->
     Option.iter
       (fun message ->
          Log.Misc.warn
            "workspace broadcast local mirror write failed request_id=%s seq=%d: %s"
            request_id seq message)
       mirror_error;
     notify_workspace_message_mutation config msg;
     (match backend_publish config ~channel:(broadcast_channel config)
         ~message:(Yojson.Safe.to_string (message_to_yojson msg)) with
      | Ok _ -> ()
      | Error (Backend_types.BackendNotSupported msg)
        when String.starts_with ~prefix:"FileSystem backend" msg ->
        Log.Misc.debug "broadcast publish skipped: %s" msg
      | Error ((Backend_types.BackendNotSupported _
               | Backend_types.NotFound _ | Backend_types.AlreadyExists _
               | Backend_types.IOError _ | Backend_types.InvalidKey _
               | Backend_types.ConnectionFailed _) as e) ->
        Log.Misc.error "broadcast publish failed: %s" (Backend_types.show_error e));
     emit_message_activity config ~from_agent:safe_agent ~content:safe_content
       ~mention ();
     let mention_delivery =
       match deferred_by_predecessor with
       | None -> deliver_committed_mention ~audience config msg
       | Some reason -> Deferred reason
     in
     observe safe_msg_type;
     Ok { delivery with mention_delivery })

let broadcast ?trace_context ?(msg_type = "broadcast") ?task_cache_signal
      ~audience config ~from_agent ~content =
  ensure_initialized config;
  (* Preserve original content and extract mention tokens before any
     fleet-wide invariant rewrite. Explicit mentions share the recovery lock,
     so sequence assignment, commit, intake materialization, and wake request
     cannot overtake an older explicit mention. Passive fanout remains
     unsynchronized. *)
  let pre_extract_mention = Mention.extract content in
  match rewrite_task_cache_signal config ~msg_type ~task_cache_signal ~content with
  | Error _ as error -> error
  | Ok (content, msg_type) ->
    let run deferred_by_predecessor =
      broadcast_with_mention
        ?trace_context
        ~msg_type
        ~audience
        config
        ~from_agent
        ~content
        ~pre_extract_mention
        ~deferred_by_predecessor
    in
    (match pre_extract_mention with
     | None -> run None
     | Some target ->
       Cross_context_mutex.with_lock mention_delivery_mutex (fun () ->
         let deferred_by_predecessor =
           match reconcile_pending_mentions_unlocked config with
           | Error detail ->
             Log.Misc.error
               "workspace mention predecessor reconciliation unavailable target=%s: %s"
               target
               detail;
             Some Recovery_unavailable
           | Ok report ->
             if report.global_barrier || List.mem target report.blocked_targets
             then Some Predecessor_pending
             else None
         in
         run deferred_by_predecessor))

module For_testing = struct
  let replace_on_broadcast_mention handler =
    Atomic.exchange on_broadcast_mention handler

  let replace_write_json_commit handler = Atomic.exchange write_json_commit handler
end
