(** Existing Telegram bot credential, resolved at the config boundary. *)
val bot_token_opt : unit -> string option

(** Existing environment or runtime.toml path overrides, resolved against the
    effective base path. TELEGRAM_ names take precedence over MASC_TELEGRAM_. *)
val binding_store_path : unit -> string
val binding_audit_path : unit -> string
