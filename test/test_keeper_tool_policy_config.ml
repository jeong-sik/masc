open Alcotest

module KTPC = Masc_mcp.Keeper_tool_policy_config

let test_load_falls_back_to_resolved_config_dir () =
  let missing_base_path =
    Filename.concat (Filename.get_temp_dir_name ()) "keeper-tool-policy-config-missing"
  in
  match KTPC.load ~base_path:missing_base_path with
  | Ok cfg ->
      let presets = KTPC.preset_names cfg in
      check bool "loads config via fallback candidates" true
        (List.mem "full" presets && List.mem "messaging" presets)
  | Error msg ->
      fail
        (Printf.sprintf
           "expected fallback config load to succeed for base_path=%s: %s"
           missing_base_path msg)

let () =
  run "Keeper_tool_policy_config"
    [
      ( "load",
        [
          test_case "falls back to resolved config dir" `Quick
            test_load_falls_back_to_resolved_config_dir;
        ] );
    ]
