open Keeper_approval_queue_rules_types
module Exact_output = Agent_core.Exact_output
open Result.Syntax

module Registry = Runtime_exact_output_registry
module Schema = Keeper_structured_output_schema

let lane_id = Standalone_lane.to_id Standalone_lane.Hitl_auto_judge

let system_prompt = Hitl_judge_original.system_prompt

(* The three messages of the judgment request are spelled once, in
   [Hitl_judge_original], so a prepared original and this request cannot drift. *)
let messages_for_summary ~system_prompt ~context_bundle =
  Hitl_judge_original.messages_of
    ~system_prompt
    ~output_contract:(Hitl_judge_original.canonical_output_contract ())
    ~context_bundle
;;

let output_requirement =
  Exact_output.make_output_requirement
    ~schema:Schema.hitl_context_summary_schema
    ~minimum_guarantee:Exact_output.Json_syntax
;;

type prepared_transport =
  | Http_attempt of Exact_output.flow_attempt * Registry.resolved_lane
  | Http_held of
      { slot_id : string
      ; until : float
      }
  | Cli_only

type prepared_flow =
  { entry : pending_approval
  ; generated_at : float
  ; transport : prepared_transport
  ; cli_slots : string list
        (* Official-client runtime ids the lane walks after every catalog
           slot is exhausted, carried from the resolved lane declaration
           (RFC cli-runtimes-as-lane-slots). *)
  ; system_prompt : string
  ; context_bundle : Yojson.Safe.t
        (* Kept beside the frozen HTTP attempt because a cli one-shot has no
           request body: its input is the rendered prompt, rebuilt from the
           same contract and bundle the HTTP messages carry. *)
  }

let registry_error error =
  "HITL exact-output registry unavailable: " ^ Registry.publication_error_to_string error
;;

let lane_error error =
  "HITL exact-output lane unavailable: " ^ Registry.lane_resolution_error_to_string error
;;

let flow_candidates selected_slots =
  let rec loop candidates = function
    | [] -> Ok (List.rev candidates)
    | (slot : Registry.selected_slot) :: rest ->
      (match
         Exact_output.make_flow_candidate
           ~id:slot.slot_id
           ~admitted_target:slot.admitted_target
       with
       | Ok candidate -> loop (candidate :: candidates) rest
       | Error Exact_output.Blank_flow_candidate_id ->
         Error "HITL exact-output lane contains a blank slot id")
  in
  loop [] selected_slots
;;

let snapshot_resolved_lane ~messages (resolved : Registry.resolved_lane) =
  let* candidates = flow_candidates resolved.selected_slots in
  match candidates with
  | [] -> Error "HITL exact-output lane has no usable candidates"
  | first :: rest ->
    Exact_output.snapshot_flow
      ~first
      ~rest
      ~messages
      output_requirement
    |> Result.map_error (fun _ ->
      "HITL exact-output flow snapshot failed")
;;

let prepare_flow
      ~(entry : pending_approval)
  =
  let* context_bundle =
    Hitl_summary_request.capture_context_bundle ~entry
    |> Lane_addon_action.canonical
  in
  let* system_prompt =
    system_prompt ()
    |> Result.map_error (fun detail ->
      "HITL Gate judgment prompt unavailable: " ^ detail)
  in
  let* registry =
    Registry.current ()
    |> Result.map_error registry_error
  in
  let* resolved =
    Registry.resolve_lane registry ~lane_id
    |> Result.map_error lane_error
  in
  (* Which admitted exact-output slot this Keeper uses first for this lane.
     Only here: the readiness check below asks whether the lane can run at all,
     which is a workspace question with no Keeper in it. *)
  let* (ordered : Runtime_exact_lane_backpressure.ordered) =
    Keeper_exact_lane_preference.apply
      ~base_path:entry.Keeper_approval_queue_rules_types.audit_base_path
      ~keeper_name:entry.Keeper_approval_queue_rules_types.keeper_name
      ~lane_id
      resolved
    |> Result.map_error (fun detail ->
      "HITL exact-lane preference unavailable: " ^ detail)
    |> Result.map Runtime_exact_lane_backpressure.order
  in
  let resolved = ordered.lane in
  let* transport =
    match resolved.selected_slots, resolved.cli_slots, ordered.held_http with
    | [], _ :: _, _ -> Ok Cli_only
    | [], [], (first : Runtime_exact_lane_backpressure.held_slot) :: rest ->
      (* Every HTTP slot waits for a time its provider stated. This is not a
         lane without slots: the worker settles it as those slots, called and
         refused for their accounts, would have
         (RFC-exact-lane-waits-for-a-stated-reset R5). *)
      let earliest =
        List.fold_left
          (fun (earliest : Runtime_exact_lane_backpressure.held_slot)
               (held : Runtime_exact_lane_backpressure.held_slot) ->
             if held.until < earliest.until then held else earliest)
          first
          rest
      in
      Ok (Http_held { slot_id = earliest.slot_id; until = earliest.until })
    | _ :: _, _, _ | [], [], [] ->
      let* snapshot = snapshot_resolved_lane
        ~messages:(messages_for_summary ~system_prompt ~context_bundle) resolved in
      Exact_output.start_flow
        ~admission_class:(Standalone_lane.admission_class Hitl_auto_judge)
        snapshot
      |> Result.map (fun attempt -> Http_attempt (attempt, resolved))
      |> Result.map_error (fun _ -> "HITL exact-output flow attempt allocation failed")
  in
  Ok
    { entry
    ; generated_at = Time_compat.now ()
    ; transport
    ; cli_slots = resolved.Registry.cli_slots
    ; system_prompt
    ; context_bundle
    }
;;

let snapshot_topology_readiness () =
  let* system_prompt = system_prompt () in
  let* registry = Registry.current () |> Result.map_error registry_error in
  let* resolved =
    Registry.resolve_lane registry ~lane_id
    |> Result.map_error lane_error
  in
  let* candidates = flow_candidates resolved.selected_slots in
  match candidates with
  | [] ->
    if List.exists (fun runtime_id -> Fusion_official_client.is_official_client ~runtime_id) resolved.cli_slots
    then Ok ()
    else Error "HITL exact-output lane has no usable HTTP or official-client candidates"
  | first :: rest ->
    Exact_output.snapshot_flow
      ~first
      ~rest
      ~messages:
        (messages_for_summary
           ~system_prompt
           ~context_bundle:(`Assoc []))
      output_requirement
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun _ ->
      "HITL exact-output readiness snapshot failed")
;;
