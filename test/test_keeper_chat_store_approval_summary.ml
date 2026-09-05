(* Pins the decision written on [Keeper_chat_store.approval_lifecycle_equal]:
   [call_summary] is a rendering of the approval's request input, not a fact
   about the approval, so it takes no part in deciding whether a second row
   for the same approval slot is the same row. Two rows that differ only in
   the summary are one row; the first one written is the one that stays. The
   durable fields keep their strictness, which the last case shows. *)

module K = Masc.Keeper_chat_store

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let with_base prefix f =
  let base_dir = temp_base_path prefix in
  Fun.protect ~finally:(fun () -> try remove_tree base_dir with _ -> ()) (fun () -> f base_dir)

let keeper_name = "keeper-chat-approval-summary"

let lifecycle_rows ~base_dir ~approval_id =
  K.load_all ~base_dir ~keeper_name
  |> List.filter_map (fun (message : K.chat_message) ->
    match message.approval_lifecycle with
    | Some lifecycle when String.equal lifecycle.approval_id approval_id ->
      Some (message.id, lifecycle)
    | Some _ | None -> None)

let appended_row_id label = function
  | Ok (K.Appended { row_id }) -> row_id
  | Ok (K.Already_present _) -> Alcotest.fail (label ^ ": first write was not appended")
  | Error detail -> Alcotest.fail (label ^ ": first write failed: " ^ detail)

let already_present_row_id label = function
  | Ok (K.Already_present { row_id }) -> row_id
  | Ok (K.Appended _) -> Alcotest.fail (label ^ ": second write appended a duplicate")
  | Error detail -> Alcotest.fail (label ^ ": second write was refused: " ^ detail)

let resolution ~approval_id ~call_summary : K.approval_lifecycle =
  { approval_id
  ; tool_name = Some "tool_execute"
  ; phase = K.Approval_resolved_approved
  ; artifact_ref = None
  ; call_summary
  }

(* The resolution slot already holds a row with one summary; a retry that
   renders the same request differently is the same row, and the store keeps
   the first rendering. *)
let test_resolution_with_a_different_summary_is_the_same_row () =
  with_base "keeper-chat-approval-summary-differs" (fun base_dir ->
    let approval_id = "appr_summary_differs" in
    let first = resolution ~approval_id ~call_summary:(Some "git log -- lib") in
    let first_row_id =
      appended_row_id
        "first resolution"
        (K.append_approval_lifecycle_once ~base_dir ~keeper_name ~lifecycle:first)
    in
    let second = { first with call_summary = Some "git log -- lib/keeper" } in
    let second_row_id =
      already_present_row_id
        "second resolution"
        (K.append_approval_lifecycle_once ~base_dir ~keeper_name ~lifecycle:second)
    in
    Alcotest.(check string) "the existing row is the one reported" first_row_id second_row_id;
    match lifecycle_rows ~base_dir ~approval_id with
    | [ (row_id, stored) ] ->
      Alcotest.(check string) "one row holds the slot" first_row_id row_id;
      Alcotest.(check (option string))
        "the first rendering stays"
        (Some "git log -- lib")
        stored.call_summary
    | rows ->
      Alcotest.failf "expected one lifecycle row, found %d" (List.length rows))

(* A writer without the request in hand (the rejection and unreadable-delivery
   paths) writes no summary. A later writer that has one does not backfill
   it: the slot is append-once and the summary is not what identifies it. *)
let test_summary_is_not_backfilled_into_a_summary_less_row () =
  with_base "keeper-chat-approval-summary-backfill" (fun base_dir ->
    let approval_id = "appr_summary_backfill" in
    let without = resolution ~approval_id ~call_summary:None in
    let first_row_id =
      appended_row_id
        "summary-less resolution"
        (K.append_approval_lifecycle_once ~base_dir ~keeper_name ~lifecycle:without)
    in
    let with_summary = { without with call_summary = Some "git status" } in
    let second_row_id =
      already_present_row_id
        "resolution carrying a summary"
        (K.append_approval_lifecycle_once ~base_dir ~keeper_name ~lifecycle:with_summary)
    in
    Alcotest.(check string) "the existing row is the one reported" first_row_id second_row_id;
    match lifecycle_rows ~base_dir ~approval_id with
    | [ (_, stored) ] ->
      Alcotest.(check (option string)) "the row stays summary-less" None stored.call_summary
    | rows ->
      Alcotest.failf "expected one lifecycle row, found %d" (List.length rows))

(* The replay path is where a false conflict would do the most harm: it
   would append a correction row that corrects nothing. A replay receipt
   re-emitted with a different summary is idempotent and writes no
   correction. *)
let test_replay_reconcile_with_a_different_summary_writes_no_correction () =
  with_base "keeper-chat-approval-summary-replay" (fun base_dir ->
    let approval_id = "appr_summary_replay" in
    let artifact_ref =
      Tool_output.make_artifact_ref
        ~sha256:(String.make 64 'a')
        ~bytes:12
        ~preview:"applied"
        ~mime:"text/plain"
      |> Result.get_ok
    in
    let first : K.approval_lifecycle =
      { approval_id
      ; tool_name = Some "tool_execute"
      ; phase = K.Approval_replay_applied
      ; artifact_ref = Some artifact_ref
      ; call_summary = Some "ls -la"
      }
    in
    let first_row_id =
      appended_row_id
        "first replay receipt"
        (K.reconcile_approval_replay_lifecycle_once ~base_dir ~keeper_name ~lifecycle:first)
    in
    let second = { first with call_summary = Some "ls -la /tmp" } in
    let second_row_id =
      already_present_row_id
        "replay receipt with another summary"
        (K.reconcile_approval_replay_lifecycle_once ~base_dir ~keeper_name ~lifecycle:second)
    in
    Alcotest.(check string) "the existing receipt is the one reported" first_row_id second_row_id;
    Alcotest.(check int)
      "no correction row was written"
      1
      (List.length (lifecycle_rows ~base_dir ~approval_id)))

(* Contrast: [tool_name] is a fact, and two known names that disagree are a
   conflict on the same slot. This is the line the summary sits on the other
   side of. *)
let test_a_different_known_tool_name_still_conflicts () =
  with_base "keeper-chat-approval-summary-tool-conflict" (fun base_dir ->
    let approval_id = "appr_summary_tool_conflict" in
    let first = resolution ~approval_id ~call_summary:(Some "git status") in
    ignore
      (appended_row_id
         "first resolution"
         (K.append_approval_lifecycle_once ~base_dir ~keeper_name ~lifecycle:first)
       : string);
    let other_tool = { first with tool_name = Some "identity_call" } in
    match K.append_approval_lifecycle_once ~base_dir ~keeper_name ~lifecycle:other_tool with
    | Error _ -> ()
    | Ok (K.Appended _) -> Alcotest.fail "a conflicting tool name was appended as a new row"
    | Ok (K.Already_present _) ->
      Alcotest.fail "a conflicting tool name was reported as the same row")

let () =
  Alcotest.run
    "keeper_chat_store_approval_summary"
    [ ( "call_summary is not row identity"
      , [ Alcotest.test_case
            "resolution with a different summary is the same row"
            `Quick
            test_resolution_with_a_different_summary_is_the_same_row
        ; Alcotest.test_case
            "a summary is not backfilled into a summary-less row"
            `Quick
            test_summary_is_not_backfilled_into_a_summary_less_row
        ; Alcotest.test_case
            "replay reconcile with a different summary writes no correction"
            `Quick
            test_replay_reconcile_with_a_different_summary_writes_no_correction
        ; Alcotest.test_case
            "a different known tool name still conflicts"
            `Quick
            test_a_different_known_tool_name_still_conflicts
        ] )
    ]
