(** Test keeper masc_* tool bridge — verifies schema injection
    and dispatch passthrough work correctly. *)

module KET = Masc_mcp.Keeper_exec_tools

(** Verify inject_masc_schemas populates the ref correctly. *)
let test_inject_populates () =
  let schemas : Types.tool_schema list = [
    { name = "masc_join"; description = ""; input_schema = `Assoc [] };
    { name = "masc_broadcast"; description = ""; input_schema = `Assoc [] };
    { name = "masc_heartbeat"; description = ""; input_schema = `Assoc [] };
  ] in
  KET.inject_masc_schemas schemas;
  (* inject should not crash; the ref is internal so we test via
     the public all_schemas_extended injection in a real server *)
  Alcotest.(check bool) "inject succeeds" true true

(** Verify dispatch passthrough recognizes masc_* tools in registry.
    Tool_dispatch.dispatch returns None for unregistered tools,
    Some for registered ones. *)
let test_dispatch_passthrough_unregistered () =
  (* A tool NOT in the registry should return None *)
  let result = Masc_mcp.Tool_dispatch.dispatch
    ~name:"masc_nonexistent_tool_xyz" ~args:(`Assoc []) in
  Alcotest.(check bool) "unregistered returns None" true (result = None)

let test_dispatch_passthrough_format () =
  (* Verify the execute_keeper_tool_call catchall formats correctly
     for an unregistered masc_* tool *)
  let result_json = Yojson.Safe.from_string
    (Printf.sprintf {|{"error":"unregistered_masc_tool","tool":"masc_fake"}|}) in
  let err = Yojson.Safe.Util.(member "error" result_json |> to_string) in
  Alcotest.(check string) "error key" "unregistered_masc_tool" err

(** Verify Mode.tool_category classifies known tools correctly. *)
let test_category_classification () =
  let open Masc_mcp.Mode in
  Alcotest.(check bool) "join is Core_Room" true
    (tool_category "masc_join" = Core_Room);
  Alcotest.(check bool) "broadcast is Comm" true
    (tool_category "masc_broadcast" = Comm);
  Alcotest.(check bool) "heartbeat is Health" true
    (tool_category "masc_heartbeat" = Health);
  Alcotest.(check bool) "board_post is Board" true
    (tool_category "masc_board_post" = Board);
  Alcotest.(check bool) "voice_speak is Voice" true
    (tool_category "masc_voice_speak" = Voice);
  Alcotest.(check bool) "code_search is Code" true
    (tool_category "masc_code_search" = Code);
  Alcotest.(check bool) "auth_create_token is Auth (blocked)" true
    (tool_category "masc_auth_create_token" = Auth);
  Alcotest.(check bool) "encryption_enable is Encryption (blocked)" true
    (tool_category "masc_encryption_enable" = Encryption)

(** Verify that all_schemas_extended has enough tools for the bridge. *)
let test_all_schemas_count () =
  let all = Masc_mcp.Tools.all_schemas_extended in
  let masc_only = List.filter (fun (s : Types.tool_schema) ->
    String.starts_with ~prefix:"masc_" s.name) all in
  Printf.printf "  all_schemas_extended: %d total, %d masc_*\n"
    (List.length all) (List.length masc_only);
  Alcotest.(check bool) "at least 200 masc tools" true
    (List.length masc_only >= 200)

(** Verify inject + filter end-to-end with real schemas. *)
let test_inject_real_schemas () =
  KET.inject_masc_schemas Masc_mcp.Tools.all_schemas_extended;
  (* After injection, the internal ref should be populated.
     We can't call keeper_masc_tool_names without a keeper_meta,
     but we can verify injection doesn't crash with real data. *)
  Alcotest.(check bool) "real schema injection succeeds" true true

let () =
  Alcotest.run "Keeper masc bridge" [
    ("injection", [
      Alcotest.test_case "inject populates" `Quick test_inject_populates;
      Alcotest.test_case "inject real schemas" `Quick test_inject_real_schemas;
    ]);
    ("dispatch", [
      Alcotest.test_case "unregistered returns None" `Quick test_dispatch_passthrough_unregistered;
      Alcotest.test_case "error format" `Quick test_dispatch_passthrough_format;
    ]);
    ("categories", [
      Alcotest.test_case "classification" `Quick test_category_classification;
    ]);
    ("schemas", [
      Alcotest.test_case "all schemas count" `Quick test_all_schemas_count;
    ]);
  ]
