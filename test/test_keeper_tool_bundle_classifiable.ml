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
    Keeper_skill_catalog.of_documents
      [ "gate-inline", composition_skill ~name:"gate-inline" ~execution:"inline"
      ; "gate-async", composition_skill ~name:"gate-async" ~execution:"async"
      ]
  with
  | Ok catalog -> catalog
  | Error e ->
    failf "the gate's own skill fixtures must parse: %s"
      (Keeper_skill_catalog.error_to_string e)
;;

let with_bundle f =
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
       let bundle =
         Keeper_tools_agent_core_bundle.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot
           ~skill_catalog:(skill_catalog ())
           ()
       in
       Fun.protect ~finally:bundle.cleanup (fun () ->
         f
           (List.map
              (fun (tool : Agent_core.Tool.t) -> tool.schema.name)
              bundle.tools)))
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
      ])
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
        ; test_case "names are unique" `Quick test_bundle_names_are_unique
        ] )
    ; ( "the approval policy"
      , [ test_case "can classify every tool in it" `Quick
            test_every_bundle_tool_is_classifiable
        ] )
    ]
;;
