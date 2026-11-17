module State = Keeper_librarian_history_resolution_state
module Request = Keeper_librarian_durable_request
module Source = Keeper_librarian_durable_capture
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Store = Lane_addon_store
module Current = Keeper_memory_os_current
module Receipts = Keeper_memory_os_current_receipt_store
module Types = Keeper_memory_os_current_types
module Atom = Keeper_librarian_progress
module Official = Keeper_librarian_official_progress
module Cursor = Keeper_external_read_cursor
module Exact = Lane_addon_exact
open Result.Syntax

type error =
  | Original_absent
  | Ineligible of string
  | Observation_changed
  | Range_already_recorded
  | Already_fenced of State.t
  | Host_claim_busy
  | Unavailable of string
  | Publication_uncertain of string
type preview = { expected:State.guard; scope:string; request_id:string; request_digest:string }
let error_to_string = function
  | Original_absent -> "Original history request is absent"
  | Ineligible detail -> detail
  | Observation_changed -> "Original, Memory or cursor observation changed"
  | Range_already_recorded -> "Original range has a prepared or committed Memory receipt"
  | Already_fenced _ -> "Original history result is already fenced"
  | Host_claim_busy -> "Original history execution claim is busy"
  | Unavailable detail -> "History fence observation unavailable: " ^ detail
  | Publication_uncertain detail -> "History fence publication is unconfirmed: " ^ detail
let unavailable result = Result.map_error (fun detail -> Unavailable detail) result
let require condition error = if condition then Ok () else Error error
let digest json =
  let+ canonical = unavailable (Lane_addon_action.canonical json) in
  Agent_core_sha256.(to_hex (digest_string (Yojson.Safe.to_string canonical)))
let optional encode = function None -> `Null | Some value -> encode value
let io work = Systhread_host.run ~label:__FUNCTION__ work
let scope ~config ~keeper_name ~request_id =
  let* scope = unavailable (Request.discovery_scope ~base_path:config.Workspace.base_path
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path)
    ~keeper_id:keeper_name) in
  let* requested = unavailable (Request.scope_of_request_id request_id) in
  let+ () = require (scope=requested) (Ineligible "Request belongs to another workspace or Keeper") in scope
let read ~config ~keeper_name ~request_id =
  let* scope = scope ~config ~keeper_name ~request_id in
  unavailable (State.read ~store:(Store.of_config config) ~scope ~request_id)
let load_original ~config ~keeper_name ~request_id =
  let store = Store.of_config config in
  let* scope = scope ~config ~keeper_name ~request_id in
  let* original = Owner.load ~store ~scope ~request_id |> Result.map_error (fun error ->
    Unavailable (Owner.error_to_string error)) in
  let* original = match original with None -> Error Original_absent | Some value -> Ok value in
  let* owner = unavailable (Request.observe_record_owner ~base_path:config.base_path
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path) original) in
  let* request = unavailable (Request.restore ~owner original) in
  Ok (store, original, request)
let load ~config ~keeper_name ~request_id =
  let* scope=scope ~config ~keeper_name ~request_id in
  let* fence=unavailable (State.read ~store:(Store.of_config config) ~scope ~request_id) in
  let* ()=match fence with None -> Ok () | Some fence -> Error (Already_fenced fence) in
  load_original ~config ~keeper_name ~request_id
type original_kind = Absent_original | Cut_original
let eligible ~kind ~request ~(original:Owner.retained) =
  let* () = match kind,Progress.phase original.progress with
    | Absent_original,Dispatch_pending (Some (Absent _)) -> Ok ()
    | Cut_original,Rejected {stage=Execution;evidence} ->
      let* exact=unavailable (Request.request request) in
      let* schema=Option.to_result ~none:(Ineligible "Cut original has no captured schema") exact.Exact.schema in
      let* final=unavailable (Exact.retained_final_of_json ~schema evidence) in
      (match final with
       | Exact.Retained_unknown Cut ->
         require (Option.is_none (Progress.settlement original.progress))
           (Ineligible "Cut original already has a source disposition")
       | Retained_unknown (Interrupted | Raised) | Retained_call _ | Retained_not_allowed _
       | Retained_request_id_reused ->
         Error (Ineligible "Original is not a retained execution-stage Cut"))
    | Absent_original,(Captured | Admission_wait _ | Dispatch_pending (None | Some (Waiting _ | Outcome_unknown _))
      | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _ | Rejected _
      | Subdividing _ | Subdivided _)
    | Cut_original,(Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
      | Commit_unknown _ | Finished _ | Conflicted _ | Rejected {stage=Before_dispatch;_}
      | Subdividing _ | Subdivided _) ->
      Error (Ineligible "Original phase does not carry the requested fence authority") in
  require (Option.is_none (Progress.preparation original.progress)
    && Option.is_none (Progress.replacement original.progress))
    (Ineligible "Original already owns gate or replacement preparation")
let no_host_result ~store request =
  let* exact = unavailable (Request.request request) in
  let* schema = match exact.Exact.schema with
    | None -> Error (Ineligible "Original history request has no schema") | Some schema -> Ok schema in
  let* installation = Owner.installation_of_id (Request.destination request).installation_id |> unavailable in
  let* declaration_id = match installation with
    | Owner.Configuration value -> Ok value
    | Manual _ -> Error (Ineligible "History original is not owned by a configuration declaration") in
  let* observed = unavailable (Exact.observe_retained ~store ~declaration_id ~schema exact) in
  let* () = match observed with
    | Exact.Retained_absent -> Ok ()
    | Retained_open | Retained_terminal _ ->
      Error (Ineligible "Original host execution exists; reobserve its outcome before fencing") in
  let* proof = unavailable (Exact.read_latest_original_execution ~store ~declaration_id ~schema exact) in
  match proof with
  | Exact.No_completed_latest -> Ok ()
  | Completed_latest _ -> Error (Ineligible "Original host execution proof is available")
let with_host_exclusion ~kind ~store ~request consume = match kind with
  | Absent_original -> let* ()=no_host_result ~store request in consume None
  | Cut_original ->
    let* exact=unavailable (Request.request request) in
    let* schema=Option.to_result ~none:(Ineligible "Cut original has no captured schema") exact.Exact.schema in
    let* installation=unavailable (Owner.installation_of_id (Request.destination request).installation_id) in
    let* declaration_id=match installation with Owner.Configuration id -> Ok id
      | Manual _ -> Error (Ineligible "Cut original is not configured") in
    let* outcome=Exact.with_cut_exclusion ~store ~declaration_id ~schema exact
      ~use:(fun exclusion -> consume (Some exclusion))
      |> Result.map_error (fun error -> Unavailable (Exact.describe_recovery_error error)) in
    match outcome with
    | Exact.Cut_busy -> Error Host_claim_busy
    | Cut_not_retained _ -> Error (Ineligible "Original host no longer retains a terminal Cut")
    | Cut_excluded result -> result
let no_range_receipt request =
  let owner = Request.physical_owner request and source = Request.source request in
  let* reading = unavailable (Receipts.read_durable_range_receipts_cached
    ~keepers_dir:(Request.keepers_dir owner) ~keeper_id:(Request.keeper_id owner)) in
  let* receipts = match reading with
    | Receipts.Cached_receipts entry -> Ok entry.receipts
    | Uncached_receipts (receipts, []) -> Ok receipts
    | Uncached_receipts (_, _::_) -> Error (Unavailable "Original range receipt store contains unreadable entries") in
  let matches receipt = match Receipts.receipt_range_id receipt with
    | Types.Atom_range range -> Option.exists (fun (expected:Current.durable_range_id) ->
        range.receipt_scope=expected.receipt_scope
        && range.trace_id=expected.trace_id
        && range.history_start_boundary_line=expected.history_start_boundary_line
        && range.start_atom<expected.end_atom && expected.start_atom<range.end_atom)
        (Source.range_id source)
    | Official_range range -> Option.exists (fun (expected:Current.official_range_id) ->
        range.receipt_scope=expected.receipt_scope
        && List.exists (fun (line, turn) -> List.exists (fun (expected_line, expected_turn) ->
          line=expected_line && Ids.Turn_ref.equal turn expected_turn) expected.turns) range.turns)
        (Source.official_range_id source)
    | Explicit_candidate _ | Explicit_candidate_with_recall _ -> false in
  require (not (List.exists matches receipts)) Range_already_recorded
let cursors request =
  let owner = Request.physical_owner request in
  let keepers_dir = Request.runtime_keepers_dir owner and keeper_id = Request.keeper_id owner in
  let* atom = Atom.read ~keepers_dir ~keeper_id |> Result.map_error (fun error ->
    Unavailable (Atom.read_error_to_string error)) in
  let* official = Official.read ~keepers_dir ~keeper_id |> Result.map_error (fun error ->
    Unavailable (Official.read_error_to_string error)) in
  let* external_cursor = unavailable (Cursor.observe ~runtime_keepers_dir:keepers_dir ~keeper_name:keeper_id) in
  digest (`Assoc ["atom",optional Atom.to_json atom;"official",optional Official.to_json official;
    "external",Cursor.observation_to_json external_cursor])
let with_observation ~check_fence ~kind ~store ~(original:Owner.retained) ~request consume =
  Keeper_librarian_durable_source_lock.with_original_snapshot ~request (fun ~messages:_ ->
    let owner = Request.physical_owner request in
    let keepers_dir = Request.keepers_dir owner and keeper_id = Request.keeper_id owner in
    Ok (Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
      File_lock_eio.with_lock (Current.path_for_keepers_dir ~keepers_dir ~keeper_id) (fun () ->
        let* () = unavailable (Request.confirm_owner request) in
        let* current = Owner.reload ~store original |> Result.map_error (fun error ->
          Unavailable (Owner.error_to_string error)) in
        let* current = match current with None -> Error Observation_changed | Some value -> Ok value in
        let* () = eligible ~kind ~request ~original:current in
        let* record_sha256 = digest (Owner.to_json current) in
        let* original_sha256 = digest (Owner.to_json original) in
        let* () = require (record_sha256=original_sha256) Observation_changed in
        let* () = check_fence current in
        with_host_exclusion ~kind ~store ~request (fun exclusion ->
        let* snapshot = unavailable (Current.read_locked_for_keepers_dir ~keepers_dir ~keeper_id) in
        let* memory_sha256 = match snapshot with
          | None -> Ok None | Some snapshot -> let+ digest = digest (Current.to_json snapshot) in Some digest in
        let* () = no_range_receipt request in
        let* inventory = unavailable (Keeper_librarian_durable_gate.Inventory.read ~store ~owner) in
        let* () = require (Keeper_librarian_durable_gate.Inventory.execution_records inventory
          ~execution_id:current.request_id = []) (Ineligible "Original has retained gate records") in
        let* cursors_sha256 = cursors request in
        consume current {State.owner_record_sha256=record_sha256;
          memory_revision=Option.map (fun (snapshot:Current.t) -> snapshot.revision) snapshot;
          memory_sha256;cursors_sha256} exclusion)))))
  |> unavailable |> Result.join
let observe ~kind ~config ~keeper_name ~request_id consume =
  let* store, original, request = load ~config ~keeper_name ~request_id in
  with_observation ~kind ~store ~original ~request
    ~check_fence:(fun current -> unavailable (State.check_unfenced ~store ~request ~original:current))
    (fun current expected exclusion -> consume store request current expected exclusion)
let preview_kind ~kind ~config ~keeper_name ~request_id =
  try observe ~kind ~config ~keeper_name ~request_id (fun _store _request original expected _exclusion ->
    Ok {expected;scope=original.Owner.scope;request_id;request_digest=original.request_digest})
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Unavailable (Printexc.to_string exn))
let preview ~config ~keeper_name ~request_id =
  preview_kind ~kind:Absent_original ~config ~keeper_name ~request_id
let preview_cut ~config ~keeper_name ~request_id =
  preview_kind ~kind:Cut_original ~config ~keeper_name ~request_id
let fence_kind ~kind ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now =
  try
    let* expected = State.guard_of_json (State.guard_to_json expected) |> unavailable in
    observe ~kind ~config ~keeper_name ~request_id (fun store request original actual exclusion ->
      let* () = require (actual=expected) Observation_changed in
      let* fence = unavailable (match kind,exclusion with
        | Absent_original,None -> State.create ~request ~original ~expected ~actor ~reason ~now
        | Cut_original,Some exclusion ->
          State.create_cut ~store ~request ~original ~expected ~exclusion ~actor ~reason ~now
        | Absent_original,Some _ | Cut_original,None -> Error "History fence exclusion kind differs") in
      match State.publish ~store fence with
      | Error detail -> Error (Publication_uncertain detail)
      | Ok Store.History_fence_unconfirmed detail -> Error (Publication_uncertain detail)
      | Ok History_fence_owner_changed -> Error Observation_changed
      | Ok (History_fence_stored | History_fence_already_stored) ->
        let* readback = State.read ~store ~scope:fence.scope ~request_id:fence.request_id
          |> Result.map_error (fun detail -> Publication_uncertain detail) in
        match readback with
        | Some actual when State.to_json actual=State.to_json fence -> Ok actual
        | None | Some _ -> Error (Publication_uncertain "History fence readback differs"))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Publication_uncertain (Printexc.to_string exn))
let fence_serialized ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now =
  fence_kind ~kind:Absent_original ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now
let fence_cut_serialized ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now =
  fence_kind ~kind:Cut_original ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now

let same_binding ~config request =
  Keeper_librarian_durable_edge.confirm_destination ~config
    ~reserved:(Keeper_librarian_durable_edge.reserved ()) (Request.destination request)
  |> Result.map_error (function
    | Lane_addon_submit_once.Unavailable detail | Rejected detail -> Ineligible detail
    | Uncertain detail -> Unavailable detail)
let preview_cut_command ~config ~keeper_name ~request_id =
  try
    let* store,original,request=io (fun () -> load ~config ~keeper_name ~request_id) in
    let* ()=same_binding ~config request in
    io (fun () -> with_observation ~kind:Cut_original ~store ~original ~request
      ~check_fence:(fun current -> unavailable (State.check_unfenced ~store ~request ~original:current))
      (fun current expected exclusion ->
        let* exclusion=Option.to_result ~none:(Unavailable "Cut observation has no held claim") exclusion in
        let+ basis=unavailable (State.observe_cut_basis ~store ~request ~exclusion) in
        {expected;scope=current.Owner.scope;request_id;request_digest=current.request_digest},basis))
  with Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Unavailable (Printexc.to_string exn))
type cut_grant = {
  store:Store.t; request:Request.t; original:Owner.retained;
  exclusion:Exact.cut_exclusion; fence:State.t;
}
let confirm_cut_grant ~store grant =
  let* ()=Request.confirm_owner grant.request in
  let* ()=State.confirm_binding ~request:grant.request ~original:grant.original grant.fence in
  let* basis=State.observe_cut_basis ~store ~request:grant.request ~exclusion:grant.exclusion in
  let* ()=match grant.fence.authority with
    | State.Excluded_cut expected -> if basis=expected then Ok () else Error "Cut claim evidence changed"
    | Worker_absent -> Error "Cut grant cannot use a worker-absence fence" in
  let* stored=State.read ~store ~scope:grant.fence.scope ~request_id:grant.fence.request_id in
  let* stored=Option.to_result ~none:"Cut grant fence disappeared" stored in
  let* expected=Lane_addon_action.canonical (State.to_json grant.fence) in
  let* actual=Lane_addon_action.canonical (State.to_json stored) in
  let+ ()=if expected=actual then Ok () else Error "Cut grant fence changed" in stored
let with_cut_fence_serialized_with ~after_publish ~config ~keeper_name ~request_id ~expected ~basis ~actor ~reason ~now ~use =
  try
    let* store,original,request=io (fun () -> load_original ~config ~keeper_name ~request_id) in
    let run () =
    let* previous=unavailable (State.read ~store ~scope:original.scope ~request_id) in
    let check_fence current = match previous with
      | None -> unavailable (State.check_unfenced ~store ~request ~original:current)
      | Some fence ->
        let* ()=unavailable (State.confirm_binding ~request ~original:current fence) in
        let* ()=require (fence.expected.owner_record_sha256=expected.State.owner_record_sha256
          && fence.expected.cursors_sha256=expected.cursors_sha256
          && fence.actor=actor && fence.reason=reason) Observation_changed in
        (match fence.authority with
         | State.Excluded_cut actual -> require (actual=basis) Observation_changed
         | Worker_absent -> Error (Ineligible "Cut command cannot adopt an absence fence")) in
    with_observation ~kind:Cut_original ~check_fence ~store ~original ~request
      (fun current actual exclusion ->
        (* Memory may advance independently. Source progress, owner and this
           original's retained host evidence may not. *)
        let* ()=require (actual.State.owner_record_sha256=expected.State.owner_record_sha256
          && actual.cursors_sha256=expected.cursors_sha256) Observation_changed in
        let* exclusion=Option.to_result ~none:(Unavailable "Cut command has no actual claim") exclusion in
        let* observed=unavailable (State.observe_cut_basis ~store ~request ~exclusion) in
        let* ()=require (observed=basis) Observation_changed in
        let* fence=match previous with
          | Some fence -> Ok fence
          | None ->
            let* fence=unavailable (State.create_cut ~store ~request ~original:current ~expected:actual
              ~exclusion ~actor ~reason ~now) in
            let* published=unavailable (State.publish ~store fence) in
            (match published with
             | Store.History_fence_stored | History_fence_already_stored -> after_publish (); Ok fence
             | History_fence_owner_changed -> Error Observation_changed
             | History_fence_unconfirmed detail -> Error (Publication_uncertain detail)) in
        let grant={store;request;original=current;exclusion;fence} in
        let* _=confirm_cut_grant ~store:grant.store grant |> Result.map_error (fun detail -> Publication_uncertain detail) in
        Ok (use grant)) in
    Keeper_librarian_durable_edge.with_destination ~config
      ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun current ->
        if Lane_addon_captured_destination.same_semantic current (Request.destination request)
        then Ok (io run)
        else Error "Cut command no longer has its same semantic destination")
    |> unavailable |> Result.join
  with Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Publication_uncertain (Printexc.to_string exn))
let with_cut_fence_serialized ~config ~keeper_name ~request_id ~expected ~basis ~actor ~reason ~now ~use =
  with_cut_fence_serialized_with ~after_publish:(fun () -> ())
    ~config ~keeper_name ~request_id ~expected ~basis ~actor ~reason ~now ~use
module For_testing = struct
  let with_cut_fence_serialized = with_cut_fence_serialized_with
end
