open Alcotest

module Admission = Masc.Keeper_wip_admission
module Env_config_core = Masc.Env_config_core
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

let old_release_timestamp = "2020-01-01T00:00:00Z"

let mark_agent_stale_for_release config ~agent_name =
  Masc.Workspace.update_local_agent_state config ~agent_name (fun agent ->
    { agent with status = Masc_domain.Active; last_seen = old_release_timestamp })

let rewrite_task_status config ~task_id ~f =
  let backlog = Masc.Workspace.read_backlog config in
  let updated_tasks =
    List.map
      (fun (task : Masc_domain.task) ->
         if String.equal task.id task_id
         then { task with task_status = f task.task_status }
         else task)
      backlog.tasks
  in
  Masc.Workspace.write_backlog config { backlog with tasks = updated_tasks }

let age_claimed_task_for_release config ~task_id =
  rewrite_task_status config ~task_id ~f:(function
    | Masc_domain.Claimed { assignee; _ } ->
      Masc_domain.Claimed { assignee; claimed_at = old_release_timestamp }
    | other -> other)

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

let test_keeper_task_claim_releases_stale_owner_before_wip_admission () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let goal, _ =
         match Goal_store.upsert_goal config ~title:"WIP stale release goal" () with
         | Ok payload -> payload
         | Error msg -> fail msg
       in
       for i = 1 to 4 do
         add_goal_task config ~goal_id:goal.id
           ~title:(Printf.sprintf "fix: stale release fixture %d" i)
       done;
       let stale_agents =
         [ "keeper-a-agent"; "keeper-b-agent"; "keeper-c-agent" ]
       in
       List.iteri
         (fun i agent_name ->
            let task_id = Printf.sprintf "task-%03d" (i + 1) in
            claim_task_exn config ~agent_name ~task_id;
            mark_agent_stale_for_release config ~agent_name;
            age_claimed_task_for_release config ~task_id)
         stale_agents;
       let payload =
         Task_runtime.handle_keeper_task_tool ~config
           ~meta:(meta_with_active_goal goal.id)
           ~name:"keeper_task_claim" ~args:(`Assoc [])
       in
       let json = Yojson.Safe.from_string payload in
       check bool "claimed task present" true
         (json |> U.member "claimed_task" <> `Null);
       check int "stale release count" 3
         (json |> U.member "stale_claim_releases" |> U.to_list |> List.length);
       check string "new claimant took released task" "task-001"
         (json |> U.member "claimed_task" |> U.member "task_id" |> U.to_string);
       let backlog = Masc.Workspace.read_backlog config in
       match
         List.find_opt
           (fun (task : Masc_domain.task) -> String.equal task.id "task-002")
           backlog.tasks
       with
       | Some { task_status = Masc_domain.Todo; _ } -> ()
       | Some task ->
         fail
           (Printf.sprintf "expected task-002 to be released, got %s"
              (Masc_domain.task_status_to_string task.task_status))
       | None -> fail "task-002 missing from backlog")

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

let test_old_claimed_task_stays_active_until_owner_release () =
  let tasks =
    [ task
        ~status:
          (Masc_domain.Claimed
             { assignee = "a"; claimed_at = old_release_timestamp })
        "task-old-but-owned"
    ]
  in
  check (list string) "old claimed task remains active" [ "task-old-but-owned" ]
    (List.map (fun item -> item.Admission.id)
       (Admission.active_items_of_tasks tasks))

let test_unparseable_claimed_at_keeps_counting_until_owner_release () =
  let tasks =
    [ task
        ~status:(Masc_domain.Claimed { assignee = "a"; claimed_at = "not-a-timestamp" })
        "task-malformed"
    ]
  in
  check (list string) "malformed timestamp stays active" [ "task-malformed" ]
    (List.map (fun item -> item.Admission.id)
       (Admission.active_items_of_tasks tasks))

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

(* --- env-configurable default_caps (MASC_KEEPER_WIP_ knobs) --- *)

let with_env name value f =
  let prev = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "" (* "" reads back as the historical default *))
    f

let wip_env_keys =
  [ "MASC_KEEPER_WIP_MAX_GLOBAL"
  ; "MASC_KEEPER_WIP_MAX_PER_REPO"
  ; "MASC_KEEPER_WIP_MAX_PER_GOAL"
  ; "MASC_KEEPER_WIP_MAX_PER_CATEGORY"
  ]

let test_default_caps_unset_uses_historical_defaults () =
  (* An unset (or "" — the restore sentinel) knob must reproduce the exact prior
     hardcoded caps. Skip only if the ambient env pins a real override. *)
  if List.exists
       (fun k -> match Sys.getenv_opt k with None | Some "" -> false | Some _ -> true)
       wip_env_keys
  then skip ()
  else (
    let c = Admission.default_caps () in
    check (option int) "max_global default" (Some 16) c.Admission.max_global;
    check (option int) "max_per_repo default" (Some 12) c.max_per_repo;
    check (option int) "max_per_goal default" (Some 3) c.max_per_goal;
    check (option int) "max_per_category default" (Some 4) c.max_per_category)

let test_default_caps_positive_env_override () =
  with_env "MASC_KEEPER_WIP_MAX_GLOBAL" "8" @@ fun () ->
  let c = Admission.default_caps () in
  check (option int) "max_global overridden" (Some 8) c.Admission.max_global;
  check (option int) "other axes untouched" (Some 3) c.max_per_goal

let test_default_caps_disable_via_zero_and_negative () =
  with_env "MASC_KEEPER_WIP_MAX_PER_REPO" "0" @@ fun () ->
  with_env "MASC_KEEPER_WIP_MAX_PER_GOAL" "-1" @@ fun () ->
  let c = Admission.default_caps () in
  check (option int) "per_repo disabled by 0" None c.Admission.max_per_repo;
  check (option int) "per_goal disabled by negative (clamped to 0)" None c.max_per_goal

let test_default_caps_unparseable_keeps_default () =
  with_env "MASC_KEEPER_WIP_MAX_PER_CATEGORY" "banana" @@ fun () ->
  let c = Admission.default_caps () in
  check (option int) "per_category keeps default on garbage" (Some 4)
    c.Admission.max_per_category

let raises_config_error f =
  try
    ignore (f ());
    false
  with Env_config_core.Config_error _ -> true

let test_default_caps_parse_warn_escalates_malformed_env () =
  with_env "MASC_PARSE_WARN" "1" @@ fun () ->
  with_env "MASC_KEEPER_WIP_MAX_PER_CATEGORY" "banana" @@ fun () ->
  check bool "strict malformed cap raises Config_error" true
    (raises_config_error Admission.default_caps)

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
        ; test_case "keeper_task_claim releases stale owners before WIP admission"
            `Quick
            test_keeper_task_claim_releases_stale_owner_before_wip_admission
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
        ; test_case "old claimed task stays active until owner release" `Quick
            test_old_claimed_task_stays_active_until_owner_release
        ; test_case
            "unparseable claimed_at keeps counting until owner release"
            `Quick
            test_unparseable_claimed_at_keeps_counting_until_owner_release
          ] )
    ; ( "env-configurable caps"
      , [ test_case "unset knobs reproduce historical defaults" `Quick
            test_default_caps_unset_uses_historical_defaults
        ; test_case "positive env value overrides a cap" `Quick
            test_default_caps_positive_env_override
        ; test_case "0/negative disable a cap axis" `Quick
            test_default_caps_disable_via_zero_and_negative
        ; test_case "unparseable value keeps the default" `Quick
            test_default_caps_unparseable_keeps_default
        ; test_case "MASC_PARSE_WARN escalates malformed cap env" `Quick
            test_default_caps_parse_warn_escalates_malformed_env
        ] )
    ]
