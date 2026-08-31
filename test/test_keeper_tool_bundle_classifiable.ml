(** Every tool a keeper is handed must be one the approval policy can
    classify.

    [Keeper_tool_approval_policy.verdict_for] resolves a name through
    [Keeper_tool_descriptor] and asks when nothing owns it. That reject is the
    right answer for a name this build genuinely cannot classify, and the
    wrong one for a tool the bundle hands the model on purpose — the operator
    is asked about a call the policy simply failed to recognise, with a reason
    that tells them nothing they can act on.

    Such tools shipped that way. [keeper_compose_<name>],
    [keeper_composition_status] and [keeper_composition_cancel] are
    materialised as Agent-Core tools outside the descriptor registry, so
    every composition asked — including one whose whole plan is reads, while
    the same tools called directly ran unasked.

    Nothing caught it. The nearest test partitions [Descriptor.public_names ()]
    — the seven LLM-native names — against a hard-coded answer, and never
    looks at the bundle. So this walks the bundle the keeper actually gets and
    fails on any name the policy cannot place, whatever the reason it was
    added. A fifth kind of undescribed tool trips it on the way in rather than
    after an operator wonders why they are being asked. *)

open Alcotest
open Masc

module Policy = Keeper_tool_approval_policy

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK -> Unix.unlink path
;;

let with_publication_recovery_registry ~registry_root f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.with_publication_recovery_registry
    ~sw
    ~fs:(Eio.Stdenv.fs env)
    ~registry_root
    f
;;

let publication_recovery_turn_context ~registry ~keeper_name =
  Keeper_publication_recovery_availability.
    { provider = Masc_test_deps.publication_recovery_provider registry
    ; keeper_name
    }
;;

(* agent_name is not free-form: keeper_meta_json_parse rejects a meta whose
   agent_name is not "keeper-<name>-agent". Derived the way production does. *)
let make_meta ~name () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "trace_id", `String "test-trace-bundle-classifiable"
          ])
  with
  | Ok meta -> meta
  | Error e -> failf "make_meta failed: %s" e
;;

(* A bundle with no skills carries no composition tools, so a gate run
   against one would only ever see the descriptor half — and would pass
   while the tools this gate exists for were never in it. These two skills
   put every kind in: an inline composition and an async one (which is what
   brings keeper_composition_status and _cancel with it). *)
let composition_skill ~name ~execution =
  Printf.sprintf
    {|---
name: %s
description: A composition used by the bundle classification gate.
---

# %s

```toml composition
[[compositions]]
name = "%s"
description = "A composition used by the bundle classification gate."
execution = "%s"

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
```
|}
    name name name execution
;;

let instruction_document =
  "---\nname: gate-instruction\ndescription: what the gate reads\n---\n\nbody\n"
;;

let skill_snapshot_and_catalog () =
  let source_config =
    match
      Skill_source_config.parse_text
        "[skills]\nresource-read-max-bytes = 65536\n[[skills.sources]]\nid = \"bundle-fixture\"\nanchor = \"base-path\"\npath = \"skills\"\naccess = \"read-only\"\n"
    with
    | Ok config -> config
    | Error _ -> fail "bundle Skill source config was rejected"
  in
  let source =
    match source_config.sources with
    | [ source ] -> source
    | _ -> fail "bundle Skill source count changed"
  in
  let resolved =
    Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source
  in
  let documents =
    [ "gate-inline", composition_skill ~name:"gate-inline" ~execution:"inline"
    ; "gate-async", composition_skill ~name:"gate-async" ~execution:"async"
    ; "gate-instruction", instruction_document
    ]
  in
  let scan : Skill_catalog_snapshot.source_scan =
    { source = resolved
    ; observation =
        Skill_catalog_snapshot.Source_ready
          { resolved_path = "/workspace/skills"
          ; candidates = List.length documents
          }
    ; candidates =
        List.map
          (fun (directory, source_text) ->
             Skill_catalog_snapshot.Candidate_document { directory; source_text })
          documents
    }
  in
  let snapshot =
    match Skill_catalog_snapshot.configured ~config:source_config [ scan ] with
    | Ok snapshot -> snapshot
    | Error _ -> fail "bundle Skill snapshot was rejected"
  in
  match Keeper_skill_catalog.of_snapshot snapshot with
  | catalog, [] -> snapshot, catalog
  | _, _ :: _ -> fail "bundle Skill snapshot projection was rejected"
;;

let instruction_reference () =
  let source_id =
    match Skill_source_config.source_id_of_string "bundle-fixture" with
    | Ok source_id -> source_id
    | Error detail -> fail detail
  in
  let package_id =
    match Skill_reference.package_id_of_directory "gate-instruction" with
    | Ok package_id -> package_id
    | Error _ -> fail "invalid instruction fixture package"
  in
  Skill_reference.make
    ~identity:
      (Skill_reference.make_identity
         ~source_id
         ~package_id
         ~name:"gate-instruction")
    ~content_revision:
      (Skill_reference.content_revision_of_source_text instruction_document)
;;

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  n = 0 || scan 0
;;

(* An attached work service's tools reach the bundle the same way the
   composition ones do, and the policy places them from what the service said
   about each. Included here rather than only where they are built: this is
   the gate that walks what the model is actually handed, and a later path
   that hands one out without recording its annotation would make every call
   ask with a reason nobody can act on. *)
let identity_tools () =
  let declaration =
    {|
id = "atlassian"
label = "Atlassian"
mcp_url = "https://mcp.atlassian.com/v1/mcp/authv2"
access_token_env = "ATLASSIAN_ACCESS_TOKEN"
expires_at_env = "ATLASSIAN_ACCESS_TOKEN_EXPIRES_AT"
refresh_token_file = "/home/keeper/.atlassian/refresh_token"
renew_before_sec = 600

[authorize_params]
audience = "api.atlassian.com"
|}
  in
  let provider =
    match Keeper_oauth_provider.load ~file_name:"atlassian" ~contents:declaration with
    | Ok provider -> provider
    | Error e ->
      failf "the gate's own declaration must parse: %s"
        (Keeper_oauth_provider.error_to_string e)
  in
  let schema =
    `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  in
  let catalog =
    { Keeper_identity_tools.provider_id = "atlassian"
    ; provider_label = "Atlassian"
    ; discovered_at = 0.0
    ; tools =
        (* One of each thing a service can say, so the gate covers all three
           arms rather than the convenient one. *)
        [ { Mcp_client.name = "readsOnly"; description = "reads"
          ; input_schema = schema; read_only = Some true }
        ; { Mcp_client.name = "mayWrite"; description = "writes"
          ; input_schema = schema; read_only = Some false }
        ; { Mcp_client.name = "saidNothing"; description = "unannotated"
          ; input_schema = schema; read_only = None }
        ]
    }
  in
  (Keeper_identity_tools.agent_tools ~provider catalog)
    .Keeper_identity_tools.offered
;;

let snapshot_reference snapshot name =
  match Skill_catalog_snapshot.find_effective_by_name snapshot name with
  | Some entry -> Skill_catalog_snapshot.entry_reference entry
  | None -> failf "exact snapshot reference %s missing" name
;;

let assert_exact_activation snapshot expected
      (activation : Keeper_skill_activation_ledger.activation)
  =
  let observed =
    Skill_reference.make
      ~identity:activation.identity
      ~content_revision:activation.content_revision
  in
  check bool "exact identity and content revision" true
    (Skill_reference.equal expected observed);
  check bool "exact frozen snapshot revision" true
    (Skill_catalog_snapshot.equal_snapshot_revision
       (Skill_catalog_snapshot.snapshot_revision snapshot)
       activation.snapshot_revision)
;;

let with_bundle_tools
      ?(record_activations = true)
      f
  =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_bundle_classifiable_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists dir then remove_tree dir)
    (fun () ->
       let config = Workspace.default_config dir in
       let meta = make_meta ~name:"bundle-classifiable" () in
       let skill_snapshot, skill_catalog = skill_snapshot_and_catalog () in
       let trace_id = meta.runtime.trace_id in
       let session_dir =
         Keeper_fs.keeper_session_dir
           config
           (Keeper_id.Trace_id.to_string trace_id)
       in
       Unix.mkdir session_dir 0o700;
       let reference = instruction_reference () in
       let snapshot_revision =
         Skill_catalog_snapshot.snapshot_revision skill_snapshot
       in
       let skill_activation_context =
         let task_selection =
           match
             Keeper_task_skill_turn.resolve_for_task
               ~snapshot:skill_snapshot
               ~task_id:"task-001"
               [ reference ]
           with
           | Ok selection -> selection
           | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
         in
         match
           Keeper_skill_activation_recorder.make
             ~trace_id
             ~runtime_id:(fun () -> Some "test.runtime")
             ~turn_ref:
               (Ids.Turn_ref.make
                  ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
                  ~absolute_turn:1)
             ~snapshot_revision
             ~task_selection
         with
         | Ok context -> context
         | Error error ->
           fail (Keeper_skill_activation_recorder.error_to_string error)
       in
       let ctx_snapshot =
         Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
       in
       with_publication_recovery_registry ~registry_root:dir
       @@ fun publication_recovery_registry ->
       let publication_recovery =
         publication_recovery_turn_context
           ~registry:publication_recovery_registry
           ~keeper_name:meta.name
       in
       let composition_plan_index =
         Masc.Keeper_tool_composition_plan_index.create ()
       in
       let capability_surface =
         Keeper_capability_surface.create
           ~skill_names:None
           ~global_skill_catalog:skill_catalog
           ~skill_inventory:(Keeper_skill_inventory.of_snapshot skill_snapshot)
           ~task_skills:[]
       in
       let bundle =
         Keeper_tools_agent_core_bundle.make_tool_bundle_for_capability_surface
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot
           ~capability_surface
           ~identity_surface:
             { Masc.Keeper_tools_agent_core.offered = identity_tools ()
             ; agent_cell = ref None
             ; history = []
             }
           ~composition_plan_index
           ?skill_activation_context:
             (if record_activations then Some skill_activation_context else None)
           ()
       in
       Fun.protect ~finally:bundle.cleanup (fun () ->
         f
           config
           meta
           skill_snapshot
           composition_plan_index
           capability_surface
           bundle.tools))
;;

let with_bundle f =
  with_bundle_tools
  @@ fun _config _meta _skill_snapshot composition_plan_index _surface tools ->
  f composition_plan_index
    (List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) tools)
;;

(* The bundle is the model-visible surface, whole. It used to be narrowable
   per Keeper through declared tool groups, and this asserted that a Tool
   outside the declared groups did not reach the bundle; #31728 removed the
   declaration because no Keeper ever wrote one, so there is no outside left
   for a Tool to be in. *)
let test_the_bundle_is_the_model_visible_surface () =
  with_bundle_tools
  @@ fun _config _meta _skill_snapshot _composition_plan_index _surface tools ->
  let names =
    List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) tools
  in
  check bool "board Tool remains executable" true (List.mem "masc_board_list" names);
  check bool "Read is in the bundle, like every model-visible Tool" true
    (List.mem "Read" names)
;;

(* The handler is the tool. Reading only its schema would let a tool that
   answers nothing pass for one that works. *)
let run_tool ?(tool_use_id = "bundle-instruction-activation")
      (tool : Agent_core.Tool.t) input =
  let invocation =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id
      ~turn:0
      ~schedule:
        { planned_index = 0
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial
        }
      ~completion:(Agent_core.Tool.completion tool)
  in
  match
    tool.handler
      (Agent_core.Tool.Execution_env.create ~invocation ())
      input
  with
  | Ok output -> output.Agent_core.Llm_provider.Types.content
  | Error err -> err.Agent_core.Llm_provider.Types.message
;;

let fetch_blob_exn ~base_path reference =
  match
    Tool_blob_store.fetch
      (Tool_blob_store.create ~base_path)
      ~sha256:reference.Tool_output.sha256
  with
  | Ok (Some payload) -> payload
  | Ok None -> fail "capability output blob is absent"
  | Error error -> fail (Tool_blob_store.fetch_error_to_string error)
;;

let decode_tool_json ~base_path content =
  match Tool_output.decode_from_agent_core content with
  | Tool_output.Not_marker -> Yojson.Safe.from_string content
  | Tool_output.Invalid_marker { detail } -> fail detail
  | Tool_output.Decoded reference ->
    let stored = fetch_blob_exn ~base_path reference |> Yojson.Safe.from_string in
    if String.equal reference.mime Tool_output.artifact_manifest_mime
    then
      (match Tool_output.artifact_manifest_of_json stored with
       | Tool_output.Decoded_artifact_manifest { structured_content; _ } ->
         structured_content
       | Tool_output.Not_artifact_manifest ->
         fail "capability output artifact is not a typed result manifest"
       | Tool_output.Invalid_artifact_manifest { detail } -> fail detail)
    else stored
;;

let test_tools_list_reads_the_supplied_capability_surface () =
  with_bundle_tools
  @@ fun config _meta _snapshot _composition_plan_index capability_surface tools ->
  let tool =
    match
      List.find_opt
        (fun (tool : Agent_core.Tool.t) ->
           String.equal tool.schema.name "keeper_tools_list")
        tools
    with
    | Some tool -> tool
    | None -> fail "keeper_tools_list is absent from the supplied surface"
  in
  let observed =
    run_tool ~tool_use_id:"bundle-capability-surface" tool (`Assoc [])
    |> decode_tool_json ~base_path:config.base_path
  in
  let expected =
    Keeper_tool_shared_runtime.keeper_tools_list_json_for_surface
      ~capability_surface
    |> Yojson.Safe.from_string
  in
  check string "production bundle uses the exact supplied surface"
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string observed);
  let read =
    Yojson.Safe.Util.(observed |> member "descriptor_surface" |> to_list)
    |> List.find_opt (fun descriptor ->
      String.equal
        "agent.read_file"
        Yojson.Safe.Util.(descriptor |> member "id" |> to_string))
  in
  match read with
  | None -> fail "complete inventory omitted Read"
  | Some descriptor ->
    check string "a model-visible Tool is active in the frozen surface"
      "active"
      Yojson.Safe.Util.(descriptor |> member "availability" |> to_string);
    let search_tool =
      match
        List.find_opt
          (fun (tool : Agent_core.Tool.t) ->
             String.equal tool.schema.name "keeper_capability_search")
          tools
      with
      | Some tool -> tool
      | None -> fail "keeper_capability_search is absent from the supplied surface"
    in
    let search =
      run_tool
        ~tool_use_id:"bundle-capability-search-scope"
        search_tool
        (`Assoc [ "query", `String "tool_read_file" ])
      |> decode_tool_json ~base_path:config.base_path
    in
    check string "search uses the frozen capability authority"
      "frozen_capability_surface"
      Yojson.Safe.Util.(search |> member "search_scope" |> to_string);
    check string "search reports the supplied surface digest"
      (Keeper_capability_surface.digest capability_surface)
      Yojson.Safe.Util.(search |> member "surface_digest" |> to_string);
    let matches = Yojson.Safe.Util.(search |> member "matches" |> to_list) in
    check bool "search answers from the frozen surface" true
      (List.exists
         (fun row ->
            String.equal
              "active"
              Yojson.Safe.Util.(
                row
                |> member "candidate"
                |> member "capability"
                |> member "availability"
                |> to_string))
         matches)
;;

let run_composition_tool ?expected_failure (tool : Agent_core.Tool.t) =
  let invocation =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"bundle-composition-activation"
      ~turn:1
      ~schedule:
        { planned_index = 0
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial
        }
      ~completion:(Agent_core.Tool.completion tool)
  in
  match Agent_core.Tool.execute ~invocation tool (`Assoc []), expected_failure with
  | Ok _, None -> ()
  | Error error, Some expected ->
    check bool "expected submission failure" true
      (contains ~needle:expected error.Agent_core.Types.message)
  | Ok _, Some expected -> failf "expected %s failure" expected
  | Error error, None -> fail error.Agent_core.Types.message
;;

let test_composition_activation_is_durable ?expected_failure ~skill_name tool_name =
  with_bundle_tools (fun config meta snapshot _composition_plan_index _surface tools ->
    let tool =
      match
        List.find_opt
          (fun (tool : Agent_core.Tool.t) ->
             String.equal tool.schema.name tool_name)
          tools
      with
      | Some tool -> tool
      | None -> failf "%s missing from exact snapshot bundle" tool_name
    in
    run_composition_tool ?expected_failure tool;
    let ledger =
      match
        Keeper_skill_activation_ledger.load
          ~config
          ~trace_id:meta.runtime.trace_id
      with
      | Ok ledger -> ledger
      | Error error ->
        fail (Keeper_skill_activation_ledger.store_error_to_string error)
    in
    match Keeper_skill_activation_ledger.activations ledger with
    | [ activation ] ->
      assert_exact_activation
        snapshot
        (snapshot_reference snapshot skill_name)
        activation;
      (match activation.invocation with
       | Keeper_skill_activation_ledger.Composition_invocation
           { origin = Session_composition; tool_name = observed } ->
         check string "exact composition origin" tool_name observed
       | Keeper_skill_activation_ledger.Composition_invocation
           { origin = Task_composition _; _ }
       | Keeper_skill_activation_ledger.Instruction_invocation _ ->
         fail "composition activation kept the wrong typed origin")
    | activations ->
      failf "expected one composition activation, got %d" (List.length activations))
;;

let test_inline_composition_activation_is_durable () =
  test_composition_activation_is_durable
    ~skill_name:"gate-inline"
    "keeper_compose_gate-inline"
;;

let test_async_composition_activation_is_durable () =
  test_composition_activation_is_durable
    ~expected_failure:"background_switch_unavailable"
    ~skill_name:"gate-async"
    "keeper_compose_gate-async"
;;

(* Guards against an empty-list false pass: a bundle that produced nothing
   would satisfy every assertion below by vacuity. *)
let test_the_bundle_is_not_empty () =
  with_bundle (fun _ names ->
    check bool "the keeper is handed tools at all" true (names <> []);
    (* Without these the gate would pass by not looking at anything. Each is a
       kind of undescribed tool the policy has an arm for. *)
    List.iter
      (fun expected ->
         check bool
           (Printf.sprintf "%s is in the bundle the gate walks" expected)
           true (List.mem expected names))
      [ "keeper_compose_gate-inline"
      ; "keeper_compose_gate-async"
      ; Keeper_tool_composition_catalog.status_tool_name
      ; Keeper_tool_composition_catalog.cancel_tool_name
      ; Keeper_tool_composition_catalog.skill_tool_name
      ])
;;

let test_skill_bundle_without_activation_context_is_rejected () =
  check_raises
    "Skill surface cannot bypass durable activation recording"
    (Invalid_argument
       "Skill-bearing Keeper bundle requires a frozen activation context")
    (fun () ->
       with_bundle_tools ~record_activations:false
         (fun _config _meta _snapshot _composition_plan_index _surface _tools -> ()))
;;

(* The point of the tool is that a body reaches the keeper. A tool that is on
   the surface and classifiable but answers nothing would pass every other
   assertion here. *)
let test_the_skill_tool_serves_the_body () =
  with_bundle_tools (fun config meta snapshot _composition_plan_index _surface tools ->
    match
      List.find_opt
        (fun (tool : Agent_core.Tool.t) ->
           String.equal tool.schema.name
             Keeper_tool_composition_catalog.skill_tool_name)
        tools
    with
    | None -> fail "the instruction skill put no tool on the surface"
    | Some tool ->
      check bool "the description names the skill it can serve" true
        (contains ~needle:"gate-instruction" tool.schema.description);
      let reference = instruction_reference () in
      let served = run_tool tool (Skill_reference.to_yojson reference) in
      check bool "asking by exact reference returns the body" true
        (contains ~needle:"body" served);
      let served_again =
        run_tool
          ~tool_use_id:"bundle-instruction-activation-second"
          tool
          (Skill_reference.to_yojson reference)
      in
      check bool "second invocation also returns the body" true
        (contains ~needle:"body" served_again);
      let ledger =
        match
          Keeper_skill_activation_ledger.load
            ~config
            ~trace_id:meta.runtime.trace_id
        with
        | Ok ledger -> ledger
        | Error error ->
          fail (Keeper_skill_activation_ledger.store_error_to_string error)
      in
      (match Keeper_skill_activation_ledger.activations ledger with
       | [ first; second ] ->
         assert_exact_activation snapshot reference first;
         assert_exact_activation snapshot reference second
       | activations ->
         failf "expected two instruction activations, got %d"
           (List.length activations));
      let stale =
        Skill_reference.make
          ~identity:reference.identity
          ~content_revision:
            (Skill_reference.content_revision_of_source_text "stale body")
      in
      let missing = run_tool tool (Skill_reference.to_yojson stale) in
      check bool "an exact reference the turn does not carry is refused" true
        (contains ~needle:"no instruction Skill matches exact reference" missing);
      check bool "and the refusal lists what it does carry" true
        (contains ~needle:"gate-instruction" missing))
;;

(* task-828: keepers that know a skill by name but not by revision sent ""
   (and copied placeholders) and were answered by a schema length error that
   could not name the catalog. The refusal has to hand back the exact
   references this keeper carries, revision included, so the next call can
   be the right one. *)
let test_a_revisionless_ask_is_taught_the_exact_reference () =
  with_bundle_tools (fun _config _meta _snapshot _composition_plan_index _surface tools ->
    match
      List.find_opt
        (fun (tool : Agent_core.Tool.t) ->
           String.equal tool.schema.name
             Keeper_tool_composition_catalog.skill_tool_name)
        tools
    with
    | None -> fail "the instruction skill put no tool on the surface"
    | Some tool ->
      let reference = instruction_reference () in
      let name_only =
        match Skill_reference.to_yojson reference with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if String.equal key "content_revision"
                  then key, `String ""
                  else key, value)
               fields)
        | other -> other
      in
      let taught = run_tool tool name_only in
      check bool "an empty revision is refused, not served" true
        (contains ~needle:"requires one canonical exact Skill reference" taught);
      check bool "the refusal carries the references this keeper holds" true
        (contains ~needle:"this keeper carries:" taught);
      check bool "the taught list includes the revision to copy verbatim" true
        (contains
           ~needle:
             (Skill_reference.content_revision_to_string
                reference.content_revision)
           taught))
;;

let test_every_bundle_tool_is_classifiable () =
  with_bundle (fun composition_plan_index names ->
    let unclassifiable =
      List.filter
        (fun tool_name ->
           not
             (Policy.classifies
                ~composition_plan_index:(Some composition_plan_index) ~tool_name))
        names
    in
    match unclassifiable with
    | [] -> ()
    | names ->
      failf
        "the approval policy cannot classify %d tool(s) the bundle hands the \
         model: %s.\n\
         Each will ask the operator for approval with no reason they can act \
         on. A tool with a Keeper_tool_descriptor is classified by its group; \
         one without needs an arm in \
         Keeper_tool_approval_policy.verdict_for_undescribed."
        (List.length names)
        (String.concat ", " names))
;;

(* Names are unique, so a duplicate cannot hide an unclassifiable twin behind
   a classifiable one of the same name. *)
let test_bundle_names_are_unique () =
  with_bundle (fun _ names ->
    check
      int
      "bundle model names are unique"
      (List.length names)
      (List.length (List.sort_uniq String.compare names)))
;;

let test_bundle_matches_expected_projection () =
  with_bundle (fun _ names ->
    let snapshot, skill_catalog = skill_snapshot_and_catalog () in
    (* [tools] is the official-client shape: the attached tools are in it as
       themselves, because those lanes cannot widen a running turn and a
       listing would name tools they can never make callable. The Agent Core
       shape lives in [agent_core_tools] and carries the listing instead. *)
    let identity_names =
      List.map
        (fun (offered : Keeper_identity_tools.offered_tool) ->
           offered.Keeper_identity_tools.schema.name)
        (identity_tools ())
    in
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        (* Named from the same fixture the bundle was handed. Passing [] here
           while the bundle carries them is what this check exists to catch,
           and it did. *)
        ~identity_names
        ~skill_catalog
        ~model_visible_descriptors:(Keeper_tool_descriptor.model_visible_descriptors ())
        ()
    in
    check
      (list string)
      "instruction and composition tools match the expected projection"
      expected
      (List.sort_uniq String.compare names);
    let task_reference = snapshot_reference snapshot "gate-instruction" in
    let task_selection =
      match Keeper_task_skill_turn.resolve ~snapshot [ task_reference ] with
      | Ok selection -> selection
      | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
    in
    match
      Keeper_effective_tool_surface.For_testing.project
        ~keeper_name:"bundle-classifiable"
        ~runtime_id:"test.runtime"
        ~skills_left_out:[]
        ~official_client_kind:"agent_core"
        ~tool_delivery:Keeper_effective_tool_surface.Tools_delivered
        ~native_posture:None
        ~skill_names:None
        ~current_task_id:(Some "task-001")
        ~task_skill_references:[ task_reference ]
        ~skill_snapshot:snapshot
        ~task_selection:(Some task_selection)
    with
    | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
    | Ok surface ->
      let effective_names =
        identity_names
        @ List.map
            (fun (tool : Keeper_effective_tool_surface.tool) -> tool.name)
            surface.tools
        |> List.sort_uniq String.compare
      in
      check (list string) "actual bundle equals effective surface" effective_names
        (List.sort_uniq String.compare names))
;;

let () =
  run
    "keeper_tool_bundle_classifiable"
    [ ( "the bundle"
      , [ test_case "is not empty" `Quick test_the_bundle_is_not_empty
        ; test_case "requires activation context" `Quick
            test_skill_bundle_without_activation_context_is_rejected
        ; test_case "names are unique" `Quick test_bundle_names_are_unique
        ; test_case "matches the expected projection" `Quick
            test_bundle_matches_expected_projection
        ; test_case "the bundle is the model-visible surface" `Quick
            test_the_bundle_is_the_model_visible_surface
        ; test_case "tools list reads supplied capability surface" `Quick
            test_tools_list_reads_the_supplied_capability_surface
        ; test_case "the skill tool serves the body" `Quick
            test_the_skill_tool_serves_the_body
        ; test_case "a revisionless ask is taught the exact reference" `Quick
            test_a_revisionless_ask_is_taught_the_exact_reference
        ; test_case "inline composition activation is durable" `Quick
            test_inline_composition_activation_is_durable
        ; test_case "async composition activation is durable" `Quick
            test_async_composition_activation_is_durable
        ] )
    ; ( "the approval policy"
      , [ test_case "can classify every tool in it" `Quick
            test_every_bundle_tool_is_classifiable
        ] )
    ]
;;
