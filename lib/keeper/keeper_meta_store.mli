(** Keeper meta store I/O and CAS write helpers. *)

type current_meta_unavailable_reason =
  | Invalid_current
  | Read_failed
  | Missing_current
  | Discovery_failed

type current_meta_unavailable =
  { keeper_name : string
  ; path_identity : string
  ; reason : current_meta_unavailable_reason
  ; detail : string
  }

type keeper_name_discovery =
  { names : string list
  ; unavailable : current_meta_unavailable list
  }

type current_meta_discovery =
  { keeper_names : string list
  ; persisted_keeper_names : string list
  ; persistent_keeper_names : string list
  ; metas : (string * Keeper_meta_contract.keeper_meta) list
  ; unavailable : current_meta_unavailable list
  }

type current_meta_unavailable_observation =
  | Current_meta_observed of current_meta_unavailable list
  | Current_meta_observation_unavailable

val current_meta_unavailable_reason_to_string :
  current_meta_unavailable_reason -> string

val current_meta_unavailable_message : current_meta_unavailable -> string
val current_meta_unavailable_to_yojson : current_meta_unavailable -> Yojson.Safe.t

val current_meta_unavailable_collection_to_yojson :
  current_meta_unavailable_observation -> Yojson.Safe.t

(** Hook invoked after each successful [write_meta] /
    [write_meta_with_merge]. Reset by the runtime to keep
    [Workspace_state] caches in sync. *)
val runtime_meta_write_sync_hook :
  Workspace.config -> Keeper_meta_contract.keeper_meta -> unit

(** Replace [runtime_meta_write_sync_hook] with [f]. *)
val register_runtime_meta_write_sync :
  (Workspace.config -> Keeper_meta_contract.keeper_meta -> unit) -> unit

(** Pre-compiled regex matching the CAS [meta version conflict]
    error message. Exposed for symmetry — used internally by
    [is_version_conflict_error]. *)
val version_conflict_re : Re.re

(** Read a keeper meta JSON file at [path]. Returns [Ok None] when
    the file does not exist. Unknown top-level keys are rejected with a
    reset-required error; the persisted file is never rewritten. *)
val read_meta_file_path :
  string -> (Keeper_meta_contract.keeper_meta option, string) result

val read_meta_file_path_current :
  string ->
  (Keeper_meta_contract.keeper_meta option, current_meta_unavailable) result

(** [true] when [f] has an exact canonical Keeper-metadata interpretation. *)
val is_keeper_meta_file : string -> bool

(** List keeper names with persisted JSON in [.masc/keepers/].
    Sidecars filtered, names validated, sorted ascending. *)
val persisted_keeper_names_result :
  Workspace.config -> (string list, current_meta_unavailable) result
val persisted_keeper_names : Workspace.config -> keeper_name_discovery

(** List keeper names declared in TOML config (overlay sources). *)
val configured_keeper_names : Workspace.config -> string list

(** Primary keeper discovery: persisted JSON names. *)
val keeper_names_result :
  Workspace.config -> (string list, current_meta_unavailable) result
val keeper_names : Workspace.config -> keeper_name_discovery

(** One current-schema observation used by operator, health, and dashboard
    projections. Each candidate metadata row is decoded at most once. *)
val discover_current_meta : Workspace.config -> current_meta_discovery

val current_meta_unavailable_facts :
  Workspace.config -> current_meta_unavailable list

(** Default autoboot policy when a keeper has TOML config but no
    persisted JSON yet. *)
val declarative_autoboot_enabled_by_default : Workspace.config -> string -> bool
val effective_autoboot_enabled :
  Workspace.config -> string -> Keeper_meta_contract.keeper_meta -> bool

(** Keepers eligible for the keepalive fiber set plus every current-meta fact
    that prevented an eligibility decision. *)
val discover_keepalive_keepers :
  Workspace.config -> keeper_name_discovery

(** Persistent keeper discovery without collapsing unavailable rows. *)
val discover_persistent_agents :
  Workspace.config -> keeper_name_discovery

(** Read the keeper meta for [name]. The name is the canonical keeper
    filename component; agent-name aliases are not retried here. Callers
    that accept aliases must normalize explicitly before reading. *)
val read_meta_resolved :
  Workspace.config ->
  string ->
  ((string * Keeper_meta_contract.keeper_meta) option, string) result

(** Like [read_meta_resolved] but discards the filename component. *)
val read_meta :
  Workspace.config -> string -> (Keeper_meta_contract.keeper_meta option, string) result

(** Read persisted keeper meta and overlay TOML/persona defaults before
    returning it. Status/list/operator surfaces should use this for
    TOML-owned fields such as [sandbox_profile] and [network_mode]. *)
val read_effective_meta_resolved :
  Workspace.config ->
  string ->
  ((string * Keeper_meta_contract.keeper_meta) option, string) result

(** Like [read_effective_meta_resolved] but discards the filename component. *)
val read_effective_meta :
  Workspace.config -> string -> (Keeper_meta_contract.keeper_meta option, string) result

(** Revalidate the canonical [name] row on every observation. [last_mtime] is
    retained only for caller compatibility and never authorizes a cached row.
    Missing, unreadable, or unstatable current state is a typed error. *)
val read_meta_if_changed :
  Workspace.config ->
  string ->
  last_mtime:float ->
  ((Keeper_meta_contract.keeper_meta * float) option, current_meta_unavailable) result

(** Atomic write of [persisted] to [path]; runs the
    [runtime_meta_write_sync_hook] on success. *)
val persist_meta :
  Workspace.config -> string -> Keeper_meta_contract.keeper_meta -> (unit, string) result

(** Persist [m] with a CAS bump on [meta_version]: the write is rejected
    if the on-disk version has moved since [m] was read. There is no force
    / bypass path — cumulative usage counters are a monotone invariant
    (RFC-0225 §3.2, RFC-0237), so callers that lost a race must resolve the
    conflict through {!write_meta_with_merge}, not overwrite the disk. *)
val write_meta :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  (unit, string) result

(** Lifecycle-owner variant of [write_meta]. The opaque reservation token is
    checked against the same BasePath/name key before entering the per-path
    CAS critical section. *)
val write_meta_for_lifecycle :
  Keeper_lifecycle_reservation.token ->
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  (unit, string) result

type identity_update_error =
  | Identity_missing
  | Identity_changed
  | Identity_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Identity_read_failed of string
  | Identity_write_failed of string

val identity_update_error_to_string : identity_update_error -> string

(** Re-read and CAS-update [name] only while its trace/generation identity
    matches the shutdown snapshot. Every CAS retry rechecks identity before
    applying [update], so a replacement generation is never overwritten. *)
val update_meta_if_identity :
  Workspace.config ->
  name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  generation:int ->
  (Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta) ->
  (Keeper_meta_contract.keeper_meta, identity_update_error) result

type identity_remove_error =
  | Remove_identity_missing
  | Remove_identity_changed
  | Remove_identity_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Remove_identity_read_failed of string
  | Remove_identity_unlink_failed of string

val identity_remove_error_to_string : identity_remove_error -> string

(** Remove [name]'s meta only while the same trace/generation still occupies
    the path. This shares the per-path lock used by [write_meta]. *)
val remove_meta_if_identity :
  Workspace.config ->
  name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  generation:int ->
  (unit, identity_remove_error) result

type exact_identity_error =
  | Exact_identity_missing
  | Exact_identity_changed
  | Exact_meta_version_changed of
      { expected : int
      ; actual : int
      }
  | Exact_identity_read_failed of string
  | Exact_identity_unlink_failed of string

val exact_identity_error_to_string : exact_identity_error -> string

(** Re-read [name] under its per-path lock and return it only while both its
    trace/generation identity and [meta_version] still match the durable
    lifecycle intent. *)
val read_meta_if_exact_identity :
  Workspace.config ->
  name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  generation:int ->
  meta_version:int ->
  (Keeper_meta_contract.keeper_meta, exact_identity_error) result

(** Atomically unlink [name] only while both its trace/generation identity and
    [meta_version] still match. A caller that observes a version conflict must
    preserve the newer metadata and surface the lifecycle operation as
    blocked. *)
val remove_meta_if_exact_identity :
  Workspace.config ->
  name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  generation:int ->
  meta_version:int ->
  (unit, exact_identity_error) result

(** [true] iff [msg] matches [version_conflict_re]. *)
val is_version_conflict_error : string -> bool

(** Retry [write_meta] on CAS version conflicts using caller-declared
    field ownership via [merge]. Use [Keeper_meta_merge.caller_wins]
    for payload-wins writes, or a narrower merge such as
    [Keeper_meta_merge.heartbeat_fields_from_disk] when concurrent
    writers own specific fields. *)
val write_meta_with_merge :
  ?max_retries:int ->
  merge:(latest:Keeper_meta_contract.keeper_meta -> caller:Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta) ->
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  (unit, string) result

val write_meta_with_merge_for_lifecycle :
  Keeper_lifecycle_reservation.token ->
  ?max_retries:int ->
  merge:
    (latest:Keeper_meta_contract.keeper_meta ->
     caller:Keeper_meta_contract.keeper_meta ->
     Keeper_meta_contract.keeper_meta) ->
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  (unit, string) result

(** [persist_compaction_decision config ~keeper_name ~decision] stamps [decision]
    onto the durable on-disk [compaction_rt.last_decision], the field the
    status and dashboard read paths surface as [last_compaction_decision].

    Used by the reactive provider-overflow failure path, whose registry stamp is
    in-memory only and whose turn-failure meta flush persists a pre-overflow meta
    without the decision. Reads the current on-disk meta, stamps only
    [last_decision], and writes back via {!write_meta_with_merge} so a CAS race
    with a concurrent heartbeat/turn write re-applies the stamp. [`No_durable_meta]
    reports that no on-disk meta exists to stamp (non-fatal); [Error] carries a
    read/write failure. *)
val persist_compaction_decision :
  Workspace.config ->
  keeper_name:string ->
  decision:Keeper_meta_contract.compaction_runtime_decision ->
  ([ `Persisted | `No_durable_meta ], string) result

val persist_compaction_outcome :
  Workspace.config ->
  keeper_name:string ->
  outcome:
    [ `Committed | `Overflow_episode_committed | `Failed | `Recovered ] ->
  ([ `Persisted | `No_durable_meta ], string) result
(** Advance the compaction outcome counters on [compaction_rt] using the same
    read/stamp/merge shape as {!persist_compaction_decision}.

    [`Overflow_episode_committed] (an in-lane reactive commit) increments
    [count] AND the streak — committed savings under an incompressible floor
    must still count toward the ceiling (#25538). [`Recovered] (a turn
    completed without provider overflow) resets the streak; callers skip the
    write when the streak is already 0.

    [`Committed] increments [count] and resets [consecutive_failures] to 0;
    [`Failed] increments [consecutive_failures]. The streak is what
    {!settlement_of_cycle_outcome} reads to escalate instead of requeuing a
    failing compaction (RFC-0351 S0, #25461); [count] had no writer before this
    despite being serialized and rendered. *)

val persist_transcript_corruption_pause :
  Workspace.config ->
  keeper_name:string ->
  ([ `Persisted | `No_durable_meta ], string) result
(** CAS-merge the existing fail-closed pause surface after structural
    transcript corruption. A dead tombstone remains stronger and every other
    live/pause state becomes typed reset-required state. No decoder or
    automatic retry state is created. *)
