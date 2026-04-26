(** Coverage tests for Tool_shard — dynamic tool sharding for MASC agents.

    Tests shard types, predefined shards, grant/revoke logic,
    tools_of_shards composition, agent shard state, execute dispatch,
    and MCP schemas.

    Pure synchronous tests — no Eio or network required. *)

module Tool_shard = Masc_mcp.Tool_shard
module Types = Types

let get_json_assoc key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Assoc assoc) -> Some assoc
     | _ -> None)
  | _ -> None
;;

(* ============================================================
   Predefined shard tests
   ============================================================ *)

let test_shard_base_exists () =
  match Tool_shard.get_shard "base" with
  | Some s ->
    Alcotest.(check string) "name" "base" s.Tool_shard.name;
    Alcotest.(check bool) "not removable" false s.Tool_shard.removable;
    Alcotest.(check bool) "has tools" true (List.length s.Tool_shard.tools > 0)
  | None -> Alcotest.fail "base shard not found"
;;

let test_shard_board_exists () =
  match Tool_shard.get_shard "board" with
  | Some s ->
    Alcotest.(check bool) "removable" true s.Tool_shard.removable;
    Alcotest.(check bool) "has tools" true (List.length s.Tool_shard.tools >= 1)
  | None -> Alcotest.fail "board shard not found"
;;

let test_shard_filesystem_exists () =
  match Tool_shard.get_shard "filesystem" with
  | Some s ->
    Alcotest.(check bool) "removable" true s.Tool_shard.removable;
    Alcotest.(check bool) "has tools" true (List.length s.Tool_shard.tools >= 1);
    let names = List.map (fun (t : Types.tool_schema) -> t.name) s.tools in
    Alcotest.(check bool) "contains fs_read" true (List.mem "keeper_fs_read" names);
    Alcotest.(check bool) "contains fs_edit" true (List.mem "keeper_fs_edit" names)
  | None -> Alcotest.fail "filesystem shard not found"
;;

let test_shard_shell_exists () =
  match Tool_shard.get_shard "shell" with
  | Some s ->
    Alcotest.(check bool) "removable" true s.Tool_shard.removable;
    Alcotest.(check bool) "has tools" true (List.length s.Tool_shard.tools >= 1)
  | None -> Alcotest.fail "shell shard not found"
;;

let test_shard_governance_removed () =
  Alcotest.(check bool)
    "governance shard removed"
    true
    (Option.is_none (Tool_shard.get_shard "governance"))
;;

let test_shard_coding_exists () =
  match Tool_shard.get_shard "coding" with
  | Some s ->
    Alcotest.(check bool) "removable" true s.Tool_shard.removable;
    Alcotest.(check bool) "has tools" true (List.length s.Tool_shard.tools >= 1);
    let names = List.map (fun (t : Types.tool_schema) -> t.name) s.tools in
    (* keeper_bash is the coding shard's shell bridge.
       keeper_shell (incl. op=gh) lives in shard_shell, not coding. *)
    Alcotest.(check bool) "contains keeper_bash" true (List.mem "keeper_bash" names);
    Alcotest.(check bool)
      "contains worktree_create"
      true
      (List.mem "masc_worktree_create" names);
    Alcotest.(check bool) "contains code_search" true (List.mem "masc_code_search" names)
  | None -> Alcotest.fail "coding shard not found"
;;

let test_coding_in_defaults () =
  Alcotest.(check bool)
    "coding in defaults"
    true
    (List.mem "coding" Tool_shard.default_shard_names)
;;

let test_shard_voice_exists () =
  match Tool_shard.get_shard "voice" with
  | Some s ->
    Alcotest.(check bool) "removable" true s.Tool_shard.removable;
    Alcotest.(check bool) "has tools" true (List.length s.Tool_shard.tools >= 1)
  | None -> Alcotest.fail "voice shard not found"
;;

let test_shard_unknown () =
  Alcotest.(check bool)
    "unknown returns None"
    true
    (Tool_shard.get_shard "nonexistent" = None)
;;

let test_all_shards_count () =
  let all = Tool_shard.list_all_shards () in
  Alcotest.(check bool) "at least 8 predefined shards" true (List.length all >= 8)
;;

(* ============================================================
   default_shard_names tests
   ============================================================ *)

let test_default_shard_names () =
  let defaults = Tool_shard.default_shard_names in
  (* All shards are now in defaults (mode removal: every keeper gets all tools) *)
  Alcotest.(check bool) "at least 7 defaults" true (List.length defaults >= 7);
  Alcotest.(check bool) "base in defaults" true (List.mem "base" defaults);
  (* governance shard removed; must not appear in defaults *)
  Alcotest.(check bool)
    "governance not in defaults"
    false
    (List.mem "governance" defaults);
  Alcotest.(check bool) "coding in defaults" true (List.mem "coding" defaults);
  Alcotest.(check bool) "autoresearch in defaults" true (List.mem "autoresearch" defaults);
  Alcotest.(check bool)
    "weather removed from defaults"
    false
    (List.mem "weather" defaults);
  (* voice still not in defaults: gated by policy_voice_enabled boolean *)
  Alcotest.(check bool) "voice not in defaults" false (List.mem "voice" defaults)
;;

(* ============================================================
   tools_of_shards tests
   ============================================================ *)

let test_tools_of_shards_empty () =
  let tools = Tool_shard.tools_of_shards [] in
  Alcotest.(check int) "no shards → no tools" 0 (List.length tools)
;;

let test_tools_of_shards_single () =
  let tools = Tool_shard.tools_of_shards [ "base" ] in
  Alcotest.(check bool) "base has tools" true (List.length tools >= 1)
;;

let test_tools_of_shards_multiple () =
  let base_count = List.length (Tool_shard.tools_of_shards [ "base" ]) in
  let board_count = List.length (Tool_shard.tools_of_shards [ "board" ]) in
  let combined = Tool_shard.tools_of_shards [ "base"; "board" ] in
  Alcotest.(check int)
    "base+board = sum"
    (base_count + board_count)
    (List.length combined)
;;

let test_tools_of_shards_unknown_ignored () =
  let expected = Tool_shard.tools_of_shards [ "base"; "board" ] in
  let with_unknown = Tool_shard.tools_of_shards [ "base"; "doesnt_exist"; "board" ] in
  Alcotest.(check int)
    "unknown shard ignored"
    (List.length expected)
    (List.length with_unknown)
;;

let test_keeper_model_tools_count () =
  let tools = Tool_shard.keeper_model_tools in
  (* keeper_model_tools = tools_of_shards default_shard_names;
     verify it equals the sum of individual default shards.
     Standalone keeper schemas (keeper_tool_search) are added downstream
     in keeper_tool_policy.keeper_default_model_tools, not here. *)
  let expected = Tool_shard.tools_of_shards Tool_shard.default_shard_names in
  Alcotest.(check int)
    "matches default shards sum"
    (List.length expected)
    (List.length tools);
  Alcotest.(check bool) "has tools" true (List.length tools >= 1)
;;

(* ============================================================
   grant_shard tests
   ============================================================ *)

let test_grant_known_shard () =
  let active = [ "base" ] in
  match Tool_shard.grant_shard active "board" with
  | Ok new_shards ->
    Alcotest.(check int) "now 2 shards" 2 (List.length new_shards);
    Alcotest.(check bool) "board added" true (List.mem "board" new_shards)
  | Error _ -> Alcotest.fail "should succeed"
;;

let test_grant_unknown_shard () =
  match Tool_shard.grant_shard [ "base" ] "fantasy" with
  | Ok _ -> Alcotest.fail "should fail"
  | Error msg ->
    Alcotest.(check bool)
      "mentions unknown"
      true
      (String.lowercase_ascii msg
       |> fun s ->
       try
         ignore (Str.search_forward (Str.regexp_string "unknown") s 0);
         true
       with
       | Not_found -> false)
;;

let test_grant_already_granted () =
  match Tool_shard.grant_shard [ "base"; "board" ] "board" with
  | Ok _ -> Alcotest.fail "should fail"
  | Error msg ->
    Alcotest.(check bool)
      "mentions already"
      true
      (String.lowercase_ascii msg
       |> fun s ->
       try
         ignore (Str.search_forward (Str.regexp_string "already") s 0);
         true
       with
       | Not_found -> false)
;;

(* ============================================================
   revoke_shard tests
   ============================================================ *)

let test_revoke_removable () =
  let active = [ "base"; "board"; "shell" ] in
  match Tool_shard.revoke_shard active "board" with
  | Ok new_shards ->
    Alcotest.(check int) "now 2" 2 (List.length new_shards);
    Alcotest.(check bool) "board removed" false (List.mem "board" new_shards)
  | Error _ -> Alcotest.fail "should succeed"
;;

let test_revoke_non_removable () =
  match Tool_shard.revoke_shard [ "base"; "board" ] "base" with
  | Ok _ -> Alcotest.fail "should fail"
  | Error msg ->
    Alcotest.(check bool)
      "mentions non-removable"
      true
      (String.lowercase_ascii msg
       |> fun s ->
       try
         ignore (Str.search_forward (Str.regexp_string "remov") s 0);
         true
       with
       | Not_found -> false)
;;

let test_revoke_not_granted () =
  match Tool_shard.revoke_shard [ "base" ] "shell" with
  | Ok _ -> Alcotest.fail "should fail"
  | Error msg ->
    Alcotest.(check bool)
      "mentions not granted"
      true
      (String.lowercase_ascii msg
       |> fun s ->
       try
         ignore (Str.search_forward (Str.regexp_string "not") s 0);
         true
       with
       | Not_found -> false)
;;

let test_revoke_unknown () =
  match Tool_shard.revoke_shard [ "base" ] "fantasy" with
  | Ok _ -> Alcotest.fail "should fail"
  | Error msg ->
    Alcotest.(check bool)
      "mentions unknown"
      true
      (String.lowercase_ascii msg
       |> fun s ->
       try
         ignore (Str.search_forward (Str.regexp_string "unknown") s 0);
         true
       with
       | Not_found -> false)
;;

(* ============================================================
   agent shard state tests
   ============================================================ *)

let test_get_agent_shards_default () =
  (* Unknown agent gets default shards *)
  let shards = Tool_shard.get_agent_shards "new-agent-never-seen" in
  let defaults = Tool_shard.default_shard_names in
  Alcotest.(check int) "matches default count" (List.length defaults) (List.length shards)
;;

let test_set_get_agent_shards () =
  Tool_shard.remove_agent_shards "test-agent-x";
  Tool_shard.set_agent_shards "test-agent-x" [ "base"; "shell" ];
  let shards = Tool_shard.get_agent_shards "test-agent-x" in
  Alcotest.(check int) "2 shards" 2 (List.length shards);
  Alcotest.(check bool) "sorted" true (shards = List.sort String.compare shards);
  (* Cleanup *)
  Tool_shard.remove_agent_shards "test-agent-x"
;;

(* ============================================================
   execute (MCP dispatch) tests
   ============================================================ *)

let test_execute_unknown_tool () =
  let ok, _json = Tool_shard.execute "unknown_tool" (`Assoc []) in
  Alcotest.(check bool) "fails" false ok
;;

let test_execute_tool_list () =
  let ok, json = Tool_shard.execute "masc_tool_list" (`Assoc []) in
  Alcotest.(check bool) "succeeds" true ok;
  let shards = Yojson.Safe.Util.(member "shards" json |> to_list) in
  let all = Tool_shard.list_all_shards () in
  Alcotest.(check int) "matches list_all_shards" (List.length all) (List.length shards)
;;

let test_execute_tool_list_with_agent () =
  Tool_shard.remove_agent_shards "test-ex";
  Tool_shard.set_agent_shards "test-ex" [ "base"; "board" ];
  let ok, json =
    Tool_shard.execute "masc_tool_list" (`Assoc [ "agent_name", `String "test-ex" ])
  in
  Alcotest.(check bool) "succeeds" true ok;
  let active = Yojson.Safe.Util.(member "active_shards" json |> to_list) in
  Alcotest.(check int) "2 active" 2 (List.length active);
  Tool_shard.remove_agent_shards "test-ex"
;;

let test_execute_grant () =
  Tool_shard.remove_agent_shards "test-grant";
  Tool_shard.set_agent_shards "test-grant" [ "base" ];
  let ok, json =
    Tool_shard.execute
      "masc_tool_grant"
      (`Assoc [ "agent_name", `String "test-grant"; "shard_name", `String "board" ])
  in
  Alcotest.(check bool) "succeeds" true ok;
  let status = Yojson.Safe.Util.(member "status" json |> to_string) in
  Alcotest.(check string) "granted" "granted" status;
  Tool_shard.remove_agent_shards "test-grant"
;;

let test_execute_grant_missing_params () =
  let ok, json = Tool_shard.execute "masc_tool_grant" (`Assoc []) in
  Alcotest.(check bool) "fails" false ok;
  let status = Yojson.Safe.Util.(member "status" json |> to_string) in
  Alcotest.(check string) "error status" "error" status
;;

let test_execute_revoke () =
  Tool_shard.remove_agent_shards "test-revoke";
  Tool_shard.set_agent_shards "test-revoke" [ "base"; "board"; "shell" ];
  let ok, json =
    Tool_shard.execute
      "masc_tool_revoke"
      (`Assoc [ "agent_name", `String "test-revoke"; "shard_name", `String "board" ])
  in
  Alcotest.(check bool) "succeeds" true ok;
  let status = Yojson.Safe.Util.(member "status" json |> to_string) in
  Alcotest.(check string) "revoked" "revoked" status;
  Tool_shard.remove_agent_shards "test-revoke"
;;

let test_execute_revoke_non_removable () =
  Tool_shard.remove_agent_shards "test-rev-base";
  Tool_shard.set_agent_shards "test-rev-base" [ "base"; "board" ];
  let ok, json =
    Tool_shard.execute
      "masc_tool_revoke"
      (`Assoc [ "agent_name", `String "test-rev-base"; "shard_name", `String "base" ])
  in
  Alcotest.(check bool) "fails" false ok;
  let status = Yojson.Safe.Util.(member "status" json |> to_string) in
  Alcotest.(check string) "error" "error" status;
  Tool_shard.remove_agent_shards "test-rev-base"
;;

(* ============================================================
   schemas tests
   ============================================================ *)

let test_schemas_count () =
  Alcotest.(check int) "3 schemas" 3 (List.length Tool_shard.schemas)
;;

let test_schemas_names () =
  let names = List.map (fun (s : Types.tool_schema) -> s.name) Tool_shard.schemas in
  List.iter
    (fun expected ->
       Alcotest.(check bool) (expected ^ " present") true (List.mem expected names))
    [ "masc_tool_grant"; "masc_tool_revoke"; "masc_tool_list" ]
;;

(* ============================================================
   base_tools / board_tools content tests
   ============================================================ *)

let test_base_tools_names () =
  let names = List.map (fun (t : Types.tool_schema) -> t.name) Tool_shard.base_tools in
  Alcotest.(check bool) "has time_now" true (List.mem "keeper_time_now" names);
  Alcotest.(check bool) "has context_status" true (List.mem "keeper_context_status" names);
  Alcotest.(check bool) "has memory_search" true (List.mem "keeper_memory_search" names)
;;

let test_board_tools_names () =
  let names = List.map (fun (t : Types.tool_schema) -> t.name) Tool_shard.board_tools in
  Alcotest.(check bool) "has board_post" true (List.mem "keeper_board_post" names);
  Alcotest.(check bool) "has board_list" true (List.mem "keeper_board_list" names);
  Alcotest.(check bool) "has board_comment" true (List.mem "keeper_board_comment" names);
  Alcotest.(check bool) "has board_vote" true (List.mem "keeper_board_vote" names)
;;

let test_keeper_board_post_schema_supports_judgment () =
  match
    List.find_opt
      (fun (tool : Types.tool_schema) -> tool.name = "keeper_board_post")
      Tool_shard.board_tools
  with
  | None -> Alcotest.fail "keeper_board_post schema missing"
  | Some schema ->
    (match get_json_assoc "properties" schema.input_schema with
     | Some props ->
       Alcotest.(check bool)
         "has classification_reason"
         true
         (List.mem_assoc "classification_reason" props);
       Alcotest.(check bool) "has judgment" true (List.mem_assoc "judgment" props)
     | None -> Alcotest.fail "keeper_board_post missing properties")
;;

(* ============================================================
   Voice tools content tests (#3: all 5 voice tools present)
   ============================================================ *)

let test_voice_tools_names () =
  let voice_shard =
    match Tool_shard.get_shard "voice" with
    | Some s -> s
    | None -> Alcotest.failf "voice shard missing"
  in
  let names =
    List.map (fun (t : Types.tool_schema) -> t.name) voice_shard.Tool_shard.tools
  in
  Alcotest.(check bool) "has voice_speak" true (List.mem "keeper_voice_speak" names);
  Alcotest.(check bool) "has voice_listen" true (List.mem "keeper_voice_listen" names);
  Alcotest.(check bool) "has voice_agent" true (List.mem "keeper_voice_agent" names);
  Alcotest.(check bool) "has voice_sessions" true (List.mem "keeper_voice_sessions" names);
  Alcotest.(check bool)
    "has voice_session_start"
    true
    (List.mem "keeper_voice_session_start" names);
  Alcotest.(check bool)
    "has voice_session_end"
    true
    (List.mem "keeper_voice_session_end" names)
;;

let test_keeper_model_excludes_voice_tools () =
  let names =
    List.map (fun (t : Types.tool_schema) -> t.name) Tool_shard.keeper_model_tools
  in
  Alcotest.(check bool)
    "keeper_model no voice_speak"
    false
    (List.mem "keeper_voice_speak" names);
  (* Governance tools are no longer in keeper_model_tools *)
  Alcotest.(check bool)
    "keeper_model no governance_status"
    false
    (List.mem "masc_governance_status" names)
;;

(* ============================================================
   Shard revoke voice (#6: revoke removes all 5 voice tools)
   ============================================================ *)

let test_revoke_voice_removes_all_tools () =
  let all_shards = Tool_shard.default_shard_names @ [ "voice" ] in
  let tools_before = Tool_shard.tools_of_shards all_shards in
  let voice_before =
    List.filter
      (fun (t : Types.tool_schema) ->
         let n = t.name in
         String.length n >= 13 && String.sub n 0 13 = "keeper_voice_")
      tools_before
  in
  Alcotest.(check bool)
    "voice tools present before revoke"
    true
    (List.length voice_before >= 1);
  match Tool_shard.revoke_shard all_shards "voice" with
  | Ok shards_after ->
    let tools_after = Tool_shard.tools_of_shards shards_after in
    let voice_after =
      List.filter
        (fun (t : Types.tool_schema) ->
           let n = t.name in
           String.length n >= 13 && String.sub n 0 13 = "keeper_voice_")
        tools_after
    in
    Alcotest.(check int) "0 voice tools after revoke" 0 (List.length voice_after)
  | Error msg -> Alcotest.fail ("revoke should succeed: " ^ msg)
;;

(* Heartbeat voice integration (#4, #5) verified in
   test_tool_heartbeat_coverage.ml which has Eio context and
   direct access to Keeper_heartbeat internals. *)

(* ============================================================
   Keeper dispatch coverage: every shard schema has a dispatch handler
   ============================================================ *)

(** All keeper tool names from all shards (default + coding). *)
let all_keeper_shard_tool_names () : string list =
  let all_shard_names =
    Tool_shard.list_all_shards () |> List.map (fun (name, _, _) -> name)
  in
  Tool_shard.tools_of_shards all_shard_names
  |> List.filter (fun (t : Types.tool_schema) ->
    String.length t.name >= 7 && String.sub t.name 0 7 = "keeper_")
  |> List.map (fun (t : Types.tool_schema) -> t.name)
  |> List.sort_uniq String.compare
;;

(** Verify that every keeper_ tool in any shard also appears in
    one of the effective keeper shard bundles. This ensures no
    tool schema is orphaned from the dispatch pipeline. *)
let test_keeper_dispatch_coverage () =
  let names = all_keeper_shard_tool_names () in
  Alcotest.(check bool) "at least 25 keeper tools" true (List.length names >= 25);
  let shard_tool_names shard_name =
    match Tool_shard.get_shard shard_name with
    | Some shard ->
      shard.Tool_shard.tools |> List.map (fun (t : Types.tool_schema) -> t.name)
    | None -> []
  in
  let reachable =
    List.concat
      [ Tool_shard.keeper_model_tools |> List.map (fun (t : Types.tool_schema) -> t.name)
      ; shard_tool_names "voice"
      ; Tool_shard.coding_tools |> List.map (fun (t : Types.tool_schema) -> t.name)
      ]
    |> List.sort_uniq String.compare
  in
  let missing = List.filter (fun n -> not (List.mem n reachable)) names in
  if missing <> []
  then
    Alcotest.fail
      (Printf.sprintf
         "Shard tools unreachable by dispatch: %s"
         (String.concat ", " missing))
;;

(** Verify coding tools ARE in keeper_model_tools (default set).
    Mode removal: all keepers get all tools unconditionally. *)
let test_coding_tools_included_in_defaults () =
  let default_names =
    Tool_shard.keeper_model_tools |> List.map (fun (t : Types.tool_schema) -> t.name)
  in
  let coding_names =
    Tool_shard.coding_tools |> List.map (fun (t : Types.tool_schema) -> t.name)
  in
  let missing = List.filter (fun n -> not (List.mem n default_names)) coding_names in
  if missing <> []
  then
    Alcotest.fail
      (Printf.sprintf
         "Coding tools missing from defaults: %s"
         (String.concat ", " missing))
;;

(* ============================================================
   Per-persona shard configuration tests
   ============================================================ *)

module Keeper_types_profile = Masc_mcp.Keeper_types_profile

let test_empty_defaults_shards_none () =
  let d = Keeper_types_profile.empty_keeper_profile_defaults in
  Alcotest.(check bool) "shards is None" true (d.shards = None)
;;

let test_set_agent_shards_from_persona () =
  (* Simulate what keeper_persona.ml does after keeper creation:
     when persona specifies shards, set_agent_shards is called. *)
  Tool_shard.remove_agent_shards "test-persona-shard";
  let persona_shards = [ "base"; "board"; "library" ] in
  Tool_shard.set_agent_shards "test-persona-shard" persona_shards;
  let active = Tool_shard.get_agent_shards "test-persona-shard" in
  Alcotest.(check int) "3 shards" 3 (List.length active);
  Alcotest.(check bool) "has base" true (List.mem "base" active);
  Alcotest.(check bool) "has board" true (List.mem "board" active);
  Alcotest.(check bool) "has library" true (List.mem "library" active);
  Alcotest.(check bool) "no coding" false (List.mem "coding" active);
  Alcotest.(check bool) "no shell" false (List.mem "shell" active);
  (* Verify tools_of_shards returns restricted set *)
  let tools = Tool_shard.tools_of_shards active in
  let tool_names = List.map (fun (t : Types.tool_schema) -> t.name) tools in
  Alcotest.(check bool)
    "has keeper_board_post"
    true
    (List.mem "keeper_board_post" tool_names);
  Alcotest.(check bool) "no keeper_bash" false (List.mem "keeper_bash" tool_names);
  Tool_shard.remove_agent_shards "test-persona-shard"
;;

let test_no_shards_gets_defaults () =
  (* When persona has no shards configured, agent gets all defaults *)
  Tool_shard.remove_agent_shards "test-no-shard-persona";
  let active = Tool_shard.get_agent_shards "test-no-shard-persona" in
  Alcotest.(check int)
    "matches default count"
    (List.length Tool_shard.default_shard_names)
    (List.length active)
;;

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run
    "Tool_shard coverage"
    [ ( "predefined_shards"
      , [ Alcotest.test_case "base" `Quick test_shard_base_exists
        ; Alcotest.test_case "board" `Quick test_shard_board_exists
        ; Alcotest.test_case "filesystem" `Quick test_shard_filesystem_exists
        ; Alcotest.test_case "shell" `Quick test_shard_shell_exists
        ; Alcotest.test_case "governance removed" `Quick test_shard_governance_removed
        ; Alcotest.test_case "coding" `Quick test_shard_coding_exists
        ; Alcotest.test_case "coding in defaults" `Quick test_coding_in_defaults
        ; Alcotest.test_case "voice" `Quick test_shard_voice_exists
        ; Alcotest.test_case "unknown" `Quick test_shard_unknown
        ; Alcotest.test_case "all count" `Quick test_all_shards_count
        ] )
    ; ( "autoresearch_shard"
      , [ Alcotest.test_case "exists" `Quick (fun () ->
            let s = Tool_shard.get_shard "autoresearch" in
            Alcotest.(check bool) "found" true (s <> None))
        ; Alcotest.test_case "removable" `Quick (fun () ->
            let s = Option.get (Tool_shard.get_shard "autoresearch") in
            Alcotest.(check bool) "removable" true s.removable)
        ; Alcotest.test_case "has no retired swarm front doors" `Quick (fun () ->
            let tools = Tool_shard.autoresearch_keeper_tools in
            let has_swarm =
              List.exists
                (fun (t : Types.tool_schema) -> t.name = "masc_autoresearch_swarm_start")
                tools
            in
            let has_repo_synthesis =
              List.exists
                (fun (t : Types.tool_schema) ->
                   t.name = "masc_repo_synthesis_swarm_start")
                tools
            in
            Alcotest.(check bool) "no swarm_start" false has_swarm;
            Alcotest.(check bool) "no repo synthesis swarm start" false has_repo_synthesis)
        ; Alcotest.test_case "has cycle" `Quick (fun () ->
            let tools = Tool_shard.autoresearch_keeper_tools in
            let has_cycle =
              List.exists
                (fun (t : Types.tool_schema) -> t.name = "masc_autoresearch_cycle")
                tools
            in
            let has_record =
              List.exists
                (fun (t : Types.tool_schema) ->
                   t.name = "masc_autoresearch_record_finding")
                tools
            in
            let has_search =
              List.exists
                (fun (t : Types.tool_schema) ->
                   t.name = "masc_autoresearch_search_findings")
                tools
            in
            Alcotest.(check bool) "has cycle" true has_cycle;
            Alcotest.(check bool) "has record finding" true has_record;
            Alcotest.(check bool) "has search findings" true has_search)
        ; Alcotest.test_case "in defaults" `Quick (fun () ->
            let defaults = Tool_shard.default_shard_names in
            Alcotest.(check bool)
              "autoresearch in defaults"
              true
              (List.mem "autoresearch" defaults))
        ] )
    ; ( "default_shard_names"
      , [ Alcotest.test_case "defaults" `Quick test_default_shard_names ] )
    ; ( "tools_of_shards"
      , [ Alcotest.test_case "empty" `Quick test_tools_of_shards_empty
        ; Alcotest.test_case "single" `Quick test_tools_of_shards_single
        ; Alcotest.test_case "multiple" `Quick test_tools_of_shards_multiple
        ; Alcotest.test_case "unknown ignored" `Quick test_tools_of_shards_unknown_ignored
        ; Alcotest.test_case "keeper_model_tools" `Quick test_keeper_model_tools_count
        ] )
    ; ( "grant_shard"
      , [ Alcotest.test_case "known" `Quick test_grant_known_shard
        ; Alcotest.test_case "unknown" `Quick test_grant_unknown_shard
        ; Alcotest.test_case "already granted" `Quick test_grant_already_granted
        ] )
    ; ( "revoke_shard"
      , [ Alcotest.test_case "removable" `Quick test_revoke_removable
        ; Alcotest.test_case "non-removable" `Quick test_revoke_non_removable
        ; Alcotest.test_case "not granted" `Quick test_revoke_not_granted
        ; Alcotest.test_case "unknown" `Quick test_revoke_unknown
        ] )
    ; ( "agent_shards"
      , [ Alcotest.test_case "default" `Quick test_get_agent_shards_default
        ; Alcotest.test_case "set/get" `Quick test_set_get_agent_shards
        ] )
    ; ( "execute"
      , [ Alcotest.test_case "unknown tool" `Quick test_execute_unknown_tool
        ; Alcotest.test_case "list" `Quick test_execute_tool_list
        ; Alcotest.test_case "list with agent" `Quick test_execute_tool_list_with_agent
        ; Alcotest.test_case "grant" `Quick test_execute_grant
        ; Alcotest.test_case
            "grant missing params"
            `Quick
            test_execute_grant_missing_params
        ; Alcotest.test_case "revoke" `Quick test_execute_revoke
        ; Alcotest.test_case
            "revoke non-removable"
            `Quick
            test_execute_revoke_non_removable
        ] )
    ; ( "schemas"
      , [ Alcotest.test_case "count" `Quick test_schemas_count
        ; Alcotest.test_case "names" `Quick test_schemas_names
        ] )
    ; ( "tool_content"
      , [ Alcotest.test_case "base tools" `Quick test_base_tools_names
        ; Alcotest.test_case "board tools" `Quick test_board_tools_names
        ; Alcotest.test_case
            "keeper_board_post supports judgment"
            `Quick
            test_keeper_board_post_schema_supports_judgment
        ; Alcotest.test_case "voice tools" `Quick test_voice_tools_names
        ; Alcotest.test_case
            "keeper_model excludes voice"
            `Quick
            test_keeper_model_excludes_voice_tools
        ] )
    ; ( "voice_shard_revoke"
      , [ Alcotest.test_case
            "revoke removes all voice tools"
            `Quick
            test_revoke_voice_removes_all_tools
        ] )
    ; ( "keeper_dispatch_coverage"
      , [ Alcotest.test_case
            "all shard tools reachable"
            `Quick
            test_keeper_dispatch_coverage
        ; Alcotest.test_case
            "coding included in defaults"
            `Quick
            test_coding_tools_included_in_defaults
        ] )
    ; ( "persona_shard_config"
      , [ Alcotest.test_case
            "empty defaults shards None"
            `Quick
            test_empty_defaults_shards_none
        ; Alcotest.test_case
            "set_agent_shards from persona"
            `Quick
            test_set_agent_shards_from_persona
        ; Alcotest.test_case "no shards gets defaults" `Quick test_no_shards_gets_defaults
        ] )
    ]
;;
