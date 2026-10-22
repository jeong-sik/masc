(** Candle consumes the optional [candle_appraise] export. The Add-on owns
    durable judgment intents and the common host Exact runner owns dispatch;
    this consumer retains full domain decoding and audit receipts. *)
val available : config:Workspace.config -> unit -> (unit, string) result
val declaration_change_probe : config:Workspace.config -> unit -> (unit -> bool)
(** Changes of a usable export's worker generation release scheduling rejection.
    Absence retains the last observed generation. Retained terminal judgments
    are still read under their original request ID, never dispatched anew. *)
val run : config:Workspace.config -> Candle_appraisal.runner
(** Every return still reads the original worker result and validates the full
    domain decision. Rereading an identical durable terminal receipt preserves
    its first observed elapsed time; retrying a failed receipt append preserves
    that first time too. A replay-only restart marker may still be replaced by
    the actual worker result. *)
module For_testing : sig
  val run : registry:Exact_lane_run_registry.t -> base_path:string
    -> retain:(request_id:string -> request:Yojson.Safe.t -> (unit, Lane_addon_runtime.tool_call_error) result)
    -> call:(arguments:Yojson.Safe.t ->
      (Mcp_protocol.Mcp_types.tool_result, Lane_addon_runtime.tool_call_error) result)
    -> Candle_appraisal.runner
  (** Inject only the exported-tool boundary. Prompt rendering, original intent
      identity, wire/result validation and receipt persistence are production. *)
end
