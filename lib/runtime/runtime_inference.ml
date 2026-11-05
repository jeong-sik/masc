(* Per-runtime sampling temperature. A model may declare a fixed [temperature]
   in runtime.toml ([models.<id>.temperature], read via
   [Runtime.temperature_of_runtime_id]); when set, that value is the request
   temperature at every inference boundary for the model. Otherwise the caller's
   explicitly configured subsystem value stands.

   A model whose endpoint fixes the value is not declared here: its AGENT_CORE
   catalog row lists [ignored_sampling_parameters] and the request leaves the
   field out, whatever this resolves to. *)
let resolve_temperature ~runtime_id ~fallback =
  match Runtime.temperature_of_runtime_id runtime_id with
  | Some temperature -> temperature
  | None -> fallback ()

(* Explicit live-ID reasoning lookup for callers that still request it.
   Snapshot-driven native boundaries carry the selected model declaration
   directly and apply their own client admission. This helper preserves an
   absent declaration as [None]; it does not select a runtime or establish
   a native client's effort policy. *)
let resolve_reasoning_effort ~runtime_id =
  Runtime.reasoning_effort_of_runtime_id runtime_id

let resolve_turn_timeout_s ~runtime_id = Runtime.turn_timeout_s_of_runtime_id runtime_id

(* One spelling for the turn-timeout rule every official-client boundary
   shares. Absent leaves the caller's default standing; a non-positive
   declaration removes the bound — the deadline exists to notice a client
   that has gone silent, not to cap how long legitimate work may take, so a
   deployment is allowed to say the client decides. *)
let turn_timeout_s_of_declared ~default = function
  | None -> Some default
  | Some seconds when seconds <= 0.0 -> None
  | Some seconds -> Some seconds
;;

(* masc#24067 / agent-core boundary: MASC must not synthesize a request [max_tokens]
   value. The former resolver invented one from either a model capability
   ceiling or a flat fallback. Callers now carry explicit intent as [int
   option], and AGENT_CORE alone owns model-capability validation plus
   envelope-specific clamp/fallback policy. *)

let for_runtime ~name =
  match Runtime.get_runtime_by_id name with
  | Some runtime ->
    (match Runtime_execution.checkpoint_owner runtime.Runtime_instance.execution with
     | Runtime_execution.Official_client -> Runtime_thinking_seed.absent
     | Runtime_execution.Masc_agent_core ->
       Runtime_thinking_seed.of_model runtime.Runtime_instance.model)
  | None -> Runtime_thinking_seed.absent
;;
