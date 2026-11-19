(** What one Librarian model call answers
    (RFC librarian-call-only-proposes §6.2).

    An answer names only what changes: a fact no op names stays as it is. The
    answer points at a fact by the short name the question gave it ([m3]) and
    at a unit by the short name the question gave that unit. This module does
    not know the question's tables, so a name is kept as written; the plan
    resolves it and records an op with an unknown name as not applied, without
    throwing the other ops away.

    A new fact of an answer is always observed. Derived facts are written only
    by a Keeper's direct write. *)

open Keeper_memory_os_types

type new_fact =
  { claim : string
  ; category : category
  ; observation : observation
  ; from_units : string list (** Names of the units the claim was read from. *)
  }

type op =
  | Add of new_fact
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

(** The wire shape. [working_state] is [null] for {!Keep}.

    {v
    { "question": "<front half>", "question_end": "<back half>",
      "working_state": null,
      "ops": [
        { "op": "add", "claim": "…", "category": "fact",
          "basis": { "kind": "observed" }, "from": ["u1"] },
        { "op": "drop", "ref": "m2", "reason": "…" },
        { "op": "merge", "refs": ["m1", "m3"], "claim": "…", "category": "fact",
          "basis": { "kind": "observed" }, "from": [] },
        { "op": "revise", "ref": "m4", "claim": "…", "category": "fact",
          "basis": { "kind": "observed" }, "from": ["u2"] } ] }
    v}

    [basis] has the shape a fact's basis has in Memory, so the model writes
    what it reads. *)
val to_json : t -> Yojson.Safe.t

(** A new fact alone, with the fields it has inside an op: [claim],
    [category], [basis], [from]. A commit line carries the claim of an op
    that was left out in this shape. *)
val new_fact_to_json : new_fact -> Yojson.Safe.t

val new_fact_of_json : Yojson.Safe.t -> (new_fact, wire_error) result

(** Decode an answer to the question [asked]. Every object is field-exact.
    Checks run in this order, and the first failure is the rejection: the
    document's field set, the two echoed halves being strings
    ({!Schema_violation}), the halves being those of [asked]
    ({!Echo_mismatch}), then [working_state] and each op
    ({!Schema_violation}). *)
val of_json : asked:Librarian_question_id.t -> Yojson.Safe.t -> (t, rejection) result

(** {!of_json} on text that is exactly one JSON document. Text around the
    document, a code fence included, is {!Not_json}. *)
val of_string : asked:Librarian_question_id.t -> string -> (t, rejection) result
