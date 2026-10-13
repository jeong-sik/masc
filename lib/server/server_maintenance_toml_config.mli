(** Typed [maintenance] contract for runtime.toml.

    Prune passes (startup and periodic) delete JSONL day files older than one
    retention window. That window used to come from the environment alone
    ([MASC_JSONL_RETENTION_DAYS]); it now resolves per workspace as process
    env, then this table, then the documented default — the same
    caller-override-wins order the keeper TOML bridge uses. Both prunes share
    {!resolve_retention_days}, so the window cannot drift between them. *)

val table_name : string
(** ["maintenance"] — the runtime.toml table this module owns. *)

val retention_days_key : string
(** ["jsonl_retention_days"] — day-file retention for the JSONL stores under
    [.masc]. Must be a positive integer when present. *)

type diagnostic =
  | Toml_syntax of string
  | Unreadable_file of string
  | Not_a_table
  | Unexpected_field of string
  | Retention_days_not_an_integer of string
  | Retention_days_not_positive of int
(** Closed parse failures. [Unexpected_field] carries the offending key;
    [Retention_days_not_an_integer] carries the TOML type error. *)

val diagnostic_to_string : diagnostic -> string

val parse_string : string -> (int option, diagnostic list) result
(** Parse one runtime.toml document. [Ok None] means no [maintenance] table
    or no [jsonl_retention_days] key; [Ok (Some days)] is a positive window.
    Any diagnostic fails the whole table — callers fall back, never guess. *)

type source =
  | Env
  | Toml
  | Default
(** Where {!resolve_retention_days} took the window from. *)

val resolve_retention_days : config_path:string -> int * source * diagnostic list
(** Resolve the window for one workspace: process env (blank counts as
    unset), then [config_path]'s [maintenance] table, then the documented
    default. A missing file is quiet [Default]; anything else wrong with the
    file parses to [Default] with diagnostics for the caller to log. Reads
    the process environment and the filesystem. *)
