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

let skill_catalog () =
  match
    Keeper_skill_catalog.partition_documents
      [ "gate-inline", composition_skill ~name:"gate-inline" ~execution:"inline"
      ; "gate-async", composition_skill ~name:"gate-async" ~execution:"async"
      ; ( "gate-instruction"
          (* An instruction skill puts [keeper_skill] on the surface. It is a
             third shape the policy has to place, and it reaches the bundle
             the same way the composition ones do. *)
        , "---\nname: gate-instruction\ndescription: what the gate reads\n---\n\nbody\n" )
      ]
  with
  | catalog, [] -> catalog
  | _, { error = e; _ } :: _ ->
    failf "the gate's own skill fixtures must parse: %s"
      (Keeper_skill_catalog.error_to_string e)
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
  let source_text =
    "---\nname: gate-instruction\ndescription: what the gate reads\n---\n\nbody\n"
  in
  Skill_reference.make
    ~identity:
      (Skill_reference.make_identity
         ~source_id
         ~package_id
         ~name:"gate-instruction")
    ~content_revision:
      (Skill_reference.content_revision_of_source_text source_text)
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
let identity_tools ~base_path =
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
  (Keeper_identity_tools.agent_tools ~base_path ~keeper_name:"bundle-classifiable"
     ~provider catalog)
    .Keeper_identity_tools.offered
;;

let with_bundle_tools f =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_bundle_classifiable_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with _ -> ())
    (fun () ->
       let config = Workspace.default_config dir in
       let meta = make_meta ~name:"bundle-classifiable" () in
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
       let bundle =
         Keeper_tools_agent_core_bundle.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot
           ~skill_catalog:(skill_catalog ())
           ~identity_tools:(identity_tools ~base_path:dir)
           ~composition_plan_index
           ~task_instruction_skills:
             [ instruction_reference (), "what the gate reads", "body" ]
           ()
       in
       Fun.protect ~finally:bundle.cleanup (fun () ->
         f composition_plan_index bundle.tools))
;;

let with_bundle f = with_bundle_tools (fun composition_plan_index tools ->
  f composition_plan_index
    (List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) tools))
;;

(* The handler is the tool. Reading only its schema would let a tool that
   answers nothing pass for one that works. *)
let run_tool (tool : Agent_core.Tool.t) input =
  match tool.handler (Agent_core.Tool.Execution_env.create ()) input with
  | Ok output -> output.Agent_core.Llm_provider.Types.content
  | Error err -> err.Agent_core.Llm_provider.Types.message
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
      ; Keeper_tool_composition_catalog.plan_execute_tool_name
      ; Keeper_tool_composition_catalog.status_tool_name
      ; Keeper_tool_composition_catalog.cancel_tool_name
      ; Keeper_tool_composition_catalog.skill_tool_name
      ])
;;

(* The point of the tool is that a body reaches the keeper. A tool that is on
   the surface and classifiable but answers nothing would pass every other
   assertion here. *)
let test_the_skill_tool_serves_the_body () =
  with_bundle_tools (fun _ tools ->
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
      let served = run_tool tool (`Assoc [ "name", `String "gate-instruction" ]) in
      check bool "asking by name returns the body" true
        (contains ~needle:"body" served);
      let missing = run_tool tool (`Assoc [ "name", `String "no-such-skill" ]) in
      check bool "a name the catalog does not carry is refused" true
        (contains ~needle:"no instruction skill named" missing);
      check bool "and the refusal lists what it does carry" true
        (contains ~needle:"gate-instruction" missing))
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
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        (* Named from the same fixture the bundle was handed. Passing [] here
           while the bundle carries them is what this check exists to catch,
           and it did. *)
        ~identity_tool_names:
          (List.map
             (fun (tool : Agent_core.Tool.t) -> tool.schema.name)
             (identity_tools ~base_path:(Filename.get_temp_dir_name ())))
        ~skill_catalog:(skill_catalog ())
        ~model_visible_descriptors:(Keeper_tool_descriptor.model_visible_descriptors ())
        ()
    in
    check
      (list string)
      "instruction and composition tools match the expected projection"
      expected
      (List.sort_uniq String.compare names))
;;

let () =
  run
    "keeper_tool_bundle_classifiable"
    [ ( "the bundle"
      , [ test_case "is not empty" `Quick test_the_bundle_is_not_empty
        ; test_case "names are unique" `Quick test_bundle_names_are_unique
        ; test_case "matches the expected projection" `Quick
            test_bundle_matches_expected_projection
        ; test_case "the skill tool serves the body" `Quick
            test_the_skill_tool_serves_the_body
        ] )
    ; ( "the approval policy"
      , [ test_case "can classify every tool in it" `Quick
            test_every_bundle_tool_is_classifiable
        ] )
    ]
;;
