(** Connector wire models, refusals and name-page projection. *)

open Tui_decode_fields
let ( let* ) = Result.bind

type connector_connection =
  | Connector_connected
  | Connector_connected_unavailable
  | Connector_disconnected
  | Connector_offline
  | Connector_stale

type connector_binding = {
  cb_channel_id : string;
  cb_channel_name : string option;
  cb_keeper_name : string;
}

type connector_name_kind =
  | Connector_channel_name
  | Connector_person_name
  | Connector_server_name

type connector_name_mapping = {
  cnm_kind : connector_name_kind;
  cnm_id : string;
  cnm_name : string;
}

type connector_directory_state =
  | Connector_directory_not_started
  | Connector_directory_refreshing
  | Connector_directory_complete
  | Connector_directory_partial

type connector_gateway_state =
  | Connector_gateway_disconnected
  | Connector_gateway_awaiting_hello
  | Connector_gateway_identifying
  | Connector_gateway_resuming
  | Connector_gateway_connected
  | Connector_gateway_reconnect_pending
  | Connector_gateway_failed

type connector_poll_state =
  | Connector_poll_not_started
  | Connector_poll_polling
  | Connector_poll_degraded

type connector = {
  cn_id : string;
  cn_display_name : string;
  cn_available : bool;
  cn_connected : bool;
  cn_status : string;
  cn_connection : connector_connection;
  cn_channel : string option;
  cn_error : string option;
  cn_status_source : string option;
  cn_gateway_state : connector_gateway_state option;
  cn_poll_state : connector_poll_state option;
  cn_endpoint : string option;
  cn_status_path : string option;
  cn_binding_store_path : string option;
  cn_binding_store_read_ok : bool option;
  cn_binding_store_error : string option;
  cn_updated_at : string option;
  cn_binding_source : string option;
  cn_trigger_policy : string option;
  cn_reply_mode : string option;
  cn_chat_db_path : string option;
  cn_bot_user_id : string option;
  cn_bot_user_name : string option;
  cn_bot_token_present : bool option;
  cn_app_token_present : bool option;
  cn_gate_healthy : bool option;
  cn_pid : int option;
  cn_guild_count : int option;
  cn_directory_state : connector_directory_state option;
  cn_directory_server_count : int option;
  cn_directory_channel_count : int option;
  cn_directory_person_count : int option;
  cn_directory_authentication_failed : string list;
  cn_directory_permission_denied : string list;
  cn_directory_errors : string list;
  cn_directory_updated_at : string option;
  cn_workspace_id : string option;
  cn_server_names_path : string option;
  cn_channel_names_path : string option;
  cn_people_names_path : string option;
  cn_name_mappings : connector_name_mapping list;
  cn_name_mapping_scope : string option;
  cn_names_error : string option;
  cn_bindings : connector_binding list;
}

type connector_name_page = {
  cnp_connector_id : string;
  cnp_kind : connector_name_kind;
  cnp_mapping_scope : string;
  cnp_current_workspace_id : string option;
  cnp_path : string;
  cnp_after_id : string option;
  cnp_next_after_id : string option;
  cnp_total : int;
  cnp_has_more : bool;
  cnp_mappings : connector_name_mapping list;
}

type connector_refusal = {
  cr_row : int;
  cr_connector_id : string option;
  cr_reason : string;
}

type connector_snapshot = {
  cs_connectors : connector list;
  cs_refused : connector_refusal list;
  cs_total : int;
  cs_active : int;
}

let nonblank_option = function
  | Some value ->
      let value = String.trim value in
      if String.equal value "" then None else Some value
  | None -> None

let decode_connector_binding json =
  let* cb_channel_id = required_string_field json "channel_id" in
  let* cb_channel_name = optional_string_field json "channel_name" in
  let* cb_keeper_name = required_string_field json "keeper_name" in
  Ok { cb_channel_id; cb_channel_name = nonblank_option cb_channel_name; cb_keeper_name }

let decode_connector_connection ~status ~available ~connected =
  match status, available, connected with
  | "connected", true, true -> Ok Connector_connected
  | "offline", false, true -> Ok Connector_connected_unavailable
  | "disconnected", true, false -> Ok Connector_disconnected
  | "offline", false, false -> Ok Connector_offline
  | "stale", true, false -> Ok Connector_stale
  | _ ->
      Error
        (Printf.sprintf
           "connector status %S contradicts available=%b connected=%b" status
           available connected)

let decode_connector json =
  let* cn_id = required_string_field json "connector_id" in
  let* cn_display_name = required_string_field json "display_name" in
  let* cn_status = required_string_field json "status" in
  (* Both default to false: a connector that does not say it is available or
     connected is not, and defaulting the other way would draw a dead
     connector as a working one. *)
  let* cn_available = decode_bool_field_or json "available" ~default:false in
  let* cn_connected = decode_bool_field_or json "connected" ~default:false in
  let* cn_connection =
    decode_connector_connection ~status:cn_status ~available:cn_available
      ~connected:cn_connected
  in
  let* cn_channel = optional_string_field json "channel" in
  let* cn_error = optional_string_field json "error" in
  let* cn_status_source = optional_string_field json "status_source" in
  let* raw_gateway_state = optional_string_field json "gateway_state" in
  let* cn_gateway_state =
    match nonblank_option raw_gateway_state with
    | None -> Ok None
    | Some "disconnected" -> Ok (Some Connector_gateway_disconnected)
    | Some "awaiting_hello" -> Ok (Some Connector_gateway_awaiting_hello)
    | Some "identifying" -> Ok (Some Connector_gateway_identifying)
    | Some "resuming" -> Ok (Some Connector_gateway_resuming)
    | Some "connected" -> Ok (Some Connector_gateway_connected)
    | Some "reconnect_pending" -> Ok (Some Connector_gateway_reconnect_pending)
    | Some "failed" -> Ok (Some Connector_gateway_failed)
    | Some unknown ->
      Error (Printf.sprintf "unknown connector gateway state %S" unknown)
  in
  let* raw_poll_state = optional_string_field json "poll_state" in
  let* cn_poll_state =
    match nonblank_option raw_poll_state with
    | None -> Ok None
    | Some "not_started" -> Ok (Some Connector_poll_not_started)
    | Some "polling" -> Ok (Some Connector_poll_polling)
    | Some "degraded" -> Ok (Some Connector_poll_degraded)
    | Some unknown ->
      Error (Printf.sprintf "unknown connector poll state %S" unknown)
  in
  let* cn_endpoint = optional_string_field json "gate_base_url" in
  let* cn_status_path = optional_string_field json "status_path" in
  let* cn_binding_store_path = optional_string_field json "binding_store_path" in
  let* cn_binding_store_read_ok = optional_bool_field json "binding_store_read_ok" in
  let* cn_binding_store_error = optional_string_field json "binding_store_error" in
  let* cn_updated_at = optional_string_field json "updated_at" in
  let* cn_binding_source = optional_string_field json "binding_source" in
  let* cn_trigger_policy = optional_string_field json "trigger_policy" in
  let* cn_reply_mode = optional_string_field json "reply_mode" in
  let* cn_chat_db_path = optional_string_field json "chat_db_path" in
  let* cn_bot_user_id = optional_string_field json "bot_user_id" in
  let* cn_bot_user_name = optional_string_field json "bot_user_name" in
  let* cn_bot_token_present = optional_bool_field json "bot_token_present" in
  let* cn_app_token_present = optional_bool_field json "app_token_present" in
  let* cn_gate_healthy = optional_bool_field json "gate_healthy" in
  let* cn_pid = optional_int_field json "pid" in
  let* cn_guild_count = optional_int_field json "guild_count" in
  let* raw_directory_state = optional_string_field json "directory_state" in
  let* cn_directory_state =
    match nonblank_option raw_directory_state with
    | None -> Ok None
    | Some "not_started" -> Ok (Some Connector_directory_not_started)
    | Some "refreshing" -> Ok (Some Connector_directory_refreshing)
    | Some "complete" -> Ok (Some Connector_directory_complete)
    | Some "partial" -> Ok (Some Connector_directory_partial)
    | Some unknown ->
      Error (Printf.sprintf "unknown connector directory state %S" unknown)
  in
  let* cn_directory_server_count =
    optional_int_field json "directory_server_count"
  in
  let* cn_directory_channel_count =
    optional_int_field json "directory_channel_count"
  in
  let* cn_directory_person_count =
    optional_int_field json "directory_person_count"
  in
  let decode_string_rows label rows =
    decode_list label
      (function
        | `String value -> Ok value
        | _ -> Error (label ^ " contains a non-string value"))
      rows
  in
  let* authentication_rows =
    optional_list_field json "directory_authentication_failed"
  in
  let* cn_directory_authentication_failed =
    decode_string_rows "directory_authentication_failed" authentication_rows
  in
  let* permission_rows = optional_list_field json "directory_permission_denied" in
  let* cn_directory_permission_denied =
    decode_string_rows "directory_permission_denied" permission_rows
  in
  let* error_rows = optional_list_field json "directory_errors" in
  let* cn_directory_errors = decode_string_rows "directory_errors" error_rows in
  let* cn_directory_updated_at =
    optional_string_field json "directory_updated_at"
  in
  let* cn_workspace_id = optional_string_field json "workspace_id" in
  let* bindings_json = required_list_field json "configured_bindings" in
  let* cn_bindings =
    decode_list "configured_bindings" decode_connector_binding bindings_json
  in
  Ok
    { cn_id
    ; cn_display_name
    ; cn_available
    ; cn_connected
    ; cn_status
    ; cn_connection
    ; cn_channel = nonblank_option cn_channel
    ; cn_error = nonblank_option cn_error
    ; cn_status_source = nonblank_option cn_status_source
    ; cn_gateway_state
    ; cn_poll_state
    ; cn_endpoint = nonblank_option cn_endpoint
    ; cn_status_path = nonblank_option cn_status_path
    ; cn_binding_store_path = nonblank_option cn_binding_store_path
    ; cn_binding_store_read_ok
    ; cn_binding_store_error = nonblank_option cn_binding_store_error
    ; cn_updated_at = nonblank_option cn_updated_at
    ; cn_binding_source = nonblank_option cn_binding_source
    ; cn_trigger_policy = nonblank_option cn_trigger_policy
    ; cn_reply_mode = nonblank_option cn_reply_mode
    ; cn_chat_db_path = nonblank_option cn_chat_db_path
    ; cn_bot_user_id = nonblank_option cn_bot_user_id
    ; cn_bot_user_name = nonblank_option cn_bot_user_name
    ; cn_bot_token_present
    ; cn_app_token_present
    ; cn_gate_healthy
    ; cn_pid =
        (match cn_pid with
         | Some pid when pid > 0 -> Some pid
         | Some _ | None -> None)
    ; cn_guild_count
    ; cn_directory_state
    ; cn_directory_server_count
    ; cn_directory_channel_count
    ; cn_directory_person_count
    ; cn_directory_authentication_failed
    ; cn_directory_permission_denied
    ; cn_directory_errors
    ; cn_directory_updated_at = nonblank_option cn_directory_updated_at
    ; cn_workspace_id = nonblank_option cn_workspace_id
      (* Name evidence does not travel on the connector object. It arrives as
         one connector name page per kind, and connector_with_name_pages
         fills these in from those pages -- which is already why the two
         fields below start empty. The connector used to be read for
         server_names_path, channel_names_path, people_names_path and
         name_mappings as well, but no producer has emitted any of them since
         the page vocabulary landed, so those reads only claimed a source
         that does not exist. *)
    ; cn_server_names_path = None
    ; cn_channel_names_path = None
    ; cn_people_names_path = None
    ; cn_name_mappings = []
    ; cn_name_mapping_scope = None
    ; cn_names_error = None
    ; cn_bindings
    }

let decode_connector_name_page json =
  let* cnp_connector_id = required_string_field json "connector_id" in
  let* raw_kind = required_string_field json "kind" in
  let* cnp_kind =
    match raw_kind with
    | "channel" -> Ok Connector_channel_name
    | "person" -> Ok Connector_person_name
    | "server" -> Ok Connector_server_name
    | unknown -> Error (Printf.sprintf "unknown connector name kind %S" unknown)
  in
  let* cnp_mapping_scope = required_string_field json "mapping_scope" in
  let* cnp_current_workspace_id =
    optional_string_field json "current_workspace_id"
  in
  let* cnp_path = required_string_field json "path" in
  let* cnp_after_id = optional_string_field json "after_id" in
  let* cnp_next_after_id = optional_string_field json "next_after_id" in
  let* cnp_total = required_int_field json "total" in
  let* cnp_has_more = required_bool_field json "has_more" in
  let* mappings_json = required_list_field json "mappings" in
  let decode_mapping row =
    let* cnm_id = required_string_field row "id" in
    let* cnm_name = required_string_field row "name" in
    Ok { cnm_kind = cnp_kind; cnm_id; cnm_name }
  in
  let* cnp_mappings = decode_list "mappings" decode_mapping mappings_json in
  Ok
    { cnp_connector_id
    ; cnp_kind
    ; cnp_mapping_scope
    ; cnp_current_workspace_id = nonblank_option cnp_current_workspace_id
    ; cnp_path
    ; cnp_after_id = nonblank_option cnp_after_id
    ; cnp_next_after_id = nonblank_option cnp_next_after_id
    ; cnp_total
    ; cnp_has_more
    ; cnp_mappings
    }

let connector_with_name_pages connector ~pages ~error =
  let pages =
    List.filter
      (fun page -> String.equal page.cnp_connector_id connector.cn_id)
      pages
  in
  let mappings =
    let keyed = Hashtbl.create 32 in
    List.iter
      (fun page ->
        List.iter
          (fun mapping ->
            Hashtbl.replace keyed (mapping.cnm_kind, mapping.cnm_id) mapping)
          page.cnp_mappings)
      pages;
    Hashtbl.to_seq_values keyed
    |> List.of_seq
    |> List.sort (fun left right ->
           match compare left.cnm_kind right.cnm_kind with
           | 0 -> String.compare left.cnm_id right.cnm_id
           | order -> order)
  in
  let channel_name channel_id =
    List.find_map
      (fun mapping ->
         match mapping.cnm_kind with
         | Connector_channel_name when String.equal mapping.cnm_id channel_id ->
             Some mapping.cnm_name
         | Connector_channel_name | Connector_person_name
         | Connector_server_name -> None)
      mappings
  in
  let page_path kind =
    List.find_map
      (fun page -> if page.cnp_kind = kind then Some page.cnp_path else None)
      pages
  in
  let workspace_id =
    List.find_map (fun page -> page.cnp_current_workspace_id) pages
  in
  { connector with
    cn_bindings =
      List.map
        (fun binding ->
           { binding with
             cb_channel_name = channel_name binding.cb_channel_id
           })
        connector.cn_bindings
  ; cn_name_mappings = mappings
  ; cn_server_names_path = page_path Connector_server_name
  ; cn_channel_names_path = page_path Connector_channel_name
  ; cn_people_names_path = page_path Connector_person_name
  ; cn_workspace_id = workspace_id
  ; cn_name_mapping_scope =
      List.find_map (fun page -> Some page.cnp_mapping_scope) pages
  ; cn_names_error = error
  }

let decode_connector_snapshot json =
  let* connectors_json = required_list_field json "connectors" in
  let row_connector_id = function
    | `Assoc fields -> (
        match List.assoc_opt "connector_id" fields with
        | Some (`String id) -> nonblank_option (Some id)
        | Some _ | None -> None)
    | _ -> None
  in
  let cs_connectors, cs_refused =
    connectors_json
    |> List.mapi (fun row item ->
           match decode_connector item with
           | Ok connector -> Either.Left connector
           | Error reason ->
               Either.Right
                 { cr_row = row
                 ; cr_connector_id = row_connector_id item
                 ; cr_reason = reason
                 })
    |> List.partition_map Fun.id
  in
  let cs_connectors =
    List.sort
      (fun left right -> String.compare left.cn_id right.cn_id)
      cs_connectors
  in
  let* cs_total = required_int_field json "total" in
  let* cs_active = required_int_field json "active_count" in
  Ok { cs_connectors; cs_refused; cs_total; cs_active }
