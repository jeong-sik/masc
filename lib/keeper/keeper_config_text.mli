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
(** A portable name that is not the directory name of a runtime store kept
    directly under [keepers/] ([Common.Keepers_root_scoped]). *)
val invalid_name_error : string -> string
(** Canonical explanation for a value rejected by {!validate_name}. *)

(* ── UTF-8 string processing ────────────────────────────────── *)

val utf8_repair_string : string -> string

