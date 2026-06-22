(** Tier C C-5a: smoke test for the externalized behavior prompt
    loader.  Verifies that the demonstration migration
    ([profile_policy]) loads from
    [config/prompts/behavior/*.md] (relative to the repo root, which
    Config_dir_resolver locates via [_build/] proximity) and yields
    non-empty bodies. *)

module Lib = Masc

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
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

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
      Fun.protect
        ~finally:(fun () ->
          Sys.chdir original_cwd;
          (match prev_config_dir with
           | Some v -> Unix.putenv "MASC_CONFIG_DIR" v
           | None -> Unix.putenv "MASC_CONFIG_DIR" "");
          Config_dir_resolver.reset ();
          Prompt_registry.clear ())
        f

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
          ~short_goal:"keep continuity contract loaded"
          ~mid_goal:"reduce source literal behavior blocks"
          ~long_goal:"keep prompt config operator-tunable"
          ~instructions:""
          ()
      in
      Alcotest.(check bool)
        "continuity contract present" true
        (contains_substring prompt "When <direct_reply_mode> is present");
      Alcotest.(check bool)
        "constitution still present" true
        (contains_substring prompt "PR merge rules"))

let test_system_prompt_includes_state_block_template_anchor () =
  with_repo_root_cwd (fun () ->
      Lib.Keeper_prompt_external.reset_cache ();
      let prompt =
        Lib.Keeper_prompt.build_keeper_system_prompt
          ~goal:"verify prompt anchors"
          ~short_goal:"keep state template anchored"
          ~mid_goal:"avoid noisy recovery fallback"
          ~long_goal:"keep continuity prompt stable"
          ~instructions:""
          ()
      in
      Alcotest.(check bool)
        "state block template anchor present" true
        (contains_substring prompt "State block template");
      Alcotest.(check bool)
        "normal prompt does not need recovery fallback" false
        (contains_substring prompt "Recovery guard"))

(* RFC-0282 self_model de-structure folded will/needs/desires into the persona
   `instructions` channel. This pins that channel end-to-end at the render
   boundary: the [instructions] argument must reach the built system prompt
   verbatim. Without this, a future template change that drops the instructions
   render would silently strip persona content (the deleted
   test_keeper_prompt_personality_field_aggregation used to guard the old
   will/needs/desires block). Field-level IO tests don't cover propagation;
   this is the minimal channel pin (not an LLM-behavior A/B). *)
let test_system_prompt_includes_instructions () =
  with_repo_root_cwd (fun () ->
      Lib.Keeper_prompt_external.reset_cache ();
      let sentinel = "SENTINEL_PERSONA_INSTRUCTIONS_4f1c" in
      let prompt =
        Lib.Keeper_prompt.build_keeper_system_prompt
          ~goal:"verify instructions propagation"
          ~short_goal:"keep persona instructions in prompt"
          ~mid_goal:"guard the folded self_model channel"
          ~long_goal:"keep persona content reaching the LLM"
          ~instructions:sentinel
          ()
      in
      Alcotest.(check bool)
        "persona instructions reach the rendered system prompt" true
        (contains_substring prompt sentinel))

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
        "continuity generic fallback removed" false
        (contains_substring src
           "Continuity and any end-of-reply STATE formatting requirements apply");
      Alcotest.(check bool)
        "missing behavior marker present" true
        (contains_substring src "Behavior prompt config drift");
      (* RFC-0282 removed the will/needs/desires self_model triple and the
         per-field personality config-drift marker along with it; only the
         behavior-prompt drift marker above remains. *)
      Alcotest.(check bool)
        "connected surface behavior fallback removed" false
        (contains_substring unified_prompt_src
           "External speakers may share connected surfaces.");
      Alcotest.(check bool)
        "connected surface route-context policy stays externalized" false
        (contains_substring unified_prompt_src
           "Connected surfaces are route context, not shared conversation history"))

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
          Alcotest.test_case
            "system prompt includes state block template anchor" `Quick
            test_system_prompt_includes_state_block_template_anchor;
          Alcotest.test_case "system prompt includes persona instructions"
            `Quick test_system_prompt_includes_instructions;
          Alcotest.test_case "missing returns None" `Quick
            test_missing_returns_none;
          Alcotest.test_case "second lookup uses cache" `Quick
            test_cache_is_used;
          Alcotest.test_case "source has no generic behavior fallbacks"
            `Quick test_source_has_no_generic_behavior_fallbacks;
        ] );
    ]
