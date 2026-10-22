module Checkpoint = Keeper_checkpoint_store
let ( let* ) = Result.bind
type creation =
  { keeper_name : string; trace_id : Keeper_id.Trace_id.t; keeper_uid : Keeper_id.Uid.t }
type session =
  { creation : creation; base_path : string
  ; intake_token : Keeper_shutdown_intake_fence.intake_token
  ; session_root : string }
type seed = {session : session; snapshot : Checkpoint.exact_checkpoint_snapshot}
type error =
  | Intake_expired
  | Identity_mismatch
  | Session_already_present
  | Initial_save_superseded
  | Snapshot_failed of Checkpoint.checkpoint_ref_load_error
  | Retention_unconfirmed of Checkpoint.checkpoint_installation
  | Initial_source_changed
  | Directory_failed of string

let error_to_string = function
  | Intake_expired -> "initial input creation intake is no longer live"
  | Identity_mismatch -> "initial input creation identity does not match this Keeper incarnation"
  | Session_already_present -> "generated trace directory already exists; no creation authority was granted"
  | Initial_save_superseded -> "initial input checkpoint was not installed"
  | Snapshot_failed error -> Checkpoint.checkpoint_ref_load_error_to_string error
  | Retention_unconfirmed _ -> "initial input retention was not durably confirmed; preserve its evidence"
  | Initial_source_changed -> "initial input checkpoint changed before Keeper creation"
  | Directory_failed detail -> detail

let generate ~keeper_name () =
  let* trace_id = Keeper_id.Trace_id.of_string (Keeper_identity.generate_trace_id ()) in
  Ok {keeper_name;trace_id;keeper_uid=Keeper_id.Uid.generate ()}
let trace_id (creation : creation) = creation.trace_id
let keeper_uid (creation : creation) = creation.keeper_uid
let live ~base_path ~intake_token (creation : creation) =
  Keeper_shutdown_intake_fence.intake_token_matches intake_token ~base_path ~keeper_name:creation.keeper_name
let retain ~session_dir snapshot =
  let outcome = Checkpoint.retain_exact_snapshot ~session_dir snapshot in
  let auxiliary = match outcome with
    | Checkpoint.Installed installed -> installed.auxiliary
    | Not_installed refused -> refused.auxiliary in
  List.iter (function
    | Checkpoint.Commit_observer_failed ((Eio.Cancel.Cancelled _ as cause),backtrace)
    | Post_commit_unwind_interrupted ((Eio.Cancel.Cancelled _ as cause),backtrace) ->
      Printexc.raise_with_backtrace cause backtrace
    | Commit_observer_failed _ | Post_commit_unwind_interrupted _
    | Commit_durability_unknown _ | Release_process_lock_failed _ -> ()) auxiliary;
  match outcome with
  | Checkpoint.Installed {auxiliary=[];_} -> Ok ()
  | (Installed _ | Not_installed _) as outcome -> Error (Retention_unconfirmed outcome)
let session_directory session_root creation =
  Filename.concat session_root (Keeper_id.Trace_id.to_string creation.trace_id)
let reserve_session ~base_path ~intake_token creation =
  if not (live ~base_path ~intake_token creation) then Error Intake_expired else
  let session_root = Keeper_fs.session_store_path_for_runtime_root
    (Filename.concat base_path Common.masc_dirname) in
  let session_dir = session_directory session_root creation in
  let* () = Eio_unix.run_in_systhread (fun () ->
    try Fs_compat.mkdir_p session_root; Unix.mkdir session_dir 0o700; Ok () with
    | Unix.Unix_error (Unix.EEXIST,_,_) -> Error Session_already_present
    | Unix.Unix_error (cause,operation,path) ->
      Error (Directory_failed (Printf.sprintf "%s %s: %s" operation path (Unix.error_message cause)))
    | Sys_error detail -> Error (Directory_failed detail)) in
  Ok {creation;base_path;intake_token;session_root}
let session_root (session : session) = session.session_root
let retain_initial (session : session) ~checkpoint ~outcome =
  let {creation;base_path;intake_token;session_root} = session in
  if not (live ~base_path ~intake_token creation) then Error Intake_expired else
  let session_dir = session_directory session_root creation in
  let* () = match outcome with
    | Checkpoint.Saved _ -> Ok ()
    | Stale_noop _ -> Error Initial_save_superseded in
  let* snapshot = Checkpoint.load_agent_core_exact_snapshot ~session_dir
    ~session_id:(Keeper_id.Trace_id.to_string creation.trace_id)
    |> Result.map_error (fun cause -> Snapshot_failed cause) in
  let* expected = Checkpoint.exact_snapshot_of_value ~expected_session_id:creation.trace_id checkpoint
    |> Result.map_error (fun cause -> Snapshot_failed cause) in
  let* () = if Checkpoint.exact_snapshot_canonical_bytes snapshot
      = Checkpoint.exact_snapshot_canonical_bytes expected then Ok () else Error Initial_source_changed in
  let* () = retain ~session_dir snapshot in
  if not (live ~base_path ~intake_token creation) then Error Intake_expired else
  Ok {session;snapshot}

let validate ~session_root ~keeper_name ~(meta : Keeper_meta_contract.keeper_meta) seed =
  let source = seed.session in
  let creation = source.creation in
  if not (live ~base_path:source.base_path ~intake_token:source.intake_token creation)
  then Error Intake_expired else
  if keeper_name<>creation.keeper_name || meta.name<>creation.keeper_name
      || not (Keeper_id.Trace_id.equal meta.runtime.trace_id creation.trace_id)
      || not (Option.equal Keeper_id.Uid.equal meta.keeper_id (Some creation.keeper_uid))
      || session_root<>source.session_root then Error Identity_mismatch else
  let session_dir = session_directory session_root creation in
  let reference = Checkpoint.exact_snapshot_reference seed.snapshot in
  let* current = Checkpoint.load_agent_core_exact_snapshot ~session_dir
    ~session_id:(Keeper_id.Trace_id.to_string creation.trace_id)
    |> Result.map_error (fun cause -> Snapshot_failed cause) in
  let* retained = Checkpoint.load_retained_exact_snapshot ~session_dir ~reference
    |> Result.map_error (fun cause -> match cause with
      | Checkpoint.Source_unavailable cause -> Snapshot_failed cause
      | Source_changed _ | Candidate_identity_invalid _ | Candidate_session_mismatch _
      | Candidate_turn_regressed _ | Commit_not_installed _ -> Initial_source_changed) in
  let same snapshot = Checkpoint.exact_snapshot_canonical_bytes snapshot
    = Checkpoint.exact_snapshot_canonical_bytes seed.snapshot in
  if not (live ~base_path:source.base_path ~intake_token:source.intake_token creation)
  then Error Intake_expired
  else if same current && same retained then Ok reference else Error Initial_source_changed
