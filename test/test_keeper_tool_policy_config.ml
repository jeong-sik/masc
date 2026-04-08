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

(* ── task required_preset serialization round-trip ──────────── *)

let test_task_required_preset_roundtrip () =
  let task : Types.task = {
    id = "test-001"; title = "Test"; description = "";
    task_status = Todo; priority = 3; files = [];
    created_at = "2026-01-01T00:00:00Z";
    worktree = None;
    required_role = Types_core.Unassigned;
    required_preset = Some "delivery";
    stage = None; contract = None; handoff_context = None;
  } in
  let json = Types.task_to_yojson task in
  match Types.task_of_yojson json with
  | Ok parsed ->
    check (option string) "required_preset round-trips" (Some "delivery") parsed.required_preset
  | Error e -> fail (Printf.sprintf "task parse failed: %s" e)

let test_task_required_preset_none_compat () =
  let task : Types.task = {
    id = "test-002"; title = "Test"; description = "";
    task_status = Todo; priority = 3; files = [];
    created_at = "2026-01-01T00:00:00Z";
    worktree = None;
    required_role = Types_core.Unassigned;
    required_preset = None;
    stage = None; contract = None; handoff_context = None;
  } in
  let json = Types.task_to_yojson task in
  let json_str = Yojson.Safe.to_string json in
  check bool "None required_preset not in JSON" true
    (not (String.contains json_str (Char.chr 114) && Re.execp (Re.Pcre.re "required_preset" |> Re.compile) json_str));
  match Types.task_of_yojson json with
  | Ok parsed ->
    check (option string) "None round-trips" None parsed.required_preset
  | Error e -> fail (Printf.sprintf "task parse failed: %s" e)

let test_task_backward_compat_no_field () =
  (* Simulate old JSON without required_preset field *)
  let json = `Assoc [
    ("id", `String "old-001");
    ("title", `String "Old task");
    ("description", `String "");
    ("priority", `Int 3);
    ("files", `List []);
    ("created_at", `String "2026-01-01T00:00:00Z");
    ("status", `String "todo");
  ] in
  match Types.task_of_yojson json with
  | Ok parsed ->
    check (option string) "missing field parses as None" None parsed.required_preset
  | Error e -> fail (Printf.sprintf "backward compat failed: %s" e)

let () =
  run "Keeper_tool_policy_config"
    [
      ( "load",
        [
          test_case "falls back to resolved config dir" `Quick
            test_load_falls_back_to_resolved_config_dir;
        ] );
      ( "preset_can_satisfy",
        [
          test_case "same preset satisfies" `Quick test_same_preset_satisfies;
          test_case "social cannot satisfy delivery" `Quick test_social_cannot_satisfy_delivery;
          test_case "delivery satisfies coding" `Quick test_delivery_satisfies_coding;
          test_case "full satisfies anything" `Quick test_full_satisfies_anything;
          test_case "minimal cannot satisfy social" `Quick test_minimal_cannot_satisfy_social;
          test_case "unknown preset returns false" `Quick test_unknown_preset_returns_false;
        ] );
      ( "task_required_preset",
        [
          test_case "round-trip with Some" `Quick test_task_required_preset_roundtrip;
          test_case "round-trip with None" `Quick test_task_required_preset_none_compat;
          test_case "backward compat no field" `Quick test_task_backward_compat_no_field;
        ] );
    ]
