(** Keeper_config_text — String/UTF-8 processing, bool parsing, input key
    validation, and prompt text normalization.

    Extracted from [keeper_config.ml] during godfile decomposition.

    @since God file decomposition *)

(* ── Bool / string parsing ──────────────────────────────────── *)

val bool_default_true_of_env : string -> bool

val bool_of_string : string -> bool option

val bool_of_env_default : string -> default:bool -> bool

val bool_of_env_opt : string -> bool option

(* ── Name validation ────────────────────────────────────────── *)

val validate_name : string -> bool
val invalid_name_error : string -> string
(** Canonical explanation for a value rejected by {!validate_name}. *)

(* ── Configuration constants ────────────────────────────────── *)

val default_proactive_enabled : bool
val prompt_render_max_bytes : int

(* ── UTF-8 string processing ────────────────────────────────── *)

val utf8_repair_string : string -> string

(* ── Prompt text normalization ──────────────────────────────── *)

val normalize_prompt_text : max_bytes:int -> string -> string
