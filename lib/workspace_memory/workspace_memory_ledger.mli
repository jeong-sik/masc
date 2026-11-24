(** The workspace curator's durable result: which facts share a claim, which
    conflict, and which the curator excluded. One fact is one row of one
    Keeper's memory store.

    The ledger is the curator's interpretation. It never changes Keeper memory
    and never checks meaning. Members are stored once, as each fact's
    disposition; a claim's or conflict's members are the facts that name it. *)

(** A fact's identity, following the rule its store uses to keep one row.
    [claim_sha256] is the lowercase hex SHA-256 of the claim bytes; for an
    ordinary fact it is the store's [memory_id] without its prefix. A
    source-bound store keeps one row per [path], so two files holding the same
    claim are two facts. *)
type fact_ref =
  | Ordinary of
      { keeper_id : string
      ; claim_sha256 : string
      }

  | Source_bound of
      { keeper_id : string
      ; path : string
      ; claim_sha256 : string
      }

val fact_ref_to_json : fact_ref -> Yojson.Safe.t
val fact_ref_of_json : Yojson.Safe.t -> (fact_ref, string) result
(** Strict source identity codec shared by ledger rows and retained Curator
    batches. Unknown, missing and repeated fields are rejected. *)

val compare_fact_ref : fact_ref -> fact_ref -> int
(** Total order: Keeper, then store (ordinary before source-bound), then path,
    then claim hash. Two refs compare equal only when they are the same fact,
    so an ordinary ref and a source-bound ref of one Keeper and claim stay
    distinct. {!dispositions} lists facts in this order. *)

module Fact_map : Map.S with type key = fact_ref
(** Maps keyed by {!compare_fact_ref}. *)

type disposition =
  | Claim_member of string  (** a [claim_id] in the ledger *)
  | Conflict_member of string  (** a [conflict_id] in the ledger *)
  | Excluded of string  (** the curator's reason *)

(** Every [Claim_member] and [Conflict_member] names an entry the ledger
    holds, and every claim and conflict has at least one member. *)
type t

val empty : t

val claims : t -> (string * string) list
(** [(claim_id, claim)] in [claim_id] order. *)

val conflicts : t -> (string * string) list
(** [(conflict_id, description)] in [conflict_id] order. *)

val dispositions : t -> (fact_ref * disposition) list
(** In Keeper, store, path and hash order. *)

val to_json : t -> Yojson.Safe.t

val sha256 : t -> string
(** The SHA-256 of [Yojson.Safe.to_string (to_json t)], the bytes {!save}
    writes. It names the ledger's revision. *)

val of_json : Yojson.Safe.t -> (t, string) result
(** Refuses another [schema], unknown, missing or repeated fields, a value of
    the wrong JSON type, a blank string, a hash that is not 64 lowercase hex
    digits, an id or fact listed twice, a disposition naming an absent entry,
    and an entry no fact names. *)

val directory : base_path:string -> string
(** The workspace memory directory under [base_path]'s runtime directory. *)

val load : base_path:string -> (t, string) result
(** [empty] when the ledger file does not exist. A missing [base_path], an
    unreadable file or a file [of_json] refuses is an error, never [empty].
    Reads under {!File_lock_eio.with_lock} when the workspace-memory directory
    exists. *)

val save : base_path:string -> t -> (unit, string) result
(** Locked atomic replacement ({!File_lock_eio.with_lock} +
    {!Fs_compat.save_file_atomic_strict_staged}). A failure before the rename
    keeps the previous ledger; a failure after it can leave the new one in
    place, so an error does not say which ledger the next [load] reads.
    Cancellation propagates. *)

val update : base_path:string -> (t -> (t, string) result) -> (t, string) result
(** Locked read-modify-write transition over [ledger.json] using
    {!File_lock_eio.with_lock} and atomic replacement. When [ledger.json]
    already exists and the returned ledger has the identical {!sha256}, the
    write and change notification are skipped. *)

val briefing_sources : t -> Workspace_memory_briefing.source list
(** Complete claim and conflict texts for shared semantic synthesis. Members
    remain in the ledger; adding a member alone does not change these inputs.
    Briefing source IDs include their claim/conflict namespace; they are not
    unqualified ledger IDs for the read tool. *)

type observation =
  | Missing
  | Unavailable of string
  | Available of
      { ledger_sha256 : string
      ; claim_count : int
      ; conflict_count : int
      ; classified_count : int
      ; excluded_count : int
      ; briefing : (Workspace_memory_briefing.observation, string) result
            (** Last complete Curator synthesis, with source and current
                prompt/schema-contract freshness.
                An unreadable briefing does not hide readable ledger metadata. *)
      ; building : (Workspace_memory_briefing.pass option, string) result
      }

val observe : base_path:string -> observation
(** Observe World Memory when its SQLite store exists. Otherwise observe
    the file-backed Curator ledger. *)

val observe_curator : base_path:string -> observation
(** Observe only the file-backed Curator ledger. Its generation can be
    compared with {!sha256} of a value returned by {!load}. Old proposal
    files and publication descriptors never count as an available ledger. *)

val observe_with_briefing_template : briefing_template:string -> base_path:string -> observation
(** As {!observe}, using a caller-supplied resolved briefing template so
    blocking systhread callers do not acquire the prompt registry Eio mutex. *)

val check_readable : base_path:string -> (unit, string) result
(** Fresh regular-file, payload-read and strict decoding checks used by
    {!observe_curator}. An absent ledger in an existing workspace succeeds; an invalid
    base, nonregular file or unreadable/corrupt ledger fails. Does not compute
    the ledger digest, resolve the briefing prompt or read the briefing.
    This is a read-only availability check, not a retained snapshot or write
    authorization. *)

(** A fact the stores hold that the ledger has no disposition for. *)
type pending_fact =
  { fact : fact_ref
  ; claim : string
  }

type corroboration_stage =
  | Observed       (** Backed by a single Keeper. *)
  | Consolidated   (** Backed by multiple distinct Keepers. *)
  | Crystallized   (** Multi-Keeper convergence grounded in source-bound evidence. *)

val corroboration_stage_to_string : corroboration_stage -> string

type claim_provenance =
  { claim_id : string
  ; claim : string
  ; stage : corroboration_stage
  ; supporting_keepers : string list
  ; support_count : int
  ; has_source_bound : bool
  }

type provenance_change =
  { provenance : claim_provenance
        (** Recomputed live provenance from remaining supporting members. *)
  ; prior_stage : corroboration_stage
  ; prior_support_count : int
  ; vanished_keepers : string list
  }

val claim_provenance : t -> claim_id:string -> claim_provenance option
(** Current corroboration stage and distinct supporting Keepers for [claim_id]. *)

val all_claim_provenance : t -> claim_provenance list
(** {!claim_provenance} for every claim in [t], in [claim_id] order. *)

type reconciliation =
  { ledger : t
        (** the input ledger without the [vanished] facts; shared claims stay
            in place as long as at least one corroborating member remains and
            are retracted only when zero members remain *)
  ; current_facts : pending_fact list
        (** All readable current facts, in discovery and store order. *)
  ; new_facts : pending_fact list
        (** Current facts [ledger] has no disposition for, including facts
            whose prior conflict dissolved below two members. Oldest store
            [first_seen] first; facts first seen at the same instant follow
            Keeper, store, path and hash order. *)
  ; vanished : fact_ref list  (** in [dispositions] order *)
  }

type detailed_reconciliation =
  { reconciliation : reconciliation
  ; retracted_claims : string list
  ; shrank_claims : provenance_change list
  ; dissolved_conflicts : string list
  }

val reconcile : t -> Workspace_memory_context.keeper list -> reconciliation
(** Compare the ledger with what the stores hold now. A disposition vanishes
    when its store was read and no longer holds the fact, when the store has
    no file, or when its Keeper is not in the list. An [Unavailable] store
    adds no new facts and none of its facts vanish. Under the Curator contract
    every fact assigned to a claim independently entails that claim's text, so
    a shared claim survives partial member loss as long as at least one
    supporting member remains without re-queuing survivors; a claim is retracted
    only when zero supporting members remain. Corroboration stage is always
    recomputed from surviving members (never ratcheted), so losing the last
    source-bound or multi-Keeper supporter steps [stage] down accordingly. A
    conflict that loses a member and drops below two remaining members dissolves
    so a lone remaining fact re-enters [new_facts]. Makes no model call. *)

val reconcile_detailed :
  t -> Workspace_memory_context.keeper list -> detailed_reconciliation
(** {!reconcile} together with retracted claim ids, surviving claims whose
    provenance shrank (recording [prior_stage] alongside live recomputed
    [provenance.stage]), and dissolved conflict ids. *)

type ordinary_absence_counts = {
  facts : int;
  absent : int;
  available_stores : int;
  missing_stores : int;
}
type ordinary_absence =
  | Complete of ordinary_absence_counts
  | Partial of { counts : ordinary_absence_counts; unavailable_stores : int }

val ordinary_absence : t -> Workspace_memory_context.keeper list -> ordinary_absence
(** Distinct current ordinary fact identities without a disposition in the
    input ledger. Claim, conflict and excluded dispositions all count as present.
    Unlike [reconcile.new_facts], this does not use the reconciled ledger.
    Missing stores are known empty; unavailable ordinary stores make [facts]
    and [absent] lower bounds. Source-bound stores do not affect this count.
    This observes membership only, never why a fact is absent. *)

(** One model decision for a changed fact. A new claim or conflict receives a
    stable id derived from its text; existing ids must already be in [t]. *)
type decision =
  | Join_claim of string
  | Create_claim of string
  | Join_conflict of string
  | Create_conflict of string
  | Exclude of string

type assignment = { fact : fact_ref; decision : decision }

type apply_error =
  | Duplicate_selected_fact
  | Duplicate_assignment
  | Unselected_fact
  | Missing_assignment
  | Already_disposed
  | Unknown_claim of string
  | Unknown_conflict of string
  | Blank_value
  | Id_collision
  | Invalid_result of string

val apply_error_to_string : apply_error -> string
val apply : t -> selected:pending_fact list -> assignment list -> (t, apply_error) result
(** Apply exactly one decision for each selected changed fact. No unselected
    fact can be changed. Repeated or missing decisions, invalid references,
    and a fact already assigned in the ledger are errors. The caller persists
    the returned ledger atomically; [apply] itself has no effects. *)

val dirname : string
(** The ledger directory below [<base>/.masc]. *)
