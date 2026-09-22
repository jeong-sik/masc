(** Masc_tui_execute_result — an Execute call's result, read for the
    full-calls projection to draw as what a reader looks for first: how the
    command ended and what it printed. The envelope's other members -- where
    it ran, the sandbox, the shim receipts -- change nothing the reader does
    next, so they are not read; the Keeper Calls view keeps the result whole.

    Pure, so what the pane promises is testable without a terminal. *)

(** What the command printed, in the form the result carries it. *)
type output =
  | Printed of string  (** Inline; [""] when it printed nothing. *)
  | Stored of Tool_output.artifact_ref
      (** Too large to ride inline: the combined output is this artifact. *)

type t = {
  ok : bool;
  status : Unix.process_status;
  execution_time_ms : int;
  timeout_limit_sec : float option;
      (** The limit the command ran into, when it was stopped for time. *)
  output : output option;
  stderr : string option;
}

val of_result : string -> t option
(** [None] when the text is not a JSON object carrying the members the schema
    requires ([ok], [status], [typed], [execution_time_ms]) with their
    declared types, when [status] is not one {!Masc.Exec_core} wrote, or when
    a member this reads ([output], [output_artifact], [stderr], [timeout]) is
    not in the shape the producer writes. The caller then draws the result as
    it arrived. *)

val status_text : t -> string
(** How the command ended and how long it ran: [exit 0 · 808 ms],
    [signal 9 · 30012 ms · timed out at 30 s], [stopped 19 · 40 ms]. *)

val stored_text : Tool_output.artifact_ref -> string
(** Where output too large to ride inline went:
    [artifact sha256:9f3a12c4d5e6… · 48213 bytes]. *)
