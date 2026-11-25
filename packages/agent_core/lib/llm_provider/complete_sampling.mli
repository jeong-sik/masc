(** Gemini URL construction.

    Extracted from {!Complete} to keep the main completion module
    focused on request/response lifecycle.

    @since 0.205.9 *)

(** {1 Gemini URL Construction} *)

type gemini_target =
  { base_url : string
  ; model_resource : string
  }

(** Canonical model target shared by generation and input measurement. *)
val gemini_target : config:Provider_config.t -> gemini_target

val gemini_count_tokens_url : gemini_target -> string

(** Construct the Gemini generateContent or streamGenerateContent URL.
    Credentials are sent in headers. *)
val gemini_url : config:Provider_config.t -> stream:bool -> string
