(** Cross-cutting utilities used by many MASC subsystems.

    Kept small and dependency-light so every module can depend on it
    without introducing cycles. *)

(** Boolean environment variable with permissive truthy parsing:
    ["1"], ["true"], ["yes"], ["on"] (case/whitespace insensitive)
    all return [true]; absent, empty, or anything else returns [false]. *)
(** [true] when [MASC_STRICT_FINALIZERS] env is truthy. Callers can
    opt into raising finally-block exceptions instead of swallowing
    them. *)
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
  | Keeper_provider_inputs
  | Keeper_reaction_ledger
  | Keeper_trajectories
  | Keeper_crash_events
(** Canonical child-store names under {!keepers_runtime_dirname}. *)

val keeper_runtime_store_of_dirname : string -> keeper_runtime_store option
val keeper_runtime_store_dirname : keeper_runtime_store -> string
val keeper_runtime_stores : keeper_runtime_store list

type keeper_runtime_store_placement =
  | Keeper_scoped_dated
      (** [keepers/<name>/<store>/YYYY-MM/DD.jsonl]. Grows without bound, so
          both the startup pass and the 24h pass prune it by age. *)
  | Keeper_scoped_versioned
      (** [keepers/<name>/<store>/v<N>/]. A schema change moves to the next
          directory and the previous one is simply never read again, which is
          what a hard cut is supposed to look like. *)
  | Keeper_scoped_rotated
      (** [keepers/<name>/<store>/<file>.jsonl] plus numeric rotations. The
          flat-file pass owns these, not the dated one. *)
  | Workspace_scoped
      (** [<masc root>/<store>]: named here for the dirname, but not written
          under [keepers/]. *)

val keeper_runtime_store_placement
  :  keeper_runtime_store
  -> keeper_runtime_store_placement
(** Where a store puts its files, and therefore which retention pass owns it.

    This exists because the answer used to be a second list of directory names
    written out in the maintenance pass. turn-records was added to the store
    table on 2026-07-31 and nobody added it to that list, so it went unpruned
    for months at roughly 4 MB a day fleet-wide. A store now has to say where
    it lives, and the match is exhaustive, so the next one cannot be added
    without answering. *)
val auth_dir_from_base_path : base_path:string -> string
(** [<base_path>/.masc/auth]. SSOT path so {!Auth} and
    {!Keeper_identity} can both compute it without depending on each
    other (RFC P2 cycle-break prep). *)

val agents_dir_from_base_path : base_path:string -> string
(** [<base_path>/.masc/auth/agents]. Same SSOT motivation as
    {!auth_dir_from_base_path}; this is where keeper credential JSON
    files live ([<agent_name>.json]). *)

val max_tool_result_wire_bytes : int
(** Ceiling for one tool result on the wire, below which an official-client
    CLI does not spill it to a file the Keeper cannot read.

    Bounds both halves of externalization: what becomes a blob, and how much
    of a blob one read returns, and it is the only ceiling on a tool result.
    A separate 64KB constant once carried both, which made a read of an
    externalized result exactly the size that gets spilled.

    It does not bound how much output the runtime accepts from a subprocess —
    that is {!max_process_capture_head_bytes} + {!max_process_capture_tail_bytes}.
    Conflating the two is what let a single [Execute] call retain 590MB. *)

val max_process_capture_head_bytes : int
(** Bytes retained from the {e start} of one captured subprocess stream.
    Backed by a growable buffer, so this budget costs nothing until output
    actually reaches it. *)

val max_process_capture_tail_bytes : int
(** Bytes retained from the {e end} of one captured subprocess stream.
    Backed by a ring allocated eagerly at this size, so it is set to the
    256KB scale the dashboard already pays per keeper rather than to the
    head budget.

    Head + tail is the acceptance ceiling for a single stream. claude-code's
    comparable ceiling is 64 MiB, but it streams bash output to a file on
    disk while MASC retains the capture in memory for the turn, so the
    ceiling here is lower. The drainer keeps reading past the ceiling so the
    exit status and the tail (where failures report) stay exact; only
    retention is bounded, so memory is O(head + tail) rather than
    O(output). Elided bytes are reported by {!Exec_buffer.render}'s
    truncation marker rather than dropped silently. *)

val safe_filename : string -> string
(** Fold a value into one path component: lowercase, keep [a-z0-9._-], and
    escape anything else as [_XX]. Every layer that turns a name into a file
    name goes through this, so a name cannot mean two files. *)
