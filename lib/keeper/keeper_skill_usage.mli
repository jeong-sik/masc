(** How often each skill was used, read off recorded tool calls.

    A composition skill is used when its tool ([keeper_compose_<name>]) is
    called; an instruction skill when [keeper_skill] is called with its name.
    The rows are the tool-call log's JSON rows ([tool], [input]); the count is
    bounded by however many rows the caller read, which the API reports beside
    the count so a reader knows the window. *)

type use =
  | Composition_tool of string  (** the composition's tool name *)
  | Instruction_read of string  (** the instruction skill's name *)

val count : rows:Yojson.Safe.t list -> use -> int
(** [count ~rows use] counts the rows that record [use]. A row without a
    string [tool] field, or a [keeper_skill] row without a string [input.name],
    never matches. *)
