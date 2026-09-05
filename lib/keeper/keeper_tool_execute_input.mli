(** Typed Execute input projections (quote, render, validate). *)

val assoc_upsert : string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
val typed_input_command_text : Keeper_tool_execute_typed_input.execute_input -> string

val typed_input_call_summary
  :  Keeper_tool_execute_typed_input.execute_input
  -> string option
(** The one line an Execute approval is about: the first non-blank line of
    {!typed_input_command_text}, whole. This is the Execute tool's declared
    call summary; the Gate request carries it and the replay engine recovers
    it from the approved input through the same function. [None] when the
    command text is blank. *)

val default_timeout_sec : float
(** Wall-clock budget for an Execute call whose caller named none. *)

type timeout_budget =
  | Named_by_caller of float
  | Default of float
      (** The caller named no budget, so {!default_timeout_sec} applies. Kept
          apart from a caller's own value because a run stopped at a limit
          nobody chose has to be able to say so. *)

val typed_input_timeout_budget
  :  Keeper_tool_execute_typed_input.execute_input
  -> timeout_budget

val typed_input_timeout_sec : Keeper_tool_execute_typed_input.execute_input -> float
(** The call's wall-clock budget. An absent [timeout_sec] resolves to
    {!default_timeout_sec} here, so nothing downstream can run unbounded. *)

val typed_validation_error_text
  :  Keeper_tool_execute_typed_input.validation_error
  -> string
