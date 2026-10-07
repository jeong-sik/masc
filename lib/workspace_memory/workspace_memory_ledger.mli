(** The workspace curator's durable result: which facts share a claim, which
    conflict, and which the curator excluded. One fact is one row of one
    Keeper's memory store (RFC-workspace-curator-curates-changed-facts §2.1).

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
val of_json : Yojson.Safe.t -> (t, string) result
(** Refuses another [schema], unknown, missing or repeated fields, a value of
    the wrong JSON type, a blank string, a hash that is not 64 lowercase hex
    digits, an id or fact listed twice, a disposition naming an absent entry,
    and an entry no fact names. *)

val directory : base_path:string -> string
(** The workspace memory directory under [base_path]'s runtime directory. *)

val load : base_path:string -> (t, string) result
(** [empty] when the ledger file does not exist. A missing [base_path], an
    unreadable file or a file [of_json] refuses is an error, never [empty]. *)

val save : base_path:string -> t -> (unit, string) result
(** Atomic replacement. A failure before the rename keeps the previous ledger;
    a failure after it can leave the new one in place, so an error does not
    say which ledger the next [load] reads. Cancellation propagates. *)

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
      ; briefing : (Workspace_memory_briefing.observation, string) result
            (** Last complete Curator synthesis, with source and current
                prompt/schema-contract freshness.
                An unreadable briefing does not hide readable ledger metadata. *)
      }

val observe : base_path:string -> observation
(** Current durable ledger only. Old proposal files and publication descriptors
    never count as an available ledger. A corrupt ledger is unavailable. *)

(** A fact the stores hold that the ledger has no disposition for. *)
type pending_fact =
  { fact : fact_ref
  ; claim : string
  }

type reconciliation =
  { ledger : t  (** the input ledger without the [vanished] facts *)
  ; current_facts : pending_fact list
        (** All readable current facts, in discovery and store order. *)
  ; new_facts : pending_fact list
        (** In the given Keeper order, ordinary store first, each store in
            its own row order. *)
  ; vanished : fact_ref list  (** in [dispositions] order *)
  }

val reconcile : t -> Workspace_memory_context.keeper list -> reconciliation
(** Compare the ledger with what the stores hold now. A disposition vanishes
    when its store was read and no longer holds the fact, when the store has
    no file, or when its Keeper is not in the list. An [Unavailable] store
    adds no new facts and loses none. Removing a vanished member drops a
    claim or conflict left with no members. Makes no model call. *)

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
