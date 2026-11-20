(** Scores what a slot answered to a question whose right answer is known
    (RFC librarian-call-only-proposes §20, L1).

    The scorer is fixed before the prompt is written, so a prompt is judged by
    a measure it was not tuned against. It counts; it does not judge wording.
    What a case expects is declared in the case as tokens, and a token is
    found in a claim as a substring.

    Six numbers come out per slot:

    - how many answers were thrown away, by reason (an answer to another
      question is one of the reasons);
    - how many ops were left out, by reason;
    - how many answers changed Memory at all. When "change nothing" is the
      safe answer, this number falls first;
    - how much of what the units said is in Memory afterwards;
    - how much a merge kept of the facts it replaced;
    - how much of what Memory has to go on saying it still says afterwards,
      whether a drop, a merge or a revise removed the fact that said it. *)

open Keeper_memory_os_types

(** One question with its known answer. *)
type case =
  { name : string
  ; question : Librarian_question_id.t
  ; shown : Librarian_plan.shown
  ; facts : fact list (** Memory when the answer arrives. *)
  ; planted : string list
  (** What the units said that Memory should hold afterwards. A token is
      looked for as a case-sensitive substring of a claim, so it must not be
      part of another word or number: ["8935"] is found in ["89350"]. A
      token a claim of [facts] already holds is counted nowhere: no answer
      can recover it. *)
  ; must_keep : (string * string list) list
  (** Memory id of a fact, and what a claim that replaces it by a merge has
      to keep. A fact a merge removes that is not listed here adds to neither
      merge count. *)
  ; must_remain : string list
  (** What Memory has to go on saying after the answer, as tokens looked for
      as [planted] ones are. A token is kept when a claim of Memory after the
      answer says it. Which op removed the fact that said it does not matter:
      a drop, a merge and a revise lose it the same way, and a merge or a
      revise that carries it into the new claim keeps it. A token is what the
      fact states, not what it is about. A claim that nothing is known of the
      Friday deploy policy still says ["Friday"], so that token would count a
      fact the answer lost as kept. *)
  }

(** What one answer that was read did. *)
type reading =
  { ops : int
  ; not_applied : Librarian_effects.why_not list
  ; changed : bool (** A fact was added or removed. *)
  ; recovered : int
  (** Planted tokens Memory did not hold before the answer and holds after
      it. An answer that changes nothing recovers nothing. *)
  ; merge_expected : int (** Tokens of the facts a merge removed. *)
  ; merge_kept : int
  ; remain_expected : int (** Tokens of [must_remain]. *)
  ; remain_kept : int (** Of those, the ones a claim of Memory says after the answer. *)
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
  (** Tokens to recover, of every answer, the thrown away ones included. *)
  ; recovered : int
  ; merge_expected : int
  ; merge_kept : int
  ; remain_expected : int
  (** Of the answers that were read. A thrown away answer left Memory as it
      was, and is counted in [thrown_away] only. *)
  ; remain_kept : int
  }

(** Sum over the answers of one slot. Each answer comes with its case. *)
val tally : (case * scored) list -> tally

(** One line per number, counts only. A reader computes the rates; a rate
    printed here would hide a small denominator. *)
val tally_to_text : tally -> string
