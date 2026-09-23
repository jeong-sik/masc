(** The list of tasks whose only exit belongs to the operator.

    Every row here is a task that cannot move on its own: a stop only an
    operator may grant, or work held by a name that will never act again. The
    fixtures build those states the way production reaches them — the cancel
    claim goes through the real transition so the record it writes is the one
    the list reads back. *)
module D = Masc_domain
module W = Workspace_core
module Attention = Masc.Operator_task_attention
module Store = Workspace_verification_store

let () = Mirage_crypto_rng_unix.use_default ()

let ok = function Ok value -> value | Error detail -> Alcotest.fail detail

let workspace_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (D.masc_error_to_string error)

let live_keeper = "edgar.a.poe"
let vanished = "codex-mcp-client"
let undecodable = "half-written-keeper"
let stop_reason = "the issue this task answers was closed upstream on 2026-07-27"

let with_workspace f =
  (* The verification-request adapter is part of the contract: the cancel
     claim's record is written by the installed runtime hook, not by the
     test. *)
  Masc.Workspace_metric_hooks.install ();
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let base_path = Filename.temp_dir "masc-operator-attention-" "" in
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.on_release sw (fun () ->
        Fs_compat.clear_fs ();
        Masc_test_deps.cleanup_test_workspace base_path);
      let config = W.default_config base_path in
      ignore (W.init config ~agent_name:(Some live_keeper));
      f config))

let persist_keeper config name =
  let meta =
    ok (Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]))
  in
  ok
    (Masc.Keeper_fs.save_json_atomic
       (Masc.Keeper_types_profile.keeper_meta_path config name)
       (Masc.Keeper_meta_json.meta_to_json meta))

let add_task config ~title =
  ignore (W.add_task config ~title ~priority:1 ~description:title)

let set_status config ~task_id ~status =
  let backlog = ok (Workspace_backlog.read_backlog_r config) in
  let tasks =
    List.map
      (fun (task : D.task) ->
         if String.equal task.id task_id then { task with task_status = status } else task)
      backlog.tasks
  in
  W.write_backlog config { backlog with tasks }

let in_progress ~assignee ~started_at = D.InProgress { assignee; started_at }

let project config =
  Attention.project ~config (ok (Workspace_backlog.read_backlog_r config)).tasks

(* The producer states its whole claim and the operator reads it from the list.
   Before the record kept a copy the sentence existed only in the body of an
   unlisted Board post, which a list built from the backlog cannot reach. *)
let test_a_cancel_claim_carries_its_reason () =
  with_workspace (fun config ->
    add_task config ~title:"a task its producer gives up on";
    ignore
      (workspace_ok
         (W.transition_task_r config ~agent_name:live_keeper ~task_id:"task-001"
            ~action:D.Claim ()));
    ignore
      (workspace_ok
         (W.transition_task_r config ~agent_name:live_keeper ~task_id:"task-001"
            ~action:D.Start ()));
    ignore
      (workspace_ok
         (W.transition_task_r config ~agent_name:live_keeper ~task_id:"task-001"
            ~action:D.Cancel ~reason:stop_reason ()));
    match project config with
    | [ Attention.Cancel_claim { task_id; assignee; reason; _ } ] ->
      Alcotest.(check string) "the stop names its task" "task-001" task_id;
      Alcotest.(check string) "and its producer" live_keeper assignee;
      (match reason with
       | Store.Cancellation_reason_stated stated ->
         Alcotest.(check string) "the operator reads what the producer said"
           stop_reason stated
       | Store.Cancellation_reason_unreadable detail ->
         Alcotest.failf "the record could not be read: %s" detail)
    | items ->
      Alcotest.failf "a stop is one operator row, got %d" (List.length items))

let producer_handoff_summary = "stopped: the upstream issue was closed"
let operator = "operator-vincent"

let verdict_audit_event config =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  let events_dir =
    Filename.concat
      (Workspace_utils.masc_dir_from_base_path ~base_path:config.W.base_path)
      "events"
  in
  let path =
    Filename.concat
      (Filename.concat events_dir
         (Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)))
      (Printf.sprintf "%02d.jsonl" tm.Unix.tm_mday)
  in
  Fs_compat.load_jsonl path
  |> List.find_opt (fun json ->
    match Yojson.Safe.Util.member "type" json with
    | `String "task_completion_verdict" -> true
    | _ -> false)

(* Claims, starts and asks to stop task-001 the way a Keeper does, with a
   reason and a handoff, and returns the verification the operator judges. *)
let submit_stop config =
  add_task config ~title:"a task its producer gives up on";
  ignore
    (workspace_ok
       (W.transition_task_r config ~agent_name:live_keeper ~task_id:"task-001"
          ~action:D.Claim ()));
  ignore
    (workspace_ok
       (W.transition_task_r config ~agent_name:live_keeper ~task_id:"task-001"
          ~action:D.Start ()));
  let handoff_context =
    { D.summary = producer_handoff_summary
    ; reason = Some stop_reason
    ; next_step = None
    ; failure_mode = None
    ; reclaim_policy = None
    ; evidence_refs = []
    ; updated_at = None
    ; updated_by = Some live_keeper
    }
  in
  ignore
    (workspace_ok
       (W.transition_task_r config ~agent_name:live_keeper ~task_id:"task-001"
          ~action:D.Cancel ~reason:stop_reason ~handoff_context ()));
  match (ok (Workspace_backlog.read_backlog_r config)).tasks with
  | [ { task_status = D.AwaitingVerification { verification_id; _ }; _ } ] ->
    verification_id
  | _ -> Alcotest.fail "the stop must wait for a verdict"

(* The operator grants the stop from the TUI, which sends no notes. The
   Cancelled record keeps what the producer said under the producer's name,
   the producer's handoff survives the approval, and the verdict audit names
   the operator who signed it. *)
let test_a_granted_stop_keeps_the_producers_reason () =
  with_workspace (fun config ->
    let verification_id = submit_stop config in
    ignore
      (workspace_ok
         (W.commit_verdict_r config
            ~authority:(D.Human_operator { operator_id = operator })
            ~verdict:D.Verdict_approved ~task_id:"task-001" ~verification_id ()));
    (match (ok (Workspace_backlog.read_backlog_r config)).tasks with
     | [ { task_status = D.Cancelled { cancelled_by; reason; _ }; handoff_context; _ } ] ->
       Alcotest.(check string) "the stop is the producer's" live_keeper cancelled_by;
       Alcotest.(check (option string)) "with the producer's reason"
         (Some stop_reason) reason;
       Alcotest.(check (option string)) "and the producer's handoff"
         (Some producer_handoff_summary)
         (Option.map (fun (context : D.task_handoff_context) -> context.summary)
            handoff_context)
     | _ -> Alcotest.fail "an approved stop must end as Cancelled");
    match verdict_audit_event config with
    | None -> Alcotest.fail "the verdict left no audit record"
    | Some event ->
      Alcotest.(check string) "the verdict names the operator" operator
        Yojson.Safe.Util.(event |> member "authority_actor" |> to_string);
      Alcotest.(check string) "who signed as an operator" "human_operator"
        Yojson.Safe.Util.(event |> member "authority_kind" |> to_string))

(* Notes the operator writes with an approval are the verdict's words, so
   they ride on the verdict audit record next to the operator's name. *)
let test_operator_notes_ride_on_the_verdict_record () =
  with_workspace (fun config ->
    let verification_id = submit_stop config in
    let notes = "granted after reading the upstream thread" in
    ignore
      (workspace_ok
         (W.commit_verdict_r config
            ~authority:(D.Human_operator { operator_id = operator })
            ~verdict:D.Verdict_approved ~task_id:"task-001" ~verification_id
            ~notes ()));
    match verdict_audit_event config with
    | None -> Alcotest.fail "the verdict left no audit record"
    | Some event ->
      Alcotest.(check string) "the verdict keeps the operator's notes" notes
        Yojson.Safe.Util.(event |> member "notes" |> to_string);
      Alcotest.(check string) "under the operator's name" operator
        Yojson.Safe.Util.(event |> member "authority_actor" |> to_string))

(* A completion waits on the system authority, which is running. Only a stop
   waits on a person. *)
let test_a_completion_is_not_the_operators_row () =
  with_workspace (fun config ->
    persist_keeper config live_keeper;
    add_task config ~title:"work submitted as finished";
    set_status config ~task_id:"task-001"
      ~status:
        (D.AwaitingVerification
           { assignee = live_keeper
           ; started_at = "2026-09-01T00:00:00Z"
           ; submitted_at = "2026-09-02T00:00:00Z"
           ; intent = D.Complete_task
           ; verification_id = "vrf-completion"
           });
    Alcotest.(check int) "a completion is nobody's operator row" 0
      (List.length (project config)))

(* The route is the same one the rejection delivery computes: a name with a
   live registry entry or a Keeper meta file can still act, and a name with
   neither cannot. *)
let test_only_work_with_no_actor_is_listed () =
  with_workspace (fun config ->
    persist_keeper config live_keeper;
    add_task config ~title:"held by a Keeper that is still there";
    add_task config ~title:"held by a session that is gone";
    set_status config ~task_id:"task-001"
      ~status:(in_progress ~assignee:live_keeper ~started_at:"2026-09-03T00:00:00Z");
    set_status config ~task_id:"task-002"
      ~status:(in_progress ~assignee:vanished ~started_at:"2026-09-04T00:00:00Z");
    match project config with
    | [ Attention.Held_without_actor { task_id; assignee; since } ] ->
      Alcotest.(check string) "the abandoned task is the row" "task-002" task_id;
      Alcotest.(check string) "named by who holds it" vanished assignee;
      Alcotest.(check string) "waiting since it started" "2026-09-04T00:00:00Z" since
    | items ->
      Alcotest.failf "a live Keeper's task is not an operator row (got %d rows)"
        (List.length items))

(* A file at the meta path this binary cannot decode is a Keeper whose record
   needs repair, not a Keeper that is gone. Folding the two together would put
   a task up for recovery whose owner is still running. *)
let test_an_undecodable_keeper_record_is_its_own_row () =
  with_workspace (fun config ->
    let meta_path = Masc.Keeper_types_profile.keeper_meta_path config undecodable in
    Fs_compat.mkdir_p (Filename.dirname meta_path);
    Out_channel.with_open_text meta_path (fun out -> output_string out "[]");
    add_task config ~title:"held by a Keeper whose record does not decode";
    set_status config ~task_id:"task-001"
      ~status:(in_progress ~assignee:undecodable ~started_at:"2026-09-05T00:00:00Z");
    match project config with
    | [ Attention.Producer_record_unreadable { producer; detail; _ } ] ->
      Alcotest.(check string) "named by whose record it is" undecodable producer;
      Alcotest.(check bool) "and says what could not be read" true
        (String.length detail > 0)
    | items ->
      Alcotest.failf "an undecodable record is its own row, got %d" (List.length items))

(* The longest wait is the row that has gone unanswered the longest, and a
   surface that draws a few draws those. *)
let test_rows_are_oldest_first () =
  with_workspace (fun config ->
    add_task config ~title:"abandoned later";
    add_task config ~title:"abandoned first";
    set_status config ~task_id:"task-001"
      ~status:(in_progress ~assignee:vanished ~started_at:"2026-09-10T00:00:00Z");
    set_status config ~task_id:"task-002"
      ~status:(in_progress ~assignee:vanished ~started_at:"2026-09-02T00:00:00Z");
    Alcotest.(check (list string)) "oldest wait first"
      [ "task-002"; "task-001" ]
      (List.map Attention.task_id (project config)))

let test_terminal_and_unclaimed_tasks_are_not_rows () =
  with_workspace (fun config ->
    add_task config ~title:"nobody has claimed this";
    add_task config ~title:"finished";
    add_task config ~title:"stopped";
    set_status config ~task_id:"task-002"
      ~status:
        (D.Done
           { assignee = vanished; completed_at = "2026-09-06T00:00:00Z"; notes = None });
    set_status config ~task_id:"task-003"
      ~status:
        (D.Cancelled
           { cancelled_by = vanished
           ; cancelled_at = "2026-09-06T00:00:00Z"
           ; reason = None
           });
    Alcotest.(check int) "todo and terminal tasks wait on nobody" 0
      (List.length (project config)))

let () =
  Alcotest.run "operator_task_attention"
    [ ( "tasks only an operator can move"
      , [ Alcotest.test_case "a cancel claim carries its reason" `Quick
            test_a_cancel_claim_carries_its_reason
        ; Alcotest.test_case "a granted stop keeps the producer's reason" `Quick
            test_a_granted_stop_keeps_the_producers_reason
        ; Alcotest.test_case "operator notes ride on the verdict record" `Quick
            test_operator_notes_ride_on_the_verdict_record
        ; Alcotest.test_case "a completion is not an operator row" `Quick
            test_a_completion_is_not_the_operators_row
        ; Alcotest.test_case "only work with no actor is listed" `Quick
            test_only_work_with_no_actor_is_listed
        ; Alcotest.test_case "an undecodable keeper record is its own row" `Quick
            test_an_undecodable_keeper_record_is_its_own_row
        ; Alcotest.test_case "rows are oldest first" `Quick test_rows_are_oldest_first
        ; Alcotest.test_case "terminal and unclaimed tasks are not rows" `Quick
            test_terminal_and_unclaimed_tasks_are_not_rows
        ] )
    ]
