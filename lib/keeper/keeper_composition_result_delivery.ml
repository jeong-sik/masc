open Result.Syntax

module Async = Keeper_msg_async
module Journal = Keeper_tool_execution_journal
module Draft = Keeper_composition_draft
module Invocation = Agent_core.Tool_contract.Invocation
module Ledger = Keeper_skill_activation_ledger

type error =
  | Invalid_context of string
  | Canonical_request_failed of Async.canonical_terminal_error
  | Request_changed
  | Journal_failed of Journal.error
  | Activation_failed of Draft.error
  | Manifest_read_failed of Tool_blob_store.fetch_error
  | Invalid_manifest of string
  | Invalid_result of string
  | Invocation_collision of string
  | Recorder_failed of Keeper_skill_activation_recorder.error
  | Ledger_failed of Keeper_skill_activation_ledger.store_error

type binding =
  { entry : Async.entry
  ; source : Journal.source
  ; activation : Keeper_skill_activation_recorder.bound_context
  ; invocation : Invocation.t
  ; manifest : Tool_output.artifact_ref
  ; inline_bytes : int
  ; inline_sha256 : string
  }

type presentation = Inline_result | Manifest_reference
type observation =
  { binding : binding
  ; physical_turn_ref : Ids.Turn_ref.t
  ; runtime_id : string
  ; boundary : Ledger.delivery_boundary
  ; transport_receipt : Ledger.tool_result_receipt
  ; presentation : presentation
  }

type pending =
  { runtime_id : string
  ; agent_core_turn : int
  ; results : (binding * string * presentation) list
  }

type t =
  { base_path : string
  ; physical_turn_ref : Ids.Turn_ref.t
  ; mutable bindings : binding list
  ; mutable pending : pending option
  }

let source binding = binding.source
let original_recorder binding = binding.activation
let request_id binding = binding.entry.request_id
let status_invocation binding = binding.invocation
let sha256 content = Digestif.SHA256.(digest_string content |> to_hex)
let equal_invocation left right =
  String.equal (Invocation.tool_use_id left) (Invocation.tool_use_id right)
  && Invocation.turn left = Invocation.turn right
  && Invocation.schedule left = Invocation.schedule right
  && Invocation.completion left = Invocation.completion right

let invocation_to_json invocation =
  let schedule = Invocation.schedule invocation in
  `Assoc ["tool_use_id",`String (Invocation.tool_use_id invocation);
    "turn",`Int (Invocation.turn invocation);
    "schedule",`Assoc ["planned_index",`Int schedule.planned_index;
      "batch_index",`Int schedule.batch_index;"batch_size",`Int schedule.batch_size;
      "execution_mode",Agent_core.Tool_contract.execution_mode_to_yojson schedule.execution_mode];
    "completion",Agent_core.Tool_contract.completion_to_yojson (Invocation.completion invocation)]

let status_payload ?invocation entry =
  (* The canonical entry serializer owns this object shape. This is generated
     data, not a wire parser or a fallback for malformed external input. *)
  let fields = Async.entry_to_json entry |> Yojson.Safe.Util.to_assoc in
  let fields = fields @ Option.to_list (Option.map (fun invocation ->
    "status_invocation",invocation_to_json invocation) invocation) in
  Keeper_tool_composition_projection.with_tool_kind_field
    Keeper_tool_composition_catalog.status_tool_kind (`Assoc fields)

let error_to_string = function
  | Invalid_context detail -> "invalid prepared result context: " ^ detail
  | Canonical_request_failed error -> Async.canonical_terminal_error_to_string error
  | Request_changed -> "prepared result differs from the canonical terminal request"
  | Journal_failed error -> Journal.error_to_string error
  | Activation_failed error -> Yojson.Safe.to_string (Draft.error_to_json error)
  | Manifest_read_failed error -> Tool_blob_store.fetch_error_to_string error
  | Invalid_manifest detail -> "invalid prepared status manifest: " ^ detail
  | Invalid_result detail -> "invalid prepared status result: " ^ detail
  | Invocation_collision id -> "status invocation already binds a different result: " ^ id
  | Recorder_failed error -> Keeper_skill_activation_recorder.error_to_string error
  | Ledger_failed error -> Ledger.store_error_to_string error

let create ~base_path ~physical_turn_ref =
  {base_path; physical_turn_ref; bindings=[]; pending=None}

let prepared_run_id (entry : Async.entry) =
  match entry.request_context with
  | None -> Ok None
  | Some fields ->
    let values name = List.filter_map (fun (key,value) ->
      if String.equal key name then Some value else None) fields in
    match values "draft_reference",values "run_artifact" with
    | [],[] -> Ok None
    | [_],[_] ->
      (match values "composition_run_id" with
       | [`String id] ->
         Keeper_tool_plan.Composition_run_id.of_string id
         |> Result.map Option.some
         |> Result.map_error (fun (Keeper_tool_plan.Composition_run_id.Invalid_uuid_v7 detail) ->
           Invalid_context detail)
       | [] | [_] | _::_::_ -> Error (Invalid_context "missing, duplicate or invalid run identity"))
    | [],(_::_) | (_::_),[] | (_::_::_),(_::_) | [_],(_::_::_) ->
      Error (Invalid_context "missing or duplicate prepared artifact identity")

let canonical_entry ~base_path (entry : Async.entry) =
  let* proof = Async.load_canonical_durable_terminal ~base_path
      ~caller:entry.keeper_name entry.request_id
    |> Result.map_error (fun error -> Canonical_request_failed error) in
  if Async.same_entry_record entry (Async.durable_terminal_entry proof)
  then Ok () else Error Request_changed

let manifest_matches ~base_path ~expected result =
  let* manifest,projection = Tool_bridge.artifact_manifest_reference result
    |> Result.map_error (fun detail -> Invalid_manifest detail) in
  let* () = match projection with
    | Tool_output.Inline_with_reference -> Ok ()
    | Reference_only | Inline_with_structured_diagnostic ->
      Error (Invalid_manifest "status producer requires inline-with-reference presentation") in
  let* bytes = Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:manifest.sha256
    |> Result.map_error (fun error -> Manifest_read_failed error) in
  let* bytes = match bytes with Some bytes -> Ok bytes
    | None -> Error (Invalid_manifest "durable manifest is missing") in
  let* () = if String.length bytes = manifest.bytes then Ok ()
    else Error (Invalid_manifest "manifest byte identity differs") in
  let* json = match Yojson.Safe.from_string bytes with
    | json -> Ok json
    | exception Yojson.Json_error detail -> Error (Invalid_manifest detail) in
  let* () = match Tool_output.artifact_manifest_of_json json with
    | Tool_output.Decoded_artifact_manifest {content;structured_content;_}
      when String.equal content (Tool_result.message result)
           && Yojson.Safe.equal structured_content expected -> Ok ()
    | Decoded_artifact_manifest _ -> Error (Invalid_manifest "manifest differs from canonical status payload")
    | Not_artifact_manifest -> Error (Invalid_manifest "expected a canonical artifact manifest")
    | Invalid_artifact_manifest {detail} -> Error (Invalid_manifest detail) in
  Ok manifest

let resolve ~base_path ~entry ~invocation ~(result : Tool_result.result) =
  match entry.Async.status with
  | Async.Queued | Running | Cancelling _ | Lost _ | Cancelled _
  | Persistence_failed _ | Waiting_for_owned_jobs _ -> Ok None
  | Done _ ->
    let* run_id = prepared_run_id entry in
    match run_id with
    | None -> Ok None
    | Some composition_run_id ->
      let* () = canonical_entry ~base_path entry in
      let* journal = Journal.load ~base_path ~keeper_name:entry.keeper_name ~composition_run_id
        |> Result.map_error (fun error -> Journal_failed error) in
      let* () = Journal.validate_request journal entry
        |> Result.map_error (fun error -> Journal_failed error) in
      let source = Journal.source journal in
      let* activation = Draft.load_nested_activation ~base_path source
        |> Result.map_error (fun error -> Activation_failed error) in
      match activation with
      | None -> Ok None
      | Some activation ->
        let expected = status_payload ~invocation entry in
        let* () = match result with
          | Tool_result.Completed payload
            when String.equal payload.tool_name Keeper_tool_composition_catalog.status_tool_name
                 && Yojson.Safe.equal payload.data expected -> Ok ()
          | Completed _ | Deferred _ | Failed _ ->
            Error (Invalid_result "status result is not the exact completed canonical lookup") in
        let* manifest = manifest_matches ~base_path ~expected result in
        let inline = Tool_bridge.artifact_result_envelope ~reference:manifest
          ~structured_content:expected () in
        Ok (Some {entry;source;activation;invocation;manifest;
          inline_bytes=String.length inline;inline_sha256=sha256 inline})

let discard_status state ~invocation =
  state.bindings <- List.filter (fun known -> not (String.equal
    (Invocation.tool_use_id invocation) (Invocation.tool_use_id known.invocation))) state.bindings

let record_status state ~entry ~invocation ~result =
  let id = Invocation.tool_use_id invocation in
  let previous = List.find_opt (fun known -> String.equal id (Invocation.tool_use_id known.invocation)) state.bindings in
  (* The typed producer owns a new occurrence even when the provider reuses
     its ID. An ineligible or failed new lookup cannot inherit an older seal.
     There is no tombstone: a later valid occurrence may bind the same ID. *)
  discard_status state ~invocation;
  let* binding = resolve ~base_path:state.base_path ~entry ~invocation ~result in
  match binding with
  | None -> Ok ()
  | Some binding ->
    let* () = match previous with
      | Some known when equal_invocation known.invocation invocation ->
        if Async.same_entry_record known.entry binding.entry
           && known.source = binding.source && known.manifest = binding.manifest
           && known.inline_bytes = binding.inline_bytes
           && String.equal known.inline_sha256 binding.inline_sha256
        then Ok () else Error (Invocation_collision id)
      | Some _ | None -> Ok () in
    state.bindings <- binding :: List.filter (fun known ->
      not (String.equal id (Invocation.tool_use_id known.invocation))) state.bindings;
    Ok ()

let clear_pending state = state.pending <- None
let presentation binding content =
  if String.length content = binding.inline_bytes && String.equal (sha256 content) binding.inline_sha256
  then Some Inline_result
  else match Tool_output.decode_from_agent_core content with
    | Tool_output.Decoded reference when String.equal reference.sha256 binding.manifest.sha256
        && reference.bytes = binding.manifest.bytes && String.equal reference.mime binding.manifest.mime ->
      Some Manifest_reference
    | Decoded _ | Not_marker | Invalid_marker _ -> None

let stage_provider state ~runtime_id ~agent_core_turn ~tool_results =
  let results = List.filter_map (fun (id,content) ->
    match List.find_opt (fun binding -> String.equal id (Invocation.tool_use_id binding.invocation)) state.bindings with
    | None -> None
    | Some binding -> Option.map (fun presentation -> binding,content,presentation) (presentation binding content)) tool_results in
  state.pending <- Some {runtime_id;agent_core_turn;results}

let observe_result state ~binding ~runtime_id ~boundary ~content ~presentation ~observe ~on_error =
  let tool_use_id = Invocation.tool_use_id binding.invocation in
  let valid =
    let* () = match boundary with
      | Ledger.Model_response {agent_core_turn}
        when agent_core_turn > Invocation.turn binding.invocation -> Ok ()
      | Official_client_result_handoff {agent_core_turn}
        when agent_core_turn >= Invocation.turn binding.invocation -> Ok ()
      | Model_response _ | Official_client_result_handoff _ ->
        Error (Invalid_result "physical delivery precedes its status invocation") in
    let* () = if String.trim runtime_id <> "" then Ok ()
      else Error (Invalid_result "physical delivery has no runtime identity") in
    let* () = canonical_entry ~base_path:state.base_path binding.entry in
    let* journal = Journal.load ~base_path:state.base_path ~keeper_name:binding.source.keeper_name
        ~composition_run_id:binding.source.composition_run_id
      |> Result.map_error (fun error -> Journal_failed error) in
    let* () = Journal.validate_request journal binding.entry
      |> Result.map_error (fun error -> Journal_failed error) in
    if Journal.source journal = binding.source then Ok () else Error Request_changed in
  match valid with
  | Error error -> on_error error
  | Ok () -> observe {binding;physical_turn_ref=state.physical_turn_ref;runtime_id;boundary;
      transport_receipt=Ledger.{tool_use_id;content_bytes=String.length content;content_sha256=sha256 content};presentation}

let commit_provider_response state ~agent_core_turn ~observe ~on_error =
  match state.pending with
  | None -> ()
  | Some pending when pending.agent_core_turn = agent_core_turn ->
    clear_pending state;
    List.iter (fun (binding,content,presentation) -> observe_result state ~binding ~runtime_id:pending.runtime_id
      ~boundary:(Ledger.Model_response {agent_core_turn}) ~content ~presentation ~observe ~on_error) pending.results
  | Some _ -> ()

let observe_official_result state ~runtime_id ~invocation ~content ~observe ~on_error =
  match List.find_opt (fun binding -> String.equal (Invocation.tool_use_id binding.invocation)
      (Invocation.tool_use_id invocation)) state.bindings with
  | None -> ()
  | Some binding when not (equal_invocation binding.invocation invocation) ->
    on_error (Invocation_collision (Invocation.tool_use_id invocation))
  | Some binding ->
    match presentation binding content with
    | None -> ()
    | Some presentation -> observe_result state ~binding ~runtime_id
      ~boundary:(Ledger.Official_client_result_handoff {agent_core_turn=Invocation.turn invocation})
      ~content ~presentation ~observe ~on_error

let observation_to_json observation =
  let binding = observation.binding and source = observation.binding.source in
  `Assoc ["request_id",`String binding.entry.request_id;
    "composition_run_id",`String (Keeper_tool_plan.Composition_run_id.to_string source.composition_run_id);
    "original_parent_tool_use_id",`String source.parent_tool_use_id;
    "original_source_turn",`Int source.source_turn;
    "original_source_task_id",Json_util.string_opt_to_json source.source_task_id;
    "draft_reference",Tool_output.normalized_artifact_ref_to_json source.draft_reference;
    "run_reference",Tool_output.normalized_artifact_ref_to_json source.run_reference;
    "original_recorder",Keeper_skill_activation_recorder.bound_context_to_yojson binding.activation;
    "physical_turn_ref",Ids.Turn_ref.to_yojson observation.physical_turn_ref;
    "runtime_id",`String observation.runtime_id;
    "transport_tool_use_id",`String observation.transport_receipt.tool_use_id;
    "transport_bytes",`Int observation.transport_receipt.content_bytes;
    "transport_sha256",`String observation.transport_receipt.content_sha256;
    "status_invocation",invocation_to_json binding.invocation;
    "boundary",(match observation.boundary with
      | Ledger.Model_response {agent_core_turn} -> `Assoc ["kind",`String "model_response";"agent_core_turn",`Int agent_core_turn]
      | Official_client_result_handoff {agent_core_turn} -> `Assoc ["kind",`String "official_client_result_handoff";"agent_core_turn",`Int agent_core_turn]);
    "presentation",`String (match observation.presentation with Inline_result -> "inline_result" | Manifest_reference -> "manifest_reference")]

let persist ~(config : Workspace.config) (observation : observation) =
  let binding = observation.binding in
  let* () = canonical_entry ~base_path:config.base_path binding.entry in
  let* journal = Journal.load ~base_path:config.base_path ~keeper_name:binding.source.keeper_name
      ~composition_run_id:binding.source.composition_run_id
    |> Result.map_error (fun error -> Journal_failed error) in
  let* () = Journal.validate_request journal binding.entry
    |> Result.map_error (fun error -> Journal_failed error) in
  let* () = if Journal.source journal = binding.source then Ok () else Error Request_changed in
  let* result = match binding.entry.status with
    | Async.Done {data=Some data;_} -> Ok data
    | Done {data=None;_} | Queued | Running | Cancelling _ | Lost _ | Cancelled _
    | Persistence_failed _ | Waiting_for_owned_jobs _ -> Error (Invalid_result "completed child result is unavailable") in
  let* restored = Draft.load_nested_result_children ~base_path:config.base_path binding.source ~result
    |> Result.map_error (fun error -> Activation_failed error) in
  let* restored,children = match restored with
    | Some value -> Ok value | None -> Error (Invalid_context "original nested recorder is unavailable") in
  let* () = if Yojson.Safe.equal
      (Keeper_skill_activation_recorder.bound_context_to_yojson restored)
      (Keeper_skill_activation_recorder.bound_context_to_yojson binding.activation)
    then Ok () else Error (Invalid_context "original recorder changed before durable handoff") in
  match children with
  | [] -> Ok None
  | _::_ ->
    let logical_parent_tool_use_id = Keeper_composition_nested_run.async_result_parent binding.source.composition_run_id in
    let* expected_activations = Keeper_skill_activation_recorder.find_bound_result_children ~config restored
      ~composition_run_id:binding.source.composition_run_id ~logical_parent_tool_use_id
      ~source_turn:binding.source.source_turn ~tool_name:Draft.run_tool_name children
      |> Result.map_error (fun error -> Recorder_failed error) in
    let* delivery = Keeper_skill_async_delivery.make
      ~original_turn_ref:(Keeper_skill_activation_recorder.bound_turn_ref restored)
      ~composition_run_id:binding.source.composition_run_id ~logical_parent_tool_use_id
      ~request_id:binding.entry.request_id ~physical_turn_ref:observation.physical_turn_ref
      ~runtime_id:observation.runtime_id ~status_invocation:binding.invocation
      ~boundary:observation.boundary ~receipt:observation.transport_receipt
      ~presentation:(match observation.presentation with Inline_result -> Keeper_skill_async_delivery.Inline_result
        | Manifest_reference -> Keeper_skill_async_delivery.Manifest_reference)
      ~child_activations:(List.map (fun (activation : Ledger.activation) -> Keeper_skill_async_delivery.{
        skill_tool_use_id=activation.skill_tool_use_id;activation_sha256=Ledger.activation_frame_sha256 activation}) expected_activations)
      ~observed_at:(Masc_domain.now_iso ())
      |> Result.map_error (fun detail -> Invalid_result detail) in
    Ledger.observe_async_result_delivery ~config
      ~trace_id:(Keeper_skill_activation_recorder.bound_trace_id restored) ~expected_activations delivery
    |> Result.map (fun (_,stored) -> Some stored) |> Result.map_error (fun error -> Ledger_failed error)
;;
