(** What a command outside the subset should have been.

    RFC execute-subset-dispositions §3.1. The fourteen arms of
    {!Masc_exec.Parsed.reason_too_complex} were one bucket with one answer --
    refuse -- and a caller told only that has exactly one move left, which is
    to send the same text through [sh -c] and lose every guarantee the gate
    exists to apply.

    They are not one thing. Most of them answer the same question, and the
    answer is a call the caller can already make:

    - a heredoc is stdin, and stdin is a typed field;
    - [;] is a connector, and the connector that keeps the failure is [&&];
    - a loop is a program, and a program belongs in a file that is written and
      then executed as an ordinary argv.

    So a refusal is a rewrite. One arm has none: a construct the parser could
    not name has no call to suggest, and {!Unrepresentable} is where it stays.

    {!of_reason} is exhaustive over the closed reason type on purpose. A
    construct cannot join the subset's excluded list without someone choosing
    what the caller should have done instead. *)

type field = Stdin | Connector
(** Fields of the Execute schema a rewrite can point at. [Stdin] is
    {!Keeper_tool_execute_typed_input.input_source}; [Connector] is the
    conditional that joins two programs. *)

type call =
  | Write_then_execute
      (** write the program to a file, then execute the file as argv *)
  | Execute_twice
      (** run the inner command first, then use its output in the second call *)
  | Spawn
      (** a process that outlives the call needs the handle, not this tool *)

type t =
  | Move_to_field of {
      field : field;
      because : string;
    }  (** the schema already has somewhere to put this *)
  | Call_this_instead of {
      call : call;
      because : string;
    }  (** a call the caller can make now *)
  | Unrepresentable of {
      construct : Masc_exec.Parsed.reason_too_complex;
      because : string;
    }
      (** no rewrite exists. The only arm that is genuinely a refusal, and it
          says why rather than only that. *)

val of_reason : Masc_exec_command_gate.Shell_command_gate.too_complex_reason -> t
(** The rewrite for a construct the subset excluded. Total and exhaustive. *)

val to_string : t -> string
(** One line, for a log or a message back to the caller: what to do, and why
    this construct needs it. *)

val tag : t -> string
(** Closed-vocabulary tag for aggregation, coarser than {!to_string}. *)
