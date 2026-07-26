(** Cross-cutting utilities used by many MASC subsystems.

    Kept small and dependency-light so every module can depend on it
    without introducing cycles. *)

(** Boolean environment variable with permissive truthy parsing:
    ["1"], ["true"], ["yes"], ["on"] (case/whitespace insensitive)
    all return [true]; absent, empty, or anything else returns [false]. *)
val env_true : string -> bool

(** [true] when [MASC_STRICT_FINALIZERS] env is truthy. Callers can
    opt into raising finally-block exceptions instead of swallowing
    them. *)
val strict_finalizers : unit -> bool

val handle_finalizer_error :
  module_name:string ->
  label:string ->
  during_exception:bool ->
  backtrace:Printexc.raw_backtrace ->
  exn ->
  unit
(** Logs a finalizer failure. When [during_exception = false] and
    [strict_finalizers ()] is [true], re-raises [exn] with its backtrace
    so strict runs surface hidden bugs. *)

val protect :
  module_name:string ->
  finally_label:string ->
  finally:(unit -> unit) ->
  (unit -> 'a) ->
  'a
(** Like [Fun.protect], but routes finalizer failures through
    {!handle_finalizer_error} so normal runs never lose the primary
    exception and strict runs surface finally failures. *)

val masc_dirname : string
(** SSOT directory name for MASC runtime state. Value is [".masc"].
    Call sites MUST reference this constant (or {!masc_dir_from_base_path})
    rather than inlining the literal — see #9571. The
    [test_masc_dirname_ssot] enforcement test flags regressions. *)

val masc_dir_from_base_path : base_path:string -> string
(** [masc_dir_from_base_path ~base_path] is
    [Filename.concat base_path masc_dirname]. Canonical way to spell
    [<base_path>/.masc]. *)

val generation_namespaced_dir : parent_dir:string -> schema_version:int -> string
(** [<parent_dir>/v<schema_version>]: the storage namespace a durable store must
    use, derived from the row schema version it reads and writes.

    A store that spells its directory this way cannot present bytes of one
    schema version to a reader compiled for another: bumping [schema_version]
    relocates the whole store, so the new reader starts on an empty namespace
    instead of rejecting the old rows in place. That in-place rejection is the
    repeated failure tracked by #25287 — five instances in 2026-07 (#25078,
    #25197, #25231, #25135, and the board-attention partition v5/v6 hard cut
    this function is introduced for), each of which took live state off the hot
    path with no reader that could still decode it.

    Retirement is NON-DESTRUCTIVE and this function performs no I/O: rows of a
    retired version stay exactly where they were written, directly under
    [parent_dir]. Nothing here deletes, moves, or rewrites them, and nothing
    here reports them — a store whose retired namespace may hold rows an
    operator still needs must provide its own drain or export path.

    Raises [Invalid_argument] when [schema_version < 1]; version 0 is the
    [Safe_ops.json_int ~default:0] miss value and must never name a namespace.

    Adopting this in a store that already holds live rows at the flat path is
    only safe when those rows are of the CURRENT version — they would otherwise
    be relocated out from under a reader that can still decode them. Such a
    store needs a relocation step first, not just this function. *)

val keepers_runtime_dirname : string
(** OUTPUT root segment for server-written keeper runtime state. Single literal
    behind both keeper-dir SSOT functions; the input/output relocation flips it. *)

val keepers_runtime_dir_of_base : base_path:string -> string
(** [<base_path>/.masc/keepers] for callers holding only a [base_path]
    (default cluster). Low-level SSOT that avoids the Workspace dependency cycle
    the cluster-aware [Workspace.keepers_runtime_dir] would impose. *)

type keeper_runtime_store =
  | Keeper_tool_usage
  | Keeper_runtime_manifests
  | Keeper_metrics
  | Keeper_execution_receipts
  | Keeper_turn_records
  | Keeper_reaction_ledger
  | Keeper_trajectories
(** Canonical child-store names under {!keepers_runtime_dirname}. *)

val keeper_runtime_store_dirname : keeper_runtime_store -> string
val keeper_runtime_store_of_dirname : string -> keeper_runtime_store option
val keeper_runtime_store_dirnames : string list

val auth_dir_from_base_path : base_path:string -> string
(** [<base_path>/.masc/auth]. SSOT path so {!Auth} and
    {!Keeper_identity} can both compute it without depending on each
    other (RFC P2 cycle-break prep). *)

val agents_dir_from_base_path : base_path:string -> string
(** [<base_path>/.masc/auth/agents]. Same SSOT motivation as
    {!auth_dir_from_base_path}; this is where keeper credential JSON
    files live ([<agent_name>.json]). *)

val max_tool_output_bytes : int
(** SSOT 64KB cap for MCP tool response bodies. *)

val truncate_response :
  ?max_bytes:int ->
  total_count:int ->
  string ->
  string
(** [truncate_response ?max_bytes ~total_count s] returns [s] unchanged
    when its length is at most [max_bytes] (default
    {!max_tool_output_bytes}). Otherwise returns the first [max_bytes]
    characters followed by a machine-readable truncation suffix that
    records the original length and [total_count]. *)
