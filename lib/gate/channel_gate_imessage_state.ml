(* Channel_gate_imessage_state — iMessage in-process connector state.

   Replaces the sidecar functor instance this module used to be. The four
   defects iMessage shipped on 2026-08-16 (#28848, #28855, #28869, #28882) were
   one shape: liveness lived in a file, so the writer and the readers could
   disagree about its path, its env var, its freshness and its meaning. None of
   those four are expressible against an [Atomic] the poll fiber owns.

   Shaped after {!Channel_gate_slack_state}. iMessage differs in what carries
   messages — a local SQLite file and osascript rather than a socket and REST —
   and in having no bot identity, no credential and no message editing. *)

module Store = Channel_gate_binding_store
module U = Yojson.Safe.Util

type binding = Store.binding =
  { channel_id : string
  ; keeper_name : string
  }

let connector_id = "imessage"
let display_name = "iMessage"
let channel = "imessage"
let default_binding_store_path = ".gate/runtime/imessage/bindings.json"
let default_binding_audit_path = ".gate/runtime/imessage/binding_audit.jsonl"

let imessage_path ~env_var ~default () =
  match Env_config_core.raw_value_opt env_var |> Env_config_core.trim_opt with
  | Some path -> Env_config_core.resolve_against_base_path path
  | None -> Env_config_core.resolve_against_base_path default
;;

let binding_store_path () =
  imessage_path ~env_var:"MASC_IMESSAGE_BINDING_STORE_PATH"
    ~default:default_binding_store_path ()
;;

let binding_audit_path () =
  imessage_path ~env_var:"MASC_IMESSAGE_BINDING_AUDIT_PATH"
    ~default:default_binding_audit_path ()
;;

(* iMessage has no Discord-style guild, so audit events omit guild_id. *)
let binding_store =
  Store.create ~binding_store_path ~binding_store_read_path:binding_store_path
    ~binding_audit_path ~binding_audit_read_path:binding_audit_path
    ~guild_id_field:Store.Omit
;;

let read_bindings_result () = Store.read_bindings_result binding_store
let binding_json = Store.binding_json
let read_recent_audit ~limit = Store.read_recent_audit binding_store ~limit

(* ---- Reply routing ---- *)

type reply_mode =
  | Self_chat
  | Source_chat

let reply_mode_to_string = function
  | Self_chat -> "self-chat"
  | Source_chat -> "source-chat"
;;

let parse_reply_mode raw =
  match String.lowercase_ascii (String.trim raw) with
  | "self-chat" -> Ok Self_chat
  | "source-chat" -> Ok Source_chat
  | other ->
    Error
      (Printf.sprintf
         "unknown reply mode %S: expected \"self-chat\" or \"source-chat\""
         other)
;;

(* Unset and unrecognised are different answers. Unset takes the documented
   default; a typo is reported, because a reply routed to the wrong
   conversation is only visible to whoever wrongly received it. *)
let configured_reply_mode () =
  match Env_config_imessage.reply_mode_opt () with
  | None -> Ok Self_chat
  | Some raw -> parse_reply_mode raw
;;

(* ---- Liveness ----

   The poll is the transport, so the poll is the liveness. One definition,
   read both by [status_json] and by the [Channel_gate_connector.S] export
   [connected]; they used to be able to disagree and no longer can. *)

type poll_state =
  | Not_started
  | Polling
  | Degraded of string

let poll_state_to_string = function
  | Not_started -> "not_started"
  | Polling -> "polling"
  | Degraded _ -> "degraded"
;;

let poll_state_ref : poll_state Atomic.t = Atomic.make Not_started
let cursor_rowid_ref : int Atomic.t = Atomic.make 0
let self_chat_guid_ref : string Atomic.t = Atomic.make ""
let startup_error : string option Atomic.t = Atomic.make None

let record_poll_ok ~cursor_rowid =
  Atomic.set cursor_rowid_ref cursor_rowid;
  Atomic.set poll_state_ref Polling
;;

let record_poll_error message = Atomic.set poll_state_ref (Degraded message)

let record_self_chat_guid guid =
  Atomic.set self_chat_guid_ref (String.trim guid)
;;

let record_startup_error message = Atomic.set startup_error (Some message)
let clear_startup_error () = Atomic.set startup_error None

let transport_connected () =
  match Atomic.get poll_state_ref with
  | Polling -> true
  | Not_started | Degraded _ -> false
;;

let poll_state_error () =
  match Atomic.get poll_state_ref with
  | Degraded reason -> reason
  | Not_started | Polling -> ""
;;

(* ---- Status ---- *)

let chat_db_path () = Imessage_chat_db.default_db_path ()

let chat_db_error () =
  match Imessage_chat_db.check_access ~db_path:(chat_db_path ()) with
  | Ok () -> ""
  | Error denial -> Imessage_chat_db.error_to_string denial
;;

(* In self-chat mode a reply needs a note-to-self handle. Without one the
   connector receives and cannot answer, which is the same kind of half-working
   Slack reports for a missing bot token, so it is part of the verdict rather
   than a surprise at send time. *)
let reply_target_error reply_mode =
  match reply_mode with
  | Source_chat -> ""
  | Self_chat ->
    if String.equal (Atomic.get self_chat_guid_ref) "" then
      "no self-chat conversation resolved: iMessage receives but every reply \
       fails. Start a note-to-self conversation in Messages.app, or set \
       MASC_IMESSAGE_SELF_CHAT_GUID"
    else ""
;;

let status_json ?(audit_limit = 10) () =
  let startup_error = Atomic.get startup_error in
  let startup_ok = Option.is_none startup_error in
  let configured_bindings_result = read_bindings_result () in
  let binding_store_read_ok = Result.is_ok configured_bindings_result in
  let configured_bindings, binding_store_error =
    match configured_bindings_result with
    | Ok bindings -> bindings, ""
    | Error error -> [], Store.binding_store_error_to_string error
  in
  let reply_mode_result = configured_reply_mode () in
  let reply_mode_error =
    match reply_mode_result with Ok _ -> "" | Error message -> message
  in
  let reply_mode =
    match reply_mode_result with Ok mode -> mode | Error _ -> Self_chat
  in
  let chat_db_error = chat_db_error () in
  let reply_target_error = reply_target_error reply_mode in
  let available =
    startup_ok && binding_store_read_ok
    && String.equal chat_db_error ""
    && String.equal reply_mode_error ""
    && String.equal reply_target_error ""
  in
  let connected = transport_connected () in
  (* NDT-OK: status_json is a dashboard observation boundary; this timestamp
     reports freshness and is not used for control flow. *)
  let updated_at = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ()) in
  (* A recorded startup error is why the gateway is not running and everything
     else is downstream of it, so it stays the whole message. Otherwise report
     every independent reason at once rather than letting one mask the rest. *)
  let error =
    match startup_error with
    | Some message -> message
    | None ->
      [ (if binding_store_read_ok then None else Some binding_store_error)
      ; (if String.equal chat_db_error "" then None else Some chat_db_error)
      ; (if String.equal reply_mode_error "" then None else Some reply_mode_error)
      ; (if String.equal reply_target_error "" then None
         else Some reply_target_error)
      ; (let poll_error = poll_state_error () in
         if String.equal poll_error "" then None else Some poll_error)
      ]
      |> List.filter_map Fun.id
      |> String.concat "; "
  in
  let recent_audit = read_recent_audit ~limit:audit_limit in
  let configured_binding_json = List.map binding_json configured_bindings in
  `Assoc
    [ "channel", `String channel
    ; "capabilities", Channel_gate_connector_capability.all_json
    ; "available", `Bool available
    ; "connected", `Bool connected
    ; ( "status"
      , `String
          (* The poll loop is the liveness source. It publishes into memory on
             every cycle, so there is no heartbeat that could age out and the
             connector is never stale. *)
          (Channel_gate_connector.connector_state_label ~available ~connected
             ~stale:false) )
    ; "error", `String error
    ; "status_source", `String "in_process_gateway"
    ; "poll_state", `String (poll_state_to_string (Atomic.get poll_state_ref))
    ; "reply_mode", `String (reply_mode_to_string reply_mode)
    ; ( "self_chat_guid"
      , `String (Imessage_chat_db.redact_chat_guid (Atomic.get self_chat_guid_ref))
      )
    ; "cursor_rowid", `Int (Atomic.get cursor_rowid_ref)
    ; "chat_db_path", `String (chat_db_path ())
    ; "chat_db_readable", `Bool (String.equal chat_db_error "")
    ; "binding_store_path", `String (binding_store_path ())
    ; "audit_path", `String (binding_audit_path ())
    ; "binding_source", `String "persisted"
    ; "binding_store_read_ok", `Bool binding_store_read_ok
    ; "binding_store_error", `String binding_store_error
    ; "runtime_bindings_count", `Int (List.length configured_bindings)
    ; "configured_bindings", `List configured_binding_json
    ; "recent_audit", `List recent_audit
    ; "updated_at", `String updated_at
    ]
;;

let connector_json ?(audit_limit = 10) () =
  let status = status_json ~audit_limit () in
  let fields =
    [ "channel"
    ; "capabilities"
    ; "available"
    ; "connected"
    ; "status"
    ; "error"
    ; "status_source"
    ; "poll_state"
    ; "reply_mode"
    ; "self_chat_guid"
    ; "cursor_rowid"
    ; "chat_db_path"
    ; "chat_db_readable"
    ; "binding_store_path"
    ; "audit_path"
    ; "binding_source"
    ; "binding_store_read_ok"
    ; "binding_store_error"
    ; "runtime_bindings_count"
    ; "configured_bindings"
    ; "recent_audit"
    ; "updated_at"
    ]
  in
  `Assoc
    (("connector_id", `String connector_id)
     :: ("display_name", `String display_name)
     :: List.map (fun field -> field, status |> U.member field) fields)
;;

(* ---- Bindings ----

   Third copy of this pair, after Discord and Slack. The shared part is already
   [Store.mutate_bindings]; what repeats is the decide callback, and folding
   three near-identical callbacks into one abstraction is a separate change
   that would touch two working connectors. Kept explicit here. *)

let bind ~channel_id ~keeper_name ~actor_name =
  let channel_id = String.trim channel_id in
  let keeper_name = String.trim keeper_name in
  if String.equal channel_id "" then Error "channel_id is required"
  else if String.equal keeper_name "" then Error "keeper_name is required"
  else
    Store.mutate_bindings binding_store ~decide:(fun original_bindings ->
      let previous_keeper =
        match
          List.find_map
            (fun (b : binding) ->
              if String.equal b.channel_id channel_id then Some b.keeper_name
              else None)
            original_bindings
        with
        | Some keeper_name -> keeper_name
        | None -> ""
      in
      let updated_bindings =
        (({ channel_id; keeper_name } : binding)
         :: List.filter
              (fun (b : binding) -> not (String.equal b.channel_id channel_id))
              original_bindings)
        |> List.sort (fun (a : binding) (b : binding) ->
             String.compare a.channel_id b.channel_id)
      in
      let event =
        Store.
          { timestamp =
              (* NDT-OK: binding audit wall-clock is operator-facing telemetry
                 only. *)
              Gate_time_util.iso8601_of_unix (Unix.gettimeofday ())
          ; action = "bind"
          ; channel_id
          ; keeper_name
          ; actor_id = actor_name
          ; actor_name
          ; previous_keeper
          }
      in
      Ok (updated_bindings, event, ()))
    |> Result.map_error Store.mutation_error_to_string
    |> Result.map (fun () -> status_json ())
;;

let unbind_internal ?expected_keeper_name ~channel_id ~actor_name () =
  let channel_id = String.trim channel_id in
  if String.equal channel_id "" then Error "channel_id is required"
  else
    Store.mutate_bindings binding_store ~decide:(fun original_bindings ->
      match
        original_bindings
        |> List.find_opt (fun (b : binding) ->
             String.equal b.channel_id channel_id)
      with
      | None -> Error "binding not found"
      | Some (removed : binding)
        when (match expected_keeper_name with
              | Some expected -> not (String.equal expected removed.keeper_name)
              | None -> false) ->
        Error "binding changed"
      | Some (removed : binding) ->
        let updated_bindings =
          List.filter
            (fun (b : binding) -> not (String.equal b.channel_id channel_id))
            original_bindings
        in
        let event =
          Store.
            { timestamp =
                (* NDT-OK: binding audit wall-clock is operator-facing
                   telemetry only. *)
                Gate_time_util.iso8601_of_unix (Unix.gettimeofday ())
            ; action = "unbind"
            ; channel_id
            ; keeper_name = removed.keeper_name
            ; actor_id = actor_name
            ; actor_name
            ; previous_keeper = removed.keeper_name
            }
        in
        Ok (updated_bindings, event, ()))
    |> Result.map_error Store.mutation_error_to_string
    |> Result.map (fun () -> status_json ())
;;

let unbind ~channel_id ~actor_name =
  unbind_internal ~channel_id ~actor_name ()
;;

let unbind_if_keeper ~channel_id ~expected_keeper_name ~actor_name =
  unbind_internal ~expected_keeper_name ~channel_id ~actor_name ()
;;

(* ---- In-process gateway support ---- *)

type keeper_binding_resolution =
  { keeper_name : string
  ; incoming_channel_id : string
  ; bound_channel_id : string
  }

(* An iMessage conversation has one identifier and no thread hierarchy, so
   resolution is a single exact lookup — no parent fallback like Discord. *)
let resolve_keeper_for_channel_result ~channel_id =
  let normalized = String.trim channel_id in
  if String.equal normalized "" then Ok None
  else (
    match read_bindings_result () with
    | Error error -> Error error
    | Ok candidates ->
      (match Store.find_binding_by_channel_id candidates ~channel_id:normalized with
       | Some b ->
         Ok
           (Some
              { keeper_name = b.keeper_name
              ; incoming_channel_id = normalized
              ; bound_channel_id = b.channel_id
              })
       | None -> Ok None))
;;

(* RFC-0223 P2 presence surface. Recomputed per call — no cached state. *)
let bound_channels ~keeper_name =
  Store.bound_channels_result binding_store ~keeper_name
;;

let connected () = transport_connected ()

(* ---- Outbound ---- *)

let reply_target ~chat_guid =
  match configured_reply_mode () with
  | Error message -> Error message
  | Ok Source_chat ->
    (match chat_guid with
     | Some guid when not (String.equal (String.trim guid) "") -> Ok (String.trim guid)
     | Some _ | None ->
       Error
         "source-chat reply mode, but the message carried no Messages.app chat \
          handle to reply to")
  | Ok Self_chat ->
    let guid = Atomic.get self_chat_guid_ref in
    if String.equal guid "" then
      Error
        "self-chat reply mode, but no note-to-self conversation is resolved: \
         start one in Messages.app, or set MASC_IMESSAGE_SELF_CHAT_GUID"
    else Ok guid
;;

let send_message ?timeout_sec ~chat_guid ~content () =
  Imessage_applescript.send ?timeout_sec ~chat_guid ~text:content ()
;;
