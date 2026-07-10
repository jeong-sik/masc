(** Tier C C-5a: smoke test for the externalized behavior prompt
    loader.  Verifies that the demonstration migration
    ([profile_policy]) loads from
    [config/prompts/behavior/*.md] (relative to the repo root, which
    Config_dir_resolver locates via [_build/] proximity) and yields
    non-empty bodies. *)

module Lib = Masc

module WO = Lib.Keeper_world_observation

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else
    let rec loop i =
      i + needle_len <= haystack_len
      && (String.sub haystack i needle_len = needle || loop (i + 1))
    in
    loop 0

let read_file path =
  let path =
    if Filename.is_relative path then
      match Sys.getenv_opt "DUNE_SOURCEROOT" with
      | Some root -> Filename.concat root path
      | None -> path
    else path
  in
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "keeper_schedule_observation_runtime_" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc runtime_toml);
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e

let with_repo_root_cwd f =
  let original_cwd = Sys.getcwd () in
  (* Test runs out of [_build/default/test]; walk up until we find the
     [config/prompts/behavior] anchor that this PR introduces. *)
  let rec find_root dir hops =
    if hops > 8 then None
    else if Sys.file_exists (Filename.concat dir "config/prompts/behavior") then
      Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else find_root parent (hops + 1)
  in
  match find_root original_cwd 0 with
  | None ->
      Alcotest.fail
        "could not locate repo root (config/prompts/behavior) from test cwd"
  | Some root ->
      (* Pin [Config_dir_resolver] to this worktree's [config/]
         directory via [MASC_CONFIG_DIR] (highest-priority resolution
         source) so the test does not depend on the test runner's
         HOME / MASC_BASE_PATH inheritance.  Reset the cached
         resolution so the new env var takes effect. *)
      let prev_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
      let config_dir = Filename.concat root "config" in
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Sys.chdir root;
      Config_dir_resolver.reset ();
      Prompt_registry.clear ();
      Prompt_registry.set_markdown_dir (Filename.concat config_dir "prompts");
      Lib.Prompt_defaults.init ();
      init_runtime_default_for_tests ();
      Fun.protect
        ~finally:(fun () ->
          Sys.chdir original_cwd;
          (match prev_config_dir with
           | Some v -> Unix.putenv "MASC_CONFIG_DIR" v
           | None -> Unix.putenv "MASC_CONFIG_DIR" "");
          Config_dir_resolver.reset ();
          Prompt_registry.clear ())
        f

let turn_intent_bullet_keys =
  [
    Keeper_prompt_names.turn_intent_claim_guidance_a;
    Keeper_prompt_names.turn_intent_claim_guidance_b;
    Keeper_prompt_names.turn_intent_board_activity_guidance;
    Keeper_prompt_names.turn_intent_board_post_guidance;
    Keeper_prompt_names.turn_intent_board_curation_guidance;
    Keeper_prompt_names.turn_intent_broadcast_guidance;
    Keeper_prompt_names.turn_intent_task_create_guidance;
    Keeper_prompt_names.turn_intent_pr_duplicate_search_guidance;
  ]

let task_create_observation : WO.world_observation =
  {
    pending_mentions = [];
    pending_board_events = [];
    pending_scope_messages = [];
    idle_seconds = 1;
    active_goals = [ "goal-test-task-create" ];
    context_ratio = lazy 0.0;
    unclaimed_task_count = 0;
    claimable_task_count = 0;
    provider_capacity_blocked_task_count = 0;
    failed_task_count = 0;
    pending_verification_count = 0;
    scheduled_automation = WO.empty_scheduled_automation_observation;
    backlog_updated_since_last_scheduled_autonomous = false;
    running_keeper_fiber_count = 1;
    connected_surfaces = [];
  }

let meta_for_task_create_prompt () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String "prompt-task-create");
          ("trace_id", `String "trace-prompt-task-create");
          ("goal", `String "test prompt task creation");
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta fixture failed: " ^ err)

let markdown_prompt ?(template_variables = []) ~description body =
  let template_line =
    match template_variables with
    | [] -> []
    | vars -> [ "template_variables: [" ^ String.concat ", " vars ^ "]" ]
  in
  String.concat "\n"
    ([
       "---";
       "description: " ^ description;
       "category: keeper";
     ]
     @ template_line
     @ [
         "---";
         body;
       ])

let with_task_create_prompt_missing f =
  let dir = Filename.temp_file "missing-task-create-prompt" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let write_prompt key ?template_variables body =
    write_file
      (Filename.concat dir (key ^ ".md"))
      (markdown_prompt ?template_variables ~description:("test " ^ key) body)
  in
  write_prompt Keeper_prompt_names.unified_system
    ~template_variables:
      [ "identity_header"; "instructions_block"; "goal_lines" ]
    "{{identity_header}}\n{{instructions_block}}{{goal_lines}}";
  write_prompt Keeper_prompt_names.turn_intent
    ~template_variables:[ "task_create_guidance" ]
    "{{task_create_guidance}}";
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.clear ();
      cleanup_dir dir)
    (fun () ->
      Prompt_registry.clear ();
      Prompt_registry.set_markdown_dir dir;
      Lib.Prompt_defaults.init ();
      f ())

let test_loads_block name expected_substring =
  with_repo_root_cwd (fun () ->
      Lib.Keeper_prompt_external.reset_cache ();
      match Lib.Keeper_prompt_external.get name with
      | Some content ->
          Alcotest.(check bool)
            "non-empty body" true
            (String.length (String.trim content) > 0);
          Alcotest.(check bool)
            "frontmatter stripped" false
            (String.length content >= 3
             && String.sub content 0 3 = "---");
          Alcotest.(check bool)
            "expected body text" true
            (contains_substring content expected_substring)
      | None ->
          Alcotest.fail
            ("expected " ^ name
             ^ ".md to load from config/prompts/behavior/"))

let test_loads_profile_policy () =
  test_loads_block "profile_policy" "reasoning"

let test_loads_continuity_contract () =
  test_loads_block "continuity_contract" "Continuity"

let test_loads_connected_surface_discretion () =
  test_loads_block "connected_surface_discretion" "unread connector lane"

let test_system_prompt_includes_continuity_contract () =
  with_repo_root_cwd (fun () ->
      Lib.Keeper_prompt_external.reset_cache ();
      let prompt =
        Lib.Keeper_prompt.build_keeper_system_prompt
          ~goal:"verify prompt behavior externalization"
          ~instructions:""
          ()
      in
      Alcotest.(check bool)
        "continuity contract present" true
        (contains_substring prompt "When <direct_reply_mode> is present");
      Alcotest.(check bool)
        "constitution still present" true
        (contains_substring prompt "PR merge rules"))

(* Pin the persona [instructions] channel end-to-end at the render boundary. *)
let test_system_prompt_includes_instructions () =
  with_repo_root_cwd (fun () ->
      Lib.Keeper_prompt_external.reset_cache ();
      let sentinel = "SENTINEL_PERSONA_INSTRUCTIONS_4f1c" in
      let prompt =
        Lib.Keeper_prompt.build_keeper_system_prompt
          ~goal:"verify instructions propagation"
          ~instructions:sentinel
          ()
      in
      Alcotest.(check bool)
        "persona instructions reach the rendered system prompt" true
        (contains_substring prompt sentinel))

let test_turn_intent_externalized_bullets_are_markdown_backed () =
  with_repo_root_cwd (fun () ->
      List.iter
        (fun key ->
          let content = Prompt_registry.get_prompt key |> String.trim in
          Alcotest.(check bool)
            ("markdown prompt body present for " ^ key)
            true
            (String.length content > 0))
        turn_intent_bullet_keys)

let test_missing_turn_intent_bullet_renders_config_drift_marker () =
  with_repo_root_cwd (fun () ->
      Masc_test_deps.init_keeper_tool_registry ();
      let meta = meta_for_task_create_prompt () in
      Alcotest.(check bool)
        "task create tool available through policy" true
        (List.mem "keeper_task_create"
           (Lib.Keeper_tool_policy.keeper_allowed_tool_names meta));
      with_task_create_prompt_missing (fun () ->
          let system_prompt, _user_msg =
            Lib.Keeper_unified_prompt.build_prompt
              ~meta
              ~base_path:"/tmp/unused"
              ~observation:task_create_observation
              ()
          in
          Alcotest.(check bool)
            "missing externalized bullet is explicit config drift" true
            (contains_substring system_prompt "Externalized prompt config drift");
          Alcotest.(check bool)
            "missing marker names the prompt key" true
            (contains_substring system_prompt
               ("config/prompts/"
                ^ Keeper_prompt_names.turn_intent_task_create_guidance
                ^ ".md"));
          Alcotest.(check bool)
            "missing externalized bullet does not use in-binary task-create prose"
            false
            (contains_substring system_prompt "Active goal work is present")))

let test_missing_returns_none () =
  with_repo_root_cwd (fun () ->
      Lib.Keeper_prompt_external.reset_cache ();
      match
        Lib.Keeper_prompt_external.get
          "definitely_not_a_real_block_name_xyz_c5a"
      with
      | None -> ()
      | Some _ ->
          Alcotest.fail
            "missing file should return None (caller renders config-drift \
             marker)")

let test_cache_is_used () =
  with_repo_root_cwd (fun () ->
      Lib.Keeper_prompt_external.reset_cache ();
      let first = Lib.Keeper_prompt_external.get "profile_policy" in
      let second = Lib.Keeper_prompt_external.get "profile_policy" in
      Alcotest.(check (option string))
        "cache returns identical content" first second)

let test_source_has_no_generic_behavior_fallbacks () =
  with_repo_root_cwd (fun () ->
      let src = read_file "lib/keeper/keeper_prompt.ml" in
      let unified_prompt_src =
        read_file "lib/keeper/keeper_unified_prompt.ml"
      in
      Alcotest.(check bool)
        "profile policy generic fallback removed" false
        (contains_substring src
           "Maintain high standard of reasoning, factual grounding, and clear communication.");
      Alcotest.(check bool)
        "missing behavior marker present" true
        (contains_substring src "Behavior prompt config drift");
      Alcotest.(check bool)
        "connected surface behavior fallback removed" false
        (contains_substring unified_prompt_src
           "External speakers may share connected surfaces.");
      Alcotest.(check bool)
        "connected surface route-context policy stays externalized" false
        (contains_substring unified_prompt_src
           "Connected surfaces are route context, not shared conversation history");
      Alcotest.(check bool)
        "turn-intent bullets do not use in-binary prose fallback" false
        (contains_substring unified_prompt_src "using in-binary fallback"))

let () =
  Alcotest.run "Keeper_prompt_external"
    [
      ( "load",
        [
          Alcotest.test_case "loads profile_policy" `Quick
            test_loads_profile_policy;
          Alcotest.test_case "loads continuity_contract" `Quick
            test_loads_continuity_contract;
          Alcotest.test_case "loads connected_surface_discretion" `Quick
            test_loads_connected_surface_discretion;
          Alcotest.test_case "system prompt includes continuity_contract"
            `Quick test_system_prompt_includes_continuity_contract;
          Alcotest.test_case "system prompt includes persona instructions"
            `Quick test_system_prompt_includes_instructions;
          Alcotest.test_case
            "turn-intent bullets are markdown-backed"
            `Quick test_turn_intent_externalized_bullets_are_markdown_backed;
          Alcotest.test_case
            "missing turn-intent bullet renders config drift"
            `Quick test_missing_turn_intent_bullet_renders_config_drift_marker;
          Alcotest.test_case "missing returns None" `Quick
            test_missing_returns_none;
          Alcotest.test_case "second lookup uses cache" `Quick
            test_cache_is_used;
          Alcotest.test_case "source has no generic behavior fallbacks"
            `Quick test_source_has_no_generic_behavior_fallbacks;
        ] );
    ]
