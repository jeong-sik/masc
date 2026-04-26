(** Tests for the autonomy liberation refactoring (Phases 1-5). *)

module Spawn = Masc_mcp.Spawn
module Agent_tool_surfaces = Masc_mcp.Agent_tool_surfaces
module Keeper_deliberation = Masc_mcp.Keeper_deliberation

(* New modules may not be visible via Masc_mcp wrapper in large libraries
   due to dune's incremental wrapper compilation. Use internal names. *)
module Team_context = Masc_mcp__Team_context
module Prompt_composer = Masc_mcp__Prompt_composer

(** Substring search helper. *)
let contains_s haystack needle =
  let nl = String.length needle in
  let hl = String.length haystack in
  if nl > hl
  then false
  else (
    let found = ref false in
    for i = 0 to hl - nl do
      if (not !found) && String.sub haystack i nl = needle then found := true
    done;
    !found)
;;

(* ── Phase 1: Protocol Liberation ─────────────────────────────── *)

let test_lifecycle_no_strict () =
  let suffix = String.lowercase_ascii Spawn.masc_lifecycle_suffix in
  Alcotest.(check bool) "no 'strictly'" false (contains_s suffix "strictly");
  Alcotest.(check bool) "no 'you must'" false (contains_s suffix "you must");
  Alcotest.(check bool) "contains 'capabilities'" true (contains_s suffix "capabilities")
;;

(* ── Phase 2: Tool Discovery ──────────────────────────────────── *)

let test_build_tool_catalog_worker () =
  let tools = Agent_tool_surfaces.build_tool_catalog ~role:"worker" () in
  Alcotest.(check bool) "non-empty" true (tools <> []);
  Alcotest.(check bool) "has heartbeat" true (List.mem "masc_heartbeat" tools);
  Alcotest.(check bool) "no admin tool" false (List.mem "masc_tool_admin_snapshot" tools)
;;

let test_build_tool_catalog_coordinator () =
  let tools = Agent_tool_surfaces.build_tool_catalog ~role:"coordinator" () in
  Alcotest.(check bool) "non-empty" true (tools <> []);
  Alcotest.(check bool) "has broadcast" true (List.mem "masc_broadcast" tools)
;;

let test_build_tool_catalog_autonomous () =
  let tools = Agent_tool_surfaces.build_tool_catalog ~role:"autonomous" () in
  Alcotest.(check bool) "non-empty" true (tools <> []);
  Alcotest.(check bool) "excludes admin" false (List.mem "masc_tool_admin_snapshot" tools);
  let worker_tools = Agent_tool_surfaces.build_tool_catalog ~role:"worker" () in
  Alcotest.(check bool)
    "more tools than worker"
    true
    (List.length tools >= List.length worker_tools)
;;

(* ── Phase 3: Team Context ────────────────────────────────────── *)

let test_team_context_empty () =
  let ctx = Team_context.empty in
  let section = Team_context.to_prompt_section ctx in
  Alcotest.(check string) "empty goal -> empty section" "" section
;;

let test_team_context_prompt_section () =
  let ctx =
    { Team_context.team_goal = "Build feature X"
    ; prior_decisions = [ "Use OCaml"; "Use Eio" ]
    ; shared_findings = [ "[worker-1] Found bug in module Y" ]
    ; active_workers = [ "worker-1"; "worker-2" ]
    ; task_tree =
        [ { Team_context.task_id = "t1"
          ; title = "Implement"
          ; status = "in_progress"
          ; assignee = Some "worker-1"
          }
        ]
    }
  in
  let section = Team_context.to_prompt_section ctx in
  Alcotest.(check bool) "contains goal" true (contains_s section "Build feature X");
  Alcotest.(check bool) "contains decision" true (contains_s section "Use OCaml");
  Alcotest.(check bool) "contains finding" true (contains_s section "Found bug");
  Alcotest.(check bool) "contains workers" true (contains_s section "worker-1")
;;

(* ── Phase 4: Prompt Composer ─────────────────────────────────── *)

let test_compose_identity () =
  let result =
    Prompt_composer.compose
      [ Prompt_composer.Identity { name = "w1"; role = "dev"; model = "auto" }
      ; Prompt_composer.Task "Do something"
      ]
  in
  Alcotest.(check bool) "has identity" true (contains_s result "Agent: w1");
  Alcotest.(check bool) "has task" true (contains_s result "Do something")
;;

let test_compose_empty_sections_omitted () =
  let result =
    Prompt_composer.compose
      [ Prompt_composer.Guidelines []
      ; Prompt_composer.Task ""
      ; Prompt_composer.FreeText "Hello"
      ]
  in
  Alcotest.(check bool) "only freetext" true (contains_s result "Hello");
  Alcotest.(check bool) "no 'Guidelines'" false (contains_s result "Guidelines")
;;

let test_compose_available_tools () =
  let result =
    Prompt_composer.compose [ Prompt_composer.AvailableTools [ "tool_a"; "tool_b" ] ]
  in
  Alcotest.(check bool) "has tool_a" true (contains_s result "tool_a");
  Alcotest.(check bool) "has tool_b" true (contains_s result "tool_b")
;;

(* ── Phase 5: Autonomous Collaboration ────────────────────────── *)

let test_start_discussion_action () =
  let action =
    Keeper_deliberation.StartDiscussion
      { topic = "architecture"; context = "reviewing module X" }
  in
  let s = Keeper_deliberation.deliberation_action_to_string action in
  Alcotest.(check bool) "contains topic" true (contains_s s "architecture");
  let policy_label = Keeper_deliberation.deliberation_action_to_policy_label action in
  Alcotest.(check string) "policy label" "start_discussion" policy_label
;;

let test_share_finding_action () =
  let action =
    Keeper_deliberation.ShareFinding
      { finding = "module Y has a race condition"; source = "code review" }
  in
  let json = Keeper_deliberation.deliberation_action_to_json action in
  let open Yojson.Safe.Util in
  let typ = json |> member "type" |> to_string in
  Alcotest.(check string) "json type" "share_finding" typ;
  let finding_val = json |> member "finding" |> to_string in
  Alcotest.(check bool) "json finding" true (contains_s finding_val "race condition")
;;

(* ── Phase 2 Integration: End-to-End Wiring ─────────────────── *)

let test_autonomous_tool_count () =
  let tools = Agent_tool_surfaces.build_tool_catalog ~role:"autonomous" () in
  let count = List.length tools in
  Alcotest.(check bool) "at least 15 tools" true (count >= 15);
  let prefixed = Agent_tool_surfaces.prefixed_tool_names tools in
  List.iter
    (fun name ->
       Alcotest.(check bool)
         ("prefixed: " ^ name)
         true
         (String.length name > 11 && String.sub name 0 11 = "mcp__masc__"))
    prefixed
;;

let test_finding_accumulation () =
  let base_path = Filename.concat (Filename.get_temp_dir_name ()) "test_findings_al" in
  let masc_dir = Filename.concat base_path Common.masc_dirname in
  let session_dir = Filename.concat masc_dir "session_test_al" in
  (try Sys.mkdir base_path 0o755 with
   | Sys_error _ -> ());
  (try Sys.mkdir masc_dir 0o755 with
   | Sys_error _ -> ());
  (try Sys.mkdir session_dir 0o755 with
   | Sys_error _ -> ());
  Team_context.add_finding ~base_path ~worker_name:"w1" ~finding:"found issue A";
  Team_context.add_finding ~base_path ~worker_name:"w2" ~finding:"found issue B";
  let findings = Team_context.load_findings ~base_path in
  Alcotest.(check int) "two findings" 2 (List.length findings);
  Alcotest.(check bool)
    "has issue A"
    true
    (List.exists (fun f -> contains_s f "found issue A") findings);
  Alcotest.(check bool)
    "has issue B"
    true
    (List.exists (fun f -> contains_s f "found issue B") findings);
  (* Cleanup *)
  let findings_file = Filename.concat session_dir "shared_findings.jsonl" in
  (try Sys.remove findings_file with
   | Sys_error _ -> ());
  (try Sys.rmdir session_dir with
   | Sys_error _ -> ());
  (try Sys.rmdir masc_dir with
   | Sys_error _ -> ());
  try Sys.rmdir base_path with
  | Sys_error _ -> ()
;;

let test_finding_accumulation_json_escaping () =
  let base_path =
    Filename.concat (Filename.get_temp_dir_name ()) "test_findings_escape"
  in
  let masc_dir = Filename.concat base_path Common.masc_dirname in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove (Filename.concat masc_dir "shared_findings.jsonl") with
       | Sys_error _ -> ());
      (try Sys.rmdir masc_dir with
       | Sys_error _ -> ());
      try Sys.rmdir base_path with
      | Sys_error _ -> ())
    (fun () ->
       (try Sys.mkdir base_path 0o755 with
        | Sys_error _ -> ());
       (try Sys.mkdir masc_dir 0o755 with
        | Sys_error _ -> ());
       Team_context.add_finding
         ~base_path
         ~worker_name:"w\"1"
         ~finding:"quote \" and slash \\\\ and newline\nok";
       let findings = Team_context.load_findings ~base_path in
       Alcotest.(check int) "one escaped finding" 1 (List.length findings);
       Alcotest.(check bool)
         "quote preserved"
         true
         (List.exists
            (fun f -> contains_s f "quote \" and slash \\\\ and newline")
            findings))
;;

let test_team_context_build_renders_findings_without_goal () =
  let base_path =
    Filename.concat (Filename.get_temp_dir_name ()) "test_findings_prompt"
  in
  let masc_dir = Filename.concat base_path Common.masc_dirname in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove (Filename.concat masc_dir "shared_findings.jsonl") with
       | Sys_error _ -> ());
      (try Sys.rmdir masc_dir with
       | Sys_error _ -> ());
      try Sys.rmdir base_path with
      | Sys_error _ -> ())
    (fun () ->
       (try Sys.mkdir base_path 0o755 with
        | Sys_error _ -> ());
       (try Sys.mkdir masc_dir 0o755 with
        | Sys_error _ -> ());
       Team_context.add_finding ~base_path ~worker_name:"w1" ~finding:"render me";
       let ctx = Team_context.build ~base_path in
       let section = Team_context.to_prompt_section ctx in
       Alcotest.(check bool)
         "section rendered without goal"
         true
         (contains_s section "render me"))
;;

let test_scope_default_unchanged () =
  (* Worker tools should remain a small focused set *)
  let worker_tools = Agent_tool_surfaces.build_tool_catalog ~role:"worker" () in
  Alcotest.(check bool) "worker tools < 20" true (List.length worker_tools < 20)
;;

(* ── Test runner ──────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Autonomy Liberation"
    [ ( "phase1_protocol"
      , [ Alcotest.test_case "lifecycle no strict/MUST" `Quick test_lifecycle_no_strict ]
      )
    ; ( "phase2_tool_discovery"
      , [ Alcotest.test_case "worker catalog" `Quick test_build_tool_catalog_worker
        ; Alcotest.test_case
            "coordinator catalog"
            `Quick
            test_build_tool_catalog_coordinator
        ; Alcotest.test_case
            "autonomous catalog"
            `Quick
            test_build_tool_catalog_autonomous
        ] )
    ; ( "phase3_team_context"
      , [ Alcotest.test_case "empty context" `Quick test_team_context_empty
        ; Alcotest.test_case "prompt section" `Quick test_team_context_prompt_section
        ] )
    ; ( "phase4_prompt_composer"
      , [ Alcotest.test_case "compose identity+task" `Quick test_compose_identity
        ; Alcotest.test_case
            "empty sections omitted"
            `Quick
            test_compose_empty_sections_omitted
        ; Alcotest.test_case "available tools" `Quick test_compose_available_tools
        ] )
    ; ( "phase5_collaboration"
      , [ Alcotest.test_case "start discussion" `Quick test_start_discussion_action
        ; Alcotest.test_case "share finding" `Quick test_share_finding_action
        ] )
    ; ( "phase2_integration"
      , [ Alcotest.test_case
            "autonomous tool count >= 15"
            `Quick
            test_autonomous_tool_count
        ; Alcotest.test_case
            "finding accumulation roundtrip"
            `Quick
            test_finding_accumulation
        ; Alcotest.test_case
            "finding accumulation uses valid json escaping"
            `Quick
            test_finding_accumulation_json_escaping
        ; Alcotest.test_case
            "build renders findings without goal"
            `Quick
            test_team_context_build_renders_findings_without_goal
        ; Alcotest.test_case "scope default unchanged" `Quick test_scope_default_unchanged
        ] )
    ]
;;
