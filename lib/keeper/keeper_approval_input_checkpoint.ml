let installed checkpoint = function
  | Keeper_checkpoint_store.Installed installed ->
    if List.exists (function
         | Keeper_checkpoint_store.Commit_durability_unknown _ -> true
         | Keeper_checkpoint_store.Commit_observer_failed _
         | Keeper_checkpoint_store.Release_process_lock_failed _
         | Keeper_checkpoint_store.Post_commit_unwind_interrupted _ -> false) installed.auxiliary
    then Error "approval input checkpoint durability could not be confirmed"
    else Ok checkpoint
  | Keeper_checkpoint_store.Not_installed _ ->
    Error "approval input checkpoint was not installed; canonical history remains authoritative"

let candidate ~co_inputs ~identity ~message (checkpoint : Agent_core.Checkpoint.t) =
  (* Close interruption evidence before appending a new User message, retaining
     provider request/result adjacency across crash recovery. *)
  match Keeper_transcript_unit.close_open_cycles checkpoint.messages with
  | Error error -> Error (Keeper_transcript_unit.show_structural_error error)
  | Ok closure ->
    let checkpoint = { checkpoint with messages = closure.messages } in
    List.fold_left
      (fun result (identity, message) ->
        Result.bind result (fun checkpoint ->
          match Keeper_approval_input_admission.prepare ~identity ~message checkpoint with
          | Ok (Admission_new checkpoint | Admission_resume checkpoint) -> Ok checkpoint
          | Error error -> Error (Keeper_approval_input_admission.error_to_string error)))
      (Ok checkpoint) ((identity, message) :: co_inputs)

let admit ?(co_inputs = []) ~session_dir ~identity ~message (fallback : Agent_core.Checkpoint.t) =
  match Keeper_checkpoint_store.load_agent_core_with_ref
          ~session_dir ~session_id:fallback.session_id with
  | Ok (current, reference) ->
    let current = { current with system_prompt = fallback.system_prompt } in
    (match candidate ~co_inputs ~identity ~message current with
     | Error _ as error -> error
     | Ok checkpoint ->
       Keeper_checkpoint_store.save_agent_core_if_source
         ~session_dir ~expected_source_ref:reference checkpoint
       |> installed checkpoint)
  | Error Keeper_checkpoint_store.Ref_not_found ->
    (match candidate ~co_inputs ~identity ~message fallback with
     | Error _ as error -> error
     | Ok checkpoint ->
       Keeper_checkpoint_store.save_agent_core_if_absent ~session_dir checkpoint
       |> installed checkpoint)
  | Error (Keeper_checkpoint_store.Ref_read_failed _)
  | Error (Keeper_checkpoint_store.Ref_identity_invalid _)
  | Error (Keeper_checkpoint_store.Ref_session_mismatch _)
  | Error (Keeper_checkpoint_store.Ref_lock_failed _) -> Error "approval input could not read authoritative checkpoint identity"


let admit_to_destination ?(co_inputs=[]) ~destination ~session_dir ~identity ~message fallback =
  match Keeper_checkpoint_destination.destination destination with
  | Keeper_owner.Global_input -> admit ~co_inputs ~session_dir ~identity ~message fallback
  | Operation_input _ ->
    let ( let* )=Result.bind in
    let* current=Keeper_checkpoint_destination.current_checkpoint destination in
    let* current=match current with
      | Some current -> Ok {current with Agent_core.Checkpoint.system_prompt=fallback.Agent_core.Checkpoint.system_prompt}
      | None -> Error "operation approval input lost its retained branch source" in
    let* checkpoint=candidate ~co_inputs ~identity ~message current in
    let* saved=Keeper_checkpoint_destination.save destination checkpoint in
    match saved with
    | Keeper_checkpoint_store.Saved {checkpoint;_} -> Ok checkpoint
    | Stale_noop _ -> Error "operation approval input was not confirmed on its original branch"
