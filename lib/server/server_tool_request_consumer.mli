(** The consumers that keep tool request originals under
    [tool-request-owners], told apart by the scope their records are stored
    under.

    The install preflight and the startup pass over the settled archive each
    decide per consumer, and both match this type without a wildcard. A scope
    the preflight accepts is therefore a scope the pass can classify, and a
    consumer that is added here has to be answered in both before the tree
    compiles.

    [Lane_addon_tool_request_owner.retain] takes its scope as a string, so
    nothing ties a consumer to this type when it starts keeping originals.
    One that is missing here stops the pass at every boot from its first live
    record, and the next install preflight refuses that record. *)

(** Each consumer keeps every original under one scope. *)
type t =
  | Completion_review
  | Goal_proof_review
  | Candle_appraisal
  | Media_reading
[@@deriving enumerate]

val scope : t -> string
(** The scope the consumer's own module retains its originals under. *)

val of_scope : string -> t option
(** The active consumer whose originals are stored under the scope, or [None]
    when no active consumer of this build keeps originals there. *)

(** Retired historical scopes whose live records may remain on disk from prior
    releases. Recognizing them explicitly prevents boot-time settled-archive
    sweeps and deploy preflight from aborting on retired records while still
    refusing genuinely unknown scopes fail-closed. *)
type retired_scope =
  | Workspace_curator
  | Keeper_librarian_parts of { scope_hash : string }
  | Keeper_librarian_partitions of { scope_hash : string }
  | Keeper_librarian_admission_gate of { scope_hash : string }
  | Keeper_librarian_admission_closure of { scope_hash : string }

type scope_classification =
  | Active of t
  | Retired of retired_scope

val classify_scope : string -> scope_classification option
(** Classify [scope] as either an active consumer of this build or an
    explicitly retired historical scope. Returns [None] for any unknown or
    malformed scope. *)
