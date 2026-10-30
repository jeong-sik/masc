(** Env_config_imessage — iMessage connector env accessors.

    Config-boundary reads for the in-process iMessage connector. Each returns
    [None] when the variable is unset or blank.

    Every name lives here once. The four defects this connector shipped on
    2026-08-16 were all one shape — two readers of the same setting that agreed
    on no variable name (#28882) — and a single accessor is what stops that
    from being expressible. *)

val chat_db_path : unit -> string
(** Where Messages.app's SQLite store is: [MASC_IMESSAGE_CHAT_DB_PATH] when
    set, otherwise [$HOME/Library/Messages/chat.db]. The override exists so
    tests can read a fixture on a machine that has no Messages.app. Resolved
    here rather than in the connector because both halves — the variable and
    the home-relative default — are environment reads, and those live at the
    config boundary. *)

val reply_mode_opt : unit -> string option
(** [MASC_IMESSAGE_REPLY_MODE] — raw value, parsed by
    {!Channel_gate_imessage_state.parse_reply_mode}. *)

val self_chat_guid_opt : unit -> string option
(** [MASC_IMESSAGE_SELF_CHAT_GUID] — explicit note-to-self chat handle. Absent
    ⇒ resolved from chat.db. *)

val poll_interval_sec_opt : unit -> string option
(** [MASC_IMESSAGE_POLL_INTERVAL_SEC] — raw value, parsed by the gateway. *)

val cursor_path_opt : unit -> string option
(** [MASC_IMESSAGE_CURSOR_PATH] — where the last delivered [message.ROWID] is
    kept. Absent ⇒ [.gate/runtime/imessage/cursor.json] under the base path. *)
