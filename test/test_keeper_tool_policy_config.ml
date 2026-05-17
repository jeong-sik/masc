open Alcotest

module KTPC = Masc_mcp.Keeper_tool_policy_config

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let with_cwd path f =
  let saved = Sys.getcwd () in
  Unix.chdir path;
  Fun.protect ~finally:(fun () -> Unix.chdir saved) f

let test_load_falls_back_to_resolved_config_dir () =
  (* Use the real project root so config/tool_policy.toml is found *)
  let base_path = Masc_test_deps.find_project_root () in
  match KTPC.load ~base_path with
  | Ok cfg ->
      let presets = KTPC.preset_names cfg in
      check bool "loads config from project root" true
        (List.mem "full" presets && List.mem "messaging" presets)
  | Error msg ->
      fail
        (Printf.sprintf
           "expected config load to succeed for base_path=%s: %s"
           base_path msg)

let test_load_honors_masc_config_dir_override () =
  with_temp_dir "tool-policy-config" @@ fun root ->
  let source_root = Masc_test_deps.find_project_root () in
  let config_dir = Filename.concat root "custom-config" in
  mkdir_p config_dir;
  let source_policy = Filename.concat source_root "config/tool_policy.toml" in
  let target_policy = Filename.concat config_dir "tool_policy.toml" in
  Out_channel.with_open_bin target_policy (fun oc ->
      output_string oc (read_file source_policy));
  with_env "MASC_CONFIG_DIR" (Some config_dir) @@ fun () ->
  match KTPC.load ~base_path:"/tmp/unrelated-base-path" with
  | Ok cfg ->
      let presets = KTPC.preset_names cfg in
      check bool "loads config from MASC_CONFIG_DIR override" true
        (List.mem "full" presets && List.mem "messaging" presets)
  | Error msg ->
      fail
        (Printf.sprintf
           "expected config load to succeed for override config_dir=%s: %s"
           config_dir msg)

let test_load_anchors_resolution_to_base_path_over_cwd_candidate () =
  with_temp_dir "tool-policy-build-root" @@ fun fake_build_root ->
  let source_root = Masc_test_deps.find_project_root () in
  let fake_config_dir = Filename.concat fake_build_root "config" in
  mkdir_p fake_config_dir;
  write_file (Filename.concat fake_config_dir "cascade.toml") "";
  with_env "MASC_CONFIG_DIR" None @@ fun () ->
  with_cwd fake_build_root @@ fun () ->
  match KTPC.load ~base_path:source_root with
  | Ok cfg ->
      let presets = KTPC.preset_names cfg in
      check bool "ignores cwd-only config candidate without tool_policy" true
        (List.mem "full" presets && List.mem "messaging" presets)
  | Error msg ->
      fail
        (Printf.sprintf
           "expected config load to use base_path=%s instead of cwd=%s: %s"
           source_root fake_build_root msg)

let test_load_normalizes_legacy_fs_tool_names () =
  with_temp_dir "tool-policy-legacy-tools" @@ fun root ->
  let config_dir = Filename.concat root "config" in
  mkdir_p config_dir;
  write_file
    (Filename.concat config_dir "tool_policy.toml")
    {|
[groups.legacy]
tools = ["keeper_fs_write", "keeper_fs_delete", "keeper_fs_edit"]

[masc.legacy]
tools = ["keeper_fs_write", "keeper_fs_delete", "masc_status"]

[presets.legacy]
groups = ["legacy"]
masc_groups = ["legacy"]
masc_tools = ["keeper_fs_write", "keeper_fs_delete", "masc_status"]
|};
  match KTPC.load ~base_path:root with
  | Error msg -> fail ("expected legacy policy config to load: " ^ msg)
  | Ok cfg ->
      let assert_no_legacy label tools =
        check bool (label ^ " drops keeper_fs_write") false
          (List.mem "keeper_fs_write" tools);
        check bool (label ^ " drops keeper_fs_delete") false
          (List.mem "keeper_fs_delete" tools);
        check bool (label ^ " keeps canonical fs_edit") true
          (List.mem "keeper_fs_edit" tools)
      in
      (match KTPC.resolve_group cfg "legacy" with
      | Some tools -> assert_no_legacy "group" tools
      | None -> fail "legacy group missing");
      assert_no_legacy "masc groups" (KTPC.all_masc_tools cfg);
      (match KTPC.resolve_preset cfg "legacy" () with
      | Some (KTPC.Subset tools) -> assert_no_legacy "preset" tools
      | Some KTPC.All_candidates -> fail "legacy preset should be explicit subset"
      | None -> fail "legacy preset missing")

(* ── preset_can_satisfy tests ───────────────────────────────── *)

let load_config () =
  let base_path = Masc_test_deps.find_project_root () in
  match KTPC.load ~base_path with
  | Ok cfg -> cfg
  | Error msg -> fail (Printf.sprintf "config load failed: %s" msg)

let test_same_preset_satisfies () =
  let cfg = load_config () in
  check bool "same preset satisfies itself" true
    (KTPC.preset_can_satisfy cfg ~agent_preset:"delivery" ~required_preset:"delivery");
  check bool "social satisfies social" true
    (KTPC.preset_can_satisfy cfg ~agent_preset:"social" ~required_preset:"social")

let test_social_cannot_satisfy_delivery () =
  let cfg = load_config () in
  check bool "social cannot satisfy delivery" false
    (KTPC.preset_can_satisfy cfg ~agent_preset:"social" ~required_preset:"delivery")

let test_delivery_satisfies_coding () =
  let cfg = load_config () in
  (* delivery is a superset of coding — includes all coding tools plus autoresearch *)
  check bool "delivery satisfies coding" true
    (KTPC.preset_can_satisfy cfg ~agent_preset:"delivery" ~required_preset:"coding")

let test_goal_lifecycle_group_routes_to_goal_capable_presets () =
  let cfg = load_config () in
  let required =
    [
      "masc_goal_list";
      "masc_goal_upsert";
      "masc_goal_transition";
      "masc_goal_verify";
      "masc_coordination_fsm_snapshot";
    ]
  in
  List.iter
    (fun preset ->
      match KTPC.resolve_preset cfg preset () with
      | Some (KTPC.Subset tools) ->
          List.iter
            (fun tool ->
              check bool (preset ^ " includes " ^ tool) true (List.mem tool tools))
            required
      | Some KTPC.All_candidates -> ()
      | None -> fail ("missing preset " ^ preset))
    [ "dispatch"; "coding"; "research"; "delivery" ]

let test_full_satisfies_anything () =
  let cfg = load_config () in
  check bool "full satisfies delivery" true
    (KTPC.preset_can_satisfy cfg ~agent_preset:"full" ~required_preset:"delivery");
  check bool "full satisfies social" true
    (KTPC.preset_can_satisfy cfg ~agent_preset:"full" ~required_preset:"social");
  check bool "full satisfies coding" true
    (KTPC.preset_can_satisfy cfg ~agent_preset:"full" ~required_preset:"coding")

let test_minimal_cannot_satisfy_social () =
  let cfg = load_config () in
  check bool "minimal cannot satisfy social" false
    (KTPC.preset_can_satisfy cfg ~agent_preset:"minimal" ~required_preset:"social")

let test_unknown_preset_returns_false () =
  let cfg = load_config () in
  check bool "unknown agent preset cannot satisfy delivery" false
    (KTPC.preset_can_satisfy cfg ~agent_preset:"nonexistent" ~required_preset:"delivery");
  check bool "any preset cannot satisfy unknown required" false
    (KTPC.preset_can_satisfy cfg ~agent_preset:"delivery" ~required_preset:"nonexistent")

let () =
  run "Keeper_tool_policy_config"
    [
      ( "load",
        [
          test_case "falls back to resolved config dir" `Quick
            test_load_falls_back_to_resolved_config_dir;
          test_case "honors MASC_CONFIG_DIR override" `Quick
            test_load_honors_masc_config_dir_override;
          test_case "anchors resolution to base_path over cwd candidate" `Quick
            test_load_anchors_resolution_to_base_path_over_cwd_candidate;
          test_case "normalizes legacy fs tool names" `Quick
            test_load_normalizes_legacy_fs_tool_names;
        ] );
      ( "preset_can_satisfy",
        [
          test_case "same preset satisfies" `Quick test_same_preset_satisfies;
          test_case "social cannot satisfy delivery" `Quick test_social_cannot_satisfy_delivery;
          test_case "delivery satisfies coding" `Quick test_delivery_satisfies_coding;
          test_case "goal lifecycle routes to goal-capable presets" `Quick
            test_goal_lifecycle_group_routes_to_goal_capable_presets;
          test_case "full satisfies anything" `Quick test_full_satisfies_anything;
          test_case "minimal cannot satisfy social" `Quick test_minimal_cannot_satisfy_social;
          test_case "unknown preset returns false" `Quick test_unknown_preset_returns_false;
        ] );
    ]
