(* The multi-Keeper acceptance runner installs these composition Skills into a
   campaign workspace and then judges the live tool-call rows by a fixed shape:
   which nodes share a concurrent batch, which node runs alone after them, and
   which output field becomes which input. The skill parser and the plan
   executor decide that shape, not the runner, so these tests read the files
   the runner installs and run them against stub tool answers. *)

open Alcotest
module Skills = Masc.Keeper_skill_catalog
module Catalog = Masc.Keeper_tool_composition_catalog
module Plan = Masc.Keeper_tool_plan
module Executor = Masc.Keeper_tool_plan_executor
module Contract = Agent_core.Tool_contract

let fixtures_root = "../scripts/fixtures/keeper-multi-collaboration/skills"
let inline_fixture = "acceptance-inline-probe"
let async_fixture = "acceptance-async-probe"

(* Spelled out whole: PR CI runs the suites that name a changed file as an
   exact string literal, so an edit to either fixture runs this suite. *)
let fixture_sources =
  [ ( async_fixture
    , "scripts/fixtures/keeper-multi-collaboration/skills/acceptance-async-probe/SKILL.md" )
  ; ( inline_fixture
    , "scripts/fixtures/keeper-multi-collaboration/skills/acceptance-inline-probe/SKILL.md" )
  ]
;;

let skill_path name =
  match List.assoc_opt name fixture_sources with
  | Some source -> Filename.concat Filename.parent_dir_name source
  | None -> fail ("no fixture source is declared for " ^ name)
;;

let fixture_packages () =
  Sys.readdir fixtures_root
  |> Array.to_list
  |> List.filter (fun name ->
    Sys.file_exists (Filename.concat (Filename.concat fixtures_root name) "SKILL.md"))
  |> List.sort String.compare
;;

let composition name =
  let document = In_channel.with_open_bin (skill_path name) In_channel.input_all in
  match Skills.parse_skill ~directory:name document with
  | Error error -> fail (name ^ ": " ^ Skills.error_to_string error)
  | Ok { Skills.surface = Skills.Instruction; _ } ->
    fail (name ^ " parsed as an instruction Skill")
  | Ok { Skills.surface = Skills.Composition entry; _ } ->
    check string "tool name" ("keeper_compose_" ^ name) (Catalog.tool_name entry);
    entry
;;

let lane_profile = "docker"

(* The executor validates every answer against the tool's declared output
   schema (board_stats_output_schema, lane_status_output_schema in
   keeper_tool_descriptor.ml) before another node may read it, so these
   stubs have to be shapes the schemas admit. *)
let answer = function
  | "masc_board_stats" ->
    `Assoc
      [ "post_count", `Int 0
      ; "comment_count", `Int 0
      ; "expired_pending", `Int 0
      ; "last_sweep", `Float 0.0
      ; "backend", `String "jsonl"
      ]
  | "keeper_lane_status" ->
    `Assoc
      [ "profile", `String lane_profile
      ; "lane", `Null
      ; "endpoint", `Null
      ; "probe", `Null
      ; "last_dispatch", `Null
      ; "operator_action", `Null
      ]
  | "masc_board_search" -> `String "p-1 · docker lane note (by keeper-a, 2026-09-15, +0, 0 replies)"
  | tool -> fail ("unexpected tool: " ^ tool)
;;

let execution_mode_name = function
  | Contract.Concurrent -> "concurrent"
  | Contract.Serial -> "serial"
;;

let execution_error_detail = function
  | Plan.Unknown_node_id node_id -> "unknown node " ^ Plan.Node_id.to_string node_id
  | Plan.Input_template_resolution_failed { node_id; _ } ->
    "input template did not resolve for " ^ Plan.Node_id.to_string node_id
  | Plan.Input_validation_failed { node_id; rejection; _ } ->
    Printf.sprintf
      "input of %s refused: %s"
      (Plan.Node_id.to_string node_id)
      (Tool_result.message (Masc.Tool_input_validation.rejection_result rejection))
  | Plan.Output_validation_failed { node_id; _ } ->
    "output of " ^ Plan.Node_id.to_string node_id ^ " does not match its schema"
  | Plan.Output_not_composable { node_id; _ } ->
    "output of " ^ Plan.Node_id.to_string node_id ^ " is not composable"
;;

(* Why the plan stopped. An answer this file does not expect raises inside
   dispatch, and the executor settles that as a failed node, so the node's own
   message is the cause to show. *)
let failure_detail (failure : Executor.failure) =
  match failure.Executor.cause with
  | Executor.Plan_execution_failed { error; _ } -> execution_error_detail error
  | Executor.Tool_did_not_complete node ->
    Printf.sprintf
      "%s did not complete: %s"
      (Plan.Node_id.to_string node.Executor.node_id)
      (Tool_result.message node.Executor.result)
  | Executor.Node_observation_failed { node; detail } ->
    Printf.sprintf
      "observing %s failed: %s"
      (Plan.Node_id.to_string node.Executor.node_id)
      detail
  | Executor.Outer_completion_mismatch _ -> "the outer completion does not match the plan"
;;

type dispatched =
  { row : string
      (** node id, batch index, batch size and execution mode: the fields the
          acceptance runner reads from each nested tool-call row. *)
  ; node_id : string
  ; input : Yojson.Safe.t
  }

let execute_fixture name =
  let plan =
    match
      Catalog.instantiate
        ~descriptors:(Masc.Keeper_tool_descriptor.all_descriptors ())
        ~args:(`Assoc [])
        (composition name)
    with
    | Ok plan -> plan
    | Error error -> fail (Catalog.instantiation_error_to_string error)
  in
  let calls = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule ~input =
    let node_id = Plan.Node_id.to_string node.Plan.id in
    let row =
      Printf.sprintf
        "%s:%d/%d/%s"
        node_id
        schedule.Contract.batch_index
        schedule.Contract.batch_size
        (execution_mode_name schedule.Contract.execution_mode)
    in
    calls := { row; node_id; input } :: !calls;
    Executor.dispatch_result
      (Tool_result.make_ok
         ~tool_name:node.Plan.tool_name
         ~start_time:0.0
         ~data:(answer node.Plan.tool_name)
         ())
  in
  (match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
   | Ok _ -> ()
   | Error failure -> fail (name ^ ": " ^ failure_detail failure));
  List.rev !calls
;;

let rows calls = List.map (fun call -> call.row) calls |> List.sort String.compare

let test_every_fixture_is_admitted () =
  let packages = fixture_packages () in
  check (list string) "fixture packages" (List.map fst fixture_sources) packages;
  List.iter (fun name -> ignore (composition name : Catalog.entry)) packages
;;

let test_inline_fixture_runs_a_concurrent_pair_then_the_dataflow_node () =
  Eio_main.run (fun _ ->
    (match (composition inline_fixture).Catalog.execution with
     | Catalog.Inline -> ()
     | Catalog.Async -> fail "the inline fixture declares async execution");
    let calls = execute_fixture inline_fixture in
    check
      (list string)
      "batches the acceptance runner judges"
      [ "board:0/2/concurrent"; "lane:0/2/concurrent"; "search:1/1/concurrent" ]
      (rows calls);
    match List.find_opt (fun call -> String.equal call.node_id "search") calls with
    | None -> fail "search did not run"
    | Some call ->
      check
        string
        "search looks for the profile the same run's lane read returned"
        lane_profile
        Yojson.Safe.Util.(call.input |> member "query" |> to_string))
;;

let test_async_fixture_runs_one_concurrent_pair () =
  Eio_main.run (fun _ ->
    (match (composition async_fixture).Catalog.execution with
     | Catalog.Async -> ()
     | Catalog.Inline -> fail "the async fixture declares inline execution");
    check
      (list string)
      "batches the acceptance runner judges"
      [ "board:0/2/concurrent"; "lane:0/2/concurrent" ]
      (rows (execute_fixture async_fixture)))
;;

let () =
  run
    "acceptance composition fixtures"
    [ ( "admission"
      , [ test_case "every fixture is admitted" `Quick test_every_fixture_is_admitted ] )
    ; ( "shape"
      , [ test_case
            "inline fixture runs a concurrent pair then the dataflow node"
            `Quick
            test_inline_fixture_runs_a_concurrent_pair_then_the_dataflow_node
        ; test_case
            "async fixture runs one concurrent pair"
            `Quick
            test_async_fixture_runs_one_concurrent_pair
        ] )
    ]
;;
