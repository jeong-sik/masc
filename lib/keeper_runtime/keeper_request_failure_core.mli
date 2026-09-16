(** An agent-core error projected into a value MASC owns (RFC-0454 §2.2).

    [category] is agent-core's own closed projection of its error type;
    [message] is [Agent_core.Error.to_string], a sentence for people. No code
    reads [message] to decide anything, and nothing writes a document into it:
    a MASC error that arrives carried is kept as the typed value it is
    ([Keeper_internal_error.Fenced_masc]) instead of being projected here.

    The module sits below [Keeper_internal_error] and carries no MASC error of
    its own, which is what lets [Keeper_terminal_effect_detail] name it
    without the two modules forming a cycle.

    RFC-0454 P2 widens this into one constructor per agent-core failure
    (rate limited, payment required, context overflow, …). The two fields here
    are what P1b needs and what that widening replaces. *)

type t =
  { category : Agent_core.Error.category
  ; message : string
  }

val of_core_error : Agent_core.Error.t -> t
(** Project an agent-core error. [message] is its rendered text. *)

val summary : t -> string
(** One line for people: line breaks in [message] become spaces. Computed from
    the value, never stored. *)

val category_to_string : Agent_core.Error.category -> string
(** MASC's wire spelling for a category. Agent-core renders its own label for
    its own observations ([Agent_core.Error.category_label]); this mapping is
    what {!of_yojson} parses back, so the two can be renamed apart. A new
    agent-core category is a compile error here. *)

val category_of_string : string -> Agent_core.Error.category option
(** [None] for any spelling {!category_to_string} does not emit. *)

val to_yojson : t -> Yojson.Safe.t
(** A JSON object with exactly ["category"] and ["message"]. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Strict: a missing or extra field, a field of the wrong shape, or an
    unknown category is [Error]. Nothing is filled with a default. *)
