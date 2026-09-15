(* The first-party Skills under skills/ are embedded in the binary and installed
   into every new workspace, so each one has to be admitted by the same parser a
   Keeper turn uses. A composition the parser refuses does not disappear: it is
   projected as an instruction Skill with a diagnostic, and the Keeper silently
   loses the tool. These tests read the shipped files, not copies of them. *)

open Alcotest
module Skills = Masc.Keeper_skill_catalog
module Catalog = Masc.Keeper_tool_composition_catalog
module Plan = Masc.Keeper_tool_plan
module Executor = Masc.Keeper_tool_plan_executor

let skills_root = "../skills"
let skill_path name = Filename.concat (Filename.concat skills_root name) "SKILL.md"

let shipped_packages () =
  Sys.readdir skills_root
  |> Array.to_list
  |> List.filter (fun name -> Sys.file_exists (skill_path name))
  |> List.sort String.compare
;;

let parsed name =
  let document = In_channel.with_open_bin (skill_path name) In_channel.input_all in
  match Skills.parse_skill ~directory:name document with
  | Ok skill -> skill
  | Error error -> fail (name ^ ": " ^ Skills.error_to_string error)
;;

let test_every_shipped_skill_is_admitted () =
  let packages = shipped_packages () in
  check bool "skills/ holds at least one package" true (packages <> []);
  List.iter (fun name -> ignore (parsed name : Skills.skill)) packages
;;

let composition name =
  match (parsed name).Skills.surface with
  | Skills.Composition entry ->
    check string "tool name" ("keeper_compose_" ^ name) (Catalog.tool_name entry);
    entry
  | Skills.Instruction -> fail (name ^ " parsed as an instruction Skill")
;;

let instantiate name args =
  match
    Catalog.instantiate
      ~descriptors:(Masc.Keeper_tool_descriptor.all_descriptors ())
      ~args
      (composition name)
  with
  | Ok plan -> plan
  | Error error -> fail (Catalog.instantiation_error_to_string error)
;;

(* Node inputs are checked against each tool's input schema only when the node
   runs, so a misspelled field loads cleanly. Running the plan with a stub
   dispatch goes through that check for every node. *)
let run_plan plan ~answer =
  let calls = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input =
    calls := (Plan.Node_id.to_string node.Plan.id, input) :: !calls;
    Executor.dispatch_result
      (Tool_result.make_ok
         ~tool_name:node.Plan.tool_name
         ~start_time:0.0
         ~data:(answer node.Plan.tool_name)
         ())
  in
  let result = Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () in
  result, List.rev !calls
;;

let input_of calls node_id =
  match List.assoc_opt node_id calls with
  | Some input -> input
  | None -> fail ("node did not run: " ^ node_id)
;;

let string_member field json =
  Yojson.Safe.Util.(json |> member field |> to_string)
;;

let test_run_and_read_waits_then_reads_both_streams () =
  Eio_main.run (fun _ ->
    let handle = "spawn-handle" in
    let plan =
      instantiate
        "run-and-read"
        (`Assoc [ "command", `String "true"; "timeout_sec", `Float 5.0 ])
    in
    let answer = function
      | "keeper_spawn" -> `Assoc [ "status", `String "running"; "handle", `String handle ]
      | "keeper_spawn_wait" ->
        `Assoc
          [ "status", `String "exited"
          ; "exit", `Assoc [ "kind", `String "exited"; "code", `Int 0 ]
          ]
      | "keeper_spawn_read" ->
        `Assoc [ "bytes", `String ""; "next", `Int 0; "dropped_before", `Int 0 ]
      | tool -> fail ("unexpected tool: " ^ tool)
    in
    let result, calls = run_plan plan ~answer in
    (match result with
     | Ok _ -> ()
     | Error _ -> fail "run-and-read did not complete against valid tool answers");
    (match List.map fst calls with
     | "start" :: "settle" :: reads ->
       check
         (list string)
         "both streams are read after the wait"
         [ "stderr"; "stdout" ]
         (List.sort String.compare reads)
     | order -> fail ("start then settle expected first, ran: " ^ String.concat ", " order));
    check
      (list string)
      "argv runs the command through sh -c"
      [ "sh"; "-c"; "true" ]
      Yojson.Safe.Util.(
        input_of calls "start" |> member "argv" |> to_list |> List.map to_string);
    check string "waits for exit" "exit" (string_member "until" (input_of calls "settle"));
    check
      string
      "wait uses the spawned handle"
      handle
      (string_member "handle" (input_of calls "settle"));
    check string "reads stdout" "stdout" (string_member "stream" (input_of calls "stdout"));
    check string "reads stderr" "stderr" (string_member "stream" (input_of calls "stderr")))
;;

let test_prior_art_bounds_every_search () =
  Eio_main.run (fun _ ->
    let plan = instantiate "prior-art" (`Assoc [ "query", `String "EACCES" ]) in
    let answer = function
      | "keeper_memory_search" | "keeper_library_search" | "masc_board_search" ->
        `String "no match"
      | tool -> fail ("unexpected tool: " ^ tool)
    in
    let result, calls = run_plan plan ~answer in
    (match result with
     | Ok _ -> ()
     | Error _ -> fail "prior-art did not complete against valid tool answers");
    let memory = input_of calls "memory" in
    let board = input_of calls "board" in
    check string "library gets the query" "EACCES" (string_member "query" (input_of calls "library"));
    check string "memory searches durable facts" "memory" (string_member "source" memory);
    check bool "memory names its limit" true
      (Yojson.Safe.Util.member "limit" memory <> `Null);
    check bool "board names its limit" true (Yojson.Safe.Util.member "limit" board <> `Null);
    check bool "board asks for compact rows" true
      (Yojson.Safe.Util.member "compact" board = `Bool true))
;;

(* A tool whose schema leaves additionalProperties open accepts a misspelled
   field without a word, and the node then runs on the tool default the
   composition meant to replace -- keeper_tasks_list is one of them. So the
   field names are held against the declared properties, not only against
   the schema check that running the plan applies. *)
let check_inputs_declared plan calls =
  List.iter
    (fun (node : Plan.node) ->
       let node_id = Plan.Node_id.to_string node.id in
       match Plan.descriptor plan node.id with
       | None -> fail ("no descriptor for node " ^ node_id)
       | Some descriptor ->
         let declared =
           Yojson.Safe.Util.(
             descriptor.Masc.Keeper_tool_descriptor.input_schema
             |> member "properties"
             |> keys)
         in
         Yojson.Safe.Util.keys (input_of calls node_id)
         |> List.iter (fun field ->
           check
             bool
             (node_id ^ " passes a field " ^ node.tool_name ^ " declares: " ^ field)
             true
             (List.mem field declared)))
    (Plan.nodes plan)
;;

let test_work_intake_names_every_page_bound () =
  Eio_main.run (fun _ ->
    let plan = instantiate "work-intake" (`Assoc []) in
    let answer = function
      | "keeper_tasks_list" ->
        `Assoc
          [ "backlog_authority", `String "primary"
          ; "degraded", `Bool false
          ; "projection", `String "compact"
          ; "kind", `String "snapshot"
          ; "revision", `String "tasks:fixture"
          ; "snapshot", `List []
          ]
      | "masc_board_list" ->
        `Assoc
          [ "kind", `String "snapshot"
          ; "revision", `String "board:fixture"
          ; "snapshot", `String "Posts (0)"
          ]
      | "masc_ask_status" ->
        `Assoc [ "open_count", `Int 0; "returned", `Int 0; "asks", `List [] ]
      | "masc_schedule_list" -> `Assoc [ "status", `String "ok"; "schedules", `List [] ]
      | tool -> fail ("unexpected tool: " ^ tool)
    in
    let result, calls = run_plan plan ~answer in
    (match result with
     | Ok _ -> ()
     | Error _ -> fail "work-intake did not complete against valid tool answers");
    check
      (list string)
      "all four reads run"
      [ "answers"; "board"; "scheduled"; "tasks" ]
      (List.sort String.compare (List.map fst calls));
    check_inputs_declared plan calls;
    let tasks = input_of calls "tasks" in
    let board = input_of calls "board" in
    let answers = input_of calls "answers" in
    let scheduled = input_of calls "scheduled" in
    let names_limit json = Yojson.Safe.Util.member "limit" json <> `Null in
    check string "tasks reads who holds work" "in_progress" (string_member "status" tasks);
    check string "tasks asks for compact rows" "compact" (string_member "projection" tasks);
    check bool "tasks names its limit" true (names_limit tasks);
    check string "board orders by latest activity" "updated" (string_member "sort_by" board);
    check bool "board asks for compact rows" true
      (Yojson.Safe.Util.member "compact" board = `Bool true);
    check bool "board names its limit" true (names_limit board);
    check bool "answers reads open questions only" true
      (Yojson.Safe.Util.member "include_resolved" answers = `Bool false);
    check string "schedules are the caller's own" "self" (string_member "owner" scheduled);
    check string "schedules still waiting to fire" "scheduled" (string_member "status" scheduled);
    check bool "schedules name their limit" true (names_limit scheduled))
;;

let () =
  run
    "shipped skills"
    [ ( "admission"
      , [ test_case
            "every shipped skill is admitted"
            `Quick
            test_every_shipped_skill_is_admitted
        ] )
    ; ( "compositions"
      , [ test_case
            "run-and-read waits then reads both streams"
            `Quick
            test_run_and_read_waits_then_reads_both_streams
        ; test_case
            "prior-art bounds every search"
            `Quick
            test_prior_art_bounds_every_search
        ; test_case
            "work-intake names every page bound"
            `Quick
            test_work_intake_names_every_page_bound
        ] )
    ]
;;
