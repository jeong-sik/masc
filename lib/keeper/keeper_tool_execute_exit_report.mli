(** What a finished process's exit status means for the answer.

    Four values used to be computed inline where the dispatch result was
    unpacked, and every one of them is a function of the status the child
    exited with. Pinning the contract they carry therefore needed a real
    child: to ask whether [ls] on a missing path is reported as a completed
    result, a test had to run [ls]. That worked while a keeper could execute
    on the host and stopped when the [Local] profile was removed (#32078), and
    the suite went red for a reason that was never about the boundary.

    So the reading moves here, where a synthesized {!Unix.process_status} is
    enough to ask the question.

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
  error_fields : (string * Yojson.Safe.t) list;
      (** [error] and [stderr], and only when the child both failed and wrote
          something. A successful command's stderr is not an error, and an
          empty stderr is not a message. *)
  timeout_fields : (string * Yojson.Safe.t) list;
      (** the limit that stopped the call, and whether the caller named it.
          Empty unless the status is a timeout. *)
}

val of_status
  :  status:Unix.process_status
  -> stderr:string
  -> timeout_budget:Keeper_tool_execute_input.timeout_budget
  -> t
(** Read a finished child's status. Total: every status yields a report, and
    none of them is a failure disposition. *)
