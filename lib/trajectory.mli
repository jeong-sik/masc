(** Trajectory — structured agent execution trace.

    Bridges OAS {!Raw_trace} records into a higher-level execution model
    inspired by Deep Agents Harbor evaluation framework.

    @stability Evolving
    @since 0.93.1 *)

(** {1 Tool Call} *)

type tool_call =
  { tool_use_id : string
  ; tool_name : string
  ; tool_input : Yojson.Safe.t
  ; tool_result : string option
  ; is_error : bool
  ; started_at : float
  ; finished_at : float option
  }

val show_tool_call : tool_call -> string
val pp_tool_call : Format.formatter -> tool_call -> unit

(** {1 Step} *)

type step =
  | Think of
      { content : string
      ; ts : float
      }
  | Act of
      { tool_call : tool_call
      ; ts : float
      }
  | Observe of
      { content : string
      ; ts : float
      }
  | Respond of
      { content : string
      ; ts : float
      }

val show_step : step -> string
val pp_step : Format.formatter -> step -> unit
val step_ts : step -> float

(** {1 Trajectory} *)

type trajectory =
  { agent_name : string
  ; model : string
  ; prompt : string
  ; steps : step list
  ; started_at : float
  ; finished_at : float option
  ; success : bool
  ; metrics : Eval.run_metrics option
  ; error : string option
  }

val show_trajectory : trajectory -> string
val pp_trajectory : Format.formatter -> trajectory -> unit

(** {1 Construction} *)

(** Build trajectory from raw trace records. Pairs tool-start/finish
    events, classifies assistant blocks into Think/Respond steps,
    and generates Observe steps from tool results. *)
val of_raw_trace_records : Raw_trace.record list -> trajectory

(** {1 JSON serialization} *)

val to_json : trajectory -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (trajectory, string) result
val tool_call_to_json : tool_call -> Yojson.Safe.t
val tool_call_of_json : Yojson.Safe.t -> (tool_call, string) result
val step_to_json : step -> Yojson.Safe.t
val step_of_json : Yojson.Safe.t -> (step, string) result

(** {1 Analysis} *)

(** Count steps by type: (think, act, observe, respond) *)
val count_steps : trajectory -> int * int * int * int

(** Total Act steps (tool calls) *)
val total_tool_calls : trajectory -> int

(** Count of Act steps where [is_error = true] *)
val tool_error_count : trajectory -> int

(** Elapsed seconds from started_at to finished_at, if finished *)
val elapsed_s : trajectory -> float option
