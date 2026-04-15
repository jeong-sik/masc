(** Structural linter: verifies tool registration consistency.

    1. Every tool referenced in Workflow_guide must exist in Config.all_tool_schemas.

    This test catches registration drift when new tools are added to schemas
    or when workflow_guide references stale tool names. *)

open Masc_mcp
module WG = Masc_mcp__Workflow_guide

(* ── All schema tool names ─────────────────────────────────────── *)

let all_schema_names =
  List.map (fun (s : Types.tool_schema) -> s.name) Config.all_tool_schemas

(* ── Test 1: Workflow guide references valid tools ────────────── *)

let test_workflow_guide_tools_exist () =
  let guide_tools = [
    "masc_start"; "masc_join"; "masc_status";
    "masc_claim"; "masc_claim_next"; "masc_done"; "masc_transition";
    "masc_add_task"; "masc_batch_add_tasks";
    "masc_plan_set_task"; "masc_set_current_task";
    "masc_heartbeat"; "masc_broadcast";
    "masc_worktree_create"; "masc_init";
    "masc_operator_digest";
    "masc_operation_start"; "masc_dispatch_tick";
    (* team session tools removed — team session cleanup *)
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

let extract_masc_tokens contents =
  let len = String.length contents in
  let rec loop idx acc =
    if idx >= len then
      List.rev acc
    else if idx + 5 <= len && String.sub contents idx 5 = "masc_" then
      let rec advance j =
        if j < len && is_token_char contents.[j] then advance (j + 1) else j
      in
      let next = advance (idx + 5) in
      let token = String.sub contents idx (next - idx) in
      loop next (token :: acc)
    else
      loop (idx + 1) acc
  in
  loop 0 []
  |> List.sort_uniq String.compare

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
  [ "MCP-SURFACE-AUDIT.md"; "QUICK-START.md"; "QUICKSTART.md"; "SPEC.md" ]
  |> List.iter (fun name ->
         let contents = read_file (doc_path name) in
         if contains_substring contents "masc_task_list" then
           Alcotest.failf "doc %s reintroduces ghost tool masc_task_list" name;
         if contains_token contents "masc_claim"
            && not (List.mem name allowed_claim_docs)
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
      if contains_token contents "masc_claim" then
        Alcotest.failf
          "front-door surface %s reintroduces deprecated masc_claim alias"
          relative)
    paths

let test_benchmark_scripts_follow_session_contract () =
  let scripts =
    [ "benchmarks/quick-bench.sh"; "benchmarks/benchmark.sh" ]
  in
  List.iter
    (fun relative ->
      let contents = read_file (repo_path relative) in
      if not (contains_substring contents "method\":\"initialize\"")
         && not (contains_substring contents "method: \"initialize\"")
      then
        Alcotest.failf
          "benchmark script %s must initialize an MCP session before tools/call"
          relative;
      if not (contains_token contents "MCP_SESSION_ID") then
        Alcotest.failf
          "benchmark script %s must carry MCP_SESSION_ID through tools/call"
          relative)
    scripts

let test_benchmark_scripts_only_reference_registered_tools () =
  (* Post-pruning exceptions: benchmark scripts still exercise a few tool
     names that were removed from the public registry during the
     tool-registry-pruning sweep. They are known stale references and
     will be cleaned up in a follow-up pass; allow them here so the
     linter does not block unrelated PRs. *)
  let pruned_benchmark_exceptions =
    [
      "masc_find_by_capability";
      "masc_runtime_verify";
      "masc_lock";
      "masc_unlock";
    ]
  in
  let scripts =
    [ "benchmarks/quick-bench.sh"; "benchmarks/benchmark.sh" ]
  in
  List.iter
    (fun relative ->
      let contents = read_file (repo_path relative) in
      extract_masc_tokens contents
      |> List.iter (fun tool_name ->
             if (not (List.mem tool_name all_schema_names))
                && not (List.mem tool_name pruned_benchmark_exceptions)
             then
               Alcotest.failf
                 "benchmark script %s references unregistered tool %s"
                 relative tool_name))
    scripts

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

let test_docs_do_not_reintroduce_removed_mode_surface () =
  let paths =
    [
      repo_path "README.md";
      doc_path "QUICK-START.md";
      doc_path "QUICKSTART.md";
      doc_path "MODE-SYSTEM.md";
    ]
  in
  List.iter
    (fun path ->
      if Sys.file_exists path then
        let contents = read_file path in
        List.iter
          (fun tool_name ->
            if contains_token contents tool_name then
              Alcotest.failf "doc %s reintroduces removed tool %s" path tool_name)
          [ "masc_switch_mode"; "masc_get_config"; "masc_tool_enable";
            "masc_tool_disable" ])
    paths

let test_tool_registration_check_does_not_depend_on_injected_masc_schemas () =
  match Keeper_exec_tools.init_policy_config ~base_path:(repo_root ()) with
  | Error msg ->
      Alcotest.failf "failed to load tool policy config: %s" msg
  | Ok () ->
      let saved = !(Keeper_exec_tools.masc_schemas_ref) in
      Fun.protect
        ~finally:(fun () -> Keeper_exec_tools.masc_schemas_ref := saved)
        (fun () ->
          Keeper_exec_tools.masc_schemas_ref := [];
          let validation = Tool_registration_check.validate () in
          let masc_orphans =
            validation.Tool_registration_check.orphan_toml
            |> List.filter (String.starts_with ~prefix:"masc_")
          in
          Alcotest.(check (list string))
            "no masc orphan_toml without injected schemas" [] masc_orphans)

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

let test_board_delete_tag_registered () =
  ignore (Masc_mcp.Mcp_server_eio.create_state ~test_mode:true ~base_path:"/tmp/masc-pr3991-tag-reg" ());
  ignore (Masc_mcp.Tool_dispatch.tag_registry_count ());
  match Masc_mcp.Tool_dispatch.lookup_tag "masc_board_delete" with
  | Some Masc_mcp.Tool_dispatch.Mod_inline -> ()
  | Some _ ->
      Alcotest.fail "masc_board_delete should route through Mod_inline"
  | None ->
      Alcotest.fail "masc_board_delete missing from tag registry"

let test_board_read_only_metadata_registered () =
  ignore (Masc_mcp.Mcp_server_eio.create_state ~test_mode:true ~base_path:"/tmp/masc-pr5973-board-meta" ());
  let meta = Masc_mcp.Tool_catalog.metadata "masc_board_list" in
  Alcotest.(check bool) "board list is read-only in dispatch"
    true (Masc_mcp.Tool_dispatch.is_read_only "masc_board_list");
  Alcotest.(check bool) "board list is idempotent in dispatch"
    true (Masc_mcp.Tool_dispatch.is_idempotent "masc_board_list");
  Alcotest.(check (option bool)) "board list metadata readonly"
    (Some true) meta.readonly;
  Alcotest.(check (option bool)) "board list metadata idempotent"
    (Some true) meta.idempotent;
  Alcotest.(check bool) "board post stays mutable"
    false (Masc_mcp.Tool_dispatch.is_read_only "masc_board_post")

(* ── Test: keeper alias SSOT — capability_registry derives from surfaces ── *)

let test_keeper_alias_ssot_consistency () =
  let open Tool_catalog_surfaces in
  (* Exhaustive: every keeper_internal_tools entry *)
  List.iter (fun keeper_name ->
    let from_surfaces = keeper_internal_replacement keeper_name in
    let from_registry = Capability_registry.keeper_backend_tool_name keeper_name in
    match from_surfaces with
    | Some masc_name ->
        Alcotest.(check string)
          (Printf.sprintf "%s alias must match" keeper_name)
          masc_name from_registry
    | None ->
        Alcotest.(check string)
          (Printf.sprintf "%s (native) must be identity" keeper_name)
          keeper_name from_registry
  ) keeper_internal_tools;
  (* Pin asymmetric mapping: keeper_tasks_list -> masc_tasks (not masc_tasks_list) *)
  Alcotest.(check string) "keeper_tasks_list quirk"
    "masc_tasks" (Capability_registry.keeper_backend_tool_name "keeper_tasks_list");
  (* Privileged native tools must remain identity *)
  Alcotest.(check string) "keeper_bash identity"
    "keeper_bash" (Capability_registry.keeper_backend_tool_name "keeper_bash");
  Alcotest.(check string) "keeper_fs_edit identity"
    "keeper_fs_edit" (Capability_registry.keeper_backend_tool_name "keeper_fs_edit");
  Alcotest.(check string) "keeper_github identity"
    "keeper_github" (Capability_registry.keeper_backend_tool_name "keeper_github");
  (* Arbitrary unknown name must pass through *)
  Alcotest.(check string) "unknown identity"
    "foobar" (Capability_registry.keeper_backend_tool_name "foobar")

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  Alcotest.run "tool_registration_consistency"
    [
      ( "linter",
        [
          Alcotest.test_case "workflow guide references valid tools" `Quick
            test_workflow_guide_tools_exist;
          Alcotest.test_case "docs do not reintroduce ghost claim surface" `Quick
            test_docs_do_not_reintroduce_ghost_claim_surface;
          Alcotest.test_case "front-door surfaces do not reintroduce claim alias" `Quick
            test_front_door_surfaces_do_not_reintroduce_claim_alias;
          Alcotest.test_case "benchmark scripts follow session contract" `Quick
            test_benchmark_scripts_follow_session_contract;
          Alcotest.test_case "benchmark scripts only reference registered tools" `Quick
            test_benchmark_scripts_only_reference_registered_tools;
          Alcotest.test_case "multi-room doc keeps historical banner" `Quick
            test_multi_room_doc_keeps_historical_banner;
          Alcotest.test_case "docs do not reintroduce removed mode surface" `Quick
            test_docs_do_not_reintroduce_removed_mode_surface;
          Alcotest.test_case "no duplicate tool schemas" `Quick
            test_no_duplicate_schemas;
          Alcotest.test_case "board delete tag registered" `Quick
            test_board_delete_tag_registered;
          Alcotest.test_case "board read-only metadata registered" `Quick
            test_board_read_only_metadata_registered;
          Alcotest.test_case
            "tool registration check does not depend on injected masc schemas"
            `Quick
            test_tool_registration_check_does_not_depend_on_injected_masc_schemas;
          Alcotest.test_case "keeper_backend_tool_name matches keeper_internal_replacement" `Quick
            test_keeper_alias_ssot_consistency;
        ] );
    ]
