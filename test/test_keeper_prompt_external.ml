(** Tier C C-5a: smoke test for the externalized behavior prompt
    loader.  Verifies that the demonstration migration
    ([profile_policy]) loads from
    [config/prompts/behavior/profile_policy.md] (relative to the
    repo root, which Config_dir_resolver locates via [_build/]
    proximity) and yields a non-empty body. *)

module Lib = Masc_mcp

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
      Lib.Config_dir_resolver.reset ();
      Fun.protect
        ~finally:(fun () ->
          Sys.chdir original_cwd;
          (match prev_config_dir with
           | Some v -> Unix.putenv "MASC_CONFIG_DIR" v
           | None -> Unix.putenv "MASC_CONFIG_DIR" "");
          Lib.Config_dir_resolver.reset ())
        f

let test_loads_profile_policy () =
  with_repo_root_cwd (fun () ->
      Lib.Keeper_prompt_external.reset_cache ();
      match Lib.Keeper_prompt_external.get "profile_policy" with
      | Some content ->
          Alcotest.(check bool)
            "non-empty body" true
            (String.length (String.trim content) > 0);
          Alcotest.(check bool)
            "frontmatter stripped" false
            (String.length content >= 3
             && String.sub content 0 3 = "---")
      | None ->
          Alcotest.fail
            "expected profile_policy.md to load from \
             config/prompts/behavior/")

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
            "missing file should return None (caller handles fallback)")

let test_cache_is_used () =
  with_repo_root_cwd (fun () ->
      Lib.Keeper_prompt_external.reset_cache ();
      let first = Lib.Keeper_prompt_external.get "profile_policy" in
      let second = Lib.Keeper_prompt_external.get "profile_policy" in
      Alcotest.(check (option string))
        "cache returns identical content" first second)

let () =
  Alcotest.run "Keeper_prompt_external"
    [
      ( "load",
        [
          Alcotest.test_case "loads profile_policy" `Quick
            test_loads_profile_policy;
          Alcotest.test_case "missing returns None" `Quick
            test_missing_returns_none;
          Alcotest.test_case "second lookup uses cache" `Quick
            test_cache_is_used;
        ] );
    ]
