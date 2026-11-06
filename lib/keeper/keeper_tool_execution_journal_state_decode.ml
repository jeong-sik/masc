module Plan = Keeper_tool_plan
module Dependency = Keeper_composition_dependency
module Nodes = Map.Make (String)
open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_json
open Keeper_tool_execution_journal_model

let event kind source_sha fields = `Assoc (["schema", `Int 3; "kind", `String kind; "source_sha", `String source_sha] @ fields)
let row json = Yojson.Safe.to_string json ^ "\n"
let source_event source = event "source" (json_sha (source_json source)) ["source", source_json source]
let source_observation_event source_sha observation =
  event "source_observation" source_sha ["observation",source_observation_json observation]
let attempt_event source_sha occurrence = event "attempting" source_sha ["occurrence", occurrence_json occurrence]

let dependency_wait_json = option_json Dependency.to_json
let dependency_wait_of_json = optional (fun json ->
  match Dependency.of_json json with
  | Ok dependency -> dependency | Error detail -> refuse detail)

let result_read_dependency children (occurrence : occurrence) =
  if not occurrence.readonly then None
  else if String.equal occurrence.tool_name Tool_schemas_composition_control.result_schema.name then
    match Nodes.bindings children |> List.find_map (fun (_,link) ->
      if Plan.Node_id.equal link.result_node_id occurrence.node_id && occurrence.input = `Assoc []
      then link.accepted else None) with
    | Some binding -> Some (Dependency.Composition_result binding)
    | None ->
    match Agent_core.Execution_json.object_fields ~context:"composition result journal input"
        ~required:["binding"] ~optional:[] occurrence.input with
    | Error _ -> None
    | Ok fields ->
      (match Dependency.composition_of_json (List.assoc "binding" fields) with
       | Ok binding when binding.request_id <> occurrence.owner.request_id ->
         Some (Dependency.Composition_result binding)
       | Ok _ | Error _ -> None)
  else
    let readonly_action = match Tool_schemas_owned_job.find_definition occurrence.tool_name with
      | Some {action=Tool_schemas_owned_job.Read_result;read_only;_} -> read_only
      | Some {action=(Start | Status | Cancel);_} | None -> false in
    if not readonly_action then None
    else match occurrence.input with
      | `Assoc ["job_id", `String id] ->
        (match Keeper_owned_job_store.Job_id.of_string id with
         | Ok job_id -> Some (Dependency.Owned_job job_id) | Error _ -> None)
      | _ -> None

let valid_dependency_wait children occurrence result phase dependency =
  result_read_dependency children occurrence = Some dependency
  && phase = Some Tool_result.Proven_pre_effect
  && (match result with Tool_result.Deferred _ -> true | Completed _ | Failed _ -> false)

let owned_job_launch occurrence =
  match Tool_schemas_owned_job.find_definition occurrence.tool_name with
  | Some {action=Tool_schemas_owned_job.Start;_} -> true
  | Some {action=(Tool_schemas_owned_job.Status | Cancel | Read_result);_} | None -> false

(* A launch leaf replays only through the exact invocation identity its
   durable occurrence recorded: re-calling with it makes the owned-job
   invocation binding return Existing, never a replacement launch. Without
   the recorded identity the fail-closed rule below still refuses replay. *)
let recheck_launch_for occurrence = match occurrence.launch_invocation with
  | Some invocation -> Some {execution_id=occurrence.execution_id; tool_use_id=occurrence.tool_use_id; invocation}
  | None -> None

let replay_for children binding node_id record =
  let refuse () = Error (Replay_not_proven node_id) in
  let recheck (occurrence : occurrence) =
    Ok (Recheck_result
      {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
  in
  let recheck_or_dispatch (occurrence : occurrence) =
    match result_read_dependency children occurrence with
    | Some _ -> recheck occurrence
    | None -> Ok Dispatch
  in
  match record with
  | None -> Ok Dispatch
  | Some (Attempting occurrence) ->
    if child_ack_proven children occurrence && not (same_binding occurrence.owner binding)
    then Ok (Recheck_child_submission {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
    else if occurrence.readonly && not (same_binding occurrence.owner binding)
    then recheck_or_dispatch occurrence
    else if owned_job_launch occurrence then
      (match recheck_launch_for occurrence with
       | Some replay -> Ok (Recheck_launch replay)
       | None -> refuse ())
    else refuse ()
  | Some (Settled (occurrence, completed, phase, job)) ->
    (match completed.result with
     | Tool_result.Completed _ -> Ok (Reuse_completed completed)
     | Tool_result.Deferred _ ->
       if child_ack_proven children occurrence && not (same_binding occurrence.owner binding)
       then Ok (Recheck_child_submission {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
       else
       (match job with
        | Some job_id when valid_dependency_wait children occurrence completed.result phase job_id ->
          recheck occurrence
        | None | Some _ -> refuse ())
     | Tool_result.Failed _ ->
       if child_ack_proven children occurrence && not (same_binding occurrence.owner binding)
       then Ok (Recheck_child_submission {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
       else
       (match phase with
        | Some Tool_result.Proven_pre_effect ->
          if child_intent_proven children occurrence then
            Ok (Recheck_child_submission {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
          else if owned_job_launch occurrence && occurrence.launch_mode = Existing_only then
            (match recheck_launch_for occurrence with
             | Some original -> Ok (Recheck_launch original)
             | None -> refuse ())
          else recheck_or_dispatch occurrence
        | Some Tool_result.Effect_outcome_unknown when owned_job_launch occurrence ->
          (match recheck_launch_for occurrence with
           | Some replay -> Ok (Recheck_launch replay)
           | None -> refuse ())
        | None | Some (Tool_result.Proven_post_effect | Effect_outcome_unknown) -> refuse ()))

let decode_state bytes = decode (fun () ->
  require (bytes <> "" && bytes.[String.length bytes - 1] = '\n') "missing or incomplete journal identity";
  let lines = String.split_on_char '\n' bytes in
  let lines = match List.rev lines with "" :: rest -> List.rev rest | _ -> refuse "incomplete journal" in
  let jsons = List.mapi (fun index line ->
    require (String.trim line <> "") (Printf.sprintf "blank journal row %d" (index + 1));
    let json = Yojson.Safe.from_string line in valid_json json; json) lines in
  let header, events = match jsons with header :: events -> header, events | [] -> refuse "missing source header" in
  let fields = object_fields ["schema"; "kind"; "source_sha"; "source"] header in
  require (field "schema" fields = `Int 3 && field "kind" fields = `String "source") "invalid source header schema";
  let source = source_of_json (field "source" fields) in
  let source_sha = string (field "source_sha" fields) in
  require (String.equal source_sha (json_sha (source_json source))) "source fingerprint mismatch";
  let source_observation, events = match events with
    | (`Assoc fields as json) :: rest
      when List.assoc_opt "kind" fields = Some (`String "source_observation") ->
        let fields = object_fields ["schema";"kind";"source_sha";"observation"] json in
        require (field "schema" fields = `Int 3 && field "source_sha" fields = `String source_sha)
          "source observation belongs to another source";
        Some (source_observation_of_json (field "observation" fields)), rest
    | _ -> None, events in
  List.fold_left (fun state json ->
    require (state.resolution = None) "journal event follows a terminal operator resolution";
    let kind = match json with `Assoc fields -> string (field "kind" fields) | _ -> refuse "invalid journal row" in
    let extras = match kind with
      | "binding" -> ["expected_owner"; "owner"]
      | "attempting" -> ["occurrence"]
      | "settled" -> ["occurrence"; "completed"; "failure_effect_disposition"; "dependency_wait"]
      | "child_intent" -> ["occurrence";"result_node_id";"child_source"]
      | "child_accepted" -> ["node_id";"binding"]
      | "resolution" -> ["resolution"]
      | _ -> refuse "unknown journal event" in
    let fields = object_fields (["schema"; "kind"; "source_sha"] @ extras) json in
    require (field "schema" fields = `Int 3 && field "source_sha" fields = `String source_sha) "event source/schema mismatch";
    match kind with
    | "resolution" ->
      let resolution = resolution_of_json (field "resolution" fields) in
      require (same_owner state.owner (Some resolution.owner)) "resolution owner mismatch";
      {state with resolution=Some resolution}
    | "child_intent" ->
      let occurrence = occurrence_of_json (field "occurrence" fields) in
      let key = Plan.Node_id.to_string occurrence.node_id in
      require (same_owner state.owner (Some occurrence.owner) && not occurrence.readonly) "child intent has no effectful current owner";
      require (match Nodes.find_opt key state.nodes with
        | Some (Attempting current) -> same_occurrence current occurrence
        | None | Some (Settled _) -> false) "child intent has no exact parent attempt";
      require (not (Nodes.mem key state.children)) "child intent already exists";
      let result_node_id = match Plan.Node_id.make (string (field "result_node_id" fields)) with
        | Ok id -> id | Error _ -> refuse "invalid child result node" in
      let child_source = source_of_json (field "child_source" fields) in
      let origin = match child_source.producer with
        | Named {origin=Nested origin;_} -> origin
        | Named {origin=Standalone;_} | Prepared -> refuse "child intent lacks original Nested origin" in
      require (Plan.Composition_run_id.equal origin.parent_run_id state.source.composition_run_id
        && Plan.Node_id.equal origin.parent_node_id occurrence.node_id
        && Plan.Node_id.equal origin.result_node_id result_node_id
        && Ids.Execution_id.equal origin.parent_execution_id occurrence.execution_id
        && String.equal origin.parent_occurrence_tool_use_id occurrence.tool_use_id
        && String.equal child_source.keeper_name state.source.keeper_name
        && child_source.source_turn = state.source.source_turn
        && child_source.source_task_id = state.source.source_task_id) "child intent differs from its original parent occurrence";
      {state with children=Nodes.add key {occurrence;result_node_id;child_source;accepted=None} state.children}
    | "child_accepted" ->
      let key = string (field "node_id" fields) in
      let link = match Nodes.find_opt key state.children with Some link -> link | None -> refuse "acceptance has no original child intent" in
      require (link.accepted = None) "child acceptance is already committed";
      require (match Nodes.find_opt key state.nodes with
        | Some (Attempting current) -> same_owner state.owner (Some current.owner)
            && child_occurrence_matches link current
        | None | Some (Settled _) -> false) "child acceptance has no original parent attempt";
      let binding = match Dependency.composition_of_json (field "binding" fields) with
        | Ok binding -> binding | Error detail -> refuse detail in
      require (child_binding_matches link binding) "child acceptance differs from its original source";
      {state with children=Nodes.add key {link with accepted=Some binding} state.children}
    | "binding" ->
      let expected = optional binding_of_json (field "expected_owner" fields) in
      let owner = binding_of_json (field "owner" fields) in
      require (same_owner state.owner expected) "binding predecessor mismatch";
      require (owner.generation = (match expected with None -> 1 | Some prior -> prior.generation + 1)) "binding generation mismatch";
      require (match expected with None -> true | Some prior -> prior.request_id <> owner.request_id) "duplicate binding event";
      {state with owner = Some owner;
        prior_owners = Option.to_list (Option.map (fun prior -> prior, state.nodes) expected)
          @ state.prior_owners}
    | "attempting" | "settled" ->
      let occurrence = occurrence_of_json (field "occurrence" fields) in
      require (same_owner state.owner (Some occurrence.owner)) "node event outside current owner";
      let key = Plan.Node_id.to_string occurrence.node_id in
      let prior = Nodes.find_opt key state.nodes in
      Option.iter (fun record -> require (same_node_identity (occurrence_of_record record)
        ~node_id:occurrence.node_id ~tool_name:occurrence.tool_name ~input:occurrence.input) "node identity changed") prior;
      let record = if kind = "attempting" then (
        require (occurrence.sequence = (match prior with None -> 1 | Some record -> (occurrence_of_record record).sequence + 1)) "attempt sequence mismatch";
        require (match replay_for state.children occurrence.owner occurrence.node_id prior with
          | Ok Dispatch -> occurrence.launch_mode = Initial_launch
          | Ok (Recheck_result stored) -> occurrence.launch_mode = Initial_launch && occurrence.readonly
              && Ids.Execution_id.equal occurrence.execution_id stored.execution_id
              && occurrence.tool_use_id = stored.tool_use_id
          | Ok (Recheck_launch stored) -> occurrence.launch_mode = Existing_only && owned_job_launch occurrence
              && Ids.Execution_id.equal occurrence.execution_id stored.execution_id
              && occurrence.tool_use_id = stored.tool_use_id
              && occurrence.launch_invocation = Some stored.invocation
          | Ok (Recheck_child_submission stored) -> occurrence.launch_mode = Initial_launch && not occurrence.readonly
              && Ids.Execution_id.equal occurrence.execution_id stored.execution_id
              && occurrence.tool_use_id = stored.tool_use_id
          | Ok (Reuse_completed _) | Error _ -> false) "unproven replay event";
        Attempting occurrence)
      else (
        require (match prior with Some (Attempting current) -> same_occurrence current occurrence
                | Some (Settled _) | None -> false) "settlement without exact attempt";
        let completed = completed_of_json (field "completed" fields) in
        require (Ids.Execution_id.equal completed.execution_id occurrence.execution_id && completed.tool_use_id = occurrence.tool_use_id
          && String.equal (Tool_result.tool_name completed.result) occurrence.tool_name) "settlement identity mismatch";
        let phase = optional effect_of_json (field "failure_effect_disposition" fields) in
        let dependency_wait = dependency_wait_of_json (field "dependency_wait" fields) in
        Option.iter (fun job_id -> require (valid_dependency_wait state.children occurrence completed.result phase job_id)
          "dependency wait does not match the exact read-only result leaf") dependency_wait;
        Settled (occurrence, completed, phase, dependency_wait)) in
      {state with nodes = Nodes.add key record state.nodes}
    | _ -> refuse "unknown journal event")
    {source; source_sha; source_observation; owner = None; prior_owners = []; nodes = Nodes.empty;
     children=Nodes.empty;resolution=None} events)
