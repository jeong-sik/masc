module Media = Keeper_media_reading
module Original = Keeper_media_reading_original
module Owner = Keeper_media_reading_owner
module Journal = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Approval = Lane_addon_request_approval
module Identity = Keeper_approval_request_fingerprint
module Media_approval = Keeper_media_reading_approval
module Reply = Keeper_media_reading_reply
module Adapter = Keeper_media_markitdown
module Queue = Keeper_approval_queue
module Queue_result = Keeper_approval_queue_result
module Remote = Keeper_sandbox_remote
module Request = Keeper_sandbox_remote.Stdio_request
module Channel = Agent_core.Mcp.Channel
open Result.Syntax

type error = Media.external_failure
let error_to_string = Media.external_failure_to_string

type t = {
  config : Workspace.config;
  meta : Keeper_meta_contract.keeper_meta;
  media_store : Agent_core.History.media_store;
  declarations : Runtime_schema.media_reader_decl list option;
  causal_context : Keeper_gate.causal_context option;
  channel : Keeper_continuation_channel.t;
  timeout_sec : float;
  endpoint : unit -> (Remote.t, string) result;
  retain_original : store:Lane_addon_store.t -> Original.t -> (Owner.retained, Owner.error) result;
  store : Lane_addon_store.t;
  attempted : (string, unit) Hashtbl.t;
  replies : (string, Reply.t) Hashtbl.t;
  transports : (string, Remote.execution_observation) Hashtbl.t;
  staged : (string, Original.t * Request.t) Hashtbl.t;
}

let create_with ~endpoint ~retain_original ~config ~(meta : Keeper_meta_contract.keeper_meta)
    ~turn_sandbox_factory:_ ~media_store ~declarations ~causal_context
    ~continuation_channel () =
  { config; meta; media_store; declarations;
    causal_context;
    channel = Option.value continuation_channel ~default:
      (Keeper_continuation_channel.unrouted "media reader has no continuation channel");
    timeout_sec = Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ();
    endpoint; retain_original;
    store = Lane_addon_store.of_config config;
    attempted = Hashtbl.create 4; replies = Hashtbl.create 4; transports = Hashtbl.create 4;
    staged = Hashtbl.create 4 }

let create ~config ~meta ~turn_sandbox_factory ~media_store ~declarations
    ~causal_context ~continuation_channel () =
  let endpoint () =
    let cwd = Keeper_sandbox_repo_path.playground_root_no_create ~config ~meta in
    Keeper_sandbox_remote_lane.endpoint ?turn_sandbox_factory ~config ~meta ~cwd () in
  create_with ~endpoint ~retain_original:Owner.retain ~config ~meta ~turn_sandbox_factory
    ~media_store ~declarations ~causal_context ~continuation_channel ()

let owner_result result = Result.map_error (fun error -> Media.Owner_failed error) result
let original_result result = Result.map_error (fun error -> Media.Original_failed error) result
let invalid detail = Error (Media.Invalid_approval detail)
let unavailable error = Media.Owned (Media.Unavailable (Media.External_failed error))
let original retained = Owner.original retained
let record retained = Owner.record retained
let request_id retained = Original.request_id (original retained)
let pending_observation retained disposition : Media.pending_observation =
  { original = Media.original_reference (original retained); disposition }
let pending first rest = Media.Owned (Media.Pending (first, rest))

let request_not_sent = function
  | Some (Remote.Execution_unavailable Remote.Request_not_sent) -> true
  | None | Some (Remote.Execution_observed _ | Remote.Execution_unavailable
      (Transport_unavailable _ | Peer_receipt_missing | Invalid_receipt _ | Shim_refused_without_receipt)) -> false

let before_reply_phase = function
  | Progress.Captured | Admission_wait _ | Dispatch_pending _ -> true
  | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
  | Rejected _ | Subdividing _ | Subdivided _ -> false

let before_dispatch_phase = function
  | Progress.Captured | Admission_wait _ -> true
  | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ | Finished _
  | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false

let reload ~config ~meta ~store retained =
  let* owner = original_result (Original.observe_owner
      ~base_path:config.Workspace.base_path ~keeper_name:meta.Keeper_meta_contract.name) in
  let* current = owner_result (Owner.load ~store ~owner ~request_id:(request_id retained)) in
  match current with
  | None -> Error (Media.Owner_failed (Owner.Store_error (Journal.Store_unavailable
      "known media original is absent")))
  | Some current ->
    (match Journal.rebind (record retained) (Journal.listed (record current)) with
     | None -> Error (Media.Owner_failed (Owner.Store_error Journal.Binding_conflict))
     | Some _ ->
       if List_util.is_prefix ~equal:( = )
           (Progress.events (record retained).progress)
           (Progress.events (record current).progress)
       then Ok current else Error (Media.Progress_failed Journal.State_conflict))

let current t retained = reload ~config:t.config ~meta:t.meta ~store:t.store retained

let advance t retained events =
  let* published = Journal.advance_events ~store:t.store ~expected:(record retained) ~events
      |> Result.map_error (fun error -> Media.Progress_failed error) in
  match published with
  | Journal.Unconfirmed detail -> Error (Media.Progress_unconfirmed detail)
  | Journal.Stored _ | Journal.Already_stored _ -> current t retained

let approval_lookup ?approval_id retained =
  let* intent = Media_approval.intent (original retained)
      |> Result.map_error (fun detail -> Media.Invalid_approval detail) in
  let known_id = match approval_id, Progress.approval (record retained).progress with
    | Some id, Some (Progress.Waiting_for_approval (_, wait)) ->
      if String.equal id (Approval.approval_id wait) then Ok (Some id)
      else invalid "approved ID differs from original wait"
    | Some id, None | Some id, Some (Progress.Intent_pending _) -> Ok (Some id)
    | None, Some (Progress.Waiting_for_approval (_, wait)) -> Ok (Some (Approval.approval_id wait))
    | None, None | None, Some (Progress.Intent_pending _) -> Ok None in
  let* known_id = known_id in
  let+ lookup = Queue.observe_exact_request ?approval_id:known_id (Approval.request intent)
      |> Result.map_error (fun error -> Media.Queue_failed error) in
  intent, lookup

let ensure_intent t retained =
  match Progress.approval (record retained).progress with
  | Some (Progress.Intent_pending _ | Progress.Waiting_for_approval _) -> Ok retained
  | None ->
    let* intent = Media_approval.intent (original retained)
        |> Result.map_error (fun detail -> Media.Invalid_approval detail) in
    advance t retained [Progress.Approval_intended intent]

let retain_wait t retained intent approval_id =
  match Progress.approval (record retained).progress with
  | Some (Progress.Waiting_for_approval (_, wait)) ->
    if String.equal (Approval.approval_id wait) approval_id then Ok retained
    else invalid "original already names another approval"
  | None -> invalid "original approval intent is not retained"
  | Some (Progress.Intent_pending _) ->
    let* wait = Approval.wait intent ~approval_id
        ~input_hash:(Identity.input_hash (Approval.request intent))
        |> Result.map_error (fun detail -> Media.Invalid_approval detail) in
    advance t retained [Progress.Approval_wait_retained wait]

let reply_link retained =
  Reply.validate_progress ~original:(original retained) (record retained).progress
  |> Result.map_error (fun detail -> Media.Reply_capture_failed detail)

let interpreted retained reply =
  let* text = Adapter.markdown reply
      |> Result.map_error (fun reason -> Media.Conversion_failed reason) in
  match Media.reading_of_original ~original:(original retained) ~text with
  | Ok reading -> Ok reading
  | Error _ -> Error (Media.Conversion_failed Adapter.Empty_markdown)

let publication t retained = function
  | Owner.Stored stored | Owner.Already_stored stored -> Ok stored
  | Owner.Unconfirmed detail ->
    (* Visibility may have changed. The caller keeps the same reply/observation
       for retention-only reconciliation; it must not launch another call. *)
    ignore (current t retained);
    Error (Media.Progress_unconfirmed detail)

let retain_reply t retained reply =
  let id = request_id retained in
  Hashtbl.replace t.replies id reply;
  let* published = owner_result (Owner.retain_reply ~store:t.store ~expected:retained ~reply) in
  let+ retained = publication t retained published in
  Hashtbl.remove t.replies id;
  retained

let retain_transport t retained observation =
  let id = request_id retained in
  Hashtbl.replace t.transports id observation;
  let* retained = current t retained in
  let* published = owner_result
      (Owner.retain_transport ~store:t.store ~expected:retained ~observation) in
  let+ retained = publication t retained published in
  Hashtbl.remove t.transports id;
  retained

let repair_local_retention t retained =
  (* A reply/link or the on_receipt writer may have published before reporting
     failure. Reobserve that exact history before retaining the same values. *)
  let* retained = current t retained in
  let* retained = match Hashtbl.find_opt t.replies (request_id retained) with
    | None -> Ok retained
    | Some reply -> retain_reply t retained reply in
  match Hashtbl.find_opt t.transports (request_id retained) with
  | None -> Ok retained
  | Some observation -> retain_transport t retained observation

let select t ~kind ~media_type =
  match t.declarations with
  | None -> Error Media.Declarations_unavailable
  | Some declarations ->
    (match List.filter (fun (declaration : Runtime_schema.media_reader_decl) ->
        declaration.kind = kind && List.mem media_type declaration.media_types) declarations with
     | [] -> Ok None
     | [declaration] -> Ok (Some declaration)
     | _ :: _ :: _ as declarations -> Error (Media.Declaration_ambiguous
         (List.map (fun (declaration : Runtime_schema.media_reader_decl) -> declaration.id) declarations)))

let declared_original t retained =
  let old = Original.declaration (original retained) in
  match t.declarations with
  | None -> Error Media.Declarations_unavailable
  | Some declarations ->
    (match List.filter (fun (declaration : Runtime_schema.media_reader_decl) ->
        String.equal declaration.id old.id) declarations with
     | [declaration] when String.equal (Original.declaration_digest declaration)
         (Original.declaration_digest old) -> Ok declaration
     | [] | [_] | _ :: _ :: _ -> Error (Media.Declaration_changed old.id))

let prepare t (declaration : Runtime_schema.media_reader_decl) =
  let* endpoint = t.endpoint ()
      |> Result.map_error (fun detail -> Media.Endpoint_unavailable detail) in
  Request.prepare ~mode:Exec_ssh_protocol.Effect ~timeout_sec:t.timeout_sec endpoint
    ~argv:(declaration.command :: declaration.args) ~env:[||] ~cwd:None
  |> Result.map_error (fun error -> Media.Request_refused error)

let prepare_original t retained =
  let* declaration = declared_original t retained in
  let* prepared = prepare t declaration in
  if Request.matches_binding prepared (Original.launch (original retained))
  then Ok prepared else Error Media.Binding_changed

let gate_request retained : Keeper_gate.request =
  let original = original retained in
  let subject = Original.original_subject original in
  { keeper_name = Original.subject_keeper_name subject;
    operation = Keeper_gate.media_read_gate_operation;
    input = Media_approval.input original;
    call_summary = Some ("Read attachment with " ^ (Original.declaration original).id);
    base_path = Original.subject_base_path subject;
    causal_context = Original.causal_context original;
    task_id = Original.task_id original;
    continuation_channel = Some (Original.continuation_channel original);
    sandbox_profile = None }

let dispatch_error = function
  | Media.Owner_failed error -> Media.Dispatch_owner_failed error
  | Media.Original_failed error -> Media.Dispatch_owner_failed (Owner.Invalid_original error)
  | Media.Progress_failed error -> Media.Dispatch_progress_failed error
  | Media.Progress_unconfirmed detail -> Media.Dispatch_unconfirmed detail
  | (Media.Declarations_unavailable | Declaration_ambiguous _ | Declaration_changed _
    | Reader_not_started | Queue_failed _ | Gate_failed _ | Approval_mismatch _
    | Invalid_approval _ | Approval_rejected _ | Endpoint_unavailable _ | Request_refused _
    | Binding_refused _ | Binding_changed | Transport_failed _ | Mcp_failed _
    | Channel_unavailable _ | Catalog_failed _ | Conversion_failed _ | Reply_capture_failed _) as error ->
    Media.Dispatch_owner_failed (Owner.Invalid_original
      (Original.Invalid_binding (error_to_string error)))

let close_channel channel use =
  match use () with
  | result -> Channel.close channel; result
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    (try Channel.close channel with
     | close_error -> Log.Keeper.warn "media MCP close failed during primary exception: %s"
         (Printexc.to_string close_error));
    Printexc.raise_with_backtrace exn backtrace

let invoke t retained prepared =
  Hashtbl.replace t.attempted (request_id retained) ();
  let latest = ref retained in
  let on_dispatch () =
    let result =
      let* now = current t !latest in
      if not (Journal.same_record (record !latest) (record now))
      then Error (Media.Progress_failed Journal.State_conflict)
      else let+ dispatched = advance t now [Progress.Dispatch_intended] in
        latest := dispatched in
    Result.map_error dispatch_error result in
  let on_receipt observation =
    match retain_transport t !latest observation with
    | Ok retained -> latest := retained
    | Error _ -> () in
  let run ~input ~output =
    let* channel = Channel.create ~input ~output ()
        |> Result.map_error (fun detail -> Media.Channel_unavailable detail) in
    close_channel channel (fun () ->
      let* () = Channel.initialize channel ~client_version:Build_version.current
          |> Result.map_error (fun error -> Media.Mcp_failed error) in
      let* tools = Channel.list_tools_full channel
          |> Result.map_error (fun error -> Media.Mcp_failed error) in
      let* () = Adapter.validate_catalog tools
          |> Result.map_error (fun error -> Media.Catalog_failed error) in
      let* sdk = Channel.call_tool_full channel ~name:Adapter.tool_name
          ~arguments:(Original.arguments (original !latest))
          |> Result.map_error (fun error -> Media.Mcp_failed error) in
      let* reply = Reply.capture_sdk_reply sdk
          |> Result.map_error (fun detail -> Media.Reply_capture_failed detail) in
      let+ retained = retain_reply t !latest reply in
      latest := retained) in
  let returned = Keeper_sandbox_remote_stdio.with_stdio prepared ~on_dispatch ~on_receipt
      ~on_stderr_chunk:(fun _ -> ()) ~on_stdout_tail:(fun _ -> ()) run in
  (* The session has closed. Finish publication of its exact in-memory values,
     including a lost acknowledgement, without another protocol call. A
     still-unavailable store returns an error; it cannot authorize a resend. *)
  let* retained = repair_local_retention t !latest in
  let* reply = owner_result (Owner.load_reply ~store:t.store retained) in
  match reply with
  | Some _ -> Ok retained
  | None ->
    (match returned with
     | Error error -> Error (Media.Transport_failed error)
     | Ok (Error error, _) -> Error error
     | Ok (Ok (), _) -> Error (Media.Reply_capture_failed "session returned without a retained reply"))

type admission = Deferred of Owner.retained * Media.pending_disposition | Executed of Owner.retained

let awaiting found =
  match found.Queue_result.exact_state with
  | Queue_result.Exact_approved_unconsumed -> Media.Awaiting_host_replay found.exact_approval_id
  | Exact_pending -> Media.Awaiting_approval found.exact_approval_id
  | Exact_rejected reason -> Media.Rejected_approval {approval_id=found.exact_approval_id;reason}
  | Exact_approved_consumed _ -> Media.Approval_consumed found.exact_approval_id

let admit t ?grant ?approval_id retained prepared =
  let* retained = ensure_intent t retained in
  let* intent, lookup = approval_lookup ?approval_id retained in
  let* retained = match approval_id, lookup with
    | None, Queue_result.Exact_absent -> Ok retained
    | Some id, Queue_result.Exact_found found
        when found.exact_state = Queue_result.Exact_approved_unconsumed
          && String.equal found.exact_approval_id id -> retain_wait t retained intent id
    | None, Queue_result.Exact_found found ->
      (match found.exact_state with
       | Queue_result.Exact_pending | Exact_approved_unconsumed ->
         retain_wait t retained intent found.exact_approval_id
       | Exact_rejected reason -> Error (Media.Approval_rejected reason)
       | Exact_approved_consumed _ -> Error (Media.Approval_mismatch lookup))
    | Some _, Queue_result.Exact_absent
    | Some _, Queue_result.Exact_found _
    | _, (Queue_result.Exact_ambiguous _ | Known_approval_missing _ | Known_approval_mismatch _) ->
      Error (Media.Approval_mismatch lookup) in
  match approval_id, lookup with
  | None, Queue_result.Exact_found found -> Ok (Deferred (retained, awaiting found))
  | (None | Some _), (Queue_result.Exact_absent | Exact_ambiguous _
      | Known_approval_missing _ | Known_approval_mismatch _)
  | Some _, Queue_result.Exact_found _ ->
    match Keeper_gate.decide ~intent:Keeper_tool_execute_typed_input.Request_effect
        ?cycle_grant:grant ~keeper_always_allow:(Option.value ~default:false t.meta.always_allow)
        (gate_request retained) with
    | Keeper_gate.Unavailable error -> Error (Media.Gate_failed error)
    | Keeper_gate.Deferred { approval_id = id; _ } ->
      let* _, observed = approval_lookup ~approval_id:id retained in
      (match observed with
       | Queue_result.Exact_found found ->
         let+ retained = retain_wait t retained intent found.exact_approval_id in
         Deferred (retained, awaiting found)
       | Exact_absent | Exact_ambiguous _ | Known_approval_missing _ | Known_approval_mismatch _ ->
         Error (Media.Approval_mismatch observed))
    | Keeper_gate.Allow authorization ->
      let* () = match approval_id, authorization.source with
        | Some expected, Keeper_gate.One_shot_resolution observed when String.equal expected observed -> Ok ()
        | Some _, (Keeper_gate.One_shot_resolution _ | Exact_always_rule _
            | Keeper_always_allow | Workspace_always_allow | Readonly_sandbox
            | Local_output | Observed_in_box _) ->
          invalid "media replay did not consume its exact one-shot approval"
        | None, (Keeper_gate.Exact_always_rule _ | Keeper_always_allow | Workspace_always_allow) -> Ok ()
        | None, (Keeper_gate.One_shot_resolution _ | Readonly_sandbox | Local_output | Observed_in_box _) ->
          invalid "media invocation received an inapplicable authorization source" in
      let+ retained = invoke t retained prepared in
      Executed retained

type assessment =
  | Ready of Owner.retained
  | Read of Owner.retained * Media.reading
  | Blocked of Owner.retained * Media.pending_observation list
  | Failed of Owner.retained * error * Media.pending_observation list
  | Not_sent of Owner.retained * Media.pending_observation list

let assess t retained =
  let* reply = owner_result (Owner.load_reply ~store:t.store retained) in
  let* transport = owner_result (Owner.load_transport ~store:t.store retained) in
  match reply with
  | Some reply ->
    (match interpreted retained reply with
     | Ok reading -> Ok (Read (retained, reading))
     | Error error -> Ok (Failed (retained, error, [])))
  | None ->
    let phase = Progress.phase (record retained).progress in
    (match phase with
     | Progress.Rejected _ | Subdividing _ | Subdivided _ ->
       Ok (Failed (retained, Media.Approval_rejected "original execution was refused", []))
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
     | Commit_unknown _ | Finished _ | Conflicted _ ->
       let* _, lookup = approval_lookup retained in
       let approval_observations = match lookup with
         | Queue_result.Exact_found found ->
           (match found.exact_state with
            | Queue_result.Exact_pending -> [pending_observation retained (Media.Awaiting_approval found.exact_approval_id)]
            | Exact_approved_unconsumed -> [pending_observation retained (Media.Awaiting_host_replay found.exact_approval_id)]
            | Exact_rejected reason -> [pending_observation retained
                (Media.Rejected_approval {approval_id=found.exact_approval_id;reason})]
            | Exact_approved_consumed _ -> [pending_observation retained
                (Media.Approval_consumed found.exact_approval_id)])
         | Exact_absent -> []
         | Exact_ambiguous ids -> [pending_observation retained (Media.Ambiguous_approvals ids)]
         | Known_approval_missing {approval_id;matching_approval_ids} ->
           [pending_observation retained (Media.Known_approval_missing {approval_id;matching_approval_ids})]
         | Known_approval_mismatch {approval_id;matching_approval_ids} ->
           [pending_observation retained (Media.Known_approval_mismatch {approval_id;matching_approval_ids})] in
       let no_send = request_not_sent transport in
       match lookup with
       | Queue_result.Exact_found { exact_state = Exact_rejected reason; _ } ->
         Ok (Failed (retained, Media.Approval_rejected reason, approval_observations))
       | Queue_result.Exact_found {exact_state=(Exact_pending | Exact_approved_unconsumed | Exact_approved_consumed _);_}
       | Exact_absent | Exact_ambiguous _ | Known_approval_missing _ | Known_approval_mismatch _ ->
         let fresh_after_no_send = match lookup with
           | Queue_result.Exact_absent
           | Exact_found {exact_state=Exact_approved_consumed _;_} -> true
           | Exact_found {exact_state=(Exact_pending | Exact_approved_unconsumed | Exact_rejected _);_}
           | Exact_ambiguous _ | Known_approval_missing _ | Known_approval_mismatch _ -> false in
         if no_send && fresh_after_no_send then Ok (Not_sent (retained, approval_observations)) else
         let execution_pending = match phase with
           | Progress.Dispatch_pending _ -> [pending_observation retained Media.Outcome_unknown]
           | Captured | Admission_wait _ -> []
           | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
           | Rejected _ | Subdividing _ | Subdivided _ ->
             [pending_observation retained Media.Reconciliation_required] in
         let execution_pending = match lookup with
           | Queue_result.Exact_found { exact_state = Exact_approved_consumed _; _ }
               when execution_pending = [] -> [pending_observation retained Media.Outcome_unknown]
           | Queue_result.Exact_found {exact_state=(Exact_pending | Exact_rejected _
               | Exact_approved_unconsumed | Exact_approved_consumed _);_}
           | Exact_absent | Exact_ambiguous _
           | Known_approval_missing _ | Known_approval_mismatch _ -> execution_pending in
         match approval_observations @ execution_pending with
         | _ :: _ as observations -> Ok (Blocked (retained, observations))
         | [] -> Ok (Ready retained))

let inventory t ~kind ~media_type source =
  let* owner = original_result (Original.observe_owner ~base_path:t.config.base_path ~keeper_name:t.meta.name) in
  let* subject = original_result (Original.subject owner ~kind ~media_type source) in
  let+ inventory = owner_result (Owner.discover_subject ~store:t.store subject) in
  subject, Owner.originals inventory

let source_key ~kind ~media_type (source : Agent_core.History.stored) =
  Yojson.Safe.to_string (`List
    [`String (match kind with Media.Audio -> "audio" | Document -> "document");
     `String media_type; `String source.sha256; `Int source.bytes])

let create_original t ~key subject declaration =
  let* original, prepared = match Hashtbl.find_opt t.staged key with
  | Some staged -> Ok staged
  | None ->
  let* source = original_result (Original.verify_source ~media_store:t.media_store subject) in
  let* prepared = prepare t declaration in
  let* binding = Request.binding prepared ~base_path:(Original.subject_base_path subject)
      ~keeper_name:(Original.subject_keeper_name subject)
      ~expected_argv:(declaration.Runtime_schema.command :: declaration.args)
      |> Result.map_error (fun error -> Media.Binding_refused error) in
  let* original = original_result (Original.create ~execution_id:(Agent_core.Event_bus.fresh_id ())
      ~source ~declaration ~launch:binding ~causal_context:t.causal_context
      ~task_id:(Option.map Keeper_id.Task_id.to_string t.meta.current_task_id)
      ~continuation_channel:t.channel) in
  Hashtbl.replace t.staged key (original, prepared);
  Ok (original, prepared) in
  let+ retained = owner_result (t.retain_original ~store:t.store original) in
  Hashtbl.remove t.staged key;
  retained, prepared

let outcome_after_execution t retained =
  let* reply = owner_result (Owner.load_reply ~store:t.store retained) in
  match reply with
  | Some reply -> Result.map (fun reading -> Media.Owned (Media.Read reading)) (interpreted retained reply)
  | None -> Ok (pending (pending_observation retained Media.Outcome_unknown) [])

let source ~effects t ~kind ~media_type source =
  let run () =
    let* subject, retained = inventory t ~kind ~media_type source in
    let key = source_key ~kind ~media_type source in
    (match Hashtbl.find_opt t.staged key with
     | Some (staged, _) when List.exists (fun retained ->
         String.equal (Original.request_id staged) (request_id retained)) retained ->
       Hashtbl.remove t.staged key
     | None | Some _ -> ());
    let* assessments = List.fold_left (fun checked retained ->
      let* found = checked in
      let* retained = if effects then repair_local_retention t retained else Ok retained in
      let+ assessed = assess t retained in
      match assessed with
      | Not_sent (original, _) when not (Hashtbl.mem t.attempted (request_id original)) -> found
      | Ready _ | Read _ | Blocked _ | Failed _ | Not_sent _ -> assessed :: found) (Ok []) retained in
    let finish retained prepared =
      match admit t retained prepared with
      | Ok (Executed retained) -> outcome_after_execution t retained
      | Ok (Deferred (retained, disposition)) ->
        Ok (pending (pending_observation retained disposition) [])
      | Error error ->
        let* retained = current t retained in
        let* observed = assess t retained in
        (match observed with
         | Blocked (_, first :: rest) -> Ok (pending first rest)
         | Failed (_, _, first :: rest) -> Ok (pending first rest)
         | Not_sent (retained, observations) ->
           Ok (pending (pending_observation retained Media.Request_not_sent) observations)
         | Ready _ | Read _ | Failed (_, _, []) | Blocked (_, []) -> Error error) in
    match List.rev assessments with
    | [] ->
      let* selected = select t ~kind ~media_type in
      (match selected with
       | None -> Ok Media.Use_builtin
       | Some _ when not effects -> Ok (unavailable Media.Reader_not_started)
       | Some declaration ->
         let* retained, prepared = create_original t ~key subject declaration in
         finish retained prepared)
    | [Read (_, reading)] -> Ok (Media.Owned (Media.Read reading))
    | [Failed (_, _, first :: rest)] -> Ok (pending first rest)
    | [Failed (_, error, [])] -> Error error
    | [Blocked (_, first :: rest)] -> Ok (pending first rest)
    | [Ready retained] ->
      if effects then
        let* prepared = prepare_original t retained in
        finish retained prepared
      else Ok (pending (pending_observation retained Media.Reconciliation_required) [])
    | ([Not_sent _] | [Blocked (_, [])] | _ :: _ :: _) as other ->
      let observations = List.concat_map (function
        | Blocked (_, (_ :: _ as observations)) -> observations
        | Not_sent (retained, observations) -> pending_observation retained Media.Request_not_sent :: observations
        | Failed (_, _, (_ :: _ as observations)) -> observations
        | Ready retained | Read (retained, _) | Failed (retained, _, [])
        | Blocked (retained, []) ->
          [pending_observation retained Media.Reconciliation_required]) other in
      (match observations with
       | first :: rest -> Ok (pending first rest)
       | [] -> invalid "media inventory reconciliation lost its originals") in
  match run () with Ok route -> route | Error error -> unavailable error

let observe t = source ~effects:false t
let read t = source ~effects:true t

let approved_original ~config ~(meta : Keeper_meta_contract.keeper_meta) ~approval_id ~input =
  let* input = Lane_addon_json.canonical input
      |> Result.map_error (fun detail -> Media.Invalid_approval detail) in
  let* id = match input with
    | `Assoc fields -> Json_util.require_field_string ~surface:"media approval" "request_id" fields
        |> Result.map_error (fun detail -> Media.Invalid_approval detail)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      invalid "approved media input is not an object" in
  let store = Lane_addon_store.of_config config in
  let* owner = original_result (Original.observe_owner ~base_path:config.Workspace.base_path ~keeper_name:meta.name) in
  let* retained = owner_result (Owner.load ~store ~owner ~request_id:id) in
  let* retained = match retained with
    | Some retained -> Ok retained
    | None -> invalid "approved media original is absent" in
  let* expected_input = Lane_addon_json.canonical (Media_approval.input (original retained))
      |> Result.map_error (fun detail -> Media.Invalid_approval detail) in
  let* () = if Yojson.Safe.equal input expected_input then Ok ()
    else invalid "approved media input differs from the complete original reference" in
  let* () = match Progress.approval (record retained).progress with
    | Some (Progress.Intent_pending _ | Progress.Waiting_for_approval _) -> Ok ()
    | None -> invalid "approved media original has no retained intent" in
  let* _, lookup = approval_lookup ~approval_id retained in
  match lookup with
  | Queue_result.Exact_found found -> Ok (store, retained, found)
  | Exact_absent | Exact_ambiguous _ | Known_approval_missing _ | Known_approval_mismatch _ ->
    Error (Media.Approval_mismatch lookup)

let transport_projection = function
  | None -> `Assoc ["status", `String "unknown"; "reason", `String "no_retained_observation"]
  | Some (Remote.Execution_observed (_, trailer)) ->
    let integer = function Some value -> `Int value | None -> `Null in
    `Assoc ["status", `String "observed"; "exit", integer trailer.exit;
      "signal", integer trailer.signal; "timed_out", `Bool trailer.timed_out;
      "shim_error_present", `Bool (Option.is_some trailer.shim_error)]
  | Some (Remote.Execution_unavailable reason) ->
    let reason = match reason with
      | Remote.Request_not_sent -> "request_not_sent"
      | Transport_unavailable _ -> "transport_unavailable"
      | Peer_receipt_missing -> "peer_receipt_missing"
      | Invalid_receipt _ -> "invalid_receipt"
      | Shim_refused_without_receipt -> "shim_refused_without_receipt" in
    `Assoc ["status", `String "unknown"; "reason", `String reason]

let execution_of_reply ~store retained reply =
  let* transport = owner_result (Owner.load_transport ~store retained) in
  let* reply_link = reply_link retained in
  let* reply_link = match reply_link with
    | Some link -> Ok link
    | None -> Error (Media.Reply_capture_failed "loaded reply has no retained link") in
  let outcome = match interpreted retained reply with
    | Ok reading -> Media.Read reading
    | Error error -> Media.Unavailable (Media.External_failed error) in
  let data = `Assoc ["reading", Media.outcome_to_json outcome;
    (* The complete receipt remains in its opaque original-owned blob. Do not
       promote raw shim details or syscall lists into public replay output. *)
    "transport", transport_projection transport; "reply_retained", `Bool true] in
  let execution = match outcome with
    | Media.Read _ -> Keeper_tool_execution.success_data data
    | Unavailable failure -> Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Effect_outcome_unknown
        ~message:(Media.failure_to_string failure) data
    | Pending _ -> Keeper_tool_execution.deferred_data
        ~effect_disposition:Tool_result.Effect_outcome_unknown data in
  Ok (Keeper_tool_execution.with_retained_artifacts
      (Reply.artifact reply_link :: Option.to_list (Owner.transport_artifact retained)) execution)

let recover_reply ~config ~meta ~approval_id ~input =
  let* store, retained, found = approved_original ~config ~meta ~approval_id ~input in
  let* () = match found.Queue_result.exact_state with
    | Queue_result.Exact_approved_consumed _ -> Ok ()
    | Exact_pending | Exact_rejected _ | Exact_approved_unconsumed ->
      invalid "media result recovery requires its consumed approval" in
  let* reply = owner_result (Owner.load_reply ~store retained) in
  match reply with
  | None -> Ok None
  | Some reply -> Result.map Option.some (execution_of_reply ~store retained reply)

let replay ~config ~meta ~turn_sandbox_factory ~grant ~approval_id ~input =
  let run () =
    let* store, retained, found = approved_original ~config ~meta ~approval_id ~input in
    let* () = match found.Queue_result.exact_state with
      | Queue_result.Exact_approved_unconsumed -> Ok ()
      | Exact_pending | Exact_rejected _ | Exact_approved_consumed _ ->
        invalid "media replay requires its unconsumed exact approval" in
    let subject = Original.original_subject (original retained) in
    let* inventory = owner_result (Owner.discover_subject ~store subject) in
    (* Observe all prior originals before reading current declarations. *)
    let* () = List.fold_left (fun checked other ->
      let* () = checked in
      if String.equal (request_id other) (request_id retained) then Ok ()
      else
        let* reply = owner_result (Owner.load_reply ~store other) in
        let* transport = owner_result (Owner.load_transport ~store other) in
        if Option.is_none reply && request_not_sent transport
            && before_reply_phase (Progress.phase (record other).progress) then
          let* _, lookup = approval_lookup other in
          (match lookup with
           | Queue_result.Exact_absent
           | Exact_found {exact_state=Exact_approved_consumed _;_} -> Ok ()
           | Exact_found {exact_state=(Exact_pending | Exact_rejected _ | Exact_approved_unconsumed);_}
           | Exact_ambiguous _ | Known_approval_missing _ | Known_approval_mismatch _ ->
             invalid "another media original has unresolved approval")
        else invalid "another media original prevents this replay") (Ok ()) (Owner.originals inventory) in
    let* reply = owner_result (Owner.load_reply ~store retained) in
    let* transport = owner_result (Owner.load_transport ~store retained) in
    let* () = if Option.is_none reply && Option.is_none transport
        && before_dispatch_phase (Progress.phase (record retained).progress)
      then Ok () else invalid "media invocation already has dispatch, reply or transport evidence" in
    let t = create ~config ~meta ~turn_sandbox_factory
        ~media_store:(Tool_blob_media_store.of_base_path ~base_path:config.Workspace.base_path)
        ~declarations:(Runtime.media_reader_declarations ())
        ~causal_context:(Original.causal_context (original retained))
        ~continuation_channel:(Some (Original.continuation_channel (original retained))) () in
    let* prepared = prepare_original t retained in
    let* admitted = admit t ~grant ~approval_id retained prepared in
    match admitted with
    | Deferred (_, _) ->
      invalid "approved media replay deferred without its exact one-shot authorization"
    | Executed retained ->
      let* reply = owner_result (Owner.load_reply ~store retained) in
      (match reply with
       | None -> invalid "media execution returned without a retained reply"
       | Some reply -> execution_of_reply ~store retained reply) in
  run ()

module For_testing = struct
  let create ~endpoint ?(retain_original=Owner.retain) ~config ~meta ~turn_sandbox_factory
      ~media_store ~declarations ~causal_context ~continuation_channel () =
    create_with ~endpoint ~retain_original ~config ~meta ~turn_sandbox_factory
      ~media_store ~declarations ~causal_context ~continuation_channel ()
end
