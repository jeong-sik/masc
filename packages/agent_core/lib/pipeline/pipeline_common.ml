open Types
open Agent_types
open Agent_trace

(** Turn pipeline: 6-stage decomposition of agent turn execution.

    Replaces the monolithic run_turn_core with named stages:
    1. Input   — lifecycle, BeforeTurn hook, elicitation
    2. Parse   — BeforeTurnParams hook, tool preparation
    3. Route   — provider selection, API call dispatch (sync/stream)
    4. Collect — usage accumulation, AfterTurn hook, events, message append
    5. Execute — exact-name tool execution on StopToolUse
    6. Output  — stop reason → turn_outcome *)

open Types
open Agent_types
open Agent_trace
open Result_syntax

type api_strategy =
  | Sync
  | Stream of
      { on_event : Types.sse_event -> unit
      ; on_telemetry : (Llm_provider.Telemetry_event.t -> unit) option
      }

type turn_outcome =
  | Complete of Types.api_response
  | ToolsExecuted

let hook_failed_sdk_error
      ~tool_name
      ~tool_use_id
      ~hook_name
      ~(stage : Hooks.hook_stage)
      ~detail
  =
  Error.Agent
    (HookExecutionFailed
       { hook_name
       ; stage = Hooks.hook_stage_to_string stage
       ; tool_name
       ; tool_use_id
       ; detail
       })
;;

let illegal_hook_decision_sdk_error ~hook_name ~stage ~decision =
  hook_failed_sdk_error
    ~hook_name
    ~stage
    ~tool_name:None
    ~tool_use_id:None
    ~detail:
      (Printf.sprintf
         "illegal hook decision %s escaped validation"
         (Hooks.decision_kind_to_string (Hooks.classify_decision decision)))
;;

(** Current timestamp. Prefer the Eio [clock] when available so tests and
    structured-concurrency code observe a consistent time source; fall back
    to [Unix.gettimeofday] only when running outside an Eio environment. *)
let timestamp_now ?clock () =
  match clock with
  | Some clock -> Eio.Time.now clock
  | None -> Unix.gettimeofday ()
;;

(* Publishing never waits for queue capacity to become available. Each matching
   subscriber applies its own explicit bounded-queue overflow behavior, and any
   discarded event is retained in that subscription's dropped_total
   observation. Do not absorb cancellation or allocation/runtime faults here. *)
let safe_publish ~log:_ bus event = Event_bus.publish bus event

let event_envelope agent : Event_bus.envelope =
  let session_id = Option.bind agent.options.raw_trace Raw_trace.session_id in
  let worker_run_id =
    Option.bind (lifecycle_snapshot agent) (fun s -> s.current_run_id)
  in
  let correlation_id =
    match session_id with
    | Some s -> s
    | None -> Event_bus.fresh_id ()
  in
  let run_id =
    match worker_run_id with
    | Some r -> r
    | None -> Event_bus.fresh_id ()
  in
  Event_bus.mk_envelope ~correlation_id ~run_id ()
;;
