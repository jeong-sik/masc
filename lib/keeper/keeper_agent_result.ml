(** Keeper Agent.run result surface helpers. *)

open Keeper_agent_prompt_metrics
open Keeper_agent_tool_surface

type tool_call_detail =
  { tool_name : string
  ; provider : string
  ; outcome : string
  ; latency_ms : float
  }

(** Result of a single Agent.run() keeper turn. *)
type run_result =
  { response_text : string
  ; model_used : string
  ; prompt_metrics : prompt_metrics
  ; ctx_composition : ctx_composition_metrics
  ; cascade_observation : Oas_worker.cascade_observation option
  ; turn_count : int
  ; tool_calls_made : int
  ; usage : Oas.Types.api_usage
  ; usage_reported : bool
  ; tools_used : string list
  ; tool_calls : tool_call_detail list
  ; checkpoint : Oas.Checkpoint.t option
  ; proof : Oas.Cdal_proof.t option
  ; trace_ref : Oas.Raw_trace.run_ref option
  ; run_validation : Oas.Raw_trace.run_validation option
  ; stop_reason : Oas_worker.stop_reason
  ; inference_telemetry : Oas.Types.inference_telemetry option
  ; tool_surface : tool_surface_metrics
  }

let nonempty_trimmed raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed
;;

let surface_model_used (result : run_result) : string =
  let attempt_surface_model (attempt : Oas_worker.cascade_attempt) =
    match Option.bind attempt.model_label nonempty_trimmed with
    | Some label -> Some label
    | None -> nonempty_trimmed attempt.model_id
  in
  let observation_surface_model (obs : Oas_worker.cascade_observation) =
    match obs.attempts |> List.rev |> List.find_map attempt_surface_model with
    | Some model -> Some model
    | None ->
      (match Option.bind obs.selected_model nonempty_trimmed with
       | Some model -> Some model
       | None -> Option.bind obs.primary_model nonempty_trimmed)
  in
  match Option.bind result.cascade_observation observation_surface_model with
  | Some model -> model
  | None -> Option.value ~default:"" (nonempty_trimmed result.model_used)
;;

let surface_resolved_model_id (result : run_result) : string =
  (* Always prefer the concrete resolved model_id over any cascade label.
     The final attempt's model_id is authoritative — cascade attempts are
     recorded in order, so [List.rev |> find_map] picks the last attempt
     that actually ran. Falls back to selected/primary observation fields
     when attempts are unavailable, then to the raw provider-reported
     [model_used]. See #9953. *)
  let attempt_resolved_id (attempt : Oas_worker.cascade_attempt) =
    nonempty_trimmed attempt.model_id
  in
  let observation_resolved_id (obs : Oas_worker.cascade_observation) =
    match obs.attempts |> List.rev |> List.find_map attempt_resolved_id with
    | Some model -> Some model
    | None ->
      (match Option.bind obs.selected_model nonempty_trimmed with
       | Some model -> Some model
       | None -> Option.bind obs.primary_model nonempty_trimmed)
  in
  match Option.bind result.cascade_observation observation_resolved_id with
  | Some model -> model
  | None -> Option.value ~default:"" (nonempty_trimmed result.model_used)
;;
