let installed checkpoint = function
  | Keeper_checkpoint_store.Installed installed ->
    if List.exists (function
         | Keeper_checkpoint_store.Commit_durability_unknown _ -> true
         | _ -> false) installed.auxiliary
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
  | Error _ -> Error "approval input could not read authoritative checkpoint identity"
