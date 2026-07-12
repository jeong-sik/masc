open Alcotest

module Identity = Masc.Keeper_chat_delivery_identity
module Journal = Masc.Keeper_chat_delivery_journal
module Keeper_chat_store = Masc.Keeper_chat_store
module Keeper_chat_queue = Masc.Keeper_chat_queue
module Surface_ref = Masc.Surface_ref

let expect_ok = function
  | Ok value -> value
  | Error error -> fail (Journal.error_to_string error)
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir f =
  let path = Filename.temp_file "keeper-chat-delivery-journal" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let direct_key () =
  Identity.Request_id.of_string "kmsg-journal-test"
  |> Result.map (fun request_id -> Identity.Direct_request request_id)
  |> function
  | Ok key -> key
  | Error error -> fail error
;;

let payload () : Journal.accepted_payload =
  { keeper_name = "sangsu"
  ; submitted_by = "owner"
  ; user_content = "소스코드를 확인해"
  ; user_attachments = []
  ; surface = Surface_ref.Dashboard { session_id = Some "dashboard-session" }
  ; conversation_id = Some "conversation-1"
  ; external_message_id = None
  ; speaker =
      { speaker_id = Some "owner"
      ; speaker_name = Some "Owner"
      ; speaker_authority = Keeper_chat_store.Owner
      }
  ; user_row_origin = Journal.Needs_append
  }
;;

let terminal () : Journal.terminal_result =
  { ok = false
  ; poll_body = "keeper_msg request was cancelled by operator"
  ; delivery =
      Journal.Transport_failure
        { content = "Keeper request failed: request was cancelled by operator" }
  }
;;

let test_full_transition_and_reload () =
  with_temp_dir (fun base_path ->
    let key = direct_key () in
    let prepared =
      Journal.prepare
        ~base_path
        ~delivery_key:key
        ~payload:(payload ())
        ~now:1.0
      |> expect_ok
    in
    check int "prepared revision" 0 prepared.revision;
    let accepted =
      Journal.mark_accepted
        ~base_path
        ~expected_revision:prepared.revision
        ~identity:prepared
        ~user_row_id:(Some "msg-user")
        ~now:2.0
      |> expect_ok
    in
    let running =
      Journal.mark_running
        ~base_path
        ~expected_revision:accepted.revision
        ~identity:accepted
        ~now:3.0
      |> expect_ok
    in
    let pending =
      Journal.mark_terminal_pending
        ~base_path
        ~expected_revision:running.revision
        ~identity:running
        ~terminal:(terminal ())
        ~now:4.0
      |> expect_ok
    in
    let committed =
      Journal.mark_transcript_committed
        ~base_path
        ~expected_revision:pending.revision
        ~identity:pending
        ~transcript_row_id:"msg-terminal"
        ~now:5.0
      |> expect_ok
    in
    let final =
      Journal.mark_final
        ~base_path
        ~expected_revision:committed.revision
        ~identity:committed
        ~now:6.0
      |> expect_ok
    in
    check int "all five transitions increment revision" 5 final.revision;
    let reloaded =
      Journal.load ~base_path ~keeper_name:"sangsu" key |> expect_ok
    in
    match reloaded.phase with
    | Journal.Final { transcript_row_id; terminal = persisted } ->
      check string "terminal row identity" "msg-terminal" transcript_row_id;
      check bool "poll failure preserved" false persisted.ok;
      check string
        "poll body preserved"
        (terminal ()).poll_body
        persisted.poll_body
    | phase ->
      failf "expected final journal, got %s" (Journal.phase_to_string phase))
;;

let test_stale_revision_and_phase_fail_closed () =
  with_temp_dir (fun base_path ->
    let key = direct_key () in
    let prepared =
      Journal.prepare
        ~base_path
        ~delivery_key:key
        ~payload:(payload ())
        ~now:1.0
      |> expect_ok
    in
    let accepted =
      Journal.mark_accepted
        ~base_path
        ~expected_revision:0
        ~identity:prepared
        ~user_row_id:(Some "msg-user")
        ~now:2.0
      |> expect_ok
    in
    (match
       Journal.mark_running
         ~base_path
         ~expected_revision:0
         ~identity:accepted
         ~now:3.0
     with
     | Error (Journal.Revision_conflict { expected = 0; actual = 1 }) -> ()
     | Error error -> fail (Journal.error_to_string error)
     | Ok _ -> fail "stale writer advanced the journal");
    match
      Journal.mark_terminal_pending
        ~base_path
        ~expected_revision:accepted.revision
        ~identity:accepted
        ~terminal:(terminal ())
        ~now:3.0
    with
    | Error (Journal.Invalid_transition _) -> ()
    | Error error -> fail (Journal.error_to_string error)
    | Ok _ -> fail "terminal result skipped the Running phase")
;;

let test_corrupt_record_is_explicit () =
  with_temp_dir (fun base_path ->
    let key = direct_key () in
    let prepared =
      Journal.prepare
        ~base_path
        ~delivery_key:key
        ~payload:(payload ())
        ~now:1.0
      |> expect_ok
    in
    let record_path =
      Journal.For_testing.path
        ~base_path
        ~keeper_name:prepared.payload.keeper_name
        key
      |> expect_ok
    in
    Fs_compat.save_file record_path "not-json";
    match Journal.load ~base_path ~keeper_name:"sangsu" key with
    | Error (Journal.Decode_error _) -> ()
    | Error error -> fail (Journal.error_to_string error)
    | Ok _ -> fail "corrupt journal was treated as readable")
;;

let test_journal_rejects_unknown_and_duplicate_fields () =
  let base_json =
    let journal : Journal.t =
      { schema_version = 1
      ; revision = 0
      ; delivery_key = direct_key ()
      ; payload = payload ()
      ; phase = Journal.Prepared
      ; created_at = 1.0
      ; updated_at = 1.0
      }
    in
    Journal.For_testing.to_yojson journal
  in
  let expect_decode_error label json =
    match Journal.For_testing.of_yojson json with
    | Error (Journal.Decode_error _) -> ()
    | Error error -> fail (Journal.error_to_string error)
    | Ok _ -> failf "%s was accepted" label
  in
  (match base_json with
   | `Assoc fields ->
     expect_decode_error
       "unknown top-level field"
       (`Assoc (("legacy_status", `String "done") :: fields));
     expect_decode_error
       "duplicate revision"
       (`Assoc (("revision", `Int 7) :: fields))
   | _ -> fail "journal encoder did not produce an object")
;;

let row_id = function
  | Keeper_chat_store.Appended { row_id }
  | Keeper_chat_store.Already_present { row_id } -> row_id
;;

let expect_chat_ok = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let test_chat_append_once_converges () =
  with_temp_dir (fun base_path ->
    let delivery_key = direct_key () in
    let append_user () =
      Keeper_chat_store.append_user_message_once
        ~base_dir:base_path
        ~keeper_name:"sangsu"
        ~delivery_key
        ~content:"소스코드를 확인해"
        ~surface:(Surface_ref.Dashboard { session_id = Some "dashboard-session" })
        ~speaker:(payload ()).speaker
        ()
    in
    let first = append_user () |> expect_chat_ok in
    let second = append_user () |> expect_chat_ok in
    check string "user retry returns the same row" (row_id first) (row_id second);
    (match first, second with
     | Keeper_chat_store.Appended _, Keeper_chat_store.Already_present _ -> ()
     | _ -> fail "append-once did not expose append then convergence");
    let append_terminal () =
      Keeper_chat_store.append_assistant_message_once
        ~base_dir:base_path
        ~keeper_name:"sangsu"
        ~delivery_key
        ~content:"Keeper request failed: timeout"
        ~surface:(Surface_ref.Dashboard { session_id = Some "dashboard-session" })
        ~assistant_kind:Keeper_chat_store.Row_kind.Transport_failure
        ~stream_lifecycle:
          [ Keeper_chat_store.Run_started
          ; Keeper_chat_store.Text_message_start
          ; Keeper_chat_store.Text_message_end
          ; Keeper_chat_store.Run_error
          ]
        ()
    in
    let terminal_first = append_terminal () |> expect_chat_ok in
    let terminal_second = append_terminal () |> expect_chat_ok in
    check string
      "terminal retry returns the same row"
      (row_id terminal_first)
      (row_id terminal_second);
    let history = Keeper_chat_store.load ~base_dir:base_path ~keeper_name:"sangsu" in
    check int "one user and one terminal row" 2 (List.length history))
;;

let test_chat_append_once_converges_across_processes () =
  with_temp_dir (fun base_path ->
    let delivery_key = direct_key () in
    let seed =
      Keeper_chat_store.append_assistant_message_result
        ~base_dir:base_path
        ~keeper_name:"sangsu"
        ~content:"seed"
        ()
    in
    (match seed with
     | Ok () -> ()
     | Error detail -> fail detail);
    let ready_read, ready_write = Unix.pipe () in
    let append_child () =
      Unix.close ready_write;
      let byte = Bytes.create 1 in
      let rec await_start () =
        match Unix.read ready_read byte 0 1 with
        | 1 -> ()
        | 0 -> exit 2
        | _ -> await_start ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> await_start ()
      in
      await_start ();
      let result =
        Keeper_chat_store.append_user_message_once
          ~base_dir:base_path
          ~keeper_name:"sangsu"
          ~delivery_key
          ~content:"cross-process request"
          ~surface:
            (Surface_ref.Dashboard { session_id = Some "dashboard-session" })
          ~speaker:(payload ()).speaker
          ()
      in
      Unix.close ready_read;
      exit (if Result.is_ok result then 0 else 3)
    in
    let spawn () =
      match Unix.fork () with
      | 0 -> append_child ()
      | pid -> pid
    in
    let first = spawn () in
    let second = spawn () in
    Unix.close ready_read;
    let rec release_children offset =
      if offset = 2
      then ()
      else
        match Unix.write_substring ready_write "xy" offset (2 - offset) with
        | 0 -> fail "cross-process start barrier made no write progress"
        | written -> release_children (offset + written)
        | exception Unix.Unix_error (Unix.EINTR, _, _) ->
          release_children offset
    in
    release_children 0;
    Unix.close ready_write;
    let await_child pid =
      match Unix.waitpid [] pid with
      | _, Unix.WEXITED 0 -> ()
      | _, status ->
        failf
          "cross-process append child failed: %s"
          (match status with
           | Unix.WEXITED code -> Printf.sprintf "exit %d" code
           | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
           | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal)
    in
    await_child first;
    await_child second;
    let matching_rows =
      Keeper_chat_store.load ~base_dir:base_path ~keeper_name:"sangsu"
      |> List.filter (fun (row : Keeper_chat_store.chat_message) ->
           Keeper_chat_store.Role.equal row.role Keeper_chat_store.Role.User
           && String.equal row.content "cross-process request")
    in
    check int
      "cross-process retries persist one provenance row"
      1
      (List.length matching_rows))
;;

let test_restart_recovery_converges_without_duplicate_rows () =
  with_temp_dir (fun base_path ->
    let key = direct_key () in
    ignore
      (Journal.prepare
         ~base_path
         ~delivery_key:key
         ~payload:(payload ())
         ~now:1.0
       |> expect_ok
        : Journal.t);
    let first = Journal.recover_all ~base_path ~now:2.0 in
    check int "one interrupted request recovered" 1 first.recovered;
    check int "recovery has no failures" 0 (List.length first.failures);
    let recovered =
      Journal.load ~base_path ~keeper_name:"sangsu" key |> expect_ok
    in
    (match recovered.phase with
     | Journal.Final _ -> ()
     | phase ->
       failf "expected recovered final, got %s" (Journal.phase_to_string phase));
    let second = Journal.recover_all ~base_path ~now:3.0 in
    check int "final journal is not recovered twice" 0 second.recovered;
    check int "final journal is observed" 1 second.already_final;
    let history = Keeper_chat_store.load ~base_dir:base_path ~keeper_name:"sangsu" in
    check int "one accepted row and one failure row" 2 (List.length history))
;;

let test_checkpoint_commits_without_fake_assistant_row () =
  with_temp_dir (fun base_path ->
    let key = direct_key () in
    let prepared =
      Journal.prepare
        ~base_path
        ~delivery_key:key
        ~payload:(payload ())
        ~now:1.0
      |> expect_ok
    in
    let user_row =
      Keeper_chat_store.append_user_message_once
        ~base_dir:base_path
        ~keeper_name:"sangsu"
        ~delivery_key:key
        ~content:prepared.payload.user_content
        ~surface:prepared.payload.surface
        ~speaker:prepared.payload.speaker
        ()
      |> expect_chat_ok
    in
    let user_row_id = row_id user_row in
    let accepted =
      Journal.mark_accepted
        ~base_path
        ~expected_revision:prepared.revision
        ~identity:prepared
        ~user_row_id:(Some user_row_id)
        ~now:2.0
      |> expect_ok
    in
    let running =
      Journal.mark_running
        ~base_path
        ~expected_revision:accepted.revision
        ~identity:accepted
        ~now:3.0
      |> expect_ok
    in
    let pending =
      Journal.mark_terminal_pending
        ~base_path
        ~expected_revision:running.revision
        ~identity:running
        ~terminal:
          { ok = true
          ; poll_body = "checkpoint"
          ; delivery =
              Journal.No_assistant_reply
                { reason = Journal.Continuation_checkpoint }
          }
        ~now:4.0
      |> expect_ok
    in
    ignore (pending : Journal.t);
    let recovery = Journal.recover_all ~base_path ~now:5.0 in
    check int "pending checkpoint recovered" 1 recovery.recovered;
    let final = Journal.load ~base_path ~keeper_name:"sangsu" key |> expect_ok in
    (match final.phase with
     | Journal.Final { transcript_row_id; _ } ->
       check string "checkpoint commits accepted row" user_row_id transcript_row_id
     | phase ->
       failf "expected checkpoint final, got %s" (Journal.phase_to_string phase));
    let history = Keeper_chat_store.load ~base_dir:base_path ~keeper_name:"sangsu" in
    check int "checkpoint adds no fake assistant row" 1 (List.length history))
;;

let test_queue_restart_finalizes_receipt_without_redispatch () =
  Eio_main.run @@ fun _env ->
  with_temp_dir (fun base_path ->
    Keeper_chat_queue.For_testing.reset ();
    ignore
      (Keeper_chat_queue.configure_persistence ~base_path
        : Keeper_chat_queue.configure_report);
    let queued_message : Keeper_chat_queue.queued_message =
      { content = "queued source check"
      ; user_blocks = []
      ; attachments = []
      ; timestamp = 1.0
      ; source = Keeper_chat_queue.Dashboard
      }
    in
    let receipt =
      match Keeper_chat_queue.enqueue ~keeper_name:"sangsu" queued_message with
      | Ok receipt -> receipt
      | Error error -> fail (Keeper_chat_queue.mutation_error_to_string error)
    in
    let delivery_key =
      match Keeper_chat_queue.lease_batch ~keeper_name:"sangsu" with
      | `Leased { items; _ } ->
        let receipt_ids =
          List.map
            (fun (item : Keeper_chat_queue.leased_message) -> item.receipt_id)
            items
          |> Identity.Receipt_ids.of_list
          |> function
          | Ok receipt_ids -> receipt_ids
          | Error error -> fail (Identity.Receipt_ids.error_to_string error)
        in
        Identity.Queue_receipts receipt_ids
      | `Empty -> fail "queue was empty after enqueue"
      | `Already_leased lease_id -> failf "unexpected existing lease %s" lease_id
      | `Error error -> fail (Keeper_chat_queue.mutation_error_to_string error)
    in
    ignore
      (Journal.prepare
         ~base_path
         ~delivery_key
         ~payload:
           { (payload ()) with
             user_content = queued_message.content
           ; user_row_origin = Journal.Needs_append
           }
         ~now:2.0
       |> expect_ok
        : Journal.t);
    Keeper_chat_queue.For_testing.reset ();
    let recovery = Journal.recover_all ~base_path ~now:3.0 in
    check int "queue journal recovered" 1 recovery.recovered;
    let queue_recovery = Keeper_chat_queue.configure_persistence ~base_path in
    check int "one inflight receipt reconciled" 1 queue_recovery.recovered_receipt_count;
    (match
       Keeper_chat_queue.lookup_receipt
         ~keeper_name:"sangsu"
         ~receipt_id:receipt.receipt_id
     with
     | Ok
         { receipt =
             Some
               { state =
                   Keeper_chat_queue.Failed
                     { kind = Keeper_chat_queue.Recovery_interrupted; _ }
               ; _
               }
         ; _
         } -> ()
     | Ok _ -> fail "recovered receipt was not terminal Recovery_interrupted"
     | Error error -> fail (Keeper_chat_queue.mutation_error_to_string error));
    let history = Keeper_chat_store.load ~base_dir:base_path ~keeper_name:"sangsu" in
    check int "queue restart writes one user and one failure row" 2 (List.length history);
    Keeper_chat_queue.For_testing.reset ())
;;

let test_dashboard_queue_origin_uses_typed_handoff_journal () =
  with_temp_dir (fun base_path ->
    let receipt_id =
      Identity.Receipt_id.of_string
        "chatq_123e4567-e89b-12d3-a456-426614174000"
      |> function
      | Ok receipt_id -> receipt_id
      | Error detail -> fail detail
    in
    let unknown_receipt_id =
      Identity.Receipt_id.of_string
        "chatq_123e4567-e89b-12d3-a456-426614174001"
      |> function
      | Ok receipt_id -> receipt_id
      | Error detail -> fail detail
    in
    let key = direct_key () in
    let prepared =
      Journal.prepare
        ~base_path
        ~delivery_key:key
        ~payload:(payload ())
        ~now:1.0
      |> expect_ok
    in
    let user_row =
      Keeper_chat_store.append_user_message_once
        ~base_dir:base_path
        ~keeper_name:"sangsu"
        ~delivery_key:key
        ~content:prepared.payload.user_content
        ~surface:prepared.payload.surface
        ~speaker:prepared.payload.speaker
        ()
      |> expect_chat_ok
    in
    let user_row_id = row_id user_row in
    let accepted =
      Journal.mark_accepted
        ~base_path
        ~expected_revision:prepared.revision
        ~identity:prepared
        ~user_row_id:(Some user_row_id)
        ~now:2.0
      |> expect_ok
    in
    let running =
      Journal.mark_running
        ~base_path
        ~expected_revision:accepted.revision
        ~identity:accepted
        ~now:3.0
      |> expect_ok
    in
    let pending =
      Journal.mark_terminal_pending
        ~base_path
        ~expected_revision:running.revision
        ~identity:running
        ~terminal:
          { ok = true
          ; poll_body = "queued"
          ; delivery =
              Journal.No_assistant_reply
                { reason = Journal.Queued_for_later { receipt_id } }
          }
        ~now:4.0
      |> expect_ok
    in
    let committed =
      Journal.mark_transcript_committed
        ~base_path
        ~expected_revision:pending.revision
        ~identity:pending
        ~transcript_row_id:user_row_id
        ~now:5.0
      |> expect_ok
    in
    ignore
      (Journal.mark_final
         ~base_path
         ~expected_revision:committed.revision
         ~identity:committed
         ~now:6.0
       |> expect_ok
        : Journal.t);
    let origin receipt_ids =
      Identity.Receipt_ids.of_list receipt_ids
      |> function
      | Error error -> fail (Identity.Receipt_ids.error_to_string error)
      | Ok receipt_ids ->
        Journal.dashboard_queue_user_row_origin
          ~base_path
          ~keeper_name:"sangsu"
          receipt_ids
    in
    (match origin [ receipt_id ] with
     | Ok Journal.Already_persisted_upstream -> ()
     | Ok _ -> fail "journaled Dashboard receipt was treated as legacy"
     | Error error -> fail (Journal.error_to_string error));
    (match origin [ unknown_receipt_id ] with
     | Ok Journal.Needs_append -> ()
     | Ok _ -> fail "legacy Dashboard receipt did not request a user append"
     | Error error -> fail (Journal.error_to_string error));
    match origin [ receipt_id; unknown_receipt_id ] with
    | Error (Journal.Transcript_error _) -> ()
    | Error error -> fail (Journal.error_to_string error)
    | Ok _ -> fail "mixed Dashboard provenance was accepted")
;;

let () =
  run
    "keeper chat delivery journal"
    [ ( "journal"
      , [ test_case "full transition and reload" `Quick test_full_transition_and_reload
        ; test_case
            "stale writers and skipped phases fail closed"
            `Quick
            test_stale_revision_and_phase_fail_closed
        ; test_case
            "corrupt records are explicit"
            `Quick
            test_corrupt_record_is_explicit
        ; test_case
            "schema drift fails closed"
            `Quick
            test_journal_rejects_unknown_and_duplicate_fields
        ; test_case
            "chat append-once converges"
            `Quick
            test_chat_append_once_converges
        ; test_case
            "chat append-once converges across processes"
            `Quick
            test_chat_append_once_converges_across_processes
        ; test_case
            "restart recovery converges"
            `Quick
            test_restart_recovery_converges_without_duplicate_rows
        ; test_case
            "checkpoint has no fake reply"
            `Quick
            test_checkpoint_commits_without_fake_assistant_row
        ; test_case
            "queue restart finalizes without redispatch"
            `Quick
            test_queue_restart_finalizes_receipt_without_redispatch
        ; test_case
            "Dashboard queue origin is typed"
            `Quick
            test_dashboard_queue_origin_uses_typed_handoff_journal
        ] )
    ]
;;
