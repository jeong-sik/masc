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
  ?result_bytes:int ->
  ?truncated_to:int ->
  unit ->
  unit
(** [log_call ...] persists a single tool call record with full I/O.
    Output is truncated to 4000 bytes. [model] records which LLM generated
    the tool call (for 9B vs GLM comparison). [result_bytes] is the original
    output size before any truncation. [truncated_to] is present when
    Tool_output_validation truncated the output. Best-effort (failures logged). *)

val read_recent :
  ?keeper_name:string ->
  ?n:int ->
  unit ->
  Yojson.Safe.t list
(** [read_recent ?keeper_name ?n ()] returns the [n] most recent entries,
    optionally filtered by keeper name. Default [n=100]. *)

val reset_for_testing : unit -> unit
(** Resets the in-memory store reference. For unit tests only. *)
