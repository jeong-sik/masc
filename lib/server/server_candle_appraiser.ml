module A = Candle_appraisal
module Intent = Candle_appraisal_intent
module Exact = Lane_addon_exact
module Runs = Exact_lane_run_registry
let ( let* ) = Result.bind
let tool_name = "candle_appraise"
let reserved_names () =
  List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) Config.raw_all_tool_schemas
  @ (Keeper_tool_descriptor.all_descriptors ()
     |> List.concat_map Keeper_tool_descriptor.registered_names)
  |> List.sort_uniq String.compare
let resolve ~config ~reserved =
  let snapshot = Lane_addon_runtime.tool_export_snapshot ~config
    ~access:Lane_addon_sources.Operator_configuration ~reserved in
  match List.find_opt (fun (conflict : Lane_addon_tool_export.conflict) ->
    String.equal conflict.name tool_name) snapshot.conflicts with
  | Some conflict -> Error (Lane_addon_tool_export.conflict_to_string conflict)
  | None ->
    match List.find_opt (fun (export : Lane_addon_runtime.tool_export) ->
      String.equal export.tool.name tool_name) snapshot.exports with
    | Some export -> Ok export
    | None -> Error (match Lane_addon_unready.summary
        (Lane_addon_unready.declaring ~name:tool_name snapshot.unready) with
      | Some reason -> reason
      | None -> "No attached Add-on provides candle_appraise")
let available ~config () = Result.map (fun _ -> ()) (resolve ~config ~reserved:(reserved_names ()))
let declaration_change_probe ~config () =
  let current () = resolve ~config ~reserved:(reserved_names ()) |> Result.to_option in
  let previous = ref (current ()) in
  fun () -> match current () with
    | None -> false
    | Some export ->
      let changed = match !previous with
        | None -> false
        | Some prior -> not (Lane_addon_tool_export.equal_owner prior.owner export.owner) in
      previous := Some export;
      changed
let prompt_key = function
  | A.Grade _ -> Prompt_names.candle_appraiser_grade
  | A.Relation _ -> Prompt_names.candle_appraiser_relation
  | A.Weights _ -> Prompt_names.candle_appraiser_weights

type state = Absent | Pending | Capacity_wait | Finished of Exact.final
let state_of_json intent json =
  let context = "Candle Add-on reply" in
  let* fields = Candle_json.object_fields ~context json in
  let* id, fields = Candle_json.field ~context "request_id" Candle_json.as_non_blank fields in
  let* () = if String.equal id (Intent.request_id intent) then Ok ()
    else Error "Candle Add-on replied for a different original request" in
  let* state, fields = Candle_json.field ~context "state" Candle_json.as_string fields in
  let* state, fields = match state with
    | "absent" -> Ok (Absent, fields)
    | "pending" -> Ok (Pending, fields)
    | "capacity_wait" -> Ok (Capacity_wait, fields)
    | "finished" ->
      let* result, fields = Candle_json.field ~context "result"
        (Exact.final_of_json ~schema:(A.schema (Intent.request intent))) fields in
      Ok (Finished result, fields)
    | _ -> Error "Unknown Candle Add-on reply state" in
  let* () = Candle_json.finish ~context fields in
  Ok state
let read_reply intent (reply : Mcp_protocol.Mcp_types.tool_result) =
  match reply.is_error with
  | Some true -> Error (A.Transport_unavailable (Agent_core.Mcp.text_of_tool_result reply))
  | None | Some false ->
    let* json = match reply.structured_content with
      | None -> Error (A.Invalid_response "Candle Add-on reply has no structured content")
      | Some json -> Ok json in
    state_of_json intent json |> Result.map_error (fun detail -> A.Invalid_response detail)
let call_error = function
  | Lane_addon_runtime.Unavailable detail | Lane_addon_runtime.Outcome_unknown detail ->
    (* A lost RPC is not a lost judgment. A later pass reads the same intent
       first; only an authoritative [absent] permits its idempotent submission. *)
    A.Transport_unavailable detail
  | Lane_addon_runtime.Host_refusal refusal ->
    match refusal with
    | Lane_addon_call_context.Unavailable detail | Activity_unobserved detail -> A.Transport_unavailable detail
    | Rejected detail | Activity_disabled detail -> A.Execution_rejected detail
let refusal_detail = function
  | Exact.Input_capacity -> "Candle appraisal input exceeds provider capacity"
  | Context_overflow -> "Candle appraisal context overflow"
  | Invalid_request -> "Candle appraisal input refused"
  | Request_body_refused -> "Candle appraisal request body refused"
let usage (value : Exact.usage) : Runs.usage =
  {input_tokens=value.input_tokens;output_tokens=value.output_tokens;
   cache_creation_input_tokens=0;cache_read_input_tokens=0;cost_usd=None}
let run_with ~registry ~base_path ~retain ~call ~identity request =
  let key = prompt_key request in
  let resolution = Prompt_registry.resolve_prompt key in
  let* prompt = Prompt_registry.render_resolved_prompt_template key resolution
      ["appraisal_input", Yojson.Safe.to_string (A.input request)]
    |> Result.map_error (fun detail -> A.Transport_unavailable detail) in
  let* intent = Intent.make ~identity ~prompt request
    |> Result.map_error (fun detail -> A.Execution_rejected detail) in
  let run_id = Intent.request_id intent in
  let* () = retain ~request_id:run_id ~request:(Intent.to_worker_request intent)
    |> Result.map_error call_error in
  let started_at = match Runs.get registry ~run_id with
    | Some run -> run.started_at
    | None ->
      let started_at = Time_compat.now () in
      Runs.register_running registry ~run_id ~lane:Runs.Candle_appraiser ~actor:base_path ~started_at
        ~input:(Runs.Exact_input (Intent.to_worker_request intent));
      started_at in
  let invoke arguments =
    let* reply = call ~arguments |> Result.map_error call_error in
    read_reply intent reply in
  let* state = invoke (Intent.read_arguments intent) in
  let* state = match state with
    | Absent -> invoke (Intent.submit_arguments intent)
    | Pending | Capacity_wait | Finished _ -> Ok state in
  let complete ?usage ~slot outcome result =
    let output = `Assoc ["result", result; "semantic_verification", `String "not_performed"] in
    let same_receipt ~recorded_outcome ~recorded_output ~recorded_slot ~recorded_usage =
      recorded_outcome = outcome && Yojson.Safe.equal recorded_output output
      && recorded_slot = slot && recorded_usage = usage in
    let write elapsed_s =
      (match elapsed_s with
       | Some elapsed_s -> Runs.mark_completed registry ~run_id ~outcome ~elapsed_s ~selected_slot:slot ?usage ~output ()
       | None -> Runs.mark_completed_unmeasured registry ~run_id ~outcome ~selected_slot:slot ?usage ~output ())
      |> Result.map_error (fun error -> A.Transport_unavailable (Runs.completion_error_to_string error)) in
    let readable = function
      | Some Runs.Available -> Ok ()
      | Some (Runs.Unavailable error) ->
        Error (A.Transport_unavailable (Runs.payload_read_error_to_string error))
      | None | Some Runs.Not_loaded ->
        Error (A.Transport_unavailable "Candle terminal receipt output was not observed") in
    let elapsed_now () = max 0. (Time_compat.now () -. started_at) in
    match Runs.get registry ~run_id with
    | None | Some {status=Runs.Running;_} -> write (Some (elapsed_now ()))
    | Some {status=Runs.Completed recorded;output_availability;_} ->
      let* () = readable output_availability in
      (* A retained judgment is read again while later payout stages progress.
         This is no new completion. Compare the whole receipt so a replay-only
         restart marker can still yield to the actual worker's terminal. *)
      if same_receipt ~recorded_outcome:recorded.outcome ~recorded_output:recorded.output
          ~recorded_slot:recorded.selected_slot ~recorded_usage:recorded.usage then Ok ()
      else (match recorded.origin with
        | Runs.Restart_replay -> write None
        | Runs.Producer -> Error (A.Transport_unavailable "Original Candle producer receipt conflicts with the retained terminal"))
    | Some {status=Runs.Completion_persistence_failed recorded;output_availability;_} ->
      let* () = readable output_availability in
      if same_receipt ~recorded_outcome:recorded.intended_outcome ~recorded_output:recorded.output
          ~recorded_slot:recorded.selected_slot ~recorded_usage:recorded.usage then
        write recorded.elapsed_s
      else Error (A.Transport_unavailable "Original Candle pending producer receipt conflicts with the retained terminal") in
  let reject ~slot ~code error result =
    (* A failed observer write cannot change a terminal judgment into a
       retryable dispatch. The retained worker result remains authoritative. *)
    let detail = A.error_to_string error in
    match complete ~slot (Runs.Failed {code;detail}) result with
    | Ok () -> Error error
    | Error receipt_error ->
      let detail = detail ^ "; receipt: " ^ A.error_to_string receipt_error in
      Error (match error with
        | A.Invalid_response _ -> A.Invalid_response detail
        | A.Execution_rejected _ -> A.Execution_rejected detail
        | A.Transport_unavailable _ -> A.Transport_unavailable detail) in
  match state with
  | Absent -> Error (A.Invalid_response "Candle Add-on did not retain the submitted intent")
  | Pending -> Error (A.Transport_unavailable "Candle appraisal is retained and awaiting its original host result")
  | Capacity_wait -> Error (A.Transport_unavailable "Candle Add-on is awaiting capacity to retain this intent")
  | Finished final ->
    match final with
    | Exact.Call_final (Exact.Answered {output;slot;usage=reported_usage}) ->
      let raw = Exact.checked_json output in
      (match A.decode request raw with
       | Error detail -> reject ~slot:(Some slot) ~code:"candle_appraisal_rejected" (A.Invalid_response detail) raw
       | Ok decision ->
         let* trace = A.trace_of_json (A.trace_json {run_id;slot_id=slot})
           |> Result.map_error (fun detail -> A.Invalid_response detail) in
         let* () = complete ?usage:(Option.map usage reported_usage) ~slot:(Some slot) Runs.Succeeded raw in
         Ok {A.decision;trace})
    | Exact.Call_final (Exact.Invalid_output {detail} | Exact.Output_limit_reached {detail}) ->
      reject ~slot:None ~code:"candle_appraisal_rejected" (A.Invalid_response detail) (Exact.final_to_json final)
    | Exact.Call_final (Exact.Input_refused refusal) ->
      reject ~slot:None ~code:"candle_appraisal_execution_rejected"
        (A.Execution_rejected (refusal_detail refusal)) (Exact.final_to_json final)
    | Exact.Outcome_unknown ->
      reject ~slot:None ~code:"candle_appraisal_outcome_unknown"
        (A.Execution_rejected "Candle appraisal outcome is unknown; the original request will not be dispatched again")
        (Exact.final_to_json final)
    | Exact.Not_allowed {reason} ->
      reject ~slot:None ~code:"candle_appraisal_not_allowed" (A.Execution_rejected reason) (Exact.final_to_json final)
    | Exact.Request_id_reused ->
      reject ~slot:None ~code:"candle_appraisal_request_id_reused"
        (A.Execution_rejected "Candle appraisal request ID already belongs to different input") (Exact.final_to_json final)
let run ~config ~identity request =
  let reserved = reserved_names () in
  let* export = resolve ~config ~reserved |> Result.map_error (fun detail -> A.Transport_unavailable detail) in
  let call ~arguments = Lane_addon_runtime.call_exported_tool_with_principal
    ~principal:(Some Lane_addon_call_context.Operator) ~config
    ~access:Lane_addon_sources.Operator_configuration ~reserved ~export ~arguments in
  let retain ~request_id ~request = Lane_addon_runtime.retain_tool_request_owner
    ~config ~access:Lane_addon_sources.Operator_configuration ~reserved ~export
    ~scope:"candle-appraisals" ~request_id ~request in
  run_with ~registry:(Runs.global ()) ~base_path:config.base_path ~retain ~call ~identity request
module For_testing = struct let run = run_with end
