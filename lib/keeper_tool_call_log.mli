(** Keeper_tool_call_log — Full I/O logging for keeper tool calls.

    Persists complete tool call records to [.masc/tool_calls/YYYY-MM/DD.jsonl].
    Used by dashboard tool-call inspector for debugging.

    @since 2.249.0 *)

val set_truncation_info :
  keeper_name:string ->
  original_bytes:int ->
  ?truncated_to:int ->
  unit ->
  unit
(** [set_truncation_info ~keeper_name ~original_bytes ?truncated_to ()]
    records pre-truncation output size for the given keeper. Called by
    the tool handler wrapper before returning the (possibly truncated)
    result to OAS. Per-keeper isolation prevents cross-keeper corruption
    under concurrent tool execution. *)

val consume_truncation_info :
  keeper_name:string ->
  unit ->
  int * int option
(** [consume_truncation_info ~keeper_name ()] returns
    [(original_bytes, truncated_to)] for the given keeper and clears
    the pending state. Returns [(0, None)] when no truncation info
    was set (e.g. OAS-internal tool call that bypassed the wrapper). *)

val set_turn_context :
  keeper_name:string ->
  ?lane:string ->
  ?tool_choice:string ->
  ?thinking_enabled:bool ->
  ?thinking_budget:int ->
  ?trace_id:string ->
  ?session_id:string ->
  ?turn:int ->
  unit ->
  unit
(** [set_turn_context ...] stores the current effective turn policy for
    subsequent tool-call logs emitted by the keeper during this turn. *)

val get_turn_context :
  keeper_name:string ->
  unit ->
  string option * string option * bool option * int option
  * string option * string option * int option
(** Returns [(lane, tool_choice, thinking_enabled, thinking_budget, trace_id,
    session_id, turn)] for the keeper, or [None] values when no turn context
    has been recorded. *)

val init : base_path:string -> unit
(** [init ~base_path] creates the Dated_jsonl store. Call once at startup. *)

val log_call :
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  success:bool ->
  duration_ms:float ->
  ?model:string ->
  ?lane:string ->
  ?tool_choice:string ->
  ?thinking_enabled:bool ->
  ?thinking_budget:int ->
  ?trace_id:string ->
  ?session_id:string ->
  ?turn:int ->
  ?result_bytes:int ->
  ?truncated_to:int ->
  unit ->
  unit
(** [log_call ...] persists a single tool call record with full I/O.
    Output is truncated to 4000 bytes. [model] records which LLM generated
    the tool call. Turn-policy fields ([lane], [tool_choice],
    [thinking_enabled], [thinking_budget]) capture the effective tool
    selection context. [result_bytes] is the original output size before
    any truncation. [truncated_to] is present when Tool_output_validation
    truncated the output. Best-effort (failures logged). *)

val read_recent :
  ?keeper_name:string ->
  ?n:int ->
  unit ->
  Yojson.Safe.t list
(** [read_recent ?keeper_name ?n ()] returns the [n] most recent entries,
    optionally filtered by keeper name. Default [n=100]. *)

val read_window :
  ?keeper_name:string ->
  window_hours:float ->
  unit ->
  Yojson.Safe.t list
(** [read_window ?keeper_name ~window_hours ()] returns entries within the
    trailing [window_hours]. Non-positive windows return [[]]. *)

val read_latest :
  ?keeper_name:string ->
  unit ->
  Yojson.Safe.t option
(** [read_latest ?keeper_name ()] returns the newest matching entry, if any.
    Uses a small raw-line scan so hot-path callers can avoid materializing
    a larger recent-entry window when they only need the latest tool. *)

val reset_for_testing : unit -> unit
(** Resets the in-memory store reference. For unit tests only. *)
