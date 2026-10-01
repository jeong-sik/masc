(** Which lane is handed the attached-tool listing.

    The listing is only useful to a lane that can widen a running turn, and
    exactly one can: {!Agent_core.Agent.extend_tools} reaches the agent that
    {!Runtime_agent} publishes, and nothing publishes one on the
    official-client lanes. Claude Code fixes its tool set in the spawn argv,
    Codex in [thread/start], Antigravity at turn start, and on all three the
    surface digest is part of a resumable session's identity.

    So a Keeper on one of those lanes that was handed the listing would read a
    tool name and be told there is no agent to make it callable in — with no
    other way to reach the service it attached. The bundle therefore carries
    both shapes and the lane picks. *)

open Alcotest
open Masc

let () = Mirage_crypto_rng_unix.use_default ()

let provider () =
  let declaration =
    {|
id = "atlassian"
label = "Atlassian"
mcp_url = "https://mcp.atlassian.com/v1/mcp/authv2"
access_token_env = "ATLASSIAN_ACCESS_TOKEN"
expires_at_env = "ATLASSIAN_ACCESS_TOKEN_EXPIRES_AT"
refresh_token_file = "/home/keeper/.atlassian/refresh_token"
renew_before_sec = 600
|}
  in
  match Keeper_oauth_provider.load ~file_name:"atlassian" ~contents:declaration with
  | Ok provider -> provider
  | Error e ->
    failf "the declaration must parse: %s" (Keeper_oauth_provider.error_to_string e)
;;

let offered names =
  let catalog =
    { Keeper_identity_tools.provider_id = "atlassian"
    ; provider_label = "Atlassian"
    ; discovered_at = 0.0
    ; tools =
        List.map
          (fun name ->
             { Mcp_client.name
             ; description = "Does one thing for Atlassian."
             ; input_schema = `Assoc [ "type", `String "object" ]
             ; read_only = Some true
             })
          names
    }
  in
  (Keeper_identity_tools.agent_tools ~provider:(provider ()) catalog)
    .Keeper_identity_tools.offered
;;

let make_meta () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String "lane-scope"
          ; "trace_id", `String "test-trace-lane-scope"
          ])
  with
  | Ok meta -> meta
  | Error e -> failf "make_meta failed: %s" e
;;

let tool_names tools =
  List.map (fun (tool : Agent_core.Tool.t) -> tool.Agent_core.Tool.schema.name) tools
;;

(* No descriptors, so the only difference between the two shapes is the one
   under test. *)
let with_bundle
      ?(history = [])
      ?(attached = true)
      ?(with_loader = true)
      ?skills
      ?retained_agent
      ?(prepare = fun _ -> ())
      f
  =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let dir = Filename.temp_file "masc_lane_scope" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Masc_test_deps.with_publication_recovery_registry
    ~sw
    ~fs:(Eio.Stdenv.fs env)
    ~registry_root:dir
  @@ fun registry ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  prepare dir;
  let meta = make_meta () in
  (* The production loader reads current task ownership from the live owner
     inventory before recording a load receipt. A retained Agent therefore
     needs the same persisted metadata and owner lifecycle as a real turn. *)
  (match retained_agent with
   | None -> ()
   | Some _ ->
     let config = Workspace.default_config dir in
     (match Keeper_meta_store.replace_snapshot config meta with
      | Ok () -> ()
      | Error detail -> fail detail);
     (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
       ~on_turn_slot_released:None config with
      | Ok count -> check int "the retained Agent has one real metadata owner" 1 count
      | Error error -> fail (Keeper_owner_registry.install_error_to_string error)));
  (* No skills unless a case passes a snapshot and its catalog, so the bundle
     carries no composition tools and the only difference between the two
     shapes is the one under test. A Skill-bearing bundle is refused without a
     frozen activation context, so a case with skills gets one, built from the
     same snapshot the catalog came from. *)
  let snapshot, skill_catalog, skill_activation_context =
    match skills with
    | None ->
      let snapshot =
        match Skill_source_config.parse_text "" with
        | Error _ -> failf "an empty skill source config must parse"
        | Ok config ->
          (match Skill_catalog_snapshot.configured ~config [] with
           | Ok snapshot -> snapshot
           | Error _ -> failf "an empty skill snapshot must build")
      in
      snapshot, Keeper_skill_catalog.empty, None
    | Some (snapshot, catalog) ->
      let trace_id = meta.Keeper_meta_contract.runtime.trace_id in
      let context =
        match
          Keeper_skill_activation_recorder.make
            ~trace_id
            ~runtime_id:(fun () -> Some "test.runtime")
            ~turn_ref:
              (Ids.Turn_ref.make
                 ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
                 ~absolute_turn:1)
            ~snapshot_revision:(Skill_catalog_snapshot.snapshot_revision snapshot)
            ~task_selection:Keeper_task_skill_turn.empty
        with
        | Ok context -> context
        | Error error -> fail (Keeper_skill_activation_recorder.error_to_string error)
      in
      snapshot, catalog, Some context
  in
  let capability_surface =
    Keeper_capability_surface.create
      ~tool_deny:[]
      ~sandbox_profile:Masc.Keeper_types_profile.Docker
      ~skill_names:None
      ~global_skill_catalog:skill_catalog
      ~skill_inventory:(Keeper_skill_inventory.of_snapshot snapshot)
      ~task_skills:[]
  in
  let context = Agent_core.Context.create_sync () in
  let load_receipts =
    match Keeper_tool_load_receipts.restore ~source:context ~target:context with
    | Ok restored -> restored
    | Error error -> fail (Keeper_tool_load_receipts.error_to_string error)
  in
  let agent_cell = match retained_agent with Some cell -> cell | None -> ref None in
  let identity_surface =
    if with_loader then
      Some
        { Keeper_tools_agent_core.offered =
            offered (if attached then [ "jira_search"; "confluence_search" ] else [])
        ; agent_cell
        ; history
        ; load_receipts
        ; keeper_turn_id = 1
        }
    else None
  in
  let bundle =
    Keeper_tools_agent_core_bundle.make_tool_bundle_for_capability_surface
      ~config:(Workspace.default_config dir)
      ~meta
      ~publication_recovery:
        Keeper_publication_recovery_availability.
          { provider = Masc_test_deps.publication_recovery_provider registry
          ; keeper_name = meta.Keeper_meta_contract.name
          }
      ~ctx_snapshot:(Keeper_context_runtime.create ~eio:false ~system_prompt:"test")
      ?identity_surface
      ?skill_activation_context
      ~capability_surface
      ()
  in
  (match retained_agent with
   | None -> ()
   | Some cell ->
     cell := Some (Agent_core.Agent.create ~net:env#net ~context
       ~config:(Agent_core.Types.default_config ~model:"test-model")
       ~tools:bundle.Keeper_tools_agent_core.agent_core_tools ()));
  Fun.protect ~finally:bundle.Keeper_tools_agent_core.cleanup (fun () -> f bundle)
;;

let called name =
  { Agent_core.Types.role = Agent_core.Types.Assistant
  ; content =
      [ Agent_core.Types.ToolUse
          { id = "toolu_fixture"
          ; name
          ; input = `Assoc []
          }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

(* Every tool in this bundle whose own file declares [defer_loading = true],
   whether or not the turn ended up placing it. *)
(* The two halves of [listing], for a bundle a case already has in hand. *)
let listing_placed bundle =
  match bundle.Keeper_tools_agent_core.listing with
  | Keeper_tools_agent_core.No_listing -> false
  | Keeper_tools_agent_core.Listing _ -> true
;;

let listing_deferred_names bundle =
  match bundle.Keeper_tools_agent_core.listing with
  | Keeper_tools_agent_core.No_listing -> []
  | Keeper_tools_agent_core.Listing { deferred_builtin_names } -> deferred_builtin_names
;;

let declared_deferrable bundle =
  List.filter
    (fun name ->
       match Keeper_tool_descriptor.declared_loading_of_model_name name with
       | Tool_definition_toml.Deferrable -> true
       | Tool_definition_toml.Always_loaded -> false)
    (tool_names bundle.Keeper_tools_agent_core.tools)
;;

let test_the_official_client_lanes_get_the_tools_themselves () =
  with_bundle (fun bundle ->
    let names = tool_names bundle.Keeper_tools_agent_core.tools in
    List.iter
      (fun name ->
         check
           bool
           (Printf.sprintf "%s is sent to a lane that cannot widen a turn" name)
           true
           (List.mem name names))
      [ "atlassian_jira_search"; "atlassian_confluence_search" ])
;;

(* A result bound is declared only for a tool whose result MASC bounds. An
   attached-service result reaches the wire as the service returned it, so a
   bound on one would let the client inline a result of any size as if it
   fitted. *)
let test_only_bounded_tools_declare_a_result_bound () =
  with_bundle (fun bundle ->
    let sent = tool_names bundle.Keeper_tools_agent_core.tools in
    let bounds = bundle.Keeper_tools_agent_core.result_bounds in
    let bounded = List.map fst bounds in
    List.iter
      (fun name ->
         check
           bool
           (Printf.sprintf "%s is an attached-service tool and declares no bound" name)
           false
           (List.mem name bounded))
      [ "atlassian_jira_search"; "atlassian_confluence_search" ];
    check bool "the built-ins declare their bound" true (bounds <> []);
    let default_descriptor =
      Keeper_tool_descriptor.model_visible_descriptors ()
      |> List.find (fun (descriptor : Keeper_tool_descriptor.t) ->
           match descriptor.model_output_projection with
           | Tool_output.Store_above _ -> true
           | Tool_output.Inline_up_to _ -> false)
    in
    let default_name =
      List.hd (Keeper_tool_descriptor.keeper_model_names default_descriptor)
    in
    check
      (option int)
      "a built-in declares the Claude Code ceiling used by its projection"
      (Some Runtime_execution.claude_code_inline_result_bytes)
      (List.assoc_opt default_name bounds);
    List.iter
      (fun (name, bytes) ->
         check
           bool
           (Printf.sprintf "%s is a tool this turn sends" name)
           true
           (List.mem name sent);
         check bool (Printf.sprintf "%s declares a positive bound" name) true (bytes > 0))
      bounds)
;;

let test_the_agent_core_lane_gets_the_listing_instead () =
  with_bundle (fun bundle ->
    let listed = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    let sent = tool_names bundle.Keeper_tools_agent_core.tools in
    List.iter
      (fun name ->
         check
           bool
           (Printf.sprintf "%s is not sent as a schema on this lane" name)
           false
           (List.mem name listed))
      [ "atlassian_jira_search"; "atlassian_confluence_search" ];
    (* What the lane view drops is every tool held back, whatever its source:
       the attached ones, which are held by default, and the built-ins whose
       own tool file declares [defer_loading = true]. What it gains in their
       place is one listing. *)
    let dropped = List.filter (fun n -> not (List.mem n listed)) sent in
    check
      bool
      "the attached tools are among what the lane view drops"
      true
      (List.for_all
         (fun n -> List.mem n dropped)
         [ "atlassian_confluence_search"; "atlassian_jira_search" ]);
    check
      (list string)
      "and every other dropped tool is one that declared itself deferrable"
      []
      (List.filter
         (fun n ->
            (not (List.mem n [ "atlassian_confluence_search"; "atlassian_jira_search" ]))
            &&
            match Keeper_tool_descriptor.declared_loading_of_model_name n with
            | Tool_definition_toml.Deferrable -> false
            | Tool_definition_toml.Always_loaded -> true)
         dropped);
    let gained = List.filter (fun n -> not (List.mem n sent)) listed in
    check int "and gains exactly one tool in their place" 1 (List.length gained))
;;

(* The axis this change adds: a built-in leaves the request because its own
   file says so, not because of where it came from. Of 89 built-ins on one
   Keeper, 33 went a whole day uncalled -- 21,601 bytes on every request of
   every turn, and a turn is many requests. *)
let test_a_builtin_that_declares_deferral_leaves_the_request () =
  with_bundle (fun bundle ->
    let listed = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    let sent = tool_names bundle.Keeper_tools_agent_core.tools in
    let declared_deferrable = declared_deferrable bundle in
    check
      bool
      "at least one built-in declares deferral, or this proves nothing"
      true
      (declared_deferrable <> []);
    check
      (list string)
      "no tool that declared deferral is sent as a schema on this lane"
      []
      (List.filter (fun n -> List.mem n listed) declared_deferrable);
    (* The model knows masc_browser_read as BrowserRead. Its declaration is in
       the file named for the internal name, and a lookup by the model name
       once missed it and kept the schema on every request. *)
    if List.mem "BrowserRead" sent
    then
      check
        bool
        "a tool the model knows by a public name follows its own file"
        false
        (List.mem "BrowserRead" listed);
    (* And the lanes that cannot widen a turn still get every one of them:
       a name they cannot load is a name they cannot reach. *)
    check
      bool
      "the lanes that cannot widen a turn still get them as schemas"
      true
      (List.for_all (fun n -> List.mem n sent) declared_deferrable))
;;

(* A Skill composition declares [defer_loading] in its composition block, not
   in a [config/tools] file. Two compositions over the same node tool, one
   declaring deferral and one not, so the declaration is the only thing that
   separates them. *)
let composition_skill_document ~name ~defer_line =
  Printf.sprintf
    "---\nname: %s\ndescription: Read the Keeper lane status.\n---\n\nComposition fixture.\n\n```toml composition\n[[compositions]]\nname = \"%s\"\nexecution = \"inline\"\n%s\n[[compositions.nodes]]\nid = \"lane\"\ntool = \"keeper_lane_status\"\n[compositions.nodes.input]\nkind = \"literal\"\nvalue = {}\n```\n"
    name
    name
    defer_line
;;

let composition_skill_snapshot documents =
  let config_text =
    {|[skills]
resource-read-max-bytes = 16384
[[skills.sources]]
id = "composition-fixture"
anchor = "base-path"
path = "skills"
access = "read-write"
|}
  in
  let skill_config =
    match Skill_source_config.parse_text config_text with
    | Ok config -> config
    | Error _ -> fail "composition Skill source fixture was rejected"
  in
  let source =
    match skill_config.Skill_source_config.sources with
    | [ source ] -> source
    | _ -> fail "composition Skill fixture must have one source"
  in
  let scan : Skill_catalog_snapshot.source_scan =
    { source =
        Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source
    ; observation =
        Skill_catalog_snapshot.Source_ready
          { resolved_path = "/workspace/skills"; candidates = List.length documents }
    ; candidates =
        List.map
          (fun (directory, source_text) ->
             Skill_catalog_snapshot.Candidate_document { directory; source_text })
          documents
    }
  in
  let snapshot =
    match Skill_catalog_snapshot.configured ~config:skill_config [ scan ] with
    | Ok snapshot -> snapshot
    | Error _ -> fail "composition Skill snapshot fixture was rejected"
  in
  match Keeper_skill_catalog.of_snapshot snapshot with
  | catalog, [] -> snapshot, catalog
  | _, diagnostic :: _ ->
    failf
      "composition fixture was rejected as a skill: %s"
      (Keeper_skill_catalog.error_to_string diagnostic.error)
;;

let composition_tool_name catalog name =
  match
    List.find_map
      (fun (skill : Keeper_skill_catalog.skill) ->
         match skill.surface with
         | Keeper_skill_catalog.Composition entry
           when String.equal entry.Keeper_tool_composition_catalog.name name ->
           Some (Keeper_tool_composition_catalog.tool_name entry)
         | Keeper_skill_catalog.Composition _ | Keeper_skill_catalog.Instruction -> None)
      (Keeper_skill_catalog.skills catalog)
  with
  | Some tool_name -> tool_name
  | None -> failf "composition %S is not in the fixture catalog" name
;;

let test_a_composition_that_declares_deferral_leaves_the_request () =
  let ((_, skill_catalog) as skills) =
    composition_skill_snapshot
      [ ( "lane-deferred"
        , composition_skill_document ~name:"lane-deferred" ~defer_line:"defer_loading = true" )
      ; "lane-loaded", composition_skill_document ~name:"lane-loaded" ~defer_line:""
      ]
  in
  let deferred = composition_tool_name skill_catalog "lane-deferred" in
  let loaded = composition_tool_name skill_catalog "lane-loaded" in
  with_bundle ~skills (fun bundle ->
    let sent = tool_names bundle.Keeper_tools_agent_core.tools in
    let listed = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    let held = listing_deferred_names bundle in
    check
      bool
      "both compositions reach the bundle, or this proves nothing"
      true
      (List.mem deferred sent && List.mem loaded sent);
    check
      bool
      "the composition that declared deferral is not sent as a schema"
      false
      (List.mem deferred listed);
    check bool "and the listing names it" true (List.mem deferred held);
    check
      bool
      "the composition that declared nothing is sent as a schema"
      true
      (List.mem loaded listed);
    check bool "and the listing does not name it" false (List.mem loaded held);
    let bounds = bundle.Keeper_tools_agent_core.result_bounds in
    check
      (option int)
      "the deferred composition carries its actual projection ceiling"
      (Some Common.max_tool_result_wire_bytes)
      (List.assoc_opt deferred bounds);
    check
      (option int)
      "the loaded composition carries its actual projection ceiling"
      (Some Common.max_tool_result_wire_bytes)
      (List.assoc_opt loaded bounds))
;;

(* Deterministic production-handler sequence, not a model-selection test.
   Discovery, loading and the generated composition all use the same bundle
   and retained Agent. The leaf reads use an isolated real Board store. *)
let test_deferred_composition_discovery_load_and_execution () =
  let document = {|---
name: deferred-board-read
description: Read board posts for the current lane profile.
---
```toml composition
[[compositions]]
name = "deferred-board-read"
execution = "inline"
defer_loading = true
[[compositions.params]]
name = "query"
type = "string"
description = "FTS5 query used by the first real capability-search node."
[[compositions.nodes]]
id = "probe"
tool = "keeper_capability_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "param"
name = "query"
[[compositions.nodes]]
id = "lane"
tool = "keeper_lane_status"
after = ["probe"]
input = { kind = "literal", value = {} }
[[compositions.nodes]]
id = "search"
tool = "masc_board_search"
after = ["lane"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "lane"
pointer = "/profile"
```
|} in
  let ((_, catalog) as skills) =
    composition_skill_snapshot ["deferred-board-read", document] in
  let name = composition_tool_name catalog "deferred-board-read" in
  let reference = match (List.hd (Keeper_skill_catalog.skills catalog)).reference with
    | Some reference -> reference | None -> fail "missing exact Skill reference" in
  let cell = ref None in
  let workspace = ref None in
  let seeded_id = ref "" in
  let previous_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect ~finally:(fun () ->
    Keeper_tool_call_log.reset_for_testing ();
    Board_dispatch.reset_for_test ();
    Board.reset_global_for_test ();
    (match previous_base with
     | Some value -> Unix.putenv "MASC_BASE_PATH" value
     | None -> Unix.unsetenv "MASC_BASE_PATH")) @@ fun () ->
  with_bundle ~attached:false ~skills ~retained_agent:cell
    ~prepare:(fun dir ->
      workspace := Some (Workspace.default_config dir);
      Unix.putenv "MASC_BASE_PATH" dir;
      Keeper_tool_call_log.reset_for_testing ();
      Keeper_tool_call_log.init ~base_path:dir ();
      Board.reset_global_for_test ();
      Board_dispatch.reset_for_test ();
      Board_dispatch.init_jsonl ();
      match Board_dispatch.create_post ~author:"fixture" ~content:(Keeper_types_profile_sandbox.sandbox_profile_to_string (make_meta ()).sandbox_profile ^ " joined evidence")
        ~post_kind:Board.Human_post () with
      | Ok post -> seeded_id := Board.Post_id.to_string post.Board.id
      | Error _ -> fail "isolated Board seed failed")
    (fun _bundle ->
      let agent = match !cell with Some agent -> agent | None -> fail "Agent missing" in
      let config = match !workspace with Some config -> config | None -> fail "workspace missing" in
      let decode_json content =
        match Tool_output.decode_from_agent_core content with
        | Tool_output.Not_marker -> Yojson.Safe.from_string content
        | Tool_output.Invalid_marker { detail } -> fail detail
        | Tool_output.Decoded reference ->
          let stored =
            match Tool_blob_store.fetch
              (Tool_blob_store.create ~base_path:config.base_path)
              ~sha256:reference.sha256 with
            | Ok (Some payload) ->
              check int "stored output matches its declared byte count"
                reference.bytes (String.length payload);
              Yojson.Safe.from_string payload
            | Ok None -> fail "composition output blob is absent"
            | Error error -> fail (Tool_blob_store.fetch_error_to_string error) in
          if String.equal reference.mime Tool_output.artifact_manifest_mime then
            (match Tool_output.artifact_manifest_of_json stored with
             | Tool_output.Decoded_artifact_manifest { structured_content; _ } ->
               structured_content
             | Tool_output.Not_artifact_manifest ->
               fail "composition output is not a typed result manifest"
             | Tool_output.Invalid_artifact_manifest { detail } -> fail detail)
          else stored in
      let find name = match Agent_core.Tool_set.find name (Agent_core.Agent.tools agent) with
        | Some tool -> tool | None -> failf "tool %s is not callable" name in
      let execute_raw id tool input =
        let invocation = Agent_core.Tool_contract.Invocation.create
          ~tool_use_id:id ~turn:1
          ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1;
                      execution_mode = Agent_core.Tool_contract.Concurrent }
          ~completion:Agent_core.Tool_contract.Continue_after_success in
        Agent_core.Tool.execute ~invocation tool input in
      let execute id tool input =
        match execute_raw id tool input with
        | Ok output -> decode_json output.content
        | Error error -> failf "real handler failed: %s" error.Agent_core.Types.message in
      check bool "generated schema absent before discovery" false
        (Agent_core.Tool_set.mem name (Agent_core.Agent.tools agent));
      let discovery = execute "discover" (find "keeper_capability_search")
        (`Assoc ["query", `String "\"deferred-board-read\""]) in
      let open Yojson.Safe.Util in
      let matches = discovery |> member "matches" |> to_list in
      check bool "discovery names the exact generated invocation" true
        (List.exists (fun row -> member "invocation_name" row = `String name
          && (row |> member "candidate" |> member "capability" |> member "reference")
             = Skill_reference.to_yojson reference) matches);
      check bool "discovery does not load schema" false
        (Agent_core.Tool_set.mem name (Agent_core.Agent.tools agent));
      (* Loading returns human-readable schema text, not JSON. Its typed
         success must precede the same Agent's callable-schema assertion. *)
      (match execute_raw "load" (find Keeper_identity_tool_search.tool_name)
        (`Assoc ["names", `List [`String name]]) with
       | Ok _ -> ()
       | Error error ->
           failf "real load handler failed: %s" error.Agent_core.Types.message);
      let loaded = find name in
      let before = Board_dispatch.list_posts () in
      let result = execute "run-composition" loaded (`Assoc ["query", `String "board"]) in
      let actions = result |> member "actions" |> to_list in
      check (list string) "real executor settles producer then consumer" ["probe"; "lane"; "search"]
        (List.map (fun row -> member "node_id" row |> to_string) actions);
      let lane = List.nth actions 1 in
      let search = List.nth actions 2 in
      List.iter (fun row -> check string "nested action completed" "completed"
        (row |> member "result" |> member "disposition" |> to_string)) actions;
      check string "consumer binds the actual producer profile"
        (lane |> member "result" |> member "data" |> member "profile" |> to_string)
        (search |> member "input" |> member "query" |> to_string);
      let search_text = search |> member "result" |> member "data" |> to_string in
      check bool "real Board search returns the seeded post" true
        (List.exists (fun line ->
          match String.split_on_char ' ' line with
          | id :: _ -> String.equal id !seeded_id
          | [] -> false) (String.split_on_char '\n' search_text));
      let evidence () = match Keeper_skill_composition_evidence.load_latest config reference with
        | Ok (Some evidence) -> Keeper_skill_composition_evidence.to_yojson evidence
        | Ok None -> fail "no exact-reference composition evidence"
        | Error error -> fail (Keeper_skill_composition_evidence.error_to_string error) in
      let success_evidence = evidence () in
      check string "durable success belongs to this exact invocation" "run-composition"
        (success_evidence |> member "parent_tool_use_id" |> to_string);
      check string "durable outer success completed" "completed"
        (success_evidence |> member "result" |> member "disposition" |> to_string);
      check string "durable settlements equal the actual returned actions"
        (Yojson.Safe.sort (`List actions) |> Yojson.Safe.to_string)
        (success_evidence |> member "executor_settlements" |> Yojson.Safe.sort |> Yojson.Safe.to_string);
      (match execute_raw "run-invalid-query" loaded (`Assoc ["query", `String "\""]) with
       | Error _ -> ()
       | Ok _ -> fail "malformed FTS producer unexpectedly completed");
      let failure_evidence = evidence () in
      check string "durable failure belongs to this exact invocation" "run-invalid-query"
        (failure_evidence |> member "parent_tool_use_id" |> to_string);
      check string "durable outer failure is failed" "failed"
        (failure_evidence |> member "result" |> member "disposition" |> to_string);
      let failed = failure_evidence |> member "executor_settlements" |> to_list in
      List.iter (fun row -> check string "real invalid FTS producer failed" "failed"
        (row |> member "result" |> member "disposition" |> to_string)) failed;
      check (list string) "failed real producer prevents both dependent dispatches" ["probe"]
        (List.map (fun row -> member "node_id" row |> to_string) failed);
      check int "read composition leaves Board post count unchanged"
        (List.length before) (List.length (Board_dispatch.list_posts ())))
;;

(* [Keeper_run_tools_setup] compares the bundle against what the descriptor
   projection says the surface should hold, and logs [Log.Error] every turn
   when they disagree. There are two surfaces now and they name the attached
   tools differently, so a check written for one of them passes while the
   other drifts. This pins the shape the Agent Core lane is checked against;
   [test_keeper_tool_bundle_classifiable] pins the other. *)
let test_the_agent_core_shape_is_what_the_projection_expects () =
  with_bundle (fun bundle ->
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        ~deferred_names:(listing_deferred_names bundle)
        ~skill_catalog:Keeper_skill_catalog.empty
        ~identity_names:[ Keeper_identity_tool_search.tool_name ]
        ~model_visible_descriptors:(Keeper_tool_descriptor.model_visible_descriptors ())
        ()
    in
    check
      (list string)
      "the listing stands for every attached tool and nothing else moved"
      expected
      (List.sort_uniq
         String.compare
         (tool_names bundle.Keeper_tools_agent_core.agent_core_tools)))
;;

let test_a_carried_tool_is_part_of_the_agent_core_identity_projection () =
  let jira = "atlassian_jira_search" in
  with_bundle ~history:[ called jira ] (fun bundle ->
    let actual = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    let identity_names =
      Keeper_run_tools_setup.agent_core_identity_names
        ~listed:true
        ~attached_names:[ jira; "atlassian_confluence_search" ]
        ~actual_names:actual
    in
    check
      (list string)
      "the listing and the carried schema are both projected"
      [ jira; Keeper_identity_tool_search.tool_name ]
      identity_names;
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        (* Same rule the setup uses: declared and not on the surface. A
           declared tool that is present -- because this conversation ran it --
           must not be subtracted, or the check expects it gone. *)
        ~deferred_names:
          (Keeper_run_tools_setup.deferred_names_absent_from
             ~declared_names:(declared_deferrable bundle)
             ~actual_names:actual)
        ~skill_catalog:Keeper_skill_catalog.empty
        ~identity_names
        ~model_visible_descriptors:(Keeper_tool_descriptor.model_visible_descriptors ())
        ()
    in
    check
      (list string)
      "the carried surface no longer produces a false projection mismatch"
      expected
      (List.sort_uniq String.compare actual))
;;

let test_an_unknown_actual_tool_stays_out_of_the_identity_expectation () =
  let jira = "atlassian_jira_search" in
  check
    (list string)
    "a configured carried tool is expected, an unknown actual tool is not"
    [ jira; Keeper_identity_tool_search.tool_name ]
    (Keeper_run_tools_setup.agent_core_identity_names
       ~listed:true
       ~attached_names:[ jira ]
       ~actual_names:[ jira; "unconfigured_service_tool" ])
;;

(* The two axes meet here. A built-in can declare [defer_loading = true] and
   still be on the surface, because this conversation has run it and a tool it
   has run is placed with its schema again.

   Live on 2026-08-31 this cost 60 [keeper_model_tool_projection_mismatch]
   errors in an hour: the bundle reported what declared itself deferrable, so
   the projection check expected [keeper_ide_annotate] to be gone from a
   Keeper that had called it the day before. What the check needs is what is
   actually missing. *)
let test_a_declared_tool_this_conversation_ran_is_not_reported_as_held () =
  let ran_a_declared_builtin =
    { Agent_core.Types.role = Agent_core.Types.Assistant
    ; content =
        [ Agent_core.Types.ToolUse
            { id = "toolu_fixture"; name = "keeper_ide_annotate"; input = `Assoc [] }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  with_bundle ~history:[ ran_a_declared_builtin ] (fun bundle ->
    let listed = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    check
      bool
      "the tool this conversation ran is on the surface despite its declaration"
      true
      (List.mem "keeper_ide_annotate" listed);
    (* Which is the whole point: the projection check subtracts what is
       missing from the surface, so a declared tool that is present must not
       be subtracted. *)
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        ~deferred_names:
          (Keeper_run_tools_setup.deferred_names_absent_from
             ~declared_names:(declared_deferrable bundle)
             ~actual_names:listed)
        ~skill_catalog:Keeper_skill_catalog.empty
        ~identity_names:
          (Keeper_run_tools_setup.agent_core_identity_names
       ~listed:true
             ~attached_names:[ "atlassian_jira_search"; "atlassian_confluence_search" ]
             ~actual_names:listed)
        ~model_visible_descriptors:(Keeper_tool_descriptor.model_visible_descriptors ())
        ()
    in
    check
      (list string)
      "so the projection check agrees with the surface"
      expected
      (List.sort_uniq String.compare listed))
;;

(* A Keeper with nothing attached still gets a listing, because a built-in can
   declare its own deferral. Deriving "is there a listing" from "is anything
   attached" left code-reviewer -- no attachment, declared built-ins -- logging
   keeper_tool_search as a tool the projection did not expect, twice in the
   two minutes after the fix for the previous mismatch went live. *)
let test_a_keeper_with_nothing_attached_still_gets_a_listing () =
  with_bundle ~attached:false (fun bundle ->
    let listed = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    check
      bool
      "the bundle reports that it placed a listing"
      true
      (listing_placed bundle);
    check
      bool
      "and the listing is on the surface"
      true
      (List.mem Keeper_identity_tool_search.tool_name listed);
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        ~deferred_names:
          (Keeper_run_tools_setup.deferred_names_absent_from
             ~declared_names:(declared_deferrable bundle)
             ~actual_names:listed)
        ~skill_catalog:Keeper_skill_catalog.empty
        ~identity_names:
          (Keeper_run_tools_setup.agent_core_identity_names
             ~listed:(listing_placed bundle)
             ~attached_names:[]
             ~actual_names:listed)
        ~model_visible_descriptors:(Keeper_tool_descriptor.model_visible_descriptors ())
        ()
    in
    check
      (list string)
      "so the projection check does not report the listing as unexpected"
      expected
      (List.sort_uniq String.compare listed))
;;

let test_a_surface_without_a_loader_keeps_builtin_schemas () =
  with_bundle ~attached:false ~with_loader:false (fun bundle ->
    check bool "no listing advertises an impossible extension" false
      (listing_placed bundle);
    check (list string) "every built-in remains directly callable"
      (tool_names bundle.Keeper_tools_agent_core.tools |> List.sort_uniq String.compare)
      (tool_names bundle.Keeper_tools_agent_core.agent_core_tools
       |> List.sort_uniq String.compare))
;;

(* And the thing the [listed] flag must not become: read back off the surface,
   it would expect the listing exactly when the listing is there. *)
let test_a_missing_listing_is_still_caught () =
  check
    (list string)
    "a listing the turn placed but the surface lost is still expected"
    [ "atlassian_jira_search"; Keeper_identity_tool_search.tool_name ]
    (Keeper_run_tools_setup.agent_core_identity_names
       ~listed:true
       ~attached_names:[ "atlassian_jira_search" ]
       ~actual_names:[ "atlassian_jira_search" ])
;;

(* The order the agent_core lane sends its tools in is the order the provider
   caches, and a prefix is reusable only byte-for-byte. The bundle states that
   order: the always-loaded tools first, then the listing, then the attached
   tools this conversation has already run. A set comparison does not see a
   reordering, and a reordering costs the whole prefix. *)
let test_the_agent_core_order_is_stated_by_the_bundle () =
  let jira = "atlassian_jira_search" in
  with_bundle (fun bundle ->
    let sent = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    check
      bool
      "with nothing carried, the listing is last"
      true
      (match List.rev sent with
       | last :: _ -> String.equal last Keeper_identity_tool_search.tool_name
       | [] -> false);
    check
      bool
      "no tool is sent twice"
      true
      (List.length (List.sort_uniq String.compare sent) = List.length sent));
  with_bundle ~history:[ called jira ] (fun bundle ->
    let sent = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    check
      (list string)
      "a carried tool follows the listing"
      [ Keeper_identity_tool_search.tool_name; jira ]
      (let rec from_listing = function
         | [] -> []
         | name :: rest
           when String.equal name Keeper_identity_tool_search.tool_name ->
           name :: rest
         | _ :: rest -> from_listing rest
       in
       from_listing sent))
;;

let () =
  run
    "attached tools lane scope"
    [ ( "the bundle"
      , [ test_case
            "hands the official-client lanes the tools themselves"
            `Quick
            test_the_official_client_lanes_get_the_tools_themselves
        ; test_case
            "hands the agent core lane the listing instead"
            `Quick
            test_the_agent_core_lane_gets_the_listing_instead
        ; test_case
            "declares a result bound only for a tool MASC bounds"
            `Quick
            test_only_bounded_tools_declare_a_result_bound
        ; test_case
            "holds back a built-in that declares deferral"
            `Quick
            test_a_builtin_that_declares_deferral_leaves_the_request
        ; test_case
            "holds back a Skill composition that declares deferral"
            `Quick
            test_a_composition_that_declares_deferral_leaves_the_request
        ; test_case "deferred composition discovery loads and executes real dependencies" `Quick
            test_deferred_composition_discovery_load_and_execution
        ; test_case
            "does not report a declared tool this conversation ran as held"
            `Quick
            test_a_declared_tool_this_conversation_ran_is_not_reported_as_held
        ; test_case
            "builds the agent core shape the projection expects"
            `Quick
            test_the_agent_core_shape_is_what_the_projection_expects
        ; test_case
            "projects an attached tool carried from history"
            `Quick
            test_a_carried_tool_is_part_of_the_agent_core_identity_projection
        ; test_case
            "gives a Keeper with nothing attached a listing"
            `Quick
            test_a_keeper_with_nothing_attached_still_gets_a_listing
        ; test_case "a surface without a loader keeps builtin schemas" `Quick
            test_a_surface_without_a_loader_keeps_builtin_schemas
        ; test_case
            "still expects a listing the surface lost"
            `Quick
            test_a_missing_listing_is_still_caught
        ; test_case
            "states the agent_core tool order"
            `Quick
            test_the_agent_core_order_is_stated_by_the_bundle
        ; test_case
            "does not explain an unknown actual tool"
            `Quick
            test_an_unknown_actual_tool_stays_out_of_the_identity_expectation
        ] )
    ]
;;
