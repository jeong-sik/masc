open Alcotest

module Admission = Masc.Keeper_wip_admission
module Task_runtime = Masc.Keeper_tool_task_runtime
module U = Yojson.Safe.Util

(* Cap-mechanism tests pass a concrete repo string; wrap it as [Some] so the
   per-repo cap is exercised. [task_repo] resolves real tasks to [None] (no repo
   attribution in the task model), covered separately below. *)
let scope ?goal_id ?(category = Admission.Fix) repo =
  { Admission.repo = Some repo; goal_id; category }

let item ?goal_id ?(category = Admission.Fix) repo id =
  { Admission.id; scope = scope ?goal_id ~category repo }

let task ?(status = Masc_domain.Todo) ?(title = "fix: task") id =
  { Masc_domain.id
  ; title
  ; description = ""
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = "2026-05-21T00:00:00Z"
  ; created_by = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }

let caps =
  { Admission.max_global = Some 10
  ; max_per_repo = Some 2
  ; max_per_goal = Some 1
  ; max_per_category = Some 3
  }

let test_admits_below_caps () =
  let active = [ item ~goal_id:"goal-a" "repo-a" "one" ] in
  match Admission.decide ~caps active ~scope:(scope ~goal_id:"goal-b" "repo-a") with
  | Admission.Admit { active_count_after_admit } ->
    check int "active after admit" 2 active_count_after_admit
  | Reject rejection ->
    fail
      (Printf.sprintf "unexpected reject: %s"
         (Admission.reject_reason_to_string rejection.reason))

let test_rejects_repo_cap_before_goal_cap () =
  let active =
    [ item ~goal_id:"goal-a" "repo-a" "one"
    ; item ~goal_id:"goal-b" "repo-a" "two"
    ]
  in
  match Admission.decide ~caps active ~scope:(scope ~goal_id:"goal-c" "repo-a") with
  | Admission.Admit _ -> fail "expected repo cap rejection"
  | Reject rejection ->
    check string "reason" "repo_cap"
      (Admission.reject_reason_to_string rejection.reason);
    check int "current" 2 rejection.current;
    check int "limit" 2 rejection.limit;
    check string "scope key" "repo:repo-a" rejection.scope_key

let test_rejects_goal_cap () =
  let active = [ item ~goal_id:"goal-a" "repo-a" "one" ] in
  match Admission.decide ~caps active ~scope:(scope ~goal_id:"goal-a" "repo-b") with
  | Admission.Admit _ -> fail "expected goal cap rejection"
  | Reject rejection ->
    check string "reason" "goal_cap"
      (Admission.reject_reason_to_string rejection.reason);
    check string "axis" "goal" (Admission.reject_reason_axis rejection.reason);
    check string "scope key" "goal:goal-a" rejection.scope_key

let test_rejects_category_cap_across_repos () =
  let active =
    [ item ~goal_id:"goal-a" ~category:Admission.Refactor "repo-a" "one"
    ; item ~goal_id:"goal-b" ~category:Admission.Refactor "repo-b" "two"
    ; item ~goal_id:"goal-c" ~category:Admission.Refactor "repo-c" "three"
    ]
  in
  match
    Admission.decide ~caps active
      ~scope:(scope ~goal_id:"goal-d" ~category:Admission.Refactor "repo-d")
  with
  | Admission.Admit _ -> fail "expected category cap rejection"
  | Reject rejection ->
    check string "reason" "category_cap"
      (Admission.reject_reason_to_string rejection.reason);
    check string "scope key" "category:refactor" rejection.scope_key

let test_active_counts_surface_all_axes () =
  let active =
    [ item ~goal_id:"goal-a" ~category:Admission.Fix "repo-a" "one"
    ; item ~goal_id:"goal-b" ~category:Admission.Docs "repo-a" "two"
    ; item ~goal_id:"goal-a" ~category:Admission.Fix "repo-b" "three"
    ]
  in
  let counts = Admission.active_counts ~scope:(scope ~goal_id:"goal-a" "repo-a") active in
  check (list (pair string int)) "counts"
    [ "global", 3; "repo:repo-a", 2; "goal:goal-a", 2; "category:fix", 2 ]
    counts

let test_decision_json_rejects_with_scope_key () =
  let decision =
    Admission.decide
      ~caps:{ caps with max_global = Some 0 }
      [] ~scope:(scope "repo-a")
  in
  let json = Admission.decision_to_json decision in
  check string "reason" "global_cap"
    Yojson.Safe.Util.(json |> member "reason" |> to_string);
  check string "axis" "global"
    Yojson.Safe.Util.(json |> member "axis" |> to_string);
  check string "scope key" "global"
    Yojson.Safe.Util.(json |> member "scope_key" |> to_string)

let test_scope_of_task_has_no_repo_uses_goal_and_title_category () =
  let task_goal_index = Hashtbl.create 1 in
  Hashtbl.replace task_goal_index "task-001" ["goal-a"];
  let scope =
    Admission.scope_of_task
      ~task_goal_index
      (task
         ~title:"refactor(keeper): split claim gate"
         "task-001")
  in
  (* The task model carries no repo, so the scope resolves to [None] — exempt
     from the per-repo cap rather than collapsed into a fleet-wide bucket. *)
  check (option string) "repo" None scope.repo;
  check (option string) "goal" (Some "goal-a") scope.goal_id;
  check string "category" "refactor" (Admission.category_to_string scope.category)

let test_repoless_tasks_exempt_from_repo_cap () =
  (* Regression guard for the WIP-cap collapse: many repoless ([None]) tasks must
     NOT share a single fleet-wide repo bucket. With [max_per_repo = Some 2] and
     three already-active repoless items, a fourth repoless task still admits
     (only the global cap bounds it). Before the fix, [task_repo] returned a
     shared fallback string, so this rejected with repo_cap once 2 were active. *)
  let active =
    [ { Admission.id = "one"; scope = { Admission.repo = None; goal_id = None; category = Admission.Fix } }
    ; { Admission.id = "two"; scope = { Admission.repo = None; goal_id = None; category = Admission.Docs } }
    ; { Admission.id = "three"; scope = { Admission.repo = None; goal_id = None; category = Admission.Chore } }
    ]
  in
  let repoless_scope = { Admission.repo = None; goal_id = None; category = Admission.Ci } in
  match Admission.decide ~caps active ~scope:repoless_scope with
  | Admission.Admit { active_count_after_admit } ->
    check int "active after admit" 4 active_count_after_admit
  | Reject rejection ->
    fail
      (Printf.sprintf "repoless task should be exempt from repo cap, got %s"
         (Admission.reject_reason_to_string rejection.reason))

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_wip_admission_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
  in
  try rm dir with
  | _ -> ()

let add_goal_task config ~goal_id ~title =
  let result =
    Masc.Workspace.add_task config ~goal_id ~title ~priority:3
      ~description:"wip admission fixture"
  in
  if not (Astring.String.is_prefix ~affix:"Added task" result)
  then fail ("add_task failed: " ^ result)

let claim_task_exn config ~agent_name ~task_id =
  match Masc.Workspace.claim_task_r config ~agent_name ~task_id () with
  | Ok _ -> ()
  | Error err -> fail ("claim_task_r failed: " ^ Masc_domain.masc_error_to_string err)

let meta_with_active_goal goal_id =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "keeper-wip-cap"
        ; "agent_name", `String "keeper-wip-cap-agent"
        ; "trace_id", `String "trace-wip-cap"
        ; "active_goal_ids", `List [ `String goal_id ]
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

let test_keeper_task_claim_reports_other_keepers_wip_cap () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let goal, _ =
         match Goal_store.upsert_goal config ~title:"WIP cap goal" () with
         | Ok payload -> payload
         | Error msg -> fail msg
       in
       for i = 1 to 4 do
         add_goal_task config ~goal_id:goal.id
           ~title:(Printf.sprintf "fix: WIP cap fixture %d" i)
       done;
       claim_task_exn config ~agent_name:"keeper-a-agent" ~task_id:"task-001";
       claim_task_exn config ~agent_name:"keeper-b-agent" ~task_id:"task-002";
       claim_task_exn config ~agent_name:"keeper-c-agent" ~task_id:"task-003";
       let payload =
         Task_runtime.handle_keeper_task_tool ~config
           ~meta:(meta_with_active_goal goal.id)
           ~name:"keeper_task_claim" ~args:(`Assoc [])
       in
       let json = Yojson.Safe.from_string payload in
       check bool "claim result present" true
         (json |> U.member "result" <> `Null);
       check string "wip kind" "claim_wip_admission"
         (json |> U.member "wip_admission" |> U.member "kind" |> U.to_string);
       check string "top-level action"
         "finish_or_release_existing_wip_before_claiming_more"
         (json |> U.member "wip_admission" |> U.member "action" |> U.to_string);
       let rejection =
         match
           json |> U.member "wip_admission" |> U.member "rejections" |> U.to_list
         with
         | first :: _ -> first
         | [] -> fail "expected at least one WIP rejection"
       in
       check string "rejection reason" "goal_cap"
         (rejection |> U.member "reason" |> U.to_string);
       check string "rejection axis" "goal"
         (rejection |> U.member "axis" |> U.to_string);
       check string "cap kind" "wip_claim_admission"
         (rejection |> U.member "cap_kind" |> U.to_string);
       check string "rejection action"
         "finish_or_release_existing_wip_before_claiming_more"
         (rejection |> U.member "action" |> U.to_string);
       check bool "scope note distinguishes claim cap" true
         (Astring.String.is_infix ~affix:"not a request to create a new repo"
            (rejection |> U.member "scope_note" |> U.to_string));
       check bool "message tells keeper not to bypass with new work" true
         (Astring.String.is_infix ~affix:"do not create unrelated repos"
            (json |> U.member "result" |> U.to_string)))

let test_keeper_task_claim_no_unclaimed_emits_no_work_outcome () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let payload =
         Task_runtime.handle_keeper_task_tool ~config
           ~meta:
             (match
                Masc_test_deps.meta_of_json_fixture
                  (`Assoc
                    [ "name", `String "keeper-empty-queue"
                    ; "agent_name", `String "keeper-empty-queue-agent"
                    ; "trace_id", `String "trace-empty-queue"
                    ; "active_goal_ids", `List []
                    ])
              with
              | Ok meta -> meta
              | Error err -> fail ("meta_of_json_fixture failed: " ^ err))
           ~name:"keeper_task_claim" ~args:(`Assoc [])
       in
       let json = Yojson.Safe.from_string payload in
       check string "result"
         "No unclaimed tasks. ACTION: Stop task-checking — nothing to claim."
         (json |> U.member "result" |> U.to_string);
       let typed = json |> U.member "typed_outcome" in
       check string "typed kind" "No_progress"
         (typed |> U.member "kind" |> U.to_string);
       check string "reason kind" "No_work_available"
         (typed |> U.member "reason" |> U.member "kind" |> U.to_string))

let test_active_items_only_include_claimed_or_in_progress () =
  let now = Masc_domain.now_iso () in
  let tasks =
    [ task
        ~status:(Masc_domain.Claimed { assignee = "a"; claimed_at = now })
        "task-001"
    ; task
        ~status:(Masc_domain.InProgress { assignee = "b"; started_at = now })
        ~title:"docs: update runbook"
        "task-002"
    ; task ~title:"fix: still todo" "task-003"
    ]
  in
  let active = Admission.active_items_of_tasks tasks in
  check (list string) "active ids" [ "task-001"; "task-002" ]
    (List.map (fun item -> item.Admission.id) active);
  check (list string) "categories" [ "fix"; "docs" ]
    (List.map
       (fun item -> Admission.category_to_string item.Admission.scope.category)
       active)

let test_active_items_include_all_active_assignees () =
  let now = Masc_domain.now_iso () in
  let tasks =
    [ task
        ~status:(Masc_domain.Claimed { assignee = "keeper-a"; claimed_at = now })
        "task-claimed-a"
    ; task
        ~status:
          (Masc_domain.InProgress { assignee = "keeper-a"; started_at = now })
        "task-progress-a"
    ; task
        ~status:(Masc_domain.Claimed { assignee = "keeper-b"; claimed_at = now })
        "task-claimed-b"
    ; task
        ~status:
          (Masc_domain.InProgress { assignee = "keeper-b"; started_at = now })
        "task-progress-b"
    ]
  in
  let active = Admission.active_items_of_tasks tasks in
  check (list string) "all active ids"
    [ "task-claimed-a"; "task-progress-a"; "task-claimed-b"; "task-progress-b" ]
    (List.map (fun item -> item.Admission.id) active)

let iso8601_of_unix_time t =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let test_stale_claimed_task_not_active () =
  (* claimed 2 hours ago, default threshold is 1 hour -> stale, not active *)
  let two_hours_ago = iso8601_of_unix_time (Unix.gettimeofday () -. 7200.) in
  let tasks =
    [ task
        ~status:(Masc_domain.Claimed { assignee = "a"; claimed_at = two_hours_ago })
        "task-stale"
    ]
  in
  check (list string) "no active ids" []
    (List.map (fun item -> item.Admission.id) (Admission.active_items_of_tasks tasks))

let test_fresh_claimed_task_stays_active_under_custom_threshold () =
  (* claimed 30 minutes ago, custom threshold 10 minutes -> stale under that
     threshold, but active under the (higher) default. Exercises the
     ?stale_threshold_s override on both task_is_active_wip and
     active_items_of_tasks. *)
  let thirty_min_ago = iso8601_of_unix_time (Unix.gettimeofday () -. 1800.) in
  let claimed_task =
    task
      ~status:(Masc_domain.Claimed { assignee = "a"; claimed_at = thirty_min_ago })
      "task-recent"
  in
  check bool "active under default (1h) threshold" true
    (Admission.task_is_active_wip claimed_task);
  check bool "stale under a 10-minute threshold" false
    (Admission.task_is_active_wip ~stale_threshold_s:600. claimed_task)

let test_unparseable_claimed_at_treated_as_stale () =
  (* Fail-closed: a malformed/unparseable claimed_at must not silently be
     treated as fresh WIP (parse_iso8601's own default is "60 seconds ago",
     which would otherwise always admit it). *)
  let tasks =
    [ task
        ~status:(Masc_domain.Claimed { assignee = "a"; claimed_at = "not-a-timestamp" })
        "task-malformed"
    ]
  in
  check (list string) "no active ids for malformed timestamp" []
    (List.map (fun item -> item.Admission.id) (Admission.active_items_of_tasks tasks))

let test_goalless_task_exempt_from_goal_cap () =
  (* RFC-0245: a goalless claim must not be rejected by the per-goal cap even
     when the goalless ([None]) bucket is at/over [max_per_goal]. With
     max_per_goal=1 and one goalless active item, the old behavior rejected;
     the exemption must now admit. *)
  let active = [ item "repo-a" "one" ] in
  match Admission.decide ~caps active ~scope:(scope "repo-b") with
  | Admission.Admit { active_count_after_admit } ->
    check int "active after admit" 2 active_count_after_admit
  | Reject rejection ->
    fail
      (Printf.sprintf "goalless claim unexpectedly rejected: %s"
         (Admission.reject_reason_to_string rejection.reason))

let test_goalless_tasks_never_goal_capped () =
  (* RFC-0245: many goalless active items, each in a distinct repo/category so
     only the per-goal cap could fire — it must not, because goalless tasks
     share no goal scope to collide on. *)
  let active =
    [ item ~category:Admission.Fix "repo-a" "one"
    ; item ~category:Admission.Docs "repo-b" "two"
    ; item ~category:Admission.Refactor "repo-c" "three"
    ]
  in
  match
    Admission.decide ~caps active
      ~scope:(scope ~category:Admission.Test "repo-d")
  with
  | Admission.Admit _ -> ()
  | Reject rejection ->
    fail
      (Printf.sprintf "goalless claim unexpectedly rejected by %s"
         (Admission.reject_reason_to_string rejection.reason))

let test_goalless_still_bounded_by_global_cap () =
  (* RFC-0245 non-goal: exempting goalless from the *goal* cap must NOT remove
     the global blast-radius cap. With max_global=1 and one active item, a
     goalless claim is still rejected — by global_cap, not goal_cap. *)
  let active = [ item "repo-a" "one" ] in
  match
    Admission.decide
      ~caps:{ caps with max_global = Some 1 }
      active ~scope:(scope "repo-b")
  with
  | Admission.Admit _ -> fail "expected global cap rejection for goalless claim"
  | Reject rejection ->
    check string "reason" "global_cap"
      (Admission.reject_reason_to_string rejection.reason)

let () =
  run "Keeper_wip_admission"
    [ ( "caps"
      , [ test_case "admits below caps" `Quick test_admits_below_caps
        ; test_case "rejects repo cap before goal cap" `Quick
            test_rejects_repo_cap_before_goal_cap
        ; test_case "rejects goal cap" `Quick test_rejects_goal_cap
        ; test_case "rejects category cap across repos" `Quick
            test_rejects_category_cap_across_repos
        ; test_case "active counts surface all axes" `Quick
            test_active_counts_surface_all_axes
        ; test_case "decision JSON rejects with scope key" `Quick
            test_decision_json_rejects_with_scope_key
        ; test_case "task scope has no repo, uses goal and title category" `Quick
            test_scope_of_task_has_no_repo_uses_goal_and_title_category
        ; test_case "repoless tasks exempt from repo cap" `Quick
            test_repoless_tasks_exempt_from_repo_cap
        ; test_case "keeper_task_claim reports other keepers WIP cap" `Quick
            test_keeper_task_claim_reports_other_keepers_wip_cap
        ; test_case "keeper_task_claim no-unclaimed emits no-work outcome" `Quick
            test_keeper_task_claim_no_unclaimed_emits_no_work_outcome
        ; test_case "active items include active WIP only" `Quick
            test_active_items_only_include_claimed_or_in_progress
        ; test_case "active items include all active assignees" `Quick
            test_active_items_include_all_active_assignees
        ; test_case "goalless task exempt from goal cap" `Quick
            test_goalless_task_exempt_from_goal_cap
        ; test_case "goalless tasks never goal-capped" `Quick
            test_goalless_tasks_never_goal_capped
        ; test_case "goalless still bounded by global cap" `Quick
            test_goalless_still_bounded_by_global_cap
        ; test_case "stale claimed task not active" `Quick
            test_stale_claimed_task_not_active
        ; test_case "fresh claimed task stays active under custom threshold" `Quick
            test_fresh_claimed_task_stays_active_under_custom_threshold
        ; test_case "unparseable claimed_at treated as stale" `Quick
            test_unparseable_claimed_at_treated_as_stale
        ] )
    ]
