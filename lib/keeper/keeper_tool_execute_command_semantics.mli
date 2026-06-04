(** Execute command semantics.

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

val stages_target_repo_commands : parsed_stage list -> bool
val stages_target_repo_hosting_cli : parsed_stage list -> bool

val repo_hosting_cli_repo_flag_api_misuse_of_stages :
  parsed_stage list -> (string * string) option
(** Detect the invalid [gh --repo <repo> api <endpoint>] shape from
    pre-computed stages. *)

val gh_pr_diff_misuse_of_stages :
  parsed_stage list -> string list option
(** Detect invalid [gh pr diff] usage with file filters or extra positional args. *)

val misuse_error_of_stages : parsed_stage list -> string option
(** Perform all command syntax misuse checks and return a descriptive error message if any. *)


val resolve_sandbox_root_git_cwd_of_stages :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  cmd:string ->
  parsed_stage list ->
  string * string option
(** Pre-computed stages variant. Callers that already hold
    [effective_stages_of_ir ir] pass them directly to avoid
    re-parsing. *)

val effective_stages_of_cmd : string -> parsed_stage list
(** Parse-and-extract helper for callers that only hold a raw command
    string. Equivalent to [effective_stages_of_ir] but parses internally.
    Returns [[]] on parse failure. *)
