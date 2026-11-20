(** The size facts of the head item, held by its writer between asks (RFC
    librarian-call-only-proposes §7.4).

    Once the width memory has narrowed to one item, no question is
    narrower. From there a slot's refusal for size is a fact about that
    question: sending the same question to the same slot again is the same
    call twice. The writer keeps those facts for the head item's two
    questions, the one that shows it with Memory and the one that shows it
    alone, and an ask does not call a slot that has one.

    A fact is held under the question's id and the slot's key. Another
    Memory version or another declaration gives another id, and another
    slot value another key, so nothing has to be cleared when they change:
    a fact under an id or key not asked now is not found. The writer
    empties this when reading moves, on an operator's [Resume] and at boot,
    the three times of §7.4.
    Nothing here reads a file or a clock.

    [specs/bug-models/LibrarianBottom.tla] has the same rules: [bottom],
    [Learn] and [Fold] there are {!t}, {!learn} and {!fold} here. *)

(** Which of the head item's two questions. *)
type which =
  | With_memory (** The head item with Memory and the working state. *)
  | Alone (** The head item and nothing else ([Read_item_alone]). *)

type t

val empty : t

(** The facts held under this question's id: the slots an ask of it does
    not call, with what each said. *)
val known
  :  t
  -> which
  -> Librarian_question_id.t
  -> (Librarian_memory_lane.slot_key * Librarian_slot_outcome.size_fact) list

(** Takes the [Refused (Sized _)] outcomes of a one-item question. Under the
    id held they join the facts held, a slot's new fact in place of its old
    one; under another id they replace them. A result with no size fact
    changes nothing. A refusal that gives no size and a silence are not
    kept: the provider may answer the next call otherwise. *)
val learn
  :  t
  -> which
  -> Librarian_question_id.t
  -> (Librarian_memory_lane.slot_key * Librarian_slot_outcome.unanswered) list
  -> t

(** What every slot the lane declares now said to one question. *)
type verdict =
  | Input (** Each has a size fact, and each fact is [Input_too_large]. *)
  | All_not_input (** Each has a size fact, and not every fact is [Input_too_large]. *)
  | Not_all
  (** One has none: it refused without a size, said nothing, was not in the
      walk, or was declared and not admitted. *)

(** Folds the outcomes of one question over the slots [lane] declares. A
    slot whose fact was held is in [slots] already: the ask filled it from
    {!known} and did not call it. A slot in [slots] that [lane] no longer
    declares is not read. *)
val fold
  :  Librarian_memory_lane.t
  -> (Librarian_memory_lane.slot_key * Librarian_slot_outcome.unanswered) list
  -> verdict
