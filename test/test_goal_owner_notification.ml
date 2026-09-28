(** #39571: owner-directed Goal notices.

    A refuted verdict and an overdue due date each owe the Goal's owner one
    Pending Message. Delivery is idempotent by the [Goal_notification] key
    (goal id, owner, event), and the Goal's marker is written only after the
    row is durably committed. These cases pin the four properties the design
    names: the same event repeated, a retry after a failed send, a restart,
    and a changed owner. *)

open Alcotest
open Masc

let temp_dir () = Filename.temp_dir "goal_notice_test" ""

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  try rm dir with _ -> ()

let with_workspace (f : Workspace.config -> unit) =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    let config = Workspace.default_config dir in
    ignore (Workspace.init config ~agent_name:(Some "test"));
    f config)

let past_date = "2000-01-01"
let future_date = "2999-01-01"

let make_goal ?(owner = Goal_store.Owner "keeper-a") ?due_date
    ?(phase = Goal_phase.Executing) id =
  { Goal_store.id
  ; owner
  ; criterion_revision = "rev-" ^ id
  ; title = "Goal " ^ id
  ; metric = Some "accepted artifacts"
  ; target_value = Some "1"
  ; due_date
  ; priority = 3
  ; phase
  ; last_review_note = None
  ; last_review_at = None
  ; notified_refuted_key = None
  ; notified_overdue_key = None
  ; created_at = "2026-01-01T00:00:00Z"
  ; updated_at = "2026-01-01T00:00:00Z"
  }

let write_goals (config : Workspace.config) goals =
  Goal_store.write_state config
    { version = 1; updated_at = "2026-01-01T00:00:00Z"; goals }

let owner_rows (config : Workspace.config) owner =
  Keeper_chat_store.load_all ~base_dir:config.base_path ~keeper_name:owner

let overdue_rows (config : Workspace.config) owner =
  owner_rows config owner
  |> List.filter (fun (m : Keeper_chat_store.chat_message) ->
    String.length m.content >= 14
    && String.sub m.content 0 14 = "[goal_overdue]")

let goal_of (config : Workspace.config) id =
  match Goal_store.find_goal config ~goal_id:id with
  | Goal_store.Goal_found goal -> goal
  | Goal_store.Goal_absent -> failwith ("goal absent: " ^ id)
  | Goal_store.Store_unavailable _ -> failwith "goal store unavailable"

let dispatch ctx ~name args =
  match Tool_workspace.dispatch ctx ~name ~args:(`Assoc args) with
  | Some result -> result
  | None -> failwith (name ^ " not handled")

let must_succeed label result =
  if Tool_result.is_success result
  then Yojson.Safe.from_string (Tool_result.message result)
  else failwith (Printf.sprintf "%s: %s" label (Tool_result.message result))

let json_state json key = Yojson.Safe.Util.(member key json |> to_string)

let verdict_rows (config : Workspace.config) owner =
  owner_rows config owner
  |> List.filter (fun (m : Keeper_chat_store.chat_message) ->
    String.length m.content >= 14
    && String.sub m.content 0 14 = "[goal_verdict]")

(* A refuted verdict sends the owner exactly one notice, and an exact replay of
   the same verdict sends nothing new. *)
let test_refuted_verdict_notifies_owner_once () =
  with_workspace (fun config ->
    let ctx : Tool_workspace.context =
      { Tool_workspace.config; agent_name = "planner" }
    in
    let created =
      must_succeed
        "create goal"
        (dispatch
           ctx
           ~name:"masc_goal_upsert"
           [ "title", `String "Refuted Goal"
           ; "metric", `String "m"
           ; "target_value", `String "1"
           ])
    in
    let goal_id = json_state created "goal_id" in
    ignore
      (must_succeed
         "request_complete"
         (dispatch
            ctx
            ~name:"masc_goal_transition"
            [ "goal_id", `String goal_id; "action", `String "request_complete" ]));
    let request_id, criterion =
      match Goal_verification.get_record_authoritative config ~goal_id with
      | Ok (Some { completion = Goal_verification.Proof_pending pending; _ }) ->
        pending.request_id, pending.criterion
      | Ok _ -> failwith "test setup needs a bound proof request"
      | Error detail -> failwith detail
    in
    let commit () =
      Workspace_goals.commit_verifier_decision
        ~tool_name:"goal_verifier_commit"
        ~start_time:(Tool_timing.start ())
        config
        ~goal_id
        ~verification_run_id:"goal-verifier-test-run"
        ~request_id
        ~criterion
        ~decision:(Workspace_goals.Proof_refuted { reason = "not proven" })
        ~evidence:"observed by the verifier"
    in
    ignore (must_succeed "refuted commit" (commit ()));
    check int "the owner gets one refuted notice" 1
      (List.length (verdict_rows config "planner"));
    ignore (commit ());
    check int "a replay sends nothing new" 1
      (List.length (verdict_rows config "planner")))

(* A failed commit-time send leaves no marker, so the periodic scan retries and
   the owner ends with exactly one row — not zero, not two. *)
let test_scan_refuted_retries_after_send_failure () =
  with_workspace (fun config ->
    let ctx : Tool_workspace.context =
      { Tool_workspace.config; agent_name = "planner" }
    in
    let created =
      must_succeed
        "create goal"
        (dispatch
           ctx
           ~name:"masc_goal_upsert"
           [ "title", `String "Refuted Goal"
           ; "metric", `String "m"
           ; "target_value", `String "1"
           ])
    in
    let goal_id = json_state created "goal_id" in
    ignore
      (must_succeed
         "request_complete"
         (dispatch
            ctx
            ~name:"masc_goal_transition"
            [ "goal_id", `String goal_id; "action", `String "request_complete" ]));
    let request_id, criterion =
      match Goal_verification.get_record_authoritative config ~goal_id with
      | Ok (Some { completion = Goal_verification.Proof_pending pending; _ }) ->
        pending.request_id, pending.criterion
      | Ok _ -> failwith "test setup needs a bound proof request"
      | Error detail -> failwith detail
    in
    let chat_dir =
      Filename.dirname
        (Keeper_chat_store.chat_path ~base_dir:config.base_path ~keeper_name:"planner")
    in
    (* A file where the chat directory belongs makes the commit-time send fail. *)
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote chat_dir)));
    ignore
      (Sys.command
         (Printf.sprintf "mkdir -p %s" (Filename.quote (Filename.dirname chat_dir))));
    let oc = open_out chat_dir in
    close_out oc;
    ignore
      (must_succeed
         "refuted commit"
         (Workspace_goals.commit_verifier_decision
            ~tool_name:"goal_verifier_commit"
            ~start_time:(Tool_timing.start ())
            config
            ~goal_id
            ~verification_run_id:"goal-verifier-test-run"
            ~request_id
            ~criterion
            ~decision:(Workspace_goals.Proof_refuted { reason = "not proven" })
            ~evidence:"observed by the verifier"));
    check int "failed send writes no row" 0
      (List.length (verdict_rows config "planner"));
    check (option string) "failed send leaves no marker" None
      (goal_of config goal_id).Goal_store.notified_refuted_key;
    Sys.remove chat_dir;
    Workspace_goals.scan_refuted_goal_notifications config;
    check int "scan retry delivers one row" 1
      (List.length (verdict_rows config "planner")))

(* A Goal whose owner changed after the refuted verdict reaches the new owner:
   the key carries the owner, so the scan delivers to the new recipient while
   the old owner keeps the one row it already had. *)
let test_scan_refuted_owner_change_notifies_new_owner () =
  with_workspace (fun config ->
    let ctx : Tool_workspace.context =
      { Tool_workspace.config; agent_name = "planner" }
    in
    let created =
      must_succeed
        "create goal"
        (dispatch
           ctx
           ~name:"masc_goal_upsert"
           [ "title", `String "Refuted Goal"
           ; "metric", `String "m"
           ; "target_value", `String "1"
           ])
    in
    let goal_id = json_state created "goal_id" in
    ignore
      (must_succeed
         "request_complete"
         (dispatch
            ctx
            ~name:"masc_goal_transition"
            [ "goal_id", `String goal_id; "action", `String "request_complete" ]));
    let request_id, criterion =
      match Goal_verification.get_record_authoritative config ~goal_id with
      | Ok (Some { completion = Goal_verification.Proof_pending pending; _ }) ->
        pending.request_id, pending.criterion
      | Ok _ -> failwith "test setup needs a bound proof request"
      | Error detail -> failwith detail
    in
    ignore
      (must_succeed
         "refuted commit"
         (Workspace_goals.commit_verifier_decision
            ~tool_name:"goal_verifier_commit"
            ~start_time:(Tool_timing.start ())
            config
            ~goal_id
            ~verification_run_id:"goal-verifier-test-run"
            ~request_id
            ~criterion
            ~decision:(Workspace_goals.Proof_refuted { reason = "not proven" })
            ~evidence:"observed by the verifier"));
    check int "the first owner gets one row" 1
      (List.length (verdict_rows config "planner"));
    (match
       Goal_store.transact_goal config ~goal_id (fun goal ->
         Ok ({ goal with Goal_store.owner = Goal_store.Owner "keeper-b" }, ()))
     with
     | Ok _ -> ()
     | Error error -> failwith (Goal_store.write_error_to_string error));
    Workspace_goals.scan_refuted_goal_notifications config;
    check int "the new owner gets one row" 1
      (List.length (verdict_rows config "keeper-b"));
    check int "the old owner keeps one row" 1
      (List.length (verdict_rows config "planner")))

(* A restart re-reads the persisted marker, so the scan sends nothing already
   delivered. A fresh config over the same base path is what a restart sees. *)
let test_scan_refuted_restart_sends_nothing () =
  with_workspace (fun config ->
    let ctx : Tool_workspace.context =
      { Tool_workspace.config; agent_name = "planner" }
    in
    let created =
      must_succeed
        "create goal"
        (dispatch
           ctx
           ~name:"masc_goal_upsert"
           [ "title", `String "Refuted Goal"
           ; "metric", `String "m"
           ; "target_value", `String "1"
           ])
    in
    let goal_id = json_state created "goal_id" in
    ignore
      (must_succeed
         "request_complete"
         (dispatch
            ctx
            ~name:"masc_goal_transition"
            [ "goal_id", `String goal_id; "action", `String "request_complete" ]));
    let request_id, criterion =
      match Goal_verification.get_record_authoritative config ~goal_id with
      | Ok (Some { completion = Goal_verification.Proof_pending pending; _ }) ->
        pending.request_id, pending.criterion
      | Ok _ -> failwith "test setup needs a bound proof request"
      | Error detail -> failwith detail
    in
    ignore
      (must_succeed
         "refuted commit"
         (Workspace_goals.commit_verifier_decision
            ~tool_name:"goal_verifier_commit"
            ~start_time:(Tool_timing.start ())
            config
            ~goal_id
            ~verification_run_id:"goal-verifier-test-run"
            ~request_id
            ~criterion
            ~decision:(Workspace_goals.Proof_refuted { reason = "not proven" })
            ~evidence:"observed by the verifier"));
    check int "commit-time send delivers one row" 1
      (List.length (verdict_rows config "planner"));
    let restarted = Workspace.default_config_uncached config.base_path in
    Workspace_goals.scan_refuted_goal_notifications restarted;
    check int "restart adds nothing" 1
      (List.length (verdict_rows config "planner")))

(* The same overdue event, scanned twice (a repeated tick, or a restart),
   leaves exactly one row in the owner's transcript. *)
let test_scan_overdue_notifies_owner_once () =
  with_workspace (fun config ->
    write_goals config [ make_goal ~due_date:past_date "goal-1" ];
    Workspace_goals.scan_overdue_goal_notifications config;
    check int "first scan delivers one row" 1
      (List.length (overdue_rows config "keeper-a"));
    Workspace_goals.scan_overdue_goal_notifications config;
    check int "second scan adds nothing" 1
      (List.length (overdue_rows config "keeper-a")))

(* A restart re-reads the persisted marker, so it sends nothing already
   delivered. A fresh config over the same base path is what a restart sees. *)
let test_scan_overdue_restart_sends_nothing () =
  with_workspace (fun config ->
    write_goals config [ make_goal ~due_date:past_date "goal-1" ];
    Workspace_goals.scan_overdue_goal_notifications config;
    check int "first scan delivers one row" 1
      (List.length (overdue_rows config "keeper-a"));
    let restarted = Workspace.default_config_uncached config.base_path in
    Workspace_goals.scan_overdue_goal_notifications restarted;
    check int "restart adds nothing" 1
      (List.length (overdue_rows config "keeper-a")))

(* The delivered row is a real Pending Message for the owner: the owner's own
   pending-message projection surfaces it as a mention, so the notice reaches
   the owner's turn rather than sitting unread in the transcript. *)
let test_overdue_notice_is_a_pending_message_for_owner () =
  with_workspace (fun config ->
    write_goals config [ make_goal ~due_date:past_date "goal-1" ];
    Workspace_goals.scan_overdue_goal_notifications config;
    let pending =
      Keeper_world_observation_message_scope.pending_messages_of_messages
        ~targets:[ "keeper-a" ]
        (owner_rows config "keeper-a")
    in
    check int "owner sees one pending notice" 1 (List.length pending);
    let (p : Keeper_world_observation_message_scope.pending_message) =
      List.hd pending
    in
    check bool "the pending notice is the overdue line" true
      (String.length p.content >= 14
       && String.sub p.content 0 14 = "[goal_overdue]"))

(* A changed owner is a new recipient: the new owner gets the notice, and the
   old owner keeps exactly the one row it already had. *)
let test_scan_overdue_owner_change_notifies_new_owner () =
  with_workspace (fun config ->
    write_goals config [ make_goal ~due_date:past_date "goal-1" ];
    Workspace_goals.scan_overdue_goal_notifications config;
    write_goals
      config
      [ make_goal ~owner:(Goal_store.Owner "keeper-b") ~due_date:past_date "goal-1" ];
    Workspace_goals.scan_overdue_goal_notifications config;
    check int "new owner gets one row" 1
      (List.length (overdue_rows config "keeper-b"));
    check int "old owner keeps one row" 1
      (List.length (overdue_rows config "keeper-a")))

(* No recipient, no notice: an ownerless Goal, a future due date, and a Goal
   that is no longer executing or verifying are all skipped. *)
let test_scan_overdue_skips_unknown_future_terminal () =
  with_workspace (fun config ->
    write_goals
      config
      [ make_goal ~owner:Goal_store.Unknown_owner ~due_date:past_date "goal-unknown"
      ; make_goal ~due_date:future_date "goal-future"
      ; make_goal ~due_date:past_date ~phase:Goal_phase.Completed "goal-done"
      ];
    Workspace_goals.scan_overdue_goal_notifications config;
    check int "ownerless goal sends nothing" 0
      (List.length (overdue_rows config "keeper-a"));
    check int "future due date sends nothing" 0
      (List.length (overdue_rows config "keeper-a"));
    check int "completed goal sends nothing" 0
      (List.length (overdue_rows config "keeper-a")))

(* A failed send leaves no marker, so the next scan retries and the owner ends
   with exactly one row — not zero, not two. *)
let test_scan_overdue_retries_after_send_failure () =
  with_workspace (fun config ->
    write_goals config [ make_goal ~due_date:past_date "goal-1" ];
    let chat_dir =
      Filename.dirname
        (Keeper_chat_store.chat_path ~base_dir:config.base_path ~keeper_name:"keeper-a")
    in
    (* A file where the chat directory belongs makes the append fail. *)
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote chat_dir)));
    ignore
      (Sys.command
         (Printf.sprintf "mkdir -p %s" (Filename.quote (Filename.dirname chat_dir))));
    let oc = open_out chat_dir in
    close_out oc;
    Workspace_goals.scan_overdue_goal_notifications config;
    check int "failed send writes no row" 0
      (List.length (overdue_rows config "keeper-a"));
    check (option string) "failed send leaves no marker" None
      (goal_of config "goal-1").Goal_store.notified_overdue_key;
    Sys.remove chat_dir;
    Workspace_goals.scan_overdue_goal_notifications config;
    check int "retry after failure delivers one row" 1
      (List.length (overdue_rows config "keeper-a")))

(* The delivery key is the dedup SSOT: the same key appends once, a new event
   appends again, and a different owner is a different transcript. *)
let test_goal_notification_delivery_key_is_idempotent () =
  with_workspace (fun config ->
    let key event =
      Keeper_chat_delivery_identity.Goal_notification
        { goal_id = "goal-1"; owner = "keeper-a"; event }
    in
    let append delivery_key =
      Keeper_chat_store.append_user_message_once
        ~base_dir:config.base_path
        ~keeper_name:"keeper-a"
        ~delivery_key
        ~content:"[goal_verdict] goal-1 — refuted"
        ~surface:Surface_ref.Agent
        ()
    in
    (match append (key "refuted:req-1") with
     | Ok _ -> ()
     | Error detail -> fail ("first append failed: " ^ detail));
    (match append (key "refuted:req-1") with
     | Ok _ -> ()
     | Error detail -> fail ("repeat append failed: " ^ detail));
    check int "same key appends once" 1 (List.length (owner_rows config "keeper-a"));
    (match append (key "refuted:req-2") with
     | Ok _ -> ()
     | Error detail -> fail ("new event append failed: " ^ detail));
    check int "a new event appends again" 2 (List.length (owner_rows config "keeper-a")))

let () =
  run "goal_owner_notification"
    [ ( "overdue scan"
      , [ test_case "notifies the owner once" `Quick
            test_scan_overdue_notifies_owner_once
        ; test_case "a restart sends nothing already delivered" `Quick
            test_scan_overdue_restart_sends_nothing
        ; test_case "the notice is a pending message for the owner" `Quick
            test_overdue_notice_is_a_pending_message_for_owner
        ; test_case "a changed owner is a new recipient" `Quick
            test_scan_overdue_owner_change_notifies_new_owner
        ; test_case "skips ownerless, future and terminal goals" `Quick
            test_scan_overdue_skips_unknown_future_terminal
        ; test_case "retries after a failed send" `Quick
            test_scan_overdue_retries_after_send_failure
        ] )
    ; ( "delivery key"
      , [ test_case "is idempotent per event" `Quick
            test_goal_notification_delivery_key_is_idempotent
        ] )
    ; ( "refuted verdict"
      , [ test_case "notifies the owner once" `Quick
            test_refuted_verdict_notifies_owner_once
        ; test_case "the scan retries after a failed send" `Quick
            test_scan_refuted_retries_after_send_failure
        ; test_case "a changed owner is a new recipient" `Quick
            test_scan_refuted_owner_change_notifies_new_owner
        ; test_case "a restart sends nothing already delivered" `Quick
            test_scan_refuted_restart_sends_nothing
        ] )
    ]
;;
