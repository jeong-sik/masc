module Store = Keeper_checkpoint_store
module Registry = Keeper_owner_registry
let ( let* ) = Result.bind

type t =
  { base_path : string; keeper_name : string; session_dir : string
  ; trace_id : Keeper_id.Trace_id.t; writer : Keeper_owner.input_checkpoint_writer }

type error =
  | Owner_failed of Registry.command_error
  | Source_missing
  | Source_changed
  | Source_read_failed of Store.checkpoint_cas_error
  | Snapshot_failed of Store.checkpoint_ref_load_error
  | Retention_unconfirmed of Store.checkpoint_installation

let destination t = Keeper_owner.input_checkpoint_destination t.writer

let error_to_string = function
  | Owner_failed error -> Registry.command_error_to_string error
  | Source_missing -> "observed input owner requires its admitted source checkpoint"
  | Source_changed -> "admitted pending input differs from the retained input owner"
  | Source_read_failed (Store.Source_unavailable error) -> Store.checkpoint_ref_load_error_to_string error
  | Source_read_failed (Store.Source_changed _) -> "retained input checkpoint identity changed"
  | Source_read_failed (Store.Candidate_identity_invalid _ | Store.Candidate_session_mismatch _
      | Store.Candidate_turn_regressed _ | Store.Commit_not_installed _) -> "retained input checkpoint is unavailable"
  | Snapshot_failed error -> Store.checkpoint_ref_load_error_to_string error
  | Retention_unconfirmed (Store.Installed _) -> "input checkpoint installed with unconfirmed auxiliary outcomes"
  | Retention_unconfirmed (Store.Not_installed _) -> "input checkpoint was not installed"

let same_pending left right = Option.equal
    (fun left right -> Yojson.Safe.equal
      (Agent_core.Agent_input_request.pending_to_json left)
      (Agent_core.Agent_input_request.pending_to_json right)) left right

let rec preserves_messages prefix messages = match prefix, messages with
  | [], _ -> true
  | expected::prefix, actual::messages -> expected = actual && preserves_messages prefix messages
  | _::_, [] -> false

let prepare ~base_path ~keeper_name ~session_dir ~trace_id ~source =
  let* writer = Registry.begin_input_checkpoint ~base_path ~keeper_name ~trace_id
    |> Result.map_error (fun error -> Owner_failed error) in
  let* () = match Keeper_owner.input_checkpoint_reference writer with
    | None -> Ok ()
    | Some reference ->
      let* snapshot = Store.load_retained_exact_snapshot ~session_dir ~reference
        |> Result.map_error (fun error -> Source_read_failed error) in
      match source with
      | None -> Error Source_missing
      | Some (source : Agent_core.Checkpoint.t) ->
        let observed = Store.exact_snapshot_checkpoint snapshot in
        if source.Agent_core.Checkpoint.session_id = Keeper_id.Trace_id.to_string trace_id
            && same_pending observed.pending_input source.pending_input
            && preserves_messages observed.messages source.messages then Ok ()
        else Error Source_changed in
  Ok {base_path;keeper_name;session_dir;trace_id;writer}

let retain t checkpoint =
  let* snapshot = Store.exact_snapshot_of_value ~expected_session_id:t.trace_id checkpoint
    |> Result.map_error (fun error -> Snapshot_failed error) in
  Store.retain_exact_snapshot ~session_dir:t.session_dir snapshot
  |> Store.require_confirmed_installation
  |> Result.map_error (fun outcome -> Retention_unconfirmed outcome)

let bind_retired_input_cut t ~cut ~seed ~operation_id ~execution_digest ~observed ~call =
  let* checkpoint=Keeper_input_history_cut.cut_checkpoint cut
    |> Result.map_error (fun _ -> Source_changed) in
  let* binding=Keeper_input_history_cut.bind_seed cut ~seed
    |> Result.map_error (fun _ -> Source_changed) in
  let* retained=retain t checkpoint in
  let* ()=if Keeper_checkpoint_ref.equal retained (Keeper_input_history_cut.checkpoint binding)
    then Ok () else Error Source_changed in
  let* writer=Registry.bind_retired_input_cut ~base_path:t.base_path ~keeper_name:t.keeper_name
    ~writer:t.writer ~operation_id ~execution_digest ~observed ~call ~cut:binding
    |> Result.map_error (fun error -> Owner_failed error) in
  Ok {t with writer}

let publish_autonomous t checkpoint =
  let* checkpoint = retain t checkpoint in
  let* writer = Registry.advance_autonomous_input_checkpoint ~base_path:t.base_path
    ~keeper_name:t.keeper_name ~writer:t.writer ~checkpoint
    |> Result.map_error (fun error -> Owner_failed error) in
  Ok {t with writer}

let publish_direct t ~operation_id ~execution_digest ~call_id ~observed checkpoint =
  let* checkpoint = retain t checkpoint in
  let* writer = Registry.advance_direct_input_checkpoint ~base_path:t.base_path
    ~keeper_name:t.keeper_name ~writer:t.writer ~operation_id ~execution_digest ~call_id ~observed ~checkpoint
    |> Result.map_error (fun error -> Owner_failed error) in
  Ok ({t with writer}, checkpoint)
