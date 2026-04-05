open Alcotest

module KTPC = Masc_mcp.Keeper_tool_policy_config

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

let () =
  run "Keeper_tool_policy_config"
    [
      ( "load",
        [
          test_case "falls back to resolved config dir" `Quick
            test_load_falls_back_to_resolved_config_dir;
        ] );
    ]
