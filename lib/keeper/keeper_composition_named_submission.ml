module Plan = Keeper_tool_plan
module Journal = Keeper_tool_execution_journal
module Async = Keeper_msg_async
open Result.Syntax

type request =
  { keeper_name : string
  ; trace_id : Keeper_id.Trace_id.t
  ; physical_turn_ref : Ids.Turn_ref.t
  ; tool_use_id : string
  ; turn : int
  ; source_task_id : string option
  ; origin : Journal.named_origin
  ; skill_reference : Skill_reference.t
  ; tool_name : string
  ; plan : Plan.t
  ; plan_json : Yojson.Safe.t
  }

type phase = Prepared | Submitting of
  { identity : Plan.Composition_run_id.t; request_id : string option }
type state = { source : Journal.source; phase : phase }
type t =
  { root : string
  ; path : string
  ; request : request
  ; journal : Journal.t
  }
type permit = { intent : t; identity : Plan.Composition_run_id.t }

type error =
  | Invalid_request of string
  | Identity_conflict
  | Missing_intent
  | Unreadable_intent of string
  | Corrupt_intent of string
  | Source_conflict
  | Journal_rejected of Journal.error
  | Submission_in_progress
  | Stale_permit
  | Persistence_failed of string

let error_to_string = function
  | Invalid_request detail -> "invalid named submission: " ^ detail
  | Identity_conflict -> "named submission invocation has different Skill, plan or original Task"
  | Missing_intent -> "original named submission intent is absent"
  | Unreadable_intent detail -> "named submission intent is unreadable: " ^ detail
  | Corrupt_intent detail -> "named submission intent is corrupt: " ^ detail
  | Source_conflict -> "named submission source differs from its original producer"
  | Journal_rejected error -> Journal.error_to_string error
  | Submission_in_progress -> "original named submission entered the broker; acceptance is not yet proven"
  | Stale_permit -> "named submission broker-entry permit is stale"
  | Persistence_failed detail -> "named submission persistence failed: " ^ detail

let protect f = try f () with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Sys_error detail -> Error (Persistence_failed detail)
  | Unix.Unix_error (code, operation, path) ->
    Error (Persistence_failed (Printf.sprintf "%s(%s): %s" operation path (Unix.error_message code)))

let equal left right = Yojson.Safe.equal (Yojson.Safe.sort left) (Yojson.Safe.sort right)
let nonblank value = String.trim value <> "" && String.equal value (String.trim value)
let option_string = function None -> `Null | Some value -> `String value

let request ~keeper_name ~trace_id ~physical_turn_ref ~invocation ~source_task_id ~origin ~skill_reference ~tool_name ~plan =
  let tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id invocation in
  let turn = Agent_core.Tool_contract.Invocation.turn invocation in
  let* () =
    if nonblank keeper_name && nonblank tool_name && nonblank tool_use_id
       && nonblank (Keeper_id.Trace_id.to_string trace_id) && turn >= 0
       && String.equal (Ids.Turn_ref.trace_id physical_turn_ref) (Keeper_id.Trace_id.to_string trace_id)
       && Option.fold ~none:true ~some:nonblank source_task_id
    then Ok () else Error (Invalid_request "invalid original invocation coordinates") in
  let* plan_json = Keeper_tool_plan_request.to_yojson plan
    |> Result.map_error (fun (Keeper_tool_plan_request.Unsubstituted_param { name }) ->
      Invalid_request ("unbound named parameter " ^ name)) in
  Ok {keeper_name;trace_id;physical_turn_ref;tool_use_id;turn;source_task_id;origin;skill_reference;tool_name;plan;plan_json}

let identity_json request = `Assoc
    ["keeper_name",`String request.keeper_name;
     "trace_id",`String (Keeper_id.Trace_id.to_string request.trace_id);
     "physical_turn_ref",Ids.Turn_ref.to_yojson request.physical_turn_ref;
     "tool_use_id",`String request.tool_use_id;"turn",`Int request.turn]

let request_json request = `Assoc
    ["skill_reference",Skill_reference.to_yojson request.skill_reference;
     "composition_tool",`String request.tool_name;
     "source_task_id",option_string request.source_task_id;"bound_plan",request.plan_json;
     "origin",Journal.named_origin_to_yojson request.origin]

let phase_json = function
  | Prepared -> `Assoc ["kind",`String "prepared"]
  | Submitting {identity;request_id} -> `Assoc ["kind",`String "submitting";
      "permit",`String (Plan.Composition_run_id.to_string identity);
      "request_id",option_string request_id]

let state_json request state = `Assoc
    ["schema",`String "keeper.named_submission.v1";
     "identity",identity_json request;"request",request_json request;
     "source",Journal.source_to_yojson state.source;"phase",phase_json state.phase]

let fields ~context ~required json =
  Agent_core.Execution_json.object_fields ~context ~required ~optional:[] json
  |> Result.map_error (fun detail -> Corrupt_intent detail)

let decode_phase phase_json =
  match phase_json with
  | `Assoc ["kind",`String "prepared"] -> Ok Prepared
  | `Assoc values ->
    let* values = fields ~context:"named submission broker entry"
        ~required:["kind";"permit";"request_id"] (`Assoc values) in
    let* request_id = match List.assoc "request_id" values with
      | `Null -> Ok None
      | `String value when nonblank value -> Ok (Some value)
      | _ -> Error (Corrupt_intent "invalid original broker request ID") in
    (match List.assoc "kind" values,List.assoc "permit" values with
     | `String "submitting",`String value ->
       Plan.Composition_run_id.of_string value
       |> Result.map (fun identity -> Submitting {identity;request_id})
       |> Result.map_error (fun _ -> Corrupt_intent "invalid broker-entry identity")
     | _ -> Error (Corrupt_intent "unknown broker-entry phase"))
  | _ -> Error (Corrupt_intent "invalid broker-entry phase")

let decode_header request bytes =
  try
    let* () = if bytes <> "" && bytes.[String.length bytes - 1] = '\n' then Ok ()
      else Error (Corrupt_intent "empty or incomplete record") in
    let* record = fields ~context:"named submission intent"
        ~required:["schema";"identity";"request";"source";"phase"] (Yojson.Safe.from_string bytes) in
    let* () = if List.assoc "schema" record = `String "keeper.named_submission.v1" then Ok ()
      else Error (Corrupt_intent "unknown record schema") in
    let* () = if equal (List.assoc "identity" record) (identity_json request)
        && equal (List.assoc "request" record) (request_json request) then Ok ()
      else Error Identity_conflict in
    let* source = Journal.source_of_yojson (List.assoc "source" record)
      |> Result.map_error (fun error -> Journal_rejected error) in
    let* phase = decode_phase (List.assoc "phase" record) in
    Ok {source;phase}
  with Yojson.Json_error detail -> Error (Corrupt_intent detail)

let source_sha source = Digestif.SHA256.(digest_string
    (Yojson.Safe.to_string (Journal.source_to_yojson source)) |> to_hex)

let header request bytes =
  let* first = match String.index_opt bytes '\n' with
    | None -> Error (Corrupt_intent "source header is incomplete")
    | Some newline -> Ok (String.sub bytes 0 (newline + 1)) in
  let* state = decode_header request first in
  match state.phase with
  | Prepared -> Ok state
  | Submitting _ -> Error (Corrupt_intent "source header already entered the broker")

let phase_event source ~expected phase = `Assoc
    ["schema",`String "keeper.named_submission.phase.v1";
     "source_sha",`String (source_sha source);
     "expected",phase_json expected;"phase",phase_json phase]

let valid_transition before after = match before,after with
  | Prepared,Submitting {request_id=None;_} -> true
  | Submitting {request_id=None;_},Prepared -> true
  | Submitting prior,Submitting next ->
    Plan.Composition_run_id.equal prior.identity next.identity
    && (match prior.request_id,next.request_id with
        | None,(None | Some _) -> true
        | Some left,Some right -> String.equal left right
        | Some _,None -> false)
  | Prepared,Prepared | Prepared,Submitting {request_id=Some _;_}
  | Submitting {request_id=Some _;_},Prepared -> false

let decode request bytes =
  try
    let* lines = match List.rev (String.split_on_char '\n' bytes) with
      | ""::rest -> Ok (List.rev rest)
      | _ -> Error (Corrupt_intent "incomplete intent transaction") in
    let* header,events = match lines with
      | header::events -> Ok (header,events)
      | [] -> Error (Corrupt_intent "source header absent") in
    let* initial = decode_header request (header ^ "\n") in
    let* () = match initial.phase with Prepared -> Ok ()
      | Submitting _ -> Error (Corrupt_intent "source header already entered the broker") in
    List.fold_left (fun prior line ->
      let* state = prior in
      let* event = fields ~context:"named submission phase event"
          ~required:["schema";"source_sha";"expected";"phase"] (Yojson.Safe.from_string line) in
      let* () = if List.assoc "schema" event = `String "keeper.named_submission.phase.v1"
          && List.assoc "source_sha" event = `String (source_sha state.source)
          && equal (List.assoc "expected" event) (phase_json state.phase)
        then Ok () else Error (Corrupt_intent "phase event has a different source or predecessor") in
      let* phase = decode_phase (List.assoc "phase" event) in
      if valid_transition state.phase phase then Ok {state with phase}
      else Error (Corrupt_intent "invalid broker-entry transition")) (Ok initial) events
  with Yojson.Json_error detail -> Error (Corrupt_intent detail)

let read ~root path =
  let* contents = Fs_compat.load_owned_regular_file_with_snapshot
      ~owner_uid:(Unix.getuid ()) ~ownership_root:root path
    |> Result.map_error (fun error -> Unreadable_intent (Fs_compat.owned_regular_file_read_error_to_string error)) in
  match contents with
  | None -> Ok None
  | Some contents when contents.snapshot.Fs_compat.permissions land 0o077 = 0 -> Ok (Some contents.content)
  | Some _ -> Error (Unreadable_intent "record is not private")

let check_source request (source : Journal.source) =
  let matches = String.equal source.Journal.keeper_name request.keeper_name
    && String.equal source.parent_tool_use_id request.tool_use_id
    && source.source_turn = request.turn && source.source_task_id = request.source_task_id
    && match source.producer with
       | Journal.Prepared -> false
       | Journal.Named {tool_name;skill_reference;activation;origin} ->
         String.equal tool_name request.tool_name && Skill_reference.equal skill_reference request.skill_reference
         && equal (Journal.named_origin_to_yojson origin) (Journal.named_origin_to_yojson request.origin)
         && Option.fold ~none:false ~some:(fun context ->
           Ids.Turn_ref.equal request.physical_turn_ref
             (Keeper_skill_activation_recorder.bound_turn_ref context)
           && String.equal
             (Keeper_id.Trace_id.to_string (Keeper_skill_activation_recorder.bound_trace_id context))
             (Keeper_id.Trace_id.to_string request.trace_id)) activation in
  if matches then Ok () else Error Source_conflict

let load_journal ~base_path request source =
  let* () = check_source request source in
  let* journal = Journal.load ~base_path ~keeper_name:request.keeper_name
      ~composition_run_id:source.Journal.composition_run_id
    |> Result.map_error (fun error -> Journal_rejected error) in
  let* () = if Journal.same_source source (Journal.source journal) then Ok () else Error Source_conflict in
  let* () = Journal.validate_source_plan journal ~plan:request.plan
    |> Result.map_error (fun error -> Journal_rejected error) in
  Ok journal

let unwrap ~path ~failure_to_string = function
  | Fs_compat.Private_file_succeeded value -> value
  | Private_file_succeeded_with_cleanup_failure {value;cleanup_failure} ->
    (try Log.Keeper.warn "named submission primary transaction preserved at %s: %s" path
       (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure) with
     | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
     | Sys_error _ | Unix.Unix_error _ -> ());
    value
  | Private_file_failed error -> Error (Persistence_failed (failure_to_string error))
  | Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
    Error (Persistence_failed (failure_to_string error ^ "; " ^
      Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))

let location ~base_path request =
  let root = Common.masc_dir_from_base_path ~base_path in
  let name = Digestif.SHA256.(digest_string (Yojson.Safe.to_string (identity_json request)) |> to_hex) ^ ".json" in
  let path = Filename.concat (Filename.concat (Filename.concat root "keeper_msg_requests") "named_submissions") name in
  root,path

let load ~base_path request = protect (fun () ->
  let base_path = Fs_compat.realpath base_path in
  let root,path = location ~base_path request in
  let* directory = Fs_compat.inspect_owned_directory_chain ~ownership_root:root (Filename.dirname path)
    |> Result.map_error (fun error -> Unreadable_intent
      (Fs_compat.owned_directory_chain_rejection_to_string error)) in
  let* bytes = match directory with
    | Fs_compat.Owned_directory_missing -> Ok None
    | Owned_directory _ -> read ~root path in
  match bytes with
  | None -> Ok None
  | Some bytes ->
    let* state = header request bytes in
    let* journal = load_journal ~base_path request state.source in
    Ok (Some {root;path;request;journal}))

let prepare ~base_path request ~make_source = protect (fun () ->
  let* existing = load ~base_path request in
  match existing with
  | Some intent -> Ok intent
  | None ->
  let base_path = Fs_compat.realpath base_path in
  let root,path = location ~base_path request in
  let* () = Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
      ~before_directory_fsync:(fun _ -> ()) ~ownership_root:root (Filename.dirname path)
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun _ -> Persistence_failed "owned intent directory preparation failed") in
  let* prior = read ~root path in
  let* () = match prior with None -> Ok () | Some bytes -> header request bytes |> Result.map (fun _ -> ()) in
  let decide bytes =
    let result =
      let* current = read ~root path in
      let* () = if current = Some bytes then Ok () else Error (Unreadable_intent "path changed during preparation") in
      if bytes = "" && prior = None then
        let* journal = make_source () in
        let source = Journal.source journal in
        let* () = check_source request source in
        let* _ = load_journal ~base_path request source in
        Ok (Some (Yojson.Safe.to_string (state_json request {source;phase=Prepared}) ^ "\n"),journal)
      else
        let* state = header request bytes in
        let* journal = load_journal ~base_path request state.source in
        Ok (None,journal) in
    match result with
    | Error error -> None,Error error
    | Ok (write,journal) -> write,Ok {root;path;request;journal} in
  Fs_compat.update_private_file_durable_locked_result path decide
  |> unwrap ~path ~failure_to_string:Fs_compat.durable_append_error_to_string)

let source intent = Journal.source intent.journal
let journal intent = intent.journal
let path intent = intent.path

let current intent =
  let* bytes = read ~root:intent.root intent.path in
  let* state = match bytes with None -> Error Missing_intent | Some bytes -> decode intent.request bytes in
  let* () = if Journal.same_source state.source (source intent) then Ok () else Error Source_conflict in
  Ok state

let accepted intent = protect (fun () ->
  let* bytes = read ~root:intent.root intent.path in
  let* recorded = match bytes with None -> Error Missing_intent
    | Some bytes -> header intent.request bytes in
  let* () = if Journal.same_source recorded.source (source intent) then Ok () else Error Source_conflict in
  Journal.named_admission intent.journal |> Result.map_error (fun error -> Journal_rejected error))

let unconfirmed_request_id intent = protect (fun () ->
  let* state = current intent in
  Ok (match state.phase with Prepared -> None | Submitting {request_id;_} -> request_id))

let update intent decide = protect (fun () ->
  let callback bytes =
    let result =
      let* state = current intent in
      let* expected = decode intent.request bytes in
      let* () = if equal (state_json intent.request state) (state_json intent.request expected)
        then Ok () else Error (Unreadable_intent "path changed during broker entry") in
      let* next,value = decide state in
      let* () = if valid_transition state.phase next.phase then Ok ()
        else Error (Corrupt_intent "invalid requested phase transition") in
      Ok (state,next,value) in
    match result with Error error -> None,Error error | Ok (before,state,value) ->
      Some (Yojson.Safe.to_string (phase_event state.source ~expected:before.phase state.phase) ^ "\n"),Ok value in
  let unpack = function None -> Error Missing_intent | Some result -> result in
  Fs_compat.update_existing_private_file_durable_locked_result intent.path callback
  |> (fun outcome -> match outcome with
      | Fs_compat.Private_file_succeeded value -> unpack value
      | Private_file_succeeded_with_cleanup_failure {value;cleanup_failure} ->
        unwrap ~path:intent.path ~failure_to_string:Fs_compat.private_jsonl_transaction_error_to_string
          (Private_file_succeeded_with_cleanup_failure {value=unpack value;cleanup_failure})
      | Private_file_failed error -> unwrap ~path:intent.path
          ~failure_to_string:Fs_compat.private_jsonl_transaction_error_to_string (Private_file_failed error)
      | Private_file_failed_with_cleanup_failure failure ->
        unwrap ~path:intent.path ~failure_to_string:Fs_compat.private_jsonl_transaction_error_to_string
          (Private_file_failed_with_cleanup_failure failure)))

let begin_submit intent = update intent (fun state ->
  let* admission = Journal.named_admission intent.journal |> Result.map_error (fun error -> Journal_rejected error) in
  match state.phase,admission with
  | Prepared,None ->
    let identity = Plan.Composition_run_id.fresh () in
    Ok ({state with phase=Submitting {identity;request_id=None}},{intent;identity})
  | Prepared,Some _ | Submitting _,(None | Some _) -> Error Submission_in_progress)

let observe_request_id permit request_id =
  if not (nonblank request_id) then Error (Invalid_request "empty broker request ID") else
  update permit.intent (fun state ->
    match state.phase with
    | Submitting entry when Plan.Composition_run_id.equal entry.identity permit.identity ->
      (match entry.request_id with
       | None -> Ok ({state with phase=Submitting {entry with request_id=Some request_id}},())
       | Some prior when String.equal prior request_id -> Ok (state,())
       | Some _ -> Error Source_conflict)
    | Prepared | Submitting _ -> Error Stale_permit)

let observe_submit_outcome permit (outcome : Async.submit_outcome) =
  observe_request_id permit outcome.request_id

let observe_submit_error permit error =
  let* () = match error with
    | Async.Acceptance_persistence_failed {request_id;_} | Background_fork_failed {request_id;_} ->
      observe_request_id permit request_id
    | Submit_lane_unavailable _ | Submit_rejected _ | Submit_invalid_keeper_name _
    | Submit_invalid_request_context _ | Initial_persistence_failed _ | Background_switch_unavailable _ -> Ok () in
  let pre_acceptance = match error with
    | Async.Submit_lane_unavailable _ | Submit_rejected _
    | Submit_invalid_keeper_name _ | Submit_invalid_request_context _
    | Initial_persistence_failed _ | Background_switch_unavailable _ -> true
    | Acceptance_persistence_failed _ | Background_fork_failed _ -> false in
  if not pre_acceptance then Ok () else
  update permit.intent (fun state ->
    let* () = match state.phase with
      | Submitting {identity;request_id=None} when Plan.Composition_run_id.equal identity permit.identity -> Ok ()
      | Prepared | Submitting _ -> Error Stale_permit in
    let* admission = Journal.named_admission permit.intent.journal
      |> Result.map_error (fun error -> Journal_rejected error) in
    match admission with
    | Some _ -> Error Source_conflict
    | None -> Ok ({state with phase=Prepared},()))
