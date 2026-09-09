(** Env_setting — the declared environment knobs, as closed vocabularies.

    A knob is a constructor. Its wire name, default, operator-facing category
    and description come from one exhaustive [spec] match, and the row list the
    snapshot reports is that spec mapped over [all], so a knob cannot be
    readable by the process and absent from [masc_config].

    The list is static rather than filled by declaration-time side effects.
    A registry populated at module initialization is complete only in a binary
    that links the declaring modules: [Env_config_snapshot] links before them
    (masc_config.cmxa order 683 vs 752), and a test executable that never
    mentions them does not link them at all, so the catalogue would report
    nothing. *)

type row =
  { env_name : string
  ; default_display : string
  ; category : string
  ; description : string
  }

module Bool_knob = struct
  type t = Oauth_enabled [@@deriving enumerate]

  let spec = function
    | Oauth_enabled ->
      ( "MASC_OAUTH_ENABLED"
      , false
      , "auth"
      , "Enable the OAuth authorization server" )
  ;;

  let env_name t = let n, _, _, _ = spec t in n
  let default t = let _, d, _, _ = spec t in d

  let row t =
    let env_name, default, category, description = spec t in
    { env_name; default_display = string_of_bool default; category; description }
  ;;

  let get t = Env_config_core.get_bool ~default:(default t) (env_name t)
end

module Int_knob = struct
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
    | Gc_space_overhead
  [@@deriving enumerate]

  let spec = function
    | Oauth_code_ttl_sec ->
      "MASC_OAUTH_CODE_TTL_SEC", 300, "auth", "Authorization-code lifetime in seconds"
    | Oauth_access_token_ttl_sec ->
      "MASC_OAUTH_ACCESS_TOKEN_TTL_SEC", 3600, "auth", "Access-token lifetime in seconds"
    | Oauth_refresh_token_ttl_sec ->
      ( "MASC_OAUTH_REFRESH_TOKEN_TTL_SEC"
      , 2_592_000
      , "auth"
      , "Refresh-token lifetime in seconds" )
    | Oauth_max_pending_codes ->
      ( "MASC_OAUTH_MAX_PENDING_CODES"
      , 128
      , "auth"
      , "Maximum process-local pending authorization codes" )
    | Oauth_max_clients ->
      ( "MASC_OAUTH_MAX_CLIENTS"
      , 128
      , "auth"
      , "Maximum durable dynamic-client registrations" )
    | Sse_connect_max_in_window ->
      ( "MASC_SSE_CONNECT_MAX_IN_WINDOW"
      , 10
      , "runtime"
      , "SSE reconnects admitted inside one window; <= 0 disables the window limit" )
    | Board_flusher_inbox_capacity ->
      ( "MASC_BOARD_FLUSHER_INBOX_CAPACITY"
      , 1000
      , "runtime"
      , "Board flusher inbox capacity" )
    | Executor_domain_count ->
      ( "MASC_EXECUTOR_DOMAIN_COUNT"
      , 0
      , "runtime"
      , "Executor domain count override; <= 0 keeps the host-aware recommendation" )
    | Full_health_critical_failure_threshold ->
      ( "MASC_FULL_HEALTH_CRITICAL_FAILURE_THRESHOLD"
      , 5
      , "runtime"
      , "Consecutive /health?full=1 refresh failures before the critical counter \
         fires; floored at 1" )
    | Rate_limit_bucket_ttl_sec ->
      ( "MASC_RATE_LIMIT_BUCKET_TTL_SEC"
      , 300
      , "runtime"
      , "Rate-limit bucket staleness TTL in seconds" )
    | Workspace_file_max_read_bytes ->
      ( "MASC_WORKSPACE_FILE_MAX_READ_BYTES"
      , 1_048_576
      , "runtime"
      , "Maximum bytes the IDE workspace file endpoint serves in one response" )
    | Tcp_listen_backlog ->
      ( "MASC_TCP_LISTEN_BACKLOG", 128, "server", "TCP listen backlog" )
    | Ws_missed_pong_threshold ->
      ( "MASC_WS_MISSED_PONG_THRESHOLD"
      , 3
      , "transport"
      , "Missed pongs before a WebSocket session is closed; read once per \
         session at creation" )
    | Gc_space_overhead ->
      ( "MASC_GC_SPACE_OVERHEAD"
      , 100
      , "runtime"
      , "OCaml GC space_overhead the server sets at boot" )
  ;;

  let env_name t = let n, _, _, _ = spec t in n
  let default t = let _, d, _, _ = spec t in d

  let row t =
    let env_name, default, category, description = spec t in
    { env_name; default_display = string_of_int default; category; description }
  ;;

  let get t = Env_config_core.get_int ~default:(default t) (env_name t)
end

module String_opt_knob = struct
  (* Optional overrides: unset or blank reads as [None] and the caller resolves
     what to do. [default_display] is what the operator surface should show for
     that absence, which is why it is spelled here rather than derived. *)
  type t =
    | Imessage_chat_db_path
    | Imessage_reply_mode
    | Imessage_self_chat_guid
    | Imessage_poll_interval_sec
    | Imessage_cursor_path
    | Sidecar_root
    | Voice_realtime_ws_url
  [@@deriving enumerate]

  let spec = function
    | Imessage_chat_db_path ->
      ( "MASC_IMESSAGE_CHAT_DB_PATH"
      , "$HOME/Library/Messages/chat.db"
      , "channel"
      , "Messages.app SQLite store; unset resolves under the account's home" )
    | Imessage_reply_mode ->
      ( "MASC_IMESSAGE_REPLY_MODE"
      , "(none)"
      , "channel"
      , "iMessage reply mode; parsed by the channel gate" )
    | Imessage_self_chat_guid ->
      ( "MASC_IMESSAGE_SELF_CHAT_GUID"
      , "(derived)"
      , "channel"
      , "Explicit note-to-self chat handle; unset resolves from chat.db" )
    | Imessage_poll_interval_sec ->
      ( "MASC_IMESSAGE_POLL_INTERVAL_SEC"
      , "(none)"
      , "channel"
      , "iMessage poll interval in seconds; parsed by the gateway" )
    | Imessage_cursor_path ->
      ( "MASC_IMESSAGE_CURSOR_PATH"
      , "(derived)"
      , "channel"
      , "Where the last delivered message ROWID is kept" )
    | Sidecar_root ->
      ( "MASC_SIDECAR_ROOT"
      , "(derived)"
      , "runtime"
      , "Repository root the sidecar routes resolve paths against" )
    | Voice_realtime_ws_url ->
      ( "MASC_VOICE_REALTIME_WS_URL"
      , "(none)"
      , "transport"
      , "WebSocket endpoint for the realtime voice bridge" )
  ;;

  let env_name t = let n, _, _, _ = spec t in n

  let row t =
    let env_name, default_display, category, description = spec t in
    { env_name; default_display; category; description }
  ;;

  let get t = Env_config_core.trim_opt (Sys.getenv_opt (env_name t))
end

module Float_knob = struct
  type t =
    | Sse_reconnect_min_interval_s
    | Sse_connect_window_s
    | Sidecar_reconcile_backoff_sec
    | Sidecar_control_timeout_sec
    | Sidecar_schema_timeout_sec
    | Full_health_refresh_timeout_sec
    | Repo_sync_interval_sec
    | Snapshot_interval_sec
    | Lazy_task_boot_guard_sec
  [@@deriving enumerate]

  let spec = function
    | Sse_reconnect_min_interval_s ->
      ( "MASC_SSE_RECONNECT_MIN_INTERVAL_S"
      , 1.0
      , "runtime"
      , "Minimum interval between SSE reconnects for one session; <= 0 disables \
         the cooldown" )
    | Sse_connect_window_s ->
      ( "MASC_SSE_CONNECT_WINDOW_S"
      , 60.0
      , "runtime"
      , "Sliding window over which SSE reconnects are counted; <= 0 disables \
         the window limit" )
    | Sidecar_reconcile_backoff_sec ->
      ( "MASC_SIDECAR_RECONCILE_BACKOFF_SEC"
      , 30.0
      , "runtime"
      , "Backoff between repeated same-generation sidecar start dispatches" )
    | Sidecar_control_timeout_sec ->
      ( "MASC_SIDECAR_CONTROL_TIMEOUT_SEC"
      , 5.0
      , "runtime"
      , "Subprocess timeout for sidecar control commands; floored at 1s" )
    | Sidecar_schema_timeout_sec ->
      ( "MASC_SIDECAR_SCHEMA_TIMEOUT_SEC"
      , 10.0
      , "runtime"
      , "Subprocess timeout for sidecar schema generation; floored at 1s" )
    | Full_health_refresh_timeout_sec ->
      ( "MASC_FULL_HEALTH_REFRESH_TIMEOUT_SEC"
      , 20.0
      , "runtime"
      , "Timeout for a /health?full=1 cache refresh; floored at 1s" )
    | Repo_sync_interval_sec ->
      ( "MASC_REPO_SYNC_INTERVAL_SEC"
      , 300.0
      , "runtime"
      , "Repository auto-sync interval in seconds; a non-positive value keeps \
         the default" )
    | Snapshot_interval_sec ->
      ( "MASC_SNAPSHOT_INTERVAL_SEC"
      , 5.0
      , "runtime"
      , "Minimum seconds between SSE snapshot broadcasts" )
    | Lazy_task_boot_guard_sec ->
      ( "MASC_LAZY_TASK_BOOT_GUARD_SEC"
      , 120.0
      , "server"
      , "How long boot waits on lazy tasks before publishing readiness; a \
         non-positive value keeps the default" )
  ;;

  let env_name t = let n, _, _, _ = spec t in n
  let default t = let _, d, _, _ = spec t in d

  let row t =
    let env_name, default, category, description = spec t in
    { env_name
    ; default_display = Printf.sprintf "%g" default
    ; category
    ; description
    }
  ;;

  let get t = Env_config_core.get_float ~default:(default t) (env_name t)
end

let all_rows =
  List.map Bool_knob.row Bool_knob.all
  @ List.map Int_knob.row Int_knob.all
  @ List.map Float_knob.row Float_knob.all
  @ List.map String_opt_knob.row String_opt_knob.all
;;
let rows_in ~category = List.filter (fun r -> String.equal r.category category) all_rows
