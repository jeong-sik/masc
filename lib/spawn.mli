(** Spawn — Agent subprocess management.

    Manages CLI tool invocation for MASC agents including Claude, Gemini,
    and Codex. Handles prompt construction, MCP tool flag assembly,
    output parsing, and token tracking.

    @since 0.1.0 *)

(** {1 Types} *)

type parsed_output =
  { text : string
  ; input_tokens : int option
  ; output_tokens : int option
  ; cache_creation_tokens : int option
  ; cache_read_tokens : int option
  ; cost_usd : float option
  }

type mcp_flag =
  | Mcp_joined of string
  | Mcp_spread of string
  | Mcp_none

type prompt_flag =
  | Prompt_flag of string
  | Prompt_stdin

type spawn_config =
  { agent_name : string
  ; command : string
  ; timeout_seconds : int
  ; working_dir : string option
  ; mcp_tools : string list
  ; parse_output : string -> parsed_output
  ; stdin_prompt : bool
  ; mcp_mode : mcp_flag
  ; prompt_mode : prompt_flag
  }

type spawn_result =
  { success : bool
  ; output : string
  ; exit_code : int
  ; elapsed_ms : int
  ; input_tokens : int option
  ; output_tokens : int option
  ; cache_creation_tokens : int option
  ; cache_read_tokens : int option
  ; cost_usd : float option
  }

(** {1 Configuration} *)

val masc_mcp_tools : string list
val masc_lifecycle_suffix : string
val get_config : string -> spawn_config option

(** {1 Output Parsing} *)

val parse_raw_output : string -> parsed_output
val parse_claude_output : string -> parsed_output
val parse_gemini_output : string -> parsed_output

(** {1 CLI Argument Builders} *)

val build_mcp_args : string -> string list -> string list
val build_prompt_args : string -> string -> string list
val build_mcp_args_from_config : spawn_config -> string list -> string list
val build_prompt_args_from_config : spawn_config -> string -> string list
val parse_command : string -> string list

(** {1 Spawning} *)

val spawn
  :  agent_name:string
  -> prompt:string
  -> ?timeout_seconds:int
  -> ?working_dir:string
  -> unit
  -> spawn_result

(** Deprecated alias for {!spawn}. *)
val spawn_sync
  :  agent_name:string
  -> prompt:string
  -> ?timeout_seconds:int
  -> ?working_dir:string
  -> unit
  -> spawn_result

(** {1 Result Formatting} *)

val int_opt_to_json : int option -> Yojson.Safe.t
val float_opt_to_json : float option -> Yojson.Safe.t
val result_to_json : spawn_result -> Yojson.Safe.t
val format_token_info : spawn_result -> string
val result_to_string : spawn_result -> string

(** {1 Helpers} *)

val output_for_status
  :  status:Unix.process_status
  -> stdout:string
  -> stderr:string
  -> string

val fallback_spawn_failure_output : exit_code:int -> string
val add_default_model_arg : string -> string list -> string list
