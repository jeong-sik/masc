(** Connector snapshots and name pages; pure parsing and projection. *)

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

(** Where a websocket transport's gateway stands, as the Slack and Discord
    gateway state machines report it on the wire ([gateway_state]). *)
type connector_gateway_state =
  | Connector_gateway_disconnected
  | Connector_gateway_awaiting_hello
  | Connector_gateway_identifying
  | Connector_gateway_resuming
  | Connector_gateway_connected
  | Connector_gateway_reconnect_pending
  | Connector_gateway_failed

(** Where a polling transport stands, as the iMessage poller reports it on
    the wire ([poll_state]). *)
type connector_poll_state =
  | Connector_poll_not_started
  | Connector_poll_polling
  | Connector_poll_degraded

(** A connector the gate can deliver through, including the server-owned
    configuration and route evidence an operator needs to act on it. *)
type connector = {
  cn_id : string;
  cn_display_name : string;
  cn_available : bool;  (** Configured and usable. *)
  cn_connected : bool;
      (** Reachable right now. Kept apart from [cn_available]: a connector can
          be configured and unreachable, and the two call for different
          actions. *)
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

val decode_connector_name_page :
  Yojson.Safe.t -> (connector_name_page, string) result

val connector_with_name_pages :
  connector -> pages:connector_name_page list -> error:string option -> connector

(** A connector row the TUI could not read. The row is refused on its own,
    so the rows beside it still decode and draw. *)
type connector_refusal = {
  cr_row : int;  (** Position in the server's [connectors] list. *)
  cr_connector_id : string option;
      (** The row's [connector_id], when the row carries one. *)
  cr_reason : string;
}

type connector_snapshot = {
  cs_connectors : connector list;
  cs_refused : connector_refusal list;
  cs_total : int;
  cs_active : int;  (** How many the server counted as available. *)
}

val decode_connector_snapshot :
  Yojson.Safe.t -> (connector_snapshot, string) result
