(** Scores what a slot answered to a question whose right answer is known
    (RFC librarian-call-only-proposes §20, L1).

    The scorer is fixed before the prompt is written, so a prompt is judged by
    a measure it was not tuned against. It counts; it does not judge wording.
    What a case expects is declared in the case as tokens, and a token is
    found in a claim as a substring.

    Five numbers come out per slot:

    - how many answers were thrown away, by reason (an answer to another
      question is one of the reasons);
    - how many ops were left out, by reason;
    - how many answers changed Memory at all. When "change nothing" is the
      safe answer, this number falls first;
    - how much of what the units said is in Memory afterwards;
    - how much a merge kept of the facts it replaced. *)

open Keeper_memory_os_types

(** One question with its known answer. *)
type case =
  { name : string
  ; question : Librarian_question_id.t
  ; shown : Librarian_plan.shown
  ; facts : fact list (** Memory when the answer arrives. *)
  ; planted : string list
  (** What the units said that Memory should hold afterwards. *)
  ; must_keep : (string * string list) list
  (** Memory id of a fact, and what a claim that replaces it by a merge has
      to keep. *)
  }

(** What one answer that was read did. *)
type reading =
  { ops : int
  ; not_applied : Librarian_effects.why_not list
  ; changed : bool (** A fact was added or removed. *)
  ; recovered : int (** Planted tokens found in Memory afterwards. *)
  ; merge_expected : int (** Tokens of the facts a merge removed. *)
  ; merge_kept : int
  }

type scored =
  | Thrown_away of Librarian_answer.rejection
  | Read of reading

val score : case -> string -> scored

type tally =
  { answers : int
  ; thrown_away : (string * int) list (** By rejection kind, sorted. *)
  ; ops : int
  ; not_applied : (string * int) list (** By reason, sorted. *)
  ; changed : int
  ; planted : int
  ; recovered : int
  ; merge_expected : int
  ; merge_kept : int
  }

(** Sum over the answers of one slot. Each answer comes with its case. *)
val tally : (case * scored) list -> tally

(** One line per number, counts only. A reader computes the rates; a rate
    printed here would hide a small denominator. *)
val tally_to_text : tally -> string
