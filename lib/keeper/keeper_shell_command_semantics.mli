(** Keeper shell command semantics.

    Pure command-shape and cwd policy helpers shared by Local/Docker shell
    dispatch. This module does not execute commands and does not know how
    Docker is launched.

    IR-first variants ([parsed_stages_of_ir], [effective_stages_of_ir])
    accept pre-parsed [Shell_ir.t] and skip re-parsing. *)

type parsed_stage = { bin : string; args : string list }

val parsed_stages_of_ir : Masc_exec.Shell_ir.t -> parsed_stage list
(** Extract literal command stages from a pre-parsed Shell IR. *)

val effective_stages_of_ir : Masc_exec.Shell_ir.t -> parsed_stage list
(** Extract effective command stages (after env/opam unwrap) from a
    pre-parsed Shell IR. *)

val stages_targets_git_or_gh : parsed_stage list -> bool
val stages_targets_gh : parsed_stage list -> bool

val cmd_prefix : string -> string
(** First whitespace-delimited token from a command string, with
    surrounding quotes stripped. *)

val gh_repo_flag_api_misuse_of_stages :
  parsed_stage list -> (string * string) option
(** Detect the invalid [gh --repo <repo> api <endpoint>] shape from
    pre-computed stages. *)

val resolve_sandbox_root_git_cwd_of_stages :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  cmd:string ->
  parsed_stage list ->
  string * string option
(** Pre-computed stages variant. Callers that already hold
    [effective_stages_of_ir ir] pass them directly to avoid
    re-parsing. *)

val effective_stages_of_cmd : string -> parsed_stage list
(** Parse-and-extract helper for callers that only hold a raw command
    string. Equivalent to [effective_stages_of_ir] but performs the
    [Bash.parse_string] internally. Returns [[]] on parse failure. *)

val cmd_targets_gh : string -> bool
(** [true] iff parsing [cmd] yields effective stages whose head binary is
    [gh] (single stage or last stage of a pipeline). Boundary policy: this
    lives in [Keeper_shell_command_semantics] only, never in
    [Keeper_shell_docker] (asserted by test_keeper_sandbox_boundary_policy). *)

val cmd_targets_git_or_gh : string -> bool
(** [true] iff parsing [cmd] yields effective stages whose head binary is
    [git] or [gh]. Same boundary policy as {!cmd_targets_gh}. *)
