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
  Store.create ~connector_id ~binding_store_path ~binding_store_read_path:binding_store_path
    ~binding_audit_path ~binding_audit_read_path:binding_audit_path
    ~guild_id_field:Store.Omit
;;

let read_bindings_result () = Store.read_bindings_result binding_store
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
   [connected]. *)

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

let equal_poll_state previous next =
  match previous, next with
  | Not_started, Not_started | Polling, Polling -> true
  | Degraded previous, Degraded next -> String.equal previous next
  | (Not_started | Polling | Degraded _), (Not_started | Polling | Degraded _) -> false
;;

(* The poll state, the self chat and the startup error each feed what the
   connector list draws, so a write that changes one tells its readers
   (RFC-0480 §3.4). The cursor moves with every poll and is not drawn. *)
let publish cell ~equal next =
  let previous = Atomic.exchange cell next in
  if not (equal previous next) then Gate_connector_announce.changed ~connector_id
;;

let record_poll_ok ~cursor_rowid =
  Atomic.set cursor_rowid_ref cursor_rowid;
  publish poll_state_ref ~equal:equal_poll_state Polling
;;

let record_poll_error message =
  publish poll_state_ref ~equal:equal_poll_state (Degraded message)
;;

let record_self_chat_guid guid =
  publish self_chat_guid_ref ~equal:String.equal (String.trim guid)
;;

let record_startup_error message =
  publish startup_error ~equal:(Option.equal String.equal) (Some message)
;;

let clear_startup_error () =
  publish startup_error ~equal:(Option.equal String.equal) None
;;

let poll_state_connected = function
  | Polling -> true
  | Not_started | Degraded _ -> false
;;

let poll_state_error = function
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
let reply_target_error ~self_chat_guid reply_mode =
  match reply_mode with
  | Source_chat -> ""
  | Self_chat ->
    if String.equal self_chat_guid "" then
      "no self-chat conversation resolved: iMessage receives but every reply \
       fails. Start a note-to-self conversation in Messages.app, or set \
       MASC_IMESSAGE_SELF_CHAT_GUID"
    else ""
;;

(* One reading of the connector, rendered by [status_json] and
   [connector_json] alike so the two views cannot disagree. The poll state and
   the self-chat handle are each read once: the rendered [connected] is
   computed from [poll_state], and [error] is built from the same two values
   the record shows. *)
type status =
  { available : bool
  ; error : string
  ; poll_state : poll_state
  ; reply_mode : reply_mode
  ; self_chat_guid : string
  ; cursor_rowid : int
  ; chat_db_path : string
  ; chat_db_readable : bool
  ; binding_store_path : string
  ; audit_path : string
  ; binding_read : (binding list, string) result
  ; recent_audit : Yojson.Safe.t list
  ; updated_at : string
  }

let read_status ~audit_limit =
  let startup_error = Atomic.get startup_error in
  let startup_ok = Option.is_none startup_error in
  let poll_state = Atomic.get poll_state_ref in
  let self_chat_guid = Atomic.get self_chat_guid_ref in
  let binding_read =
    read_bindings_result () |> Result.map_error Store.binding_store_error_to_string
  in
  let binding_store_read_ok = Result.is_ok binding_read in
  let binding_error =
    match binding_read with Ok _ -> None | Error error -> Some error
  in
  let reply_mode_result = configured_reply_mode () in
  let reply_mode_error =
    match reply_mode_result with Ok _ -> "" | Error message -> message
  in
  let reply_mode =
    match reply_mode_result with Ok mode -> mode | Error _ -> Self_chat
  in
  let chat_db_error = chat_db_error () in
  let reply_target_error = reply_target_error ~self_chat_guid reply_mode in
  let available =
    startup_ok && binding_store_read_ok
    && String.equal chat_db_error ""
    && String.equal reply_mode_error ""
    && String.equal reply_target_error ""
  in
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
      [ binding_error
      ; (if String.equal chat_db_error "" then None else Some chat_db_error)
      ; (if String.equal reply_mode_error "" then None else Some reply_mode_error)
      ; (if String.equal reply_target_error "" then None
         else Some reply_target_error)
      ; (let poll_error = poll_state_error poll_state in
         if String.equal poll_error "" then None else Some poll_error)
      ]
      |> List.filter_map Fun.id
      |> String.concat "; "
  in
  { available
  ; error
  ; poll_state
  ; reply_mode
  ; self_chat_guid
  ; cursor_rowid = Atomic.get cursor_rowid_ref
  ; chat_db_path = chat_db_path ()
  ; chat_db_readable = String.equal chat_db_error ""
  ; binding_store_path = binding_store_path ()
  ; audit_path = binding_audit_path ()
  ; binding_read
  ; recent_audit = read_recent_audit ~limit:audit_limit
  ; updated_at
  }
;;

let snapshot_of_status (status : status) : Channel_gate_connector.snapshot =
  { available = status.available
  ; connected = poll_state_connected status.poll_state
  ; stale = false
  ; error = status.error
  ; binding_read = status.binding_read
  ; binding_store_path = status.binding_store_path
  ; audit_path = status.audit_path
  ; recent_audit = status.recent_audit
  ; updated_at = status.updated_at
  ; details =
      [ "capabilities", Channel_gate_connector_capability.all_json
      ; "status_source", `String "in_process_gateway"
      ; "poll_state", `String (poll_state_to_string status.poll_state)
      ; "reply_mode", `String (reply_mode_to_string status.reply_mode)
      ; "self_chat_guid", `String (Imessage_chat_db.redact_chat_guid status.self_chat_guid)
      ; "cursor_rowid", `Int status.cursor_rowid
      ; "chat_db_path", `String status.chat_db_path
      ; "chat_db_readable", `Bool status.chat_db_readable
      ]
  ; descriptor_details = []
  }

let snapshot ?(audit_limit = 10) () =
  snapshot_of_status (read_status ~audit_limit)

let status_json ?audit_limit () =
  Channel_gate_connector.snapshot_status_json ~channel (snapshot ?audit_limit ())

let connector_json ?audit_limit () =
  Channel_gate_connector.snapshot_connector_json ~connector_id ~display_name ~channel
    (snapshot ?audit_limit ())

let bind ~channel_id ~keeper_name ~actor_name =
  Store.bind binding_store ~channel_id ~keeper_name ~actor_name
  |> Result.map_error Store.mutation_error_to_string
  |> Result.map (fun () -> status_json ())

let unbind_internal ?expected_keeper_name ~channel_id ~actor_name () =
  Store.unbind binding_store ?expected_keeper_name ~channel_id ~actor_name ()
  |> Result.map_error Store.mutation_error_to_string
  |> Result.map (fun () -> status_json ())

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

let connected () = poll_state_connected (Atomic.get poll_state_ref)

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
