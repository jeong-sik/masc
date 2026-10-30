(** What a finished process's exit status means for the answer.

    Every value below is a function of the status the child exited with, so
    a synthesized {!Unix.process_status} is enough to ask what an exit means;
    no test has to run a real child.

    The contract itself is masc#28983: a process that ran and exited nonzero,
    or died to a signal, is an observed tool result the model reads and reacts
    to, not a tool failure. Routing it through the failure disposition marked
    the whole turn terminally failed, and a keeper probing a missing path with
    [ls] died mid-mission -- four turn deaths across the E0 campaign. Only
    infra failures keep the failure disposition, and none of them are in this
    module. *)

type t = {
  ok : bool;
      (** false for any nonzero exit, signal or stop. The call still
          completed; this says what the child reported. *)
  status : Yojson.Safe.t;  (** the status as the payload carries it *)
  timeout_fields : (string * Yojson.Safe.t) list;
      (** the limit that stopped the call, and whether the caller named it.
          Empty unless the status is a timeout. *)
}

val of_status
  :  status:Unix.process_status
  -> timeout_budget:Keeper_tool_execute_input.timeout_budget
  -> t
(** Read a finished child's status. Total: every status yields a report, and
    none of them is a failure disposition. *)
