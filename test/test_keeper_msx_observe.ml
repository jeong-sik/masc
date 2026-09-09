open Alcotest
open Masc

module Catalog = Keeper_tool_composition_catalog
module Plan = Keeper_tool_plan
module Executor = Keeper_tool_plan_executor

let query = "Transcribe the current prompt; mark unreadable text with ?."

let plan () =
  let document = In_channel.with_open_bin "../skills/msx-observe/SKILL.md"
      In_channel.input_all in
  let skill = match Keeper_skill_catalog.parse_skill ~directory:"msx-observe" document with
    | Ok skill -> skill
    | Error error -> fail (Keeper_skill_catalog.error_to_string error) in
  let entry = match skill.surface with
    | Keeper_skill_catalog.Composition entry -> entry
    | Keeper_skill_catalog.Instruction -> fail "observation Skill is not executable" in
  match Catalog.instantiate
      ~descriptors:(Keeper_tool_descriptor.all_descriptors ())
      ~args:(`Assoc ["query", `String query]) entry with
  | Ok plan -> plan
  | Error error -> fail (Catalog.instantiation_error_to_string error)

let capture_result ~frame ~artifact =
  let observation : Msx_lane.observation =
    { frame; mode = "GRAPHIC6"; pc = 0xdbac; halted = false
    ; screen_text = ""; screen_view = "pixels"; tiles = []
    ; sprites = [{ index = 0; x = 1; y = 2; pattern = 3; color = 4 }]
    ; cartridge = None; disk = Some "synthetic.dsk" } in
  (* Use the production observation serializer, including nullable media and
     sprite fields, rather than a minimal hand-written schema-shaped object. *)
  Tool_misc_msx_lane.of_lane ~tool_name:"masc_msx_screen" ~start_time:0.0
    ~extra:["artifact", `String artifact; "media_type", `String "image/png";
      "width", `Int 512; "height", `Int 212; "bytes", `Int 1234]
    (Ok observation)

let execute ~capture ~reader =
  let dispatched = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input =
    dispatched := !dispatched @ [node.Plan.tool_name];
    let result = match node.Plan.tool_name with
      | "masc_msx_screen" ->
          check bool "capture accepts no previous artifact" true (input = `Assoc []);
          capture
      | "keeper_analyze_image" -> reader input
      | name -> failf "unexpected tool: %s" name in
    Executor.dispatch_result result in
  let result = Executor.execute ~plan:(plan ()) ~run_id:(Plan.Run_id.fresh ())
      ~dispatch () in
  !dispatched, result

let test_snapshot_binding () =
  Eio_main.run (fun _env ->
    List.iter (fun (frame, artifact) ->
      let capture = capture_result ~frame ~artifact in
      let reading = Tool_result.make_ok ~tool_name:"keeper_analyze_image" ~start_time:0.0
          ~data:(`Assoc ["text", `String "visible prompt"]) () in
      let dispatched, result = execute ~capture ~reader:(fun input ->
        check bool "exact captured handle and caller query, automatic runtime" true
          (input = `Assoc ["artifact", `String artifact; "query", `String query]);
        reading) in
      check (list string) "capture precedes interpretation"
        ["masc_msx_screen"; "keeper_analyze_image"] dispatched;
      match result with
      | Ok [captured; read] ->
          check bool "capture frame and full payload survive settlement" true
            (Tool_result.to_json captured.result = Tool_result.to_json capture);
          check bool "reader result survives settlement" true
            (Tool_result.to_json read.result = Tool_result.to_json reading)
      | Ok _ | Error _ -> fail "capture/read composition failed")
      [54429, String.make 64 'a'; 55449, String.make 64 'b'])

let test_capture_failure_stops_reader () =
  Eio_main.run (fun _env ->
    let capture = Tool_result.make_err ~tool_name:"masc_msx_screen" ~start_time:0.0
        ~class_:Tool_result.Workflow_rejection "no machine" in
    let dispatched, result = execute ~capture ~reader:(fun _ -> fail "reader ran without capture") in
    check (list string) "only capture attempted" ["masc_msx_screen"] dispatched;
    match result with
    | Error { cause = Executor.Tool_did_not_complete node; settled = [_]; _ } ->
        check bool "original capture error retained" true
          (Tool_result.to_json node.result = Tool_result.to_json capture)
    | Ok _ | Error _ -> fail "capture error did not stop the composition")

let test_missing_handle_rejected () =
  Eio_main.run (fun _env ->
    let fields = match Tool_result.data (capture_result ~frame:1 ~artifact:(String.make 64 'a')) with
      | `Assoc fields -> List.remove_assoc "artifact" fields
      | _ -> fail "capture data is not an object" in
    let capture = Tool_result.make_ok ~tool_name:"masc_msx_screen" ~start_time:0.0
        ~data:(`Assoc fields) () in
    let dispatched, result = execute ~capture ~reader:(fun _ -> fail "reader ran without handle") in
    check (list string) "malformed producer never reaches reader" ["masc_msx_screen"] dispatched;
    match result with
    | Error { cause = Executor.Plan_execution_failed
        { error = Plan.Output_validation_failed _; _ }; _ } -> ()
    | Ok _ | Error _ -> fail "missing artifact bypassed output validation")

let test_reader_failure_keeps_capture () =
  Eio_main.run (fun _env ->
    let capture = capture_result ~frame:55449 ~artifact:(String.make 64 'c') in
    let failure = Tool_result.make_err ~tool_name:"keeper_analyze_image" ~start_time:0.0
        ~class_:Tool_result.Runtime_failure "no capable vision runtime" in
    let _, result = execute ~capture ~reader:(fun _ -> failure) in
    match result with
    | Error { cause = Executor.Tool_did_not_complete node; settled = [captured; _]; _ } ->
        check bool "reading failure remains a failure" true
          (Tool_result.to_json node.result = Tool_result.to_json failure);
        check bool "capture evidence survives reading failure" true
          (Tool_result.to_json captured.result = Tool_result.to_json capture)
    | Ok _ | Error _ -> fail "reading failure lost snapshot evidence")

let () =
  run "MSX observation Skill"
    ["composition", [
      test_case "fresh snapshot binds exact artifact and keeps evidence" `Quick test_snapshot_binding;
      test_case "capture failure never calls the reader" `Quick test_capture_failure_stops_reader;
      test_case "missing artifact fails the output contract" `Quick test_missing_handle_rejected;
      test_case "reading failure keeps the captured snapshot" `Quick test_reader_failure_keeps_capture]]
