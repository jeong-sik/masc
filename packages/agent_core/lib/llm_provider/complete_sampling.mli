(** Gemini URL construction.

    Extracted from {!Complete} to keep the main completion module
    focused on request/response lifecycle.

    @since 0.205.9 *)

(** {1 Gemini URL Construction} *)

(** Construct Gemini API URL with model_id in path and optional key param.
    Exposed for testing. *)
val gemini_url : config:Provider_config.t -> stream:bool -> string
