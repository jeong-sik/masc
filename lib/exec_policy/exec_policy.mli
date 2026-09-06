(** Shared execution policy for shell-like tool frontends.

    This module owns the command/Shell IR policy substrate used by
    [tool_execute] and code-shell surfaces. Tool bundles should adapt to this
    policy layer instead of becoming the policy owner. *)

type block_reason =
  | Empty_command
  | Chain_or_redirect
  | Injection
  | Process_substitution
  | Unsafe_redirect
  | Pipes_not_allowed

(** The model-facing sentence for a block reason. The short reasons render
    from managed templates ([config/prompts/exec_policy.md]); on render
    failure the bare variant tag is returned and the miss is logged. *)
val block_reason_to_string : block_reason -> string

type parse_mode = Strict | Tool_execute

val parse_string_to_ir :
  mode:parse_mode -> string -> (Masc_exec.Shell_ir.t, block_reason) result

val validate_command_tool_execute :
  ?allow_pipes:bool ->
  Masc_exec.Shell_ir.t ->
  (unit, block_reason) result

(** Filesystem path normalization and allowlist checks. Exposed so callers can
    reach [validate_path] via [Exec_policy.Paths] (e.g. test keepers). *)
module Paths = Exec_policy_paths

val existing_sibling_dirs_hint : ?workdir:string -> string -> string option
(** For a required directory [path] that is missing on disk, enumerate the
    real child-directory names under its nearest existing ancestor (read via
    [Sys.readdir]) and render them as a [Cwd_not_directory] hint. Grounds
    caller self-correction in filesystem truth (a stale directory name yields
    the real sibling entries) without a rename table or any
    substring/similarity matching. [None] when no existing
    ancestor directory has child directories to surface. *)

val validate_shell_ir_paths :
  ?workdir:string ->
  Masc_exec.Shell_ir.t ->
  (unit, string) result
(** Validate only explicit typed filesystem scopes carried by Shell IR:
    [cwd] and redirect targets. Positional argv is opaque application data and
    is never classified from command names, flag strings, or token shapes.
    Runtime sandbox containment remains authoritative for the process itself. *)

(** Flatten all literal stage words from a parsed shell IR.
    Replaces the historical string-era extractors. *)
val flat_stage_words : Masc_exec.Shell_ir.t -> string list

(** All typed callers now route through {!parse_string_to_ir} +
    {!Exec_policy_literal_words.flat_stage_words}. *)

val sanitize_command_for_log_of_ir :
  fallback_cmd:string -> Masc_exec.Shell_ir.t -> string
val truncate_for_log : ?max_len:int -> string -> string
