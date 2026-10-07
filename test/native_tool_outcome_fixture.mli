(** Shared production-path assertions used by real vendor protocol fixtures. *)
type t
val create : ?redaction:Masc.Keeper_secret_redaction.t -> unit -> t
val on_event : t -> Agent_core.Types.sse_event -> unit
val on_progress : t -> block_index:int -> tool_call_id:string option ->
  Runtime_native_tools.progress -> unit
val snapshots : t -> Masc_tui_keeper_chat_log.t * Masc_tui_keeper_chat_log.t
val on_completion : t -> block_index:int -> tool_call_id:string option ->
  Runtime_native_tools.completion -> unit
val events : t -> Masc.Keeper_chat_events.keeper_chat_event list
val check : t -> expected:Runtime_native_tools.completion list -> unit
val check_progress : t -> expected:(string * int option * string option) list ->
  expected_text:string -> running:bool -> unit
