(** Every tool a keeper is handed must be one the approval policy can
    classify.

    [Keeper_tool_approval_policy.verdict_for] resolves a name through
    [Keeper_tool_descriptor] and asks when nothing owns it. That reject is the
    right answer for a name this build genuinely cannot classify, and the
    wrong one for a tool the bundle hands the model on purpose — the operator
    is asked about a call the policy simply failed to recognise, with a reason
    that tells them nothing they can act on.

    Four such tools shipped that way. [keeper_compose_<name>],
    [keeper_plan_execute], [keeper_composition_status] and
    [keeper_composition_cancel] are materialised as Agent-Core tools outside
    the descriptor registry, so every composition asked — including one whose
    whole plan is reads, while the same tools called directly ran unasked.

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
          ; "agent_name", `String (Keeper_identity.keeper_agent_name name)
          ; "trace_id", `String "test-trace-bundle-classifiable"
          ])
  with
  | Ok meta -> meta
  | Error e -> failf "make_meta failed: %s" e
;;

(* A bundle with no skills carries no composition tools, so a gate run
   against one would only ever see the descriptor half plus
   [keeper_plan_execute] — and would pass while the four tools this gate
   exists for were never in it. These two skills put all four kinds in:
   an inline composition, an async one (which is what brings
   keeper_composition_status and _cancel with it), and keeper_plan_execute
   is unconditional. *)
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
        "[skills]\nactivation-lifetime = \"session\"\nprecedence = \"earlier-source-wins\"\n[[skills.sources]]\nid = \"bundle-fixture\"\nanchor = \"base-path\"\npath = \"skills\"\naccess = \"read-only\"\n"
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

let with_bundle_tools ?(record_activations = true) f =
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
         match
           Keeper_skill_activation_recorder.make
             ~trace_id
             ~turn_ref:
               (Ids.Turn_ref.make
                  ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
                  ~absolute_turn:1)
             ~snapshot_revision
             ~task_scope:
               (Keeper_task_skill_turn.Task
                  { task_id = "task-001"; references = [ reference ] })
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
       let bundle =
         Keeper_tools_agent_core_bundle.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot
           ~skill_catalog
          ~task_instruction_skills:
             [ reference, "what the gate reads", "body" ]
           ?skill_activation_context:
             (if record_activations then Some skill_activation_context else None)
           ()
       in
       Fun.protect ~finally:bundle.cleanup (fun () ->
         f config meta skill_snapshot bundle.tools))
;;

let with_bundle f = with_bundle_tools (fun _config _meta _snapshot tools ->
  f (List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) tools))
;;

(* The handler is the tool. Reading only its schema would let a tool that
   answers nothing pass for one that works. *)
let run_tool (tool : Agent_core.Tool.t) input =
  match tool.handler (Agent_core.Tool.Execution_env.create ()) input with
  | Ok output -> output.Agent_core.Llm_provider.Types.content
  | Error err -> err.Agent_core.Llm_provider.Types.message
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
  with_bundle_tools (fun config meta snapshot tools ->
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
      (match activation.origin with
       | Keeper_skill_activation_ledger.Session_composition
           { tool_name = observed } ->
         check string "exact composition origin" tool_name observed
       | Keeper_skill_activation_ledger.Task_composition _
       | Keeper_skill_activation_ledger.Task_instruction _
       | Keeper_skill_activation_ledger.Session_instruction ->
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
  with_bundle (fun names ->
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
      ; Keeper_tool_composition_catalog.plan_execute_tool_name
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
         (fun _config _meta _snapshot _tools -> ()))
;;

(* The point of the tool is that a body reaches the keeper. A tool that is on
   the surface and classifiable but answers nothing would pass every other
   assertion here. *)
let test_the_skill_tool_serves_the_body () =
  with_bundle_tools (fun config meta snapshot tools ->
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
       | [ activation ] ->
         assert_exact_activation snapshot reference activation
       | activations ->
         failf "expected one instruction activation, got %d"
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

let test_every_bundle_tool_is_classifiable () =
  with_bundle (fun names ->
    let unclassifiable =
      List.filter
        (fun tool_name ->
           not (Policy.classifies ~tool_name))
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
  with_bundle (fun names ->
    check
      int
      "bundle model names are unique"
      (List.length names)
      (List.length (List.sort_uniq String.compare names)))
;;

let () =
  run
    "keeper_tool_bundle_classifiable"
    [ ( "the bundle"
      , [ test_case "is not empty" `Quick test_the_bundle_is_not_empty
        ; test_case "requires activation context" `Quick
            test_skill_bundle_without_activation_context_is_rejected
        ; test_case "names are unique" `Quick test_bundle_names_are_unique
        ; test_case "the skill tool serves the body" `Quick
            test_the_skill_tool_serves_the_body
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
