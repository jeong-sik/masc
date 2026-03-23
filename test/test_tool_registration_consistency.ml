(** Structural linter: verifies tool registration consistency.

    1. Every tool in Config.all_tool_schemas must be mapped in Mode.tool_category
       (not Unknown). An Unknown tool is invisible in all mode presets.
    2. Every tool referenced in Workflow_guide must exist in Config.all_tool_schemas.

    This test catches registration drift when new tools are added to schemas
    but not to mode.ml, or when workflow_guide references stale tool names. *)

open Masc_mcp
module WG = Masc_mcp__Workflow_guide

(* ── All schema tool names ─────────────────────────────────────── *)

let all_schema_names =
  List.map (fun (s : Types.tool_schema) -> s.name) Config.all_tool_schemas

(* ── Test 1: No Unknown tools in schemas ──────────────────────── *)

let test_no_unknown_tools () =
  let unknown_tools =
    List.filter
      (fun name -> Mode.tool_category name = Mode.Unknown)
      all_schema_names
  in
  match unknown_tools with
  | [] -> ()
  | tools ->
      Alcotest.fail
        (Printf.sprintf
           "Found %d tool(s) with Unknown category (invisible in all modes):\n  %s\n\
            Fix: add them to Mode.tool_category in lib/mode.ml"
           (List.length tools)
           (String.concat "\n  " tools))

(* ── Test 2: Workflow guide references valid tools ────────────── *)

let test_workflow_guide_tools_exist () =
  let guide_tools = [
    "masc_start"; "masc_set_room"; "masc_join"; "masc_status";
    "masc_claim"; "masc_claim_next"; "masc_done"; "masc_transition";
    "masc_add_task"; "masc_batch_add_tasks";
    "masc_plan_set_task"; "masc_set_current_task";
    "masc_heartbeat"; "masc_broadcast";
    "masc_worktree_create"; "masc_init"; "masc_switch_mode";
    "masc_operator_digest";
    "masc_operation_start"; "masc_dispatch_tick";
    "masc_team_session_start"; "masc_team_session_step";
    "masc_team_session_prove"; "masc_team_session_stop";
  ] in
  List.iter (fun tool_name ->
    let g_ok = WG.next_steps ~tool_name ~success:true in
    List.iter (fun (s : WG.step) ->
      if not (List.mem s.tool all_schema_names) then
        Alcotest.fail
          (Printf.sprintf
             "WG.next_steps(%s) references '%s' which is not in Config.all_tool_schemas"
             tool_name s.tool)
    ) g_ok.next_steps;
    let g_fail = WG.next_steps ~tool_name ~success:false in
    List.iter (fun (s : WG.step) ->
      if not (List.mem s.tool all_schema_names) then
        Alcotest.fail
          (Printf.sprintf
             "WG.next_steps(%s, fail) references '%s' which is not in Config.all_tool_schemas"
             tool_name s.tool)
    ) g_fail.next_steps
  ) guide_tools

let contains_substring haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > h_len then false
    else if String.sub haystack i n_len = needle then true
    else loop (i + 1)
  in
  n_len = 0 || loop 0

let is_token_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

let contains_token haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let boundary_ok idx =
    let before_ok =
      idx = 0 || not (is_token_char haystack.[idx - 1])
    in
    let after_idx = idx + n_len in
    let after_ok =
      after_idx >= h_len || not (is_token_char haystack.[after_idx])
    in
    before_ok && after_ok
  in
  let rec loop i =
    if i + n_len > h_len then false
    else if String.sub haystack i n_len = needle && boundary_ok i then true
    else loop (i + 1)
  in
  n_len = 0 || loop 0

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let repo_root () =
  let has_docs_dir path =
    Sys.file_exists (Filename.concat path "docs")
  in
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_docs_dir root -> root
  | _ ->
      let rec ascend path =
        if has_docs_dir path then path
        else
          let parent = Filename.dirname path in
          if String.equal parent path then path else ascend parent
      in
      ascend (Sys.getcwd ())

let doc_path name =
  Filename.concat (Filename.concat (repo_root ()) "docs") name

let repo_path relative =
  Filename.concat (repo_root ()) relative

let test_docs_do_not_reintroduce_ghost_claim_surface () =
  let allowed_claim_docs = [ "MCP-SURFACE-AUDIT.md" ] in
  let docs_dir = Filename.concat (repo_root ()) "docs" in
  Sys.readdir docs_dir
  |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".md")
  |> List.iter (fun name ->
         let contents = read_file (doc_path name) in
         if contains_substring contents "masc_task_list" then
           Alcotest.failf "doc %s reintroduces ghost tool masc_task_list" name;
	         if (not (List.mem name allowed_claim_docs))
	         then
	           Alcotest.failf
	             "doc %s reintroduces normative masc_claim usage outside compatibility docs"
	             name)

let test_front_door_surfaces_do_not_reintroduce_claim_alias () =
  let paths =
    [
      "llms.txt";
      "llms-full.txt";
      "examples/BEST-PRACTICES.md";
      "benchmarks/benchmark.sh";
      "dashboard/src/components/command/guided-panel.ts";
    ]
  in
  List.iter
    (fun relative ->
      let contents = read_file (repo_path relative) in
      if contains_token contents "masc_transition" then
        Alcotest.failf
          "front-door surface %s reintroduces deprecated masc_claim alias"
          relative)
    paths

let test_multi_room_doc_keeps_historical_banner () =
  let contents = read_file (doc_path "MULTI-ROOM-DESIGN.md") in
  if not (contains_substring contents "Status: historical/internal compatibility note")
  then
    Alcotest.fail
      "MULTI-ROOM-DESIGN.md must declare historical/internal compatibility status";
  if not
       (contains_substring contents
          "Historical command references below are retained for implementation context only")
  then
    Alcotest.fail
      "MULTI-ROOM-DESIGN.md must mark command references as historical-only"

(* ── Test 3: No duplicate tool names in schemas ──────────────── *)

let test_no_duplicate_schemas () =
  let seen = Hashtbl.create 256 in
  let duplicates = ref [] in
  List.iter (fun name ->
    if Hashtbl.mem seen name then
      duplicates := name :: !duplicates
    else
      Hashtbl.replace seen name true
  ) all_schema_names;
  match !duplicates with
  | [] -> ()
  | dups ->
      Alcotest.fail
        (Printf.sprintf "Found %d duplicate tool schema(s):\n  %s"
           (List.length dups)
           (String.concat "\n  " dups))

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  Alcotest.run "tool_registration_consistency"
    [
      ( "linter",
        [
          Alcotest.test_case "no Unknown tools in schemas" `Quick
            test_no_unknown_tools;
          Alcotest.test_case "workflow guide references valid tools" `Quick
            test_workflow_guide_tools_exist;
          Alcotest.test_case "docs do not reintroduce ghost claim surface" `Quick
            test_docs_do_not_reintroduce_ghost_claim_surface;
          Alcotest.test_case "front-door surfaces do not reintroduce claim alias" `Quick
            test_front_door_surfaces_do_not_reintroduce_claim_alias;
          Alcotest.test_case "multi-room doc keeps historical banner" `Quick
            test_multi_room_doc_keeps_historical_banner;
          Alcotest.test_case "no duplicate tool schemas" `Quick
            test_no_duplicate_schemas;
        ] );
    ]
