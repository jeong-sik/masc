(** What one Librarian model call answers
    (RFC librarian-call-only-proposes §6.2 + Living Evolutionary Memory).

    An answer names only what changes: a fact no op names stays as it is. The
    answer points at a fact by the short name the question gave it ([m3]) and
    at a unit by the short name the question gave that unit. This module does
    not know the question's tables, so a name is kept as written; the plan
    resolves it and records an op with an unknown name as not applied, without
    throwing the other ops away.

    Both [Observed] and [Derived] provenance are accepted. Dedicated
    evolutionary ops ([Synthesize], [Molt], [Promote_to_world]) enable
    cross-category synthesis over named premises, proactive declarative
    molting into compacted cold archive, and verified promotions to shared
    MASC World Memory. *)

open Keeper_memory_os_types

type new_fact =
  { claim : string
  ; category : category
  ; basis : basis
  ; from_units : string list (** Names of the units the claim was read from. *)
  }

type op =
  | Add of new_fact
  | Remember_personal of
      { unit_name : string
      ; item_index : int
      ; claim : string
      ; category : category
      }
  (** The model selects exactly one item in its question. The host binds
      the original author and destination from that item. *)
  | Drop of
      { ref_ : string
      ; reason : string
      }
  | Merge of
      { refs : string list (** At least one name, none repeated. *)
      ; into : new_fact
      }
  | Revise of
      { ref_ : string
      ; into : new_fact
      }
  | Seen of
      { ref_ : string
      ; from_units : string list
      (** At least one name: the units that said the fact again. *)
      }
  (** The units said again what a fact in Memory says. The answer names the
      fact instead of copying its claim, so a reconfirmation cannot fork a
      near copy of the fact it means. *)
  | Synthesize of
      { refs : string list
      (** At least one premise fact name (e.g. ["m1"; "m3"]), none repeated.
          Premise facts remain in Memory while the synthesized [Derived] fact
          records their canonical memory IDs as proof premises. *)
      ; claim : string
      ; category : category
      ; rule_id : string
      ; from_units : string list
      }
  | Molt of
      { refs : string list
      (** At least one fact name, none repeated, shed proactively into cold
          archive without waiting for overflow panic. *)
      ; reason : string
      }
  | Promote_to_world of
      { refs : string list
      (** At least one supporting local fact name, none repeated. *)
      ; scope : string
      ; claim : string
      ; category : category
      ; facets : string list
      }

type working_state =
  | Keep
  | Set of string (** Replaces it. [Set ""] clears it. *)

type t =
  { question : Librarian_question_id.t
  ; ops : op list
  ; working_state : working_state
  }

(** The only reasons a whole answer is thrown away. *)
type rejection =
  | Not_json
  | Schema_violation of wire_error
  | Echo_mismatch
  | Empty_or_partial
  (** Blank text. A completion the provider cut short is mapped here by the
      caller, which is the one that sees the stop reason. *)

(** Stable token for a metric label or a log field. *)
val rejection_kind : rejection -> string

(** The wire shape. [working_state] is [null] for {!Keep}. *)
val to_json : t -> Yojson.Safe.t

(** The JSON schemas an answer is asked to match, one for each kind of
    question: the lane value's [answer_schemas].

    - [range]: every op (including [synthesize], [molt], [promote_to_world]),
      and a working state that is a string or [null].
    - [item_alone]: [add] only, and a [null] working state.
    - [room]: [drop], [merge], [revise], [synthesize], [molt],
      [promote_to_world], and either working state. *)
val schemas : Librarian_memory_lane.answer_schemas

(** A new fact alone, with the fields it has inside an op: [claim],
    [category], [basis], [from]. A commit line carries the claim of an op
    that was left out in this shape. *)
val new_fact_to_json : new_fact -> Yojson.Safe.t

val new_fact_of_json : Yojson.Safe.t -> (new_fact, wire_error) result

(** Decode an answer to the question [asked]. Every object is field-exact. *)
val of_json : asked:Librarian_question_id.t -> Yojson.Safe.t -> (t, rejection) result

(** {!of_json} on text that is one JSON document. *)
val of_string : asked:Librarian_question_id.t -> string -> (t, rejection) result
