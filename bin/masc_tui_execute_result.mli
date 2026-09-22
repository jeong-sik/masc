(** Masc_tui_execute_result — an Execute call's result, read against the
    output schema its descriptor declares ([execute_output_schema]), for the
    full-calls projection to draw as what a reader looks for first: how the
    command ended and what it printed.

    Pure, so what the pane promises is testable without a terminal. *)

type t = {
  ok : bool;
  status : Unix.process_status;
  execution_time_ms : int;
  output : string option;
  stderr : string option;
      (** The exit report copies a failing command's stderr into both
          [stderr] and [error]; the pair reads as this one field. An [error]
          that says something else stays in {!rest}. *)
  rest : (string * Yojson.Safe.t) list;
      (** Every other member, in the order the producer wrote them. *)
}

val of_result : string -> t option
(** [None] when the text is not a JSON object carrying the members the schema
    requires ([ok], [status], [typed], [execution_time_ms]) with their
    declared types, or when [status] is not one {!Masc.Exec_core} wrote. The
    caller then draws the result as it arrived. *)

val status_text : t -> string
(** How the command ended and how long it ran: [exit 0 · 808 ms],
    [signal 9 · 1200 ms], [stopped 19 · 40 ms]. *)

val rest_text : t -> string option
(** {!rest} on one line, [key=value] joined by [ · ], a nested object's
    members named by their path ([execution_location.scope=playground_root]).
    [None] when nothing is left. *)
