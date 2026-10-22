module Store = Keeper_checkpoint_store
module Registry = Keeper_owner_registry
let ( let* ) = Result.bind

type location = {keeper_name:string;session_dir:string}
type branch_state =
  | Confirmed of Store.exact_checkpoint_snapshot
  | Unconfirmed of {previous:Store.exact_checkpoint_snapshot;detail:string}
type branch =
  {base_path:string;operation_id:Keeper_chat_operation.Operation_id.t;
   trace_id:Keeper_id.Trace_id.t;writer:Keeper_owner.input_checkpoint_writer;
   mutable state:branch_state}
type t = Canonical of location | Operation of location * branch

let canonical ~keeper_name ~session_dir = Canonical {keeper_name;session_dir}
let destination = function
  | Canonical _ -> Keeper_owner.Global_input
  | Operation (_,branch) -> Keeper_owner.Operation_input branch.operation_id
let detached_checkpoint (checkpoint:Agent_core.Checkpoint.t) =
  {checkpoint with context=Agent_core.Context.copy checkpoint.context ~eio:true}
let current_checkpoint = function
  | Canonical _ -> Ok None
  | Operation (_, {state=Confirmed snapshot;_}) -> Ok (Some (detached_checkpoint (Store.exact_snapshot_checkpoint snapshot)))
  | Operation (_, {state=Unconfirmed {detail;_};_}) -> Error detail
let invalidate branch detail =
  let previous=match branch.state with Confirmed previous | Unconfirmed {previous;_} -> previous in
  branch.state<-Unconfirmed {previous;detail}; Error detail
let owner result = result |> Result.map_error Registry.command_error_to_string
let retained_error = function
  | Store.Source_unavailable error -> Store.checkpoint_ref_load_error_to_string error
  | Source_changed _ -> "operation branch retained source changed"
  | Candidate_identity_invalid error -> Store.checkpoint_identity_error_to_string error
  | Candidate_session_mismatch _ -> "operation branch retained trace changed"
  | Candidate_turn_regressed _ -> "operation branch retained turn regressed"
  | Commit_not_installed _ -> "operation branch retention is unconfirmed"
let validate_scope operation_id (checkpoint:Agent_core.Checkpoint.t) =
  let* frame=Keeper_repetition_context.load checkpoint.context
    |> Result.map_error Keeper_repetition_snapshot.error_to_string in
  match Keeper_repetition_snapshot.active frame with
  | Some scope when Keeper_execution_scope_id.equal scope (Keeper_execution_scope_id.direct_operation operation_id) -> Ok ()
  | Some _ | None -> Error "checkpoint lost its original operation branch scope"

let capture_direct ~base_path ~keeper_name ~session_dir ~trace_id ~operation_id =
  let* observed=Registry.direct_input_branch ~base_path ~keeper_name ~operation_id |> owner in
  match observed with
  | None -> Ok (canonical ~keeper_name ~session_dir)
  | Some observed ->
    let* writer=Registry.begin_input_checkpoint ~base_path ~keeper_name ~trace_id |> owner in
    let* reference=match Keeper_owner.input_checkpoint_destination writer,
        Keeper_owner.input_checkpoint_reference writer with
      | Keeper_owner.Operation_input actual,Some reference
          when Keeper_chat_operation.Operation_id.equal actual operation_id
            && Keeper_checkpoint_ref.equal observed.checkpoint reference
            && Keeper_id.Trace_id.equal reference.trace_id trace_id -> Ok reference
      | (Global_input | Operation_input _),(Some _ | None) ->
        Error "operation checkpoint destination changed before original child capture" in
    let* snapshot=Store.load_retained_exact_snapshot ~session_dir ~reference
      |> Result.map_error retained_error in
    let* ()=validate_scope operation_id (Store.exact_snapshot_checkpoint snapshot) in
    Ok (Operation ({keeper_name;session_dir},
      {base_path;operation_id;trace_id;writer;state=Confirmed snapshot}))

let snapshot branch checkpoint =
  (* Context is mutable and the native Agent continues to own its copy. Keep
     the private source associated with these frozen bytes independent of it. *)
  let checkpoint=detached_checkpoint checkpoint in
  let* snapshot=Store.exact_snapshot_of_value ~expected_session_id:branch.trace_id checkpoint
    |> Result.map_error Store.checkpoint_ref_load_error_to_string in
  let* ()=validate_scope branch.operation_id (Store.exact_snapshot_checkpoint snapshot) in
  Ok snapshot
let confirmed_retention location snapshot =
  Store.retain_exact_snapshot ~session_dir:location.session_dir snapshot
  |> Store.require_confirmed_installation
  |> Result.map_error (fun _ -> "operation branch retention is unconfirmed; reconcile before further publication")

(* Fence before any fallible copy, retention or Owner observation. In particular,
   cancellation can arrive after the durable write but before its acknowledgement.
   An exception propagates unchanged and leaves this dispatch unconfirmed. *)
let update_branch branch update =
  match branch.state with
  | Unconfirmed {detail;_} -> Error detail
  | Confirmed previous ->
    branch.state<-Unconfirmed {previous;
      detail="operation branch publication did not complete; reconcile original ownership before further use"};
    match update previous with
    | Ok (confirmed,value) -> branch.state<-Confirmed confirmed; Ok value
    | Error detail -> invalidate branch detail

let save_canonical location checkpoint =
  Store.save_agent_core_for_keeper ~keeper_name:location.keeper_name ~session_dir:location.session_dir
    ~history_retained:(Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained) checkpoint
let publish_host location branch previous candidate transformation =
  let* ()=Keeper_checkpoint_host_transform.validate transformation ~source:previous ~candidate in
  let* reference=confirmed_retention location candidate in
  let* ()=Registry.checkpoint_operation_input_branch ~base_path:branch.base_path
    ~keeper_name:location.keeper_name ~writer:branch.writer
    ~observed:(Store.exact_snapshot_reference previous) ~checkpoint:reference ~transformation |> owner in
  Ok (candidate,Store.Saved {relation=`Equal;turn_count=reference.turn_count;
    canonical_bytes=String.length (Store.exact_snapshot_canonical_bytes candidate);
    checkpoint=detached_checkpoint (Store.exact_snapshot_checkpoint candidate)})
let save destination checkpoint = match destination with
  | Canonical location -> save_canonical location checkpoint
  | Operation (location,branch) -> update_branch branch (fun previous ->
    let* candidate=snapshot branch checkpoint in
    let* transformation=Keeper_checkpoint_host_transform.preserve ~source:previous
      ~candidate:(Store.exact_snapshot_checkpoint candidate) in
    publish_host location branch previous candidate transformation)
let save_transformed destination ~transformation checkpoint = match destination with
  | Canonical location -> save_canonical location checkpoint
  | Operation (location,branch) -> update_branch branch (fun previous ->
    let* candidate=snapshot branch checkpoint in
    publish_host location branch previous candidate transformation)

let publish_native destination ~checkpoint publish = match destination with
  | Canonical _ -> let* _,value=publish () in Ok value
  | Operation (location,branch) -> update_branch branch (fun _previous ->
    let* candidate=snapshot branch checkpoint in
    let* reference,value=publish () in
    let* ()=if Keeper_checkpoint_ref.equal reference (Store.exact_snapshot_reference candidate)
      then Ok () else Error "native publication does not name its exact checkpoint payload" in
    let* actual=Registry.direct_input_branch ~base_path:branch.base_path ~keeper_name:location.keeper_name
      ~operation_id:branch.operation_id |> owner in
    let* native=Registry.direct_native_call ~base_path:branch.base_path ~keeper_name:location.keeper_name
      ~operation_id:branch.operation_id |> owner in
    let* ()=match actual,native with
      | Some actual,(Keeper_native_call.Active call | Terminal_unacknowledged (call,_))
          when Keeper_checkpoint_ref.equal actual.checkpoint reference
            && Keeper_checkpoint_ref.equal call.checkpoint reference -> Ok ()
      | (Some _ | None),(No_native_call | Active _ | Terminal_unacknowledged _) ->
        Error "native publication no longer owns its exact retained operation branch" in
    Ok (candidate,value))

let path destination checkpoint = match destination with
  | Canonical location -> Ok (Store.agent_core_checkpoint_path ~session_dir:location.session_dir
      ~session_id:checkpoint.Agent_core.Checkpoint.session_id)
  | Operation (location,branch) ->
    let* snapshot=snapshot branch checkpoint in
    Ok (Store.retained_checkpoint_path ~session_dir:location.session_dir (Store.exact_snapshot_reference snapshot))
