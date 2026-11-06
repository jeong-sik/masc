open Result.Syntax

include Keeper_skill_activation_types
include Keeper_skill_activation_ledger_errors
include Keeper_skill_activation_ledger_model
include Keeper_skill_activation_ledger_encode
include Keeper_skill_activation_ledger_decode_parts
include Keeper_skill_activation_ledger_decode_activation
include Keeper_skill_activation_ledger_decode_ledger
include Keeper_skill_activation_ledger_events
include Keeper_skill_activation_ledger_replay

(* ── This process's view of each session store ──────────────────── *)

type session_log =
  { ledger : t
  ; cursor : Fs_compat.Private_jsonl_cursor.t
  ; header_written : bool
  }

module Session_logs = Map.Make (String)

(* Keyed by the canonical store path. A store is read and written only under
   its session lock, so one entry never has two writers; the compare-and-set
   loop keeps two sessions' updates from dropping each other. *)
let session_logs : session_log Session_logs.t Atomic.t = Atomic.make Session_logs.empty

let rec update_session_logs change =
  let current = Atomic.get session_logs in
  if not (Atomic.compare_and_set session_logs current (change current))
  then update_session_logs change
;;

let remember_session_log path log = update_session_logs (Session_logs.add path log)
let forget_session_log path = update_session_logs (Session_logs.remove path)
let remembered_session_log path = Session_logs.find_opt path (Atomic.get session_logs)

let observe_settlement_warning ~path error =
  Log.Keeper.error
    "skill_activation_ledger: descriptor settlement incomplete store=%s detail=%s"
    path
    (Fs_compat.private_jsonl_transaction_error_to_string error)
;;

let snapshot_result ~path result =
  match Fs_compat.private_jsonl_snapshot_success_receipt result with
  | Error error -> Error error
  | Ok { Fs_compat.value; settlement_error } ->
    Option.iter (observe_settlement_warning ~path) settlement_error;
    Ok value
;;

let cursor_result ~path result =
  match Fs_compat.private_jsonl_cursor_success_receipt result with
  | Error error -> Error error
  | Ok { Fs_compat.value; settlement_error } ->
    Option.iter (observe_settlement_warning ~path) settlement_error;
    Ok value
;;

(* Replay a store from its first byte: on the first read of it in this
   process, and whenever this process no longer knows where the store ends.
   A row a crash left half-appended is cut back to the last complete row
   before anything is replayed. The session lock is held, and every writer
   appends under it, so such a tail was left by a writer that died, never by
   one still writing. A store whose very first row is unterminated is refused
   and left as it is. *)
let replay_session_log ~ownership_root ~expected_trace_id path =
  let* snapshot =
    match
      snapshot_result
        ~path
        (Fs_compat.read_private_jsonl_durable_locked_result path ~after:None)
    with
    | Ok snapshot -> Ok snapshot
    | Error (Fs_compat.Incomplete_transaction_tail _) ->
      (match Fs_compat.load_owned_regular_file ~ownership_root path with
       | Error error -> Error (Read_failed error)
       | Ok (Some contents) when not (starts_with_complete_row contents) ->
         Error (Decode_failed Unterminated_header_row)
       | Ok (Some _ | None) ->
         snapshot_result ~path (Fs_compat.recover_private_jsonl_durable_locked_result path)
         |> Result.map_error (fun error -> Event_log_failed error))
    | Error
        (( Fs_compat.Stable_lock_contended _
         | Fs_compat.Unexpected_stable_lock_permissions _
         | Fs_compat.Invalid_stable_lock_state _
         | Fs_compat.Cursor_mismatch _
         | Fs_compat.Unexpected_transaction_file_kind _
         | Fs_compat.Ambiguous_transaction_file_identity _
         | Fs_compat.Transaction_path_binding_changed _
         | Fs_compat.Transaction_content_changed _
         | Fs_compat.Invalid_transaction_suffix
         | Fs_compat.Private_jsonl_operation_failed _
         | Fs_compat.Rewrite_stage_failed _
         | Fs_compat.Rewrite_published_durability_unknown _
         | Fs_compat.Transaction_settlement_failed _
         | Fs_compat.Transaction_append_failed _ ) as error) ->
      Error (Event_log_failed error)
  in
  let* ledger, header_written =
    replay_store
      ~workspace_root:ownership_root
      ~expected_trace_id
      snapshot.Fs_compat.bytes
    |> Result.map_error (fun error -> Decode_failed error)
  in
  let log = { ledger; cursor = snapshot.Fs_compat.cursor; header_written } in
  remember_session_log path log;
  Ok log
;;

(* Under the session lock. A remembered store is read only after its cursor.
   A failure there drops what this process remembers of the store, and one
   replaced, truncated or left with a torn tail behind that cursor is
   replayed from its first byte at once. *)
let read_locked ~ownership_root ~expected_trace_id session_dir =
  let path = events_path session_dir in
  match remembered_session_log path with
  | None -> replay_session_log ~ownership_root ~expected_trace_id path
  | Some log ->
    (match
       snapshot_result
         ~path
         (Fs_compat.read_private_jsonl_durable_locked_result
            path
            ~after:(Some log.cursor))
     with
     | Error (Fs_compat.Cursor_mismatch _ | Fs_compat.Incomplete_transaction_tail _) ->
       forget_session_log path;
       replay_session_log ~ownership_root ~expected_trace_id path
     | Error
         (( Fs_compat.Stable_lock_contended _
          | Fs_compat.Unexpected_stable_lock_permissions _
          | Fs_compat.Invalid_stable_lock_state _
          | Fs_compat.Unexpected_transaction_file_kind _
          | Fs_compat.Ambiguous_transaction_file_identity _
          | Fs_compat.Transaction_path_binding_changed _
          | Fs_compat.Transaction_content_changed _
          | Fs_compat.Invalid_transaction_suffix
          | Fs_compat.Private_jsonl_operation_failed _
          | Fs_compat.Rewrite_stage_failed _
          | Fs_compat.Rewrite_published_durability_unknown _
          | Fs_compat.Transaction_settlement_failed _
          | Fs_compat.Transaction_append_failed _ ) as error) ->
       forget_session_log path;
       Error (Event_log_failed error)
     | Ok (snapshot : Fs_compat.private_jsonl_snapshot) ->
       if String.equal snapshot.bytes ""
       then Ok log
       else (
         match
           let* rows = complete_rows snapshot.bytes in
           apply_event_rows ~expected_trace_id log.ledger rows
         with
         | Error error ->
           forget_session_log path;
           Error (Decode_failed error)
         | Ok ledger ->
           let log = { log with ledger; cursor = snapshot.cursor } in
           remember_session_log path log;
           Ok log))
;;

let with_lock ~config ~trace_id operation =
  let session_dir =
    Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace_id)
  in
  match
    Keeper_checkpoint_store.with_session_lock ~session_dir (fun canonical_session_dir ->
      let ownership_root = Filename.dirname canonical_session_dir in
      operation ~ownership_root canonical_session_dir)
  with
  | Error detail -> Error (Lock_failed detail)
  | Ok result -> result
;;

let load ~config ~trace_id =
  with_lock ~config ~trace_id (fun ~ownership_root session_dir ->
    read_locked ~ownership_root ~expected_trace_id:trace_id session_dir
    |> Result.map (fun log -> log.ledger))
;;

(* Without a lock: the store is only ever appended to, so what is on disk is
   a run of committed rows, possibly followed by the row a writer is
   appending right now, which [complete_rows] leaves out. *)
let replay_unlocked ~ownership_root ~trace_id path =
  match Fs_compat.load_owned_regular_file ~ownership_root path with
  | Error error -> Error (Read_failed error)
  | Ok None -> Ok None
  | Ok (Some contents) ->
    (match
       replay_store ~workspace_root:ownership_root ~expected_trace_id:trace_id contents
     with
     | Error error -> Error (Decode_failed error)
     | Ok (_, false) -> Ok None
     | Ok (ledger, true) -> Ok (Some ledger))
;;

let load_existing_read_only_from_root ~ownership_root ~trace_id =
  let session_dir =
    Filename.concat ownership_root (Keeper_id.Trace_id.to_string trace_id)
  in
  replay_unlocked ~ownership_root ~trace_id (events_path session_dir)
;;

(* The header binds the workspace key of the canonical root the writer
   resolves under its lock, so an unlocked reader resolves the same root. *)
let load_existing ~config ~trace_id =
  let session_root =
    Filename.dirname
      (Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace_id))
  in
  match Unix.realpath session_root with
  | exception Unix.Unix_error (cause, _, _) ->
    Error (Canonical_root_failed { path = session_root; cause })
  | ownership_root -> load_existing_read_only_from_root ~ownership_root ~trace_id
;;

(* A write transaction. Every append goes through [commit_event_locked], which
   takes the writer of its transaction and marks it, so a write that may have
   changed the store is announced once its session lock is released
   (RFC-0483 §4.2). A write that only re-observes what is stored appends
   nothing and announces nothing. *)
type writer = { mutable appended : bool }

let no_commit_observer ~config:_ ~trace_id:_ = ()

let commit_observer : (config:Workspace.config -> trace_id:Keeper_id.Trace_id.t -> unit) Atomic.t =
  Atomic.make no_commit_observer

let install_commit_observer observer = Atomic.set commit_observer observer

let withdraw_commit_observer observer =
  ignore (Atomic.compare_and_set commit_observer observer no_commit_observer : bool)

let with_write_lock ~config ~trace_id operation =
  let writer = { appended = false } in
  (* The observer only records the trace, so it runs on a raise too: a row
     appended before the raise is on disk all the same. *)
  let announce () = if writer.appended then (Atomic.get commit_observer) ~config ~trace_id in
  match with_lock ~config ~trace_id (operation writer) with
  | result ->
    announce ();
    result
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    announce ();
    Printexc.raise_with_backtrace exn backtrace
;;

(* Append [event] after the rows [log] was read to and keep the ledger it
   makes. The row is decoded before it is written, and the decoded event is
   the one applied: a replay reads every row this appends, so a row it could
   not read is never written, and what this process holds is what a replay
   builds. The header goes first when the store has none. A failed append
   leaves the store's end unknown to this process, so the next read replays
   it from the first byte. *)
let commit_event_locked (writer : writer) session_dir (log : session_log) event =
  let row = event_to_yojson event in
  let* ledger =
    (let* decoded = decode_event ~expected_trace_id:log.ledger.session_id row in
     let builder = builder_of_ledger log.ledger in
     let* () = apply_event builder decoded in
     Ok (ledger_of_builder builder))
    |> Result.map_error (fun error -> Decode_failed error)
  in
  let path = events_path session_dir in
  let header =
    if log.header_written
    then ""
    else
      event_row
        (header_to_yojson ~workspace_key:ledger.workspace_key ~session_id:ledger.session_id)
  in
  match
    cursor_result
      ~path
      (Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
         path
         ~expected:log.cursor
         (header ^ event_row row))
  with
  | Error error ->
    (* The row may be on disk; a reader told to read again loses one read. *)
    forget_session_log path;
    writer.appended <- true;
    Error (Event_log_failed error)
  | Ok cursor ->
    remember_session_log path { ledger; cursor; header_written = true };
    writer.appended <- true;
    Ok ledger
;;

type activation_clock = Exact_activation_clock | Original_activation_clock

let record_with_clock ~activation_clock ~config ~trace_id (activation : activation) =
  with_write_lock ~config ~trace_id (fun writer ~ownership_root session_dir ->
    let* () =
      if
        String.equal
          (Ids.Turn_ref.trace_id activation.turn_ref)
          (Keeper_id.Trace_id.to_string trace_id)
      then Ok ()
      else Error (Decode_failed Turn_ref_session_mismatch)
    in
    let* log = read_locked ~ownership_root ~expected_trace_id:trace_id session_dir in
    let current = log.ledger in
    match List.find_opt (exact_key_equal activation) current.activations with
    | Some existing ->
      let expected = match activation_clock,activation.invocation with
        | Original_activation_clock,Nested_composition_invocation _ ->
          {activation with activated_at=existing.activated_at}
        | Exact_activation_clock,_
        | Original_activation_clock,(Instruction_invocation _ | Composition_invocation _) -> activation in
      if Yojson.Safe.equal (activation_to_yojson (recorded_part existing))
          (activation_to_yojson (recorded_part expected))
      then Ok (current, Already_recorded existing)
      else Error (Invocation_id_collision activation.skill_tool_use_id)
    | None ->
      let* stored =
        commit_event_locked writer session_dir log (Activation_recorded activation)
      in
      Ok (stored, Recorded activation))
;;

let record ~config ~trace_id activation =
  record_with_clock ~activation_clock:Exact_activation_clock ~config ~trace_id activation
;;

let record_original_invocation ~config ~trace_id activation =
  record_with_clock ~activation_clock:Original_activation_clock ~config ~trace_id activation
;;

(* The rejection is evidence in its own right: it is recorded, and the
   observation that produced it still fails. *)
let reject_transition_locked writer session_dir log rejection error =
  let* _stored = commit_event_locked writer session_dir log (Transition_rejected rejection) in
  Error error
;;

let observe_delivery
      ~config
      ~trace_id
      ~turn_ref
      ~tool_results
      ~boundary
      ~runtime_id
      ~delivered_at
  =
  let agent_core_turn = delivery_boundary_turn boundary in
  let receipt_valid (receipt : tool_result_receipt) =
    if String.equal (String.trim receipt.tool_use_id) ""
    then Error (Decode_failed Invalid_skill_tool_use_id)
    else if receipt.content_bytes < 0
    then Error (Decode_failed (Invalid_served_content_bytes receipt.content_bytes))
    else
      Skill_reference.validate_revision_string receipt.content_sha256
      |> Result.map_error (fun error ->
           Decode_failed (Invalid_served_content_sha256 error))
  in
  let* () =
    if String.equal (String.trim runtime_id) ""
    then Error (Decode_failed Invalid_runtime_id)
    else Ok ()
  in
  let* () =
    List.fold_left
      (fun result receipt ->
         let* () = result in
         receipt_valid receipt)
      (Ok ())
      tool_results
  in
  with_write_lock ~config ~trace_id (fun writer ~ownership_root session_dir ->
    let* () =
      Time_codec.parse_rfc3339 delivered_at
      |> Result.map ignore
      |> Result.map_error (fun _ -> Invalid_delivery_time delivered_at)
      |> Result.map_error (fun error -> Decode_failed error)
    in
    let* log =
      read_locked ~ownership_root ~expected_trace_id:trace_id session_dir
    in
    let current = log.ledger in
    let matching_receipt (activation : activation) =
      if not (Ids.Turn_ref.equal activation.turn_ref turn_ref)
      then None
      else
        let result_tool_use_id = match activation.invocation with
          | Instruction_invocation _ | Composition_invocation _ -> activation.skill_tool_use_id
          | Nested_composition_invocation { scope; _ } -> scope.parent_tool_use_id in
        match
          List.find_opt
            (fun (receipt : tool_result_receipt) ->
               String.equal receipt.tool_use_id result_tool_use_id)
            tool_results
        with
        | None -> None
        | Some receipt ->
          (match activation.invocation with
           | Composition_invocation _ | Nested_composition_invocation _ -> Some receipt
           | Instruction_invocation { served_content; _ } ->
             let expected_bytes, expected_sha256 =
               match served_content with
               | Skill_body { bytes; sha256 }
               | Skill_resource { bytes; sha256; _ } -> bytes, sha256
             in
             if
               expected_bytes = receipt.content_bytes
               && String.equal expected_sha256 receipt.content_sha256
             then Some receipt
             else None)
    in
    let rejected =
      List.find_map
        (fun activation ->
           match matching_receipt activation with
           | None -> None
           | Some receipt ->
             if
             (match boundary with
              | Model_response _ -> agent_core_turn <= activation.agent_core_turn
              | Official_client_result_handoff _ ->
                agent_core_turn < activation.agent_core_turn)
             then
               Some
                 ( Delivery_order_rejected
                     { skill_tool_use_id = activation.skill_tool_use_id
                     ; activation_turn_ref = activation.turn_ref
                     ; observed_turn_ref = turn_ref
                     ; activation_agent_core_turn = activation.agent_core_turn
                     ; observed_agent_core_turn = agent_core_turn
                     ; observed_at = delivered_at
                     }
                 , Invalid_delivery_order
                     { skill_tool_use_id = activation.skill_tool_use_id
                     ; activation_turn = activation.agent_core_turn
                     ; delivery_turn = agent_core_turn
                     } )
             else
               match activation.delivery with
               | Some delivery
                 when not (delivery.boundary = boundary)
                      || not (String.equal delivery.runtime_id runtime_id)
                      || delivery.content_bytes <> receipt.content_bytes
                      || not
                           (String.equal
                              delivery.content_sha256
                              receipt.content_sha256) ->
                 Some
                   ( Delivery_conflict_rejected
                       { skill_tool_use_id = activation.skill_tool_use_id
                       ; activation_turn_ref = activation.turn_ref
                       ; observed_turn_ref = turn_ref
                       ; observed_agent_core_turn = agent_core_turn
                       ; observed_at = delivered_at
                       }
                   , Conflicting_delivery activation.skill_tool_use_id )
               | None | Some _ -> None)
        current.activations
    in
    match rejected with
    | Some (rejection, error) ->
      reject_transition_locked writer session_dir log rejection error
    | None ->
      (* The activations this request's results belong to, including ones
         already marked; the event carries only the deliveries not yet on
         the ledger. *)
      let matched, deliveries =
        List.fold_left
          (fun (matched, deliveries) activation ->
             match matching_receipt activation with
             | None -> matched, deliveries
             | Some receipt ->
               let matched = activation.skill_tool_use_id :: matched in
               (match activation.delivery with
                | Some _ -> matched, deliveries
                | None ->
                  ( matched
                  , ( activation.skill_tool_use_id
                    , { boundary
                      ; runtime_id
                      ; delivered_at
                      ; content_bytes = receipt.content_bytes
                      ; content_sha256 = receipt.content_sha256
                      } )
                    :: deliveries )))
          ([], [])
          current.activations
      in
      let matched = List.rev matched in
      (match List.rev deliveries with
       | [] -> Ok (current, matched)
       | deliveries ->
         let* stored =
           commit_event_locked writer session_dir log (Deliveries_observed deliveries)
         in
         Ok (stored, matched)))
;;

let observe_async_result_delivery ~config ~trace_id ~expected_activations (delivery : Keeper_skill_async_delivery.t) =
  with_write_lock ~config ~trace_id (fun writer ~ownership_root session_dir ->
    let* log = read_locked ~ownership_root ~expected_trace_id:trace_id session_dir in
    let current = log.ledger in
    let* () = validate_async_result ~expected_trace_id:trace_id ~activations:current.activations delivery
      |> Result.map_error (fun error -> Decode_failed error) in
    let ids = List.sort String.compare (List.map (fun (activation : activation) -> activation.skill_tool_use_id) expected_activations) in
    let* () = if ids = List.map (fun (child : Keeper_skill_async_delivery.child_activation) -> child.skill_tool_use_id) delivery.child_activations then Ok ()
      else Error (Decode_failed (Invalid_async_result_evidence "sealed child selection differs")) in
    let* () = List.fold_left (fun result (expected : activation) ->
      let* () = result in
      match List.find_opt (fun (known : activation) -> String.equal expected.skill_tool_use_id known.skill_tool_use_id) current.activations with
      | Some known when recorded_part known = recorded_part expected -> Ok ()
      | Some _ | None -> Error (Invocation_id_collision expected.skill_tool_use_id)) (Ok ()) expected_activations in
    match List.find_opt (fun known -> String.equal (Keeper_skill_async_delivery.identity known)
        (Keeper_skill_async_delivery.identity delivery)) current.async_result_deliveries with
    | Some known -> Ok (current,known)
    | None -> commit_event_locked writer session_dir log (Async_result_delivered delivery)
      |> Result.map (fun ledger -> ledger,delivery))
;;

let observe_async_action ~config ~trace_id action =
  with_write_lock ~config ~trace_id (fun writer ~ownership_root session_dir ->
    let* log = read_locked ~ownership_root ~expected_trace_id:trace_id session_dir in
    let current = log.ledger in
    let* () = validate_async_action ~expected_trace_id:trace_id ~activations:current.activations
      ~async_result_deliveries:current.async_result_deliveries ~async_actions:current.async_actions action
      |> Result.map_error (fun error -> Decode_failed error) in
    match List.find_opt (fun known -> String.equal (Keeper_skill_async_action.identity known)
        (Keeper_skill_async_action.identity action)) current.async_actions with
    | Some known when Keeper_skill_async_action.same_fact known action -> Ok (current,known)
    | Some _ -> Error (Decode_failed (Invalid_async_action_evidence "causal occurrence result differs"))
    | None -> commit_event_locked writer session_dir log (Async_action_observed action)
      |> Result.map (fun ledger -> ledger,action))
;;

let observe_action
      ~config
      ~trace_id
      ~turn_ref
      ~active_skill_tool_use_ids
      ~action_identity
      ~tool_name
      ~runtime_id
      ~agent_core_turn
      ~observed_at
  =
  if not (action_identity_valid action_identity)
  then Error Invalid_action_identity
  else if not (Safe_identifier.is_portable_name tool_name)
  then Error (Invalid_action_tool_name tool_name)
  else if String.equal (String.trim runtime_id) ""
  then Error (Decode_failed Invalid_runtime_id)
  else if agent_core_turn < 0
  then Error (Invalid_action_turn agent_core_turn)
  else
    match Time_codec.parse_rfc3339 observed_at with
    | Error _ -> Error (Invalid_action_observed_at observed_at)
    | Ok _ ->
      with_write_lock ~config ~trace_id (fun writer ~ownership_root session_dir ->
        let* log =
          read_locked ~ownership_root ~expected_trace_id:trace_id session_dir
        in
        let current = log.ledger in
        let active = List.sort_uniq String.compare active_skill_tool_use_ids in
        let action =
          { identity = action_identity
          ; tool_name
          ; runtime_id
          ; agent_core_turn
          ; observed_at
          }
        in
        let rejected =
          List.find_map
            (fun activation ->
               if not (List.mem activation.skill_tool_use_id active)
               then None
               else
                 let before_delivery =
                   not (Ids.Turn_ref.equal activation.turn_ref turn_ref)
                   || Option.is_none activation.delivery
                   || Option.exists
                        (fun (delivery : delivery) ->
                           agent_core_turn
                           < delivery_boundary_turn delivery.boundary)
                        activation.delivery
                 in
                 if before_delivery
                 then
                   Some
                     ( Action_before_delivery_rejected
                         { skill_tool_use_id = activation.skill_tool_use_id
                         ; activation_turn_ref = activation.turn_ref
                         ; observed_turn_ref = turn_ref
                         ; action_identity
                         ; tool_name
                         ; observed_agent_core_turn = agent_core_turn
                         ; observed_at
                         }
                     , Action_before_delivery activation.skill_tool_use_id )
                 else None)
            current.activations
        in
        match rejected with
        | Some (rejection, error) ->
          reject_transition_locked writer session_dir log rejection error
        | None ->
          (* Every active Skill that has been delivered and has not seen
             this action yet; the same identity already recorded with other
             fields is a collision. *)
          let* targets =
            List.fold_left
              (fun result (activation : activation) ->
                 let* targets = result in
                 if not (List.mem activation.skill_tool_use_id active)
                 then Ok targets
                 else
                   match activation.delivery with
                   | None -> Ok targets
                   | Some _ ->
                     (match
                        List.find_opt
                          (fun (known : action) -> known.identity = action_identity)
                          activation.actions
                      with
                      | Some known
                        when String.equal known.tool_name action.tool_name
                             && String.equal known.runtime_id action.runtime_id
                             && known.agent_core_turn = action.agent_core_turn ->
                        Ok targets
                      | Some _ -> Error (Action_identity_collision action_identity)
                      | None -> Ok (activation.skill_tool_use_id :: targets)))
              (Ok [])
              current.activations
          in
          (match List.rev targets with
           | [] -> Ok (current, 0)
           | skill_tool_use_ids ->
             let* stored =
               commit_event_locked
                 writer
                 session_dir
                 log
                 (Action_observed { skill_tool_use_ids; action })
             in
             Ok (stored, List.length skill_tool_use_ids)))
;;
