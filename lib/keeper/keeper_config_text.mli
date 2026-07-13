(** Keeper_config_text — String/UTF-8 processing, bool parsing, input key
    validation, and goal-horizon text normalization.

    Extracted from [keeper_config.ml] during godfile decomposition.

    @since God file decomposition *)

(* ── Bool / string parsing ──────────────────────────────────── *)

val bool_default_true_of_env : string -> bool

val bool_of_string : string -> bool option

val bool_of_env_default : string -> default:bool -> bool

val bool_of_env_opt : string -> bool option

(* ── Name validation ────────────────────────────────────────── *)

val validate_name : string -> bool

(* ── Configuration constants ────────────────────────────────── *)

val default_proactive_enabled : bool
val default_goal_max_chars : int
val prompt_render_max_bytes : int

(* ── Removed / rejected keeper input keys ───────────────────── *)

val removed_keeper_input_key_names : string list
val removed_keeper_msg_input_key_names : string list

val present_json_keys : string list -> Yojson.Safe.t -> string list

val reject_removed_keeper_input_keys :
  ?allow_sandbox_fields:bool ->
  tool_name:string ->
  Yojson.Safe.t ->
  (unit, string) result

val reject_removed_keeper_msg_input_keys :
  tool_name:string -> Yojson.Safe.t -> (unit, string) result

(* ── UTF-8 string processing ────────────────────────────────── *)

val utf8_repair_string : string -> string

(* ── Prompt text normalization ──────────────────────────────── *)

val normalize_prompt_text : max_bytes:int -> string -> string

val normalize_goal_text : ?max_len:int -> string -> string
