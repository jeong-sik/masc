(** Env_setting — the declared environment knobs, as closed vocabularies.

    A knob is a constructor whose wire name, default, operator-facing category
    and description come from one exhaustive match. Reading goes through the
    constructor and {!rows_in} reports it, so a knob cannot be readable by the
    process and absent from [masc_config].

    Adding a constructor is a compile error at its [spec], and {!all_rows}
    picks it up from [@@deriving enumerate] without a second list to keep in
    step. *)

type row =
  { env_name : string
  ; default_display : string
  ; category : string
  ; description : string
  }

module Bool_knob : sig
  type t = Oauth_enabled [@@deriving enumerate]

  val env_name : t -> string
  val default : t -> bool
  val get : t -> bool
end

module Int_knob : sig
  type t =
    | Oauth_code_ttl_sec
    | Oauth_access_token_ttl_sec
    | Oauth_refresh_token_ttl_sec
    | Oauth_max_pending_codes
    | Oauth_max_clients
    | Sse_connect_max_in_window
    | Board_flusher_inbox_capacity
    | Executor_domain_count
    | Full_health_critical_failure_threshold
    | Rate_limit_bucket_ttl_sec
    | Workspace_file_max_read_bytes
    | Tcp_listen_backlog
    | Ws_missed_pong_threshold
  [@@deriving enumerate]

  val env_name : t -> string
  val default : t -> int
  val get : t -> int
end

module Float_knob : sig
  type t =
    | Sse_reconnect_min_interval_s
    | Sse_connect_window_s
    | Sidecar_reconcile_backoff_sec
    | Sidecar_control_timeout_sec
    | Sidecar_schema_timeout_sec
    | Full_health_refresh_timeout_sec
    | Repo_sync_interval_sec
    | Snapshot_interval_sec
  [@@deriving enumerate]

  val env_name : t -> string
  val default : t -> float
  val get : t -> float
end

module String_opt_knob : sig
  type t =
    | Imessage_chat_db_path
    | Imessage_reply_mode
    | Imessage_self_chat_guid
    | Imessage_poll_interval_sec
    | Imessage_cursor_path
    | Sidecar_root
  [@@deriving enumerate]

  val env_name : t -> string

  val get : t -> string option
  (** The trimmed value, or [None] when the variable is unset or blank. *)
end

val all_rows : row list
(** Every declared knob, bool knobs first. *)

val rows_in : category:string -> row list
(** {!all_rows} restricted to one operator-facing category. *)
