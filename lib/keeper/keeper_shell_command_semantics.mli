(** Keeper shell command semantics.

    Pure command-shape and cwd policy helpers shared by Local/Docker shell
    dispatch. This module does not execute commands and does not know how
    Docker is launched.

    All public functions accept pre-computed [parsed_stage list] (from
    [parsed_stages_of_ir] or [effective_stages_of_ir]) instead of raw strings.
    Callers that hold a string should parse it once with
    [Masc_exec_command_gate.Shell_command_gate.parse_to_ir_opt] and then pass
    the resulting stages to the helpers below. *)

type parsed_stage = { bin : string; args : string list }

val parsed_stages_of_ir : Masc_exec.Shell_ir.t -> parsed_stage list
(** Extract literal command stages from a pre-parsed Shell IR. *)

val effective_stages_of_ir : Masc_exec.Shell_ir.t -> parsed_stage list
(** Extract effective command stages (after env/opam unwrap) from a
    pre-parsed Shell IR. *)

val stages_targets_git_or_gh : parsed_stage list -> bool
(** [true] when any effective stage's executable is [git] or [gh]. *)

val stages_targets_gh : parsed_stage list -> bool
(** [true] when any effective stage's executable is [gh]. *)

val stages_prefix : parsed_stage list -> string
(** Prefix used for shell-history grouping. Empty list yields [""]. *)

val detect_gh_repo_flag_with_api_misuse_of_stages :
  parsed_stage list -> (string * string) option
(** Detect the invalid [gh --repo <repo> api <endpoint>] shape.
    [--repo] is a subcommand flag, not a [gh api] global option. *)

val git_c_path_of_stages : parsed_stage list -> string option
(** Extract an explicit [-C <path>] argument from [git] stages. *)

val repos_path_hint_of_stages :
  cmd:string -> parsed_stage list -> (string * string) option
(** Find a [repos/<repo>] path hint in stage arguments. *)

val resolve_sandbox_root_git_cwd_of_stages :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  cmd:string ->
  parsed_stage list ->
  string * string option
(** Determine effective cwd for git/gh commands running at sandbox root.
    Callers that already hold [effective_stages_of_ir ir] pass them
    directly to avoid re-parsing. *)

val flat_stage_words : Masc_exec.Shell_ir.t -> string list
(** Flatten all literal stage words across pipeline segments.
    Non-literal-only stages contribute their literal prefix only. *)

val literal_words_of_simple :
  Masc_exec.Shell_ir.simple -> string list option
(** Extract literal words [[bin; arg0; arg1; ...]] from a single
    [Shell_ir.simple] stage.  Non-literal args abort extraction. *)
