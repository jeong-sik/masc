(** Coverage tests for Tool_shard — dynamic tool sharding for MASC agents.

    Tests shard types, predefined shards, grant/revoke logic,
    tools_of_shards composition, agent shard state, execute dispatch,
    and MCP schemas.

    Pure synchronous tests — no Eio or network required. *)

module Tool_shard = Masc.Tool_shard
module Tool_shard_types = Tool_shard_types
module Types = Masc_domain

let contains text needle =
  Astring.String.is_infix ~affix:needle text
;;

let check_contains label needle text =
  Alcotest.(check bool) label true (contains text needle)
;;

let check_not_contains label needle text =
  Alcotest.(check bool) label false (contains text needle)
;;

let markdown_code text = "`" ^ text ^ "`"

let markdown_list values =
  values |> List.map markdown_code |> String.concat ", "
;;

let schema_description name schemas =
  match List.find_opt (fun (schema : Types.tool_schema) -> String.equal schema.name name) schemas with
  | Some schema -> schema.description
  | None -> Alcotest.failf "missing schema: %s" name
;;

let get_json_assoc key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Assoc assoc) -> Some assoc
      | _ -> None)
  | _ -> None

let shard_tool_names (shard : Tool_shard.shard) =
  shard.tools |> List.map (fun (tool : Masc_domain.tool_schema) -> tool.name)
;;

let keeper_tool_shard_snapshot () =
  let defaults = Tool_shard.default_shard_names in
  let all_names =
    Tool_shard.list_all_shards () |> List.map (fun (name, _, _) -> name)
  in
  let ordered_names =
    defaults @ List.filter (fun name -> not (List.mem name defaults)) all_names
  in
  let row name =
    match Tool_shard.get_shard name with
    | None -> Alcotest.failf "missing shard in snapshot: %s" name
    | Some shard ->
      let tools = shard_tool_names shard in
      Printf.sprintf
        "| **%s** | %s | %d | %s | %s |"
        name
        (markdown_list tools)
        (List.length tools)
        (if List.mem name defaults then "Yes" else "No")
        (if shard.removable then "Yes" else "No")
  in
  String.concat
    "\n"
    ([ Printf.sprintf "Default shard order: %s" (markdown_list defaults)
     ; ""
     ; Printf.sprintf
         "Unsharded default tools: %s"
         (markdown_list
            (Tool_shard_types.typed_execute_tools
             |> List.map (fun (tool : Masc_domain.tool_schema) -> tool.name)))
     ; ""
     ; "| Shard | Tools | Count | Default | Removable |"
     ; "|-------|-------|-------|---------|-----------|"
     ]
     @ List.map row ordered_names)
;;

let extract_marked_block ~begin_marker ~end_marker text =
  let rec seek = function
    | [] -> Alcotest.failf "missing marker: %s" begin_marker
    | line :: rest when String.equal line begin_marker -> collect [] rest
    | _ :: rest -> seek rest
  and collect acc = function
    | [] -> Alcotest.failf "missing marker: %s" end_marker
    | line :: _ when String.equal line end_marker -> String.concat "\n" (List.rev acc)
    | line :: rest -> collect (line :: acc) rest
  in
  seek (String.split_on_char '\n' text)
;;

let test_keeper_capability_matrix_snapshot () =
  let actual =
    Masc_test_deps.read_source_file "docs/KEEPER-CAPABILITY-MATRIX.md"
    |> extract_marked_block
         ~begin_marker:"<!-- BEGIN:keeper-tool-shard-snapshot -->"
         ~end_marker:"<!-- END:keeper-tool-shard-snapshot -->"
  in
  Alcotest.(check string)
    "keeper shard snapshot"
    (keeper_tool_shard_snapshot ())
    actual
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

let test_shard_board_exists () =
  match Tool_shard.get_shard "board" with
  | Some s ->
    Alcotest.(check bool) "removable" true s.Tool_shard.removable;
    Alcotest.(check bool) "has tools" true (List.length s.Tool_shard.tools >= 1)
  | None -> Alcotest.fail "board shard not found"

let test_shard_filesystem_exists () =
  match Tool_shard.get_shard "filesystem" with
  | Some s ->
    Alcotest.(check bool) "removable" true s.Tool_shard.removable;
    Alcotest.(check bool) "has tools" true (List.length s.Tool_shard.tools >= 1);
    let names = List.map (fun (t : Masc_domain.tool_schema) -> t.name) s.tools in
    Alcotest.(check bool) "contains fs_read" true
      (List.mem "tool_read_file" names);
    Alcotest.(check bool) "contains fs_edit" true
      (List.mem "tool_edit_file" names)
  | None -> Alcotest.fail "filesystem shard not found"

let test_shard_search_files_exists () =
  match Tool_shard.get_shard "search_files" with
  | Some s ->
    Alcotest.(check bool) "removable" true s.Tool_shard.removable;
    Alcotest.(check bool) "has tools" true (List.length s.Tool_shard.tools >= 1)
  | None -> Alcotest.fail "search_files shard not found"

let test_user_facing_alias_copy_is_canonical () =
  let execute_description =
    schema_description "tool_execute" Tool_shard_types.typed_execute_tools
  in
  let read_description =
    schema_description "tool_read_file" Tool_shard_types.filesystem_tools
  in
  let search_shard_description =
    match Tool_shard.get_shard "search_files" with
    | Some shard -> shard.description
    | None -> Alcotest.fail "search_files shard not found"
  in
  let surface_text =
    String.concat
      "\n"
      [ execute_description
      ; read_description
      ; search_shard_description
      ]
  in
  List.iter
    (fun retired ->
       check_not_contains ("retired alias absent: " ^ retired) retired surface_text)
    [ "Search" ^ "Files"; "Edit" ^ "File"; "Read" ^ "File"; "Write" ^ "File" ];
  List.iter
    (fun canonical ->
       check_contains ("canonical alias present: " ^ canonical) canonical surface_text)
    [ "Grep"; "Edit"; "Execute" ]
;;

let test_shard_governance_removed () =
  Alcotest.(check bool) "governance shard removed"
    true (Option.is_none (Tool_shard.get_shard "governance"))

let retired_tool_mode_shard = "co" ^ "ding"

let test_retired_tool_mode_shard_removed () =
  Alcotest.(check bool) "retired tool-mode shard removed" true
    (Option.is_none (Tool_shard.get_shard retired_tool_mode_shard))

let test_retired_search_family_name_removed () =
  let legacy_name = "s" ^ "hell" in
  Alcotest.(check bool) "legacy search-family shard removed" true
    (Option.is_none (Tool_shard.get_shard legacy_name))

let test_shard_voice_exists () =
  match Tool_shard.get_shard "voice" with
  | Some s ->
    Alcotest.(check bool) "removable" true s.Tool_shard.removable;
    Alcotest.(check bool) "has tools" true (List.length s.Tool_shard.tools >= 1)
  | None -> Alcotest.fail "voice shard not found"

let test_shard_unknown () =
  Alcotest.(check bool) "unknown returns None" true
    (Tool_shard.get_shard "nonexistent" = None)

let test_all_shards_count () =
  let all = Tool_shard.list_all_shards () in
  Alcotest.(check bool) "at least 7 predefined shards" true (List.length all >= 7)

(* ============================================================
   default_shard_names tests
   ============================================================ *)

let test_default_shard_names () =
  let defaults = Tool_shard.default_shard_names in
  (* All shards are now in defaults (mode removal: every keeper gets all tools) *)
  Alcotest.(check bool) "at least 6 defaults" true (List.length defaults >= 6);
  Alcotest.(check bool) "base in defaults" true (List.mem "base" defaults);
  (* governance shard removed; must not appear in defaults *)
  Alcotest.(check bool) "governance not in defaults" false
    (List.mem "governance" defaults);
  Alcotest.(check bool) "retired tool-mode not in defaults" false
    (List.mem retired_tool_mode_shard defaults);
  Alcotest.(check bool) "weather removed from defaults" false
    (List.mem "weather" defaults);
  (* voice still not in defaults: gated by policy_voice_enabled boolean *)
  Alcotest.(check bool) "voice not in defaults" false
    (List.mem "voice" defaults)

(* ============================================================
   tools_of_shards tests
   ============================================================ *)

let test_tools_of_shards_empty () =
  let tools = Tool_shard.tools_of_shards [] in
  Alcotest.(check int) "no shards → no tools" 0 (List.length tools)

let test_tools_of_shards_single () =
  let tools = Tool_shard.tools_of_shards ["base"] in
  Alcotest.(check bool) "base has tools" true (List.length tools >= 1)

let test_tools_of_shards_multiple () =
  let base_count = List.length (Tool_shard.tools_of_shards ["base"]) in
  let board_count = List.length (Tool_shard.tools_of_shards ["board"]) in
  let combined = Tool_shard.tools_of_shards ["base"; "board"] in
  Alcotest.(check int) "base+board = sum" (base_count + board_count) (List.length combined)

let test_tools_of_shards_unknown_ignored () =
  let expected = Tool_shard.tools_of_shards ["base"; "board"] in
  let with_unknown = Tool_shard.tools_of_shards ["base"; "doesnt_exist"; "board"] in
  Alcotest.(check int) "unknown shard ignored" (List.length expected) (List.length with_unknown)

let test_keeper_model_tools_count () =
  let tools = Tool_shard.keeper_model_tools in
  (* keeper_model_tools = default shards plus unsharded execute tools.
     Standalone keeper schemas are assembled by keeper_tool_policy, not here. *)
  let expected =
    Tool_shard.tools_of_shards Tool_shard.default_shard_names
	    @ Tool_shard_types.typed_execute_tools
  in
  Alcotest.(check int) "matches default shards sum" (List.length expected) (List.length tools);
  Alcotest.(check bool) "has tools" true (List.length tools >= 1)

(* ============================================================
   grant_shard tests
   ============================================================ *)

let test_grant_known_shard () =
  let active = ["base"] in
  match Tool_shard.grant_shard active "board" with
  | Ok new_shards ->
    Alcotest.(check int) "now 2 shards" 2 (List.length new_shards);
    Alcotest.(check bool) "board added" true (List.mem "board" new_shards)
  | Error _ -> Alcotest.fail "should succeed"

let test_grant_unknown_shard () =
  match Tool_shard.grant_shard ["base"] "fantasy" with
  | Ok _ -> Alcotest.fail "should fail"
  | Error msg ->
    Alcotest.(check bool) "mentions unknown" true
      (String.lowercase_ascii msg |> fun s ->
       try ignore (Str.search_forward (Str.regexp_string "unknown") s 0); true
       with Not_found -> false)

let test_grant_already_granted () =
  match Tool_shard.grant_shard ["base"; "board"] "board" with
  | Ok _ -> Alcotest.fail "should fail"
  | Error msg ->
    Alcotest.(check bool) "mentions already" true
      (String.lowercase_ascii msg |> fun s ->
       try ignore (Str.search_forward (Str.regexp_string "already") s 0); true
       with Not_found -> false)

(* ============================================================
   revoke_shard tests
   ============================================================ *)

let test_revoke_removable () =
  let active = ["base"; "board"; "search_files"] in
  match Tool_shard.revoke_shard active "board" with
  | Ok new_shards ->
    Alcotest.(check int) "now 2" 2 (List.length new_shards);
    Alcotest.(check bool) "board removed" false (List.mem "board" new_shards)
  | Error _ -> Alcotest.fail "should succeed"

let test_revoke_non_removable () =
  match Tool_shard.revoke_shard ["base"; "board"] "base" with
  | Ok _ -> Alcotest.fail "should fail"
  | Error msg ->
    Alcotest.(check bool) "mentions non-removable" true
      (String.lowercase_ascii msg |> fun s ->
       try ignore (Str.search_forward (Str.regexp_string "remov") s 0); true
       with Not_found -> false)

let test_revoke_not_granted () =
  match Tool_shard.revoke_shard ["base"] "search_files" with
  | Ok _ -> Alcotest.fail "should fail"
  | Error msg ->
    Alcotest.(check bool) "mentions not granted" true
      (String.lowercase_ascii msg |> fun s ->
       try ignore (Str.search_forward (Str.regexp_string "not") s 0); true
       with Not_found -> false)

let test_revoke_unknown () =
  match Tool_shard.revoke_shard ["base"] "fantasy" with
  | Ok _ -> Alcotest.fail "should fail"
  | Error msg ->
    Alcotest.(check bool) "mentions unknown" true
      (String.lowercase_ascii msg |> fun s ->
       try ignore (Str.search_forward (Str.regexp_string "unknown") s 0); true
       with Not_found -> false)

(* ============================================================
   agent shard state tests
   ============================================================ *)

let test_get_agent_shards_default () =
  (* Unknown agent gets default shards *)
  let shards = Tool_shard.get_agent_shards "new-agent-never-seen" in
  let defaults = Tool_shard.default_shard_names in
  Alcotest.(check int) "matches default count" (List.length defaults) (List.length shards)

let test_set_get_agent_shards () =
  Tool_shard.remove_agent_shards "test-agent-x";
  Tool_shard.set_agent_shards "test-agent-x" ["base"; "search_files"];
  let shards = Tool_shard.get_agent_shards "test-agent-x" in
  Alcotest.(check int) "2 shards" 2 (List.length shards);
  Alcotest.(check bool) "sorted" true (shards = List.sort String.compare shards);
  (* Cleanup *)
  Tool_shard.remove_agent_shards "test-agent-x"

(* ============================================================
   execute (MCP dispatch) tests
   ============================================================ *)

let test_execute_unknown_tool () =
  let (ok, _json) = Tool_shard.execute "unknown_tool" (`Assoc []) in
  Alcotest.(check bool) "fails" false ok

let test_execute_retired_tool_names_are_unknown () =
  List.iter
    (fun name ->
      let ok, json = Tool_shard.execute name (`Assoc []) in
      Alcotest.(check bool) (name ^ " fails") false ok;
      Alcotest.(check string)
        (name ^ " unknown message")
        ("Unknown tool: " ^ name)
        Yojson.Safe.Util.(to_string json))
    [ "masc_tool_list"; "masc_tool_grant"; "masc_tool_revoke" ]

(* ============================================================
   schemas tests
   ============================================================ *)

let test_schemas_count () =
  Alcotest.(check int) "no schemas" 0 (List.length Tool_shard.schemas)

let test_schemas_names () =
  Alcotest.(check (list string))
    "no public masc_tool schemas"
    []
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) Tool_shard.schemas)

(* ============================================================
   base_tools / board_tools content tests
   ============================================================ *)

let test_base_tools_names () =
  let names = List.map (fun (t : Masc_domain.tool_schema) -> t.name)
    Tool_shard.base_tools in
  Alcotest.(check bool) "has time_now" true (List.mem "keeper_time_now" names);
  Alcotest.(check bool) "has context_status" true (List.mem "keeper_context_status" names);
  Alcotest.(check bool) "has memory_search" true (List.mem "keeper_memory_search" names)

let test_board_tools_names () =
  let names = List.map (fun (t : Masc_domain.tool_schema) -> t.name)
    Tool_shard.board_tools in
  Alcotest.(check bool) "has board_post" true (List.mem "keeper_board_post" names);
  Alcotest.(check bool) "has board_list" true (List.mem "keeper_board_list" names);
  Alcotest.(check bool) "has board_comment" true (List.mem "keeper_board_comment" names);
  Alcotest.(check bool) "has board_vote" true (List.mem "keeper_board_vote" names)

let test_keeper_board_post_schema_supports_judgment () =
  match
    List.find_opt
      (fun (tool : Masc_domain.tool_schema) -> tool.name = "keeper_board_post")
      Tool_shard.board_tools
  with
  | None -> Alcotest.fail "keeper_board_post schema missing"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has classification_reason" true
            (List.mem_assoc "classification_reason" props);
          Alcotest.(check bool) "has judgment" true
            (List.mem_assoc "judgment" props);
          Alcotest.(check bool) "has sources" true
            (List.mem_assoc "sources" props);
          let quantitative_evidence_schema =
            match List.assoc_opt "quantitative_evidence" props with
            | Some schema -> schema
            | None -> Alcotest.fail "quantitative_evidence missing"
          in
          (match quantitative_evidence_schema with
           | `Assoc fields ->
             let type_values =
               match List.assoc_opt "type" fields with
               | Some (`List values) ->
                 List.filter_map
                   (function
                     | `String value -> Some value
                     | _ -> None)
                   values
               | _ -> []
             in
             Alcotest.(check (list string))
               "quantitative_evidence schema types"
               [ "object"; "string"; "array" ]
               type_values
           | _ -> Alcotest.fail "quantitative_evidence schema not object")
      | None -> Alcotest.fail "keeper_board_post missing properties"

(* ============================================================
   Voice tools content tests (#3: all 5 voice tools present)
   ============================================================ *)

let test_voice_tools_names () =
  let voice_shard = match Tool_shard.get_shard "voice" with
    | Some s -> s | None -> Alcotest.failf "voice shard missing" in
  let names = List.map (fun (t : Masc_domain.tool_schema) -> t.name)
    voice_shard.Tool_shard.tools in
  Alcotest.(check bool) "has voice_speak" true (List.mem "keeper_voice_speak" names);
  Alcotest.(check bool) "has voice_listen" true (List.mem "keeper_voice_listen" names);
  Alcotest.(check bool) "has voice_agent" true (List.mem "keeper_voice_agent" names);
  Alcotest.(check bool) "has voice_sessions" true (List.mem "keeper_voice_sessions" names);
  Alcotest.(check bool) "has voice_session_start" true (List.mem "keeper_voice_session_start" names);
  Alcotest.(check bool) "has voice_session_end" true (List.mem "keeper_voice_session_end" names)

let test_keeper_model_excludes_voice_tools () =
  let names = List.map (fun (t : Masc_domain.tool_schema) -> t.name)
    Tool_shard.keeper_model_tools in
  Alcotest.(check bool) "keeper_model no voice_speak" false
    (List.mem "keeper_voice_speak" names);
  (* Governance tools are no longer in keeper_model_tools *)
  Alcotest.(check bool) "keeper_model no governance_status" false
    (List.mem "masc_governance_status" names)

(* ============================================================
   Shard revoke voice (#6: revoke removes all 5 voice tools)
   ============================================================ *)

let test_revoke_voice_removes_all_tools () =
  let all_shards = Tool_shard.default_shard_names @ [ "voice" ] in
  let tools_before = Tool_shard.tools_of_shards all_shards in
  let voice_before = List.filter (fun (t : Masc_domain.tool_schema) ->
    let n = t.name in
    String.length n >= 13 && String.sub n 0 13 = "keeper_voice_") tools_before in
  Alcotest.(check bool) "voice tools present before revoke" true (List.length voice_before >= 1);
  match Tool_shard.revoke_shard all_shards "voice" with
  | Ok shards_after ->
    let tools_after = Tool_shard.tools_of_shards shards_after in
    let voice_after = List.filter (fun (t : Masc_domain.tool_schema) ->
      let n = t.name in
      String.length n >= 13 && String.sub n 0 13 = "keeper_voice_") tools_after in
    Alcotest.(check int) "0 voice tools after revoke" 0 (List.length voice_after)
  | Error msg -> Alcotest.fail ("revoke should succeed: " ^ msg)

(* Heartbeat voice integration (#4, #5) verified in
   test_tool_heartbeat_coverage.ml which has Eio context and
   direct access to Keeper_heartbeat internals. *)

(* ============================================================
   Keeper dispatch coverage: every shard schema has a dispatch handler
   ============================================================ *)

(** All keeper tool names from all shards plus unsharded defaults. *)
let all_keeper_shard_tool_names () : string list =
  let all_shard_names =
    Tool_shard.list_all_shards ()
    |> List.map (fun (name, _, _) -> name)
  in
  (Tool_shard.tools_of_shards all_shard_names
	   @ Tool_shard_types.typed_execute_tools)
  |> List.filter (fun (t : Masc_domain.tool_schema) ->
       String.length t.name >= 7
       && String.sub t.name 0 7 = "keeper_")
  |> List.map (fun (t : Masc_domain.tool_schema) -> t.name)
  |> List.sort_uniq String.compare

(** Verify that every keeper_ tool in any shard also appears in
    one of the effective keeper shard bundles. This ensures no
    tool schema is orphaned from the dispatch pipeline. *)
let test_keeper_dispatch_coverage () =
  let names = all_keeper_shard_tool_names () in
  Alcotest.(check bool) "at least 25 keeper tools" true (List.length names >= 25);
  let shard_tool_names shard_name =
    match Tool_shard.get_shard shard_name with
    | Some shard ->
      shard.Tool_shard.tools
      |> List.map (fun (t : Masc_domain.tool_schema) -> t.name)
    | None -> []
  in
  let reachable =
    List.concat [
      (Tool_shard.keeper_model_tools
       |> List.map (fun (t : Masc_domain.tool_schema) -> t.name));
      shard_tool_names "voice";
    ]
    |> List.sort_uniq String.compare
  in
  let missing = List.filter (fun n -> not (List.mem n reachable)) names in
  if missing <> [] then
    Alcotest.fail
      (Printf.sprintf "Shard tools unreachable by dispatch: %s"
         (String.concat ", " missing))

(* ============================================================
   Per-persona shard configuration tests
   ============================================================ *)

module Keeper_types_profile = Masc.Keeper_types_profile

let test_empty_defaults_shards_none () =
  let d = Keeper_types_profile.empty_keeper_profile_defaults in
  Alcotest.(check bool) "shards is None" true (d.shards = None)

let test_set_agent_shards_from_persona () =
  (* Simulate what keeper_persona.ml does after keeper creation:
     when persona specifies shards, set_agent_shards is called. *)
  Tool_shard.remove_agent_shards "test-persona-shard";
  let persona_shards = ["base"; "board"; "library"] in
  Tool_shard.set_agent_shards "test-persona-shard" persona_shards;
  let active = Tool_shard.get_agent_shards "test-persona-shard" in
  Alcotest.(check int) "3 shards" 3 (List.length active);
  Alcotest.(check bool) "has base" true (List.mem "base" active);
  Alcotest.(check bool) "has board" true (List.mem "board" active);
  Alcotest.(check bool) "has library" true (List.mem "library" active);
  Alcotest.(check bool) "no retired tool-mode shard" false
    (List.mem retired_tool_mode_shard active);
  Alcotest.(check bool) "no search_files" false (List.mem "search_files" active);
  (* Verify tools_of_shards returns restricted set *)
  let tools = Tool_shard.tools_of_shards active in
  let tool_names = List.map (fun (t : Masc_domain.tool_schema) -> t.name) tools in
  Alcotest.(check bool) "has keeper_board_post" true
    (List.mem "keeper_board_post" tool_names);
  Alcotest.(check bool) "no tool_execute" false
    (List.mem "tool_execute" tool_names);
  Tool_shard.remove_agent_shards "test-persona-shard"

let test_no_shards_gets_defaults () =
  (* When persona has no shards configured, agent gets all defaults *)
  Tool_shard.remove_agent_shards "test-no-shard-persona";
  let active = Tool_shard.get_agent_shards "test-no-shard-persona" in
  Alcotest.(check int) "matches default count"
    (List.length Tool_shard.default_shard_names) (List.length active)

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_shard coverage" [
    ("predefined_shards", [
      Alcotest.test_case "base" `Quick test_shard_base_exists;
      Alcotest.test_case "board" `Quick test_shard_board_exists;
      Alcotest.test_case "filesystem" `Quick test_shard_filesystem_exists;
      Alcotest.test_case "search_files" `Quick test_shard_search_files_exists;
      Alcotest.test_case "canonical alias copy" `Quick
        test_user_facing_alias_copy_is_canonical;
      Alcotest.test_case "governance removed" `Quick test_shard_governance_removed;
      Alcotest.test_case "retired tool-mode shard removed" `Quick
        test_retired_tool_mode_shard_removed;
      Alcotest.test_case "legacy search-family removed" `Quick test_retired_search_family_name_removed;
      Alcotest.test_case "voice" `Quick test_shard_voice_exists;
      Alcotest.test_case "unknown" `Quick test_shard_unknown;
      Alcotest.test_case "all count" `Quick test_all_shards_count;
    ]);
    ("default_shard_names", [
      Alcotest.test_case "defaults" `Quick test_default_shard_names;
    ]);
    ("tools_of_shards", [
      Alcotest.test_case "empty" `Quick test_tools_of_shards_empty;
      Alcotest.test_case "single" `Quick test_tools_of_shards_single;
      Alcotest.test_case "multiple" `Quick test_tools_of_shards_multiple;
      Alcotest.test_case "unknown ignored" `Quick test_tools_of_shards_unknown_ignored;
      Alcotest.test_case "keeper_model_tools" `Quick test_keeper_model_tools_count;
    ]);
    ("grant_shard", [
      Alcotest.test_case "known" `Quick test_grant_known_shard;
      Alcotest.test_case "unknown" `Quick test_grant_unknown_shard;
      Alcotest.test_case "already granted" `Quick test_grant_already_granted;
    ]);
    ("revoke_shard", [
      Alcotest.test_case "removable" `Quick test_revoke_removable;
      Alcotest.test_case "non-removable" `Quick test_revoke_non_removable;
      Alcotest.test_case "not granted" `Quick test_revoke_not_granted;
      Alcotest.test_case "unknown" `Quick test_revoke_unknown;
    ]);
    ("agent_shards", [
      Alcotest.test_case "default" `Quick test_get_agent_shards_default;
      Alcotest.test_case "set/get" `Quick test_set_get_agent_shards;
    ]);
    ("execute", [
      Alcotest.test_case "unknown tool" `Quick test_execute_unknown_tool;
      Alcotest.test_case "retired masc_tool names" `Quick
        test_execute_retired_tool_names_are_unknown;
    ]);
    ("schemas", [
      Alcotest.test_case "count" `Quick test_schemas_count;
      Alcotest.test_case "names" `Quick test_schemas_names;
    ]);
    ("tool_content", [
      Alcotest.test_case "base tools" `Quick test_base_tools_names;
      Alcotest.test_case "board tools" `Quick test_board_tools_names;
      Alcotest.test_case "keeper_board_post supports judgment" `Quick
        test_keeper_board_post_schema_supports_judgment;
      Alcotest.test_case "voice tools" `Quick test_voice_tools_names;
      Alcotest.test_case "keeper_model excludes voice" `Quick
        test_keeper_model_excludes_voice_tools;
    ]);
    ("voice_shard_revoke", [
      Alcotest.test_case "revoke removes all voice tools" `Quick test_revoke_voice_removes_all_tools;
    ]);
    ("keeper_dispatch_coverage", [
      Alcotest.test_case "all shard tools reachable" `Quick test_keeper_dispatch_coverage;
    ]);
    ("docs", [
      Alcotest.test_case "capability matrix snapshot" `Quick
        test_keeper_capability_matrix_snapshot;
    ]);
    ("persona_shard_config", [
      Alcotest.test_case "empty defaults shards None" `Quick test_empty_defaults_shards_none;
      Alcotest.test_case "set_agent_shards from persona" `Quick test_set_agent_shards_from_persona;
      Alcotest.test_case "no shards gets defaults" `Quick test_no_shards_gets_defaults;
    ]);
  ]
