(** Canonical execution -> enclosing turn -> exact raw occurrence. No screen
    assertions and no tool execution: these exercise the source read contract. *)
open Masc
module Source = Keeper_tool_result_source
let keeper = "original-result-proof"
let trace = "trace-original-result"
let id = Ids.Execution_id.of_string "exec-original-result"
let get = function Ok value -> value | Error error -> Alcotest.fail (Source.error_to_string error)
let turn_ref = match Ids.Turn_ref.of_string (trace ^ "#1") with
  | Some value -> value | None -> failwith "invalid test Turn_ref"
let observation = Tool_observation.to_yojson
    {attribution=Agent_observation.Pathless; turn_ref; declared_progress=None}

let row kind = `Assoc [
  "record_kind", `String "tool_call"; "keeper", `String keeper;
  "agent_name", `String keeper; "execution_id", Ids.Execution_id.to_yojson id;
  "trace_id", `String trace; "session_id", `String trace;
  "keeper_turn_id", `Int 1; "turn", `Int 0; "planned_index", `Int 0;
  "turn_kind", `String (Turn_record.turn_kind_to_string kind);
  "tool", `String "Execute"; "tool_use_id", `String "provider-id";
  "tool_observation", observation]
let replace name value = function
  | `Assoc fields -> `Assoc ((name,value)::List.remove_assoc name fields)
  | _ -> failwith "expected test object"
let invocation ?(kind=Turn_record.Direct) () =
  Source.invocation ~keeper ~execution_id:id ~rows:[row kind] |> get

let with_record kind f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_file "masc-original-result-" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) (fun () ->
    let config = Workspace.default_config dir in
    let run : Turn_record.raw_trace_run_ref = {
      worker_run_id="worker-original";path=Filename.concat dir "turn-proof.jsonl";
      start_seq=1;end_seq=5;agent_name="agent_core-test";session_id=trace} in
    Keeper_turn_record_writer.write
      ~model_input_window:None ~response_observed_model_input:None
      ~config ~keeper_name:keeper ~agent_name:keeper ~turn_kind:kind ~trace_id:trace
      ~absolute_turn:1 ~runtime_profile:"test" ~selected_model:None ~finish_reason:None
      ~context_window:None ~price_input_per_million:None ~price_output_per_million:None
      ~request_latency_ms:None ~ttfrc_ms:None ~request_wire_observation:None
      ~raw_trace_run_ref:(Some run)
      ~sampling:{temperature=None;top_p=None;max_tokens=None;enable_thinking=None}
      ~turn_output_tokens:None
      ~usage:{input_tokens=None;output_tokens=None;cache_creation_input_tokens=None;
        cache_read_input_tokens=None;scope=Runtime_usage_scope.Usage_scope_unavailable}
      ~execution_ids:[id] ~blocks:[] ~input_components:None ~tool_surface_ref:None ();
    let location = Dated_jsonl.Store.keeper (Workspace.dated_store_root config)
        ~keeper Dated_jsonl.Store.Keeper.Turn_records in
    let store = Dated_jsonl.open_store location in
    let entries = match Dated_jsonl.read_recent_result store 1 with
      | Ok entries -> entries | Error _ -> Alcotest.fail "turn fixture read failed" in
    let record = match entries with
      | [Dated_jsonl.Parsed json] ->
          (match Turn_record.of_json json with Ok record -> record
           | Error detail -> Alcotest.fail detail)
      | _ -> Alcotest.fail "missing turn fixture" in
    f record)

let target record = match Source.bind (invocation ~kind:record.Turn_record.turn_kind ())
    (Some record) |> get with
  | Bound target -> target
  | Awaiting_turn | Untraced_turn -> Alcotest.fail "expected bound original run"

let raw seq record_type fields =
  let json = `Assoc (["trace_version", `Int Agent_core.Raw_trace.trace_version;
    "worker_run_id", `String "worker-original";"seq", `Int seq;"ts", `Float 1.;
    "agent_name", `String "agent_core-test";"session_id", `String trace;
    "record_type", `String (Agent_core.Raw_trace.record_type_to_string record_type)] @ fields) in
  match Agent_core.Raw_trace.record_of_yojson json with
  | Ok record -> record | Error detail -> Alcotest.fail detail
let invocation_fields = ["tool_turn", `Int 0;"tool_planned_index", `Int 0;
  "tool_use_id", `String "provider-id";"tool_name", `String "Execute"]
let records content = [
  raw 1 Agent_core.Raw_trace.Run_started [];
  raw 2 Assistant_block ["block_kind", `String "thinking";
    "assistant_block", `Assoc ["thinking", `String "private reasoning"]];
  raw 3 Tool_execution_started (invocation_fields @ ["tool_execution_mode", `String "serial"]);
  raw 4 Tool_execution_finished (invocation_fields @ ["tool_result", `String content;
    "tool_error", `Bool false]);
  raw 5 Run_finished []]
let read target rows =
  List.fold_left (fun acc record -> Result.bind acc (fun scan -> Source.observe scan record))
    (Ok (Source.start target)) rows |> fun scan -> Result.bind scan Source.finish
let reject result = Alcotest.(check bool) "source refuses mismatched evidence" true (Result.is_error result)

let test_full_result () =
  let output = String.concat "\n" (List.init 120 (fun i ->
      Printf.sprintf "원문 %03d · C → C# → D 🙂" (i+1))) ^ "\n" in
  let content = Yojson.Safe.to_string (`Assoc ["output", `String output]) in
  List.iter (fun kind -> with_record kind (fun record ->
    let result = read (target record) (records content) |> get in
    Alcotest.(check string) "entire retained result, beyond preview" content result.content;
    Alcotest.(check int) "original byte count" (String.length content) result.recorded_bytes;
    Alcotest.(check int) "exact start" 3 result.start_seq;
    Alcotest.(check int) "exact finish" 4 result.finish_seq;
    Alcotest.(check bool) "producer tool outcome" false result.is_error))
    [Turn_record.Direct;Turn_record.Autonomous]

let test_binding_failures () = with_record Direct (fun record ->
  let invocation = invocation () in
  (match Source.bind invocation None |> get with Awaiting_turn -> ()
   | Untraced_turn | Bound _ -> Alcotest.fail "not pending");
  (match Source.bind invocation (Some {record with raw_trace_run_ref=None}) |> get with
   | Untraced_turn -> () | Awaiting_turn | Bound _ -> Alcotest.fail "not untraced");
  List.iter (fun record -> reject (Source.bind invocation (Some record))) [
    {record with keeper="another"}; {record with agent_name="another"};
    {record with turn_kind=Autonomous}; {record with execution_ids=[]};
    {record with execution_ids=[id;id]};{record with trace_id="trace-foreign"}];
  let source = row Direct in
  reject (Source.invocation ~keeper ~execution_id:id ~rows:[]);
  reject (Source.invocation ~keeper ~execution_id:id ~rows:[source;source]);
  List.iter (fun row -> reject (Source.invocation ~keeper ~execution_id:id ~rows:[row])) [
    replace "session_id" (`String "another") source;
    replace "turn" (`Int (-1)) source;
    replace "keeper_turn_id" (`Int 2) source;
    replace "tool_observation" `Null source;
    replace "execution_id" (`String "exec-another") source;
    match source with `Assoc fields -> `Assoc (("turn",`Int 0)::fields)
      | _ -> Alcotest.fail "test row"])

let test_occurrence_failures () = with_record Direct (fun record ->
  let target = target record in
  let rows = records "original" in
  let started = List.nth rows 2 and finished = List.nth rows 3 in
  List.iter (fun rows -> reject (read target rows)) [
    List.filter (fun (r:Agent_core.Raw_trace.record) -> r.seq <> 3) rows;
    List.filter (fun (r:Agent_core.Raw_trace.record) -> r.seq <> 5) rows;
    [List.hd rows;started;started;finished;List.nth rows 4];
    [List.hd rows;{started with seq=2};started;finished;List.nth rows 4];
    [List.hd rows;started;{finished with tool_name=Some "Read"};List.nth rows 4];
    [List.hd rows;started;{finished with session_id=Some "trace-another"};List.nth rows 4];
    [List.hd rows;started;{finished with worker_run_id="another"};List.nth rows 4];
    [List.hd rows;started;{finished with tool_result=None};List.nth rows 4]];
  (* Same provider ID, different occurrence, cannot replace the requested one. *)
  let other_start = {started with seq=2;tool_turn=Some 1} in
  let other_finish = {finished with seq=3;tool_turn=Some 1;tool_result=Some "wrong"} in
  reject (read target [List.hd rows;other_start;other_finish;List.nth rows 4]))

let test_full_redaction () = with_record Direct (fun record ->
  let result = read (target record)
      (records {|{"output":"all retained","password":"private-secret"}|}) |> get in
  let json = Yojson.Safe.from_string result.content in
  Alcotest.(check string) "retained nonsensitive output" "all retained"
    Yojson.Safe.Util.(json |> member "output" |> to_string);
  Alcotest.(check string) "structured secret withheld" "[REDACTED]"
    Yojson.Safe.Util.(json |> member "password" |> to_string);
  let plain = "  original text\n" in
  let result = read (target record) (records plain) |> get in
  Alcotest.(check string) "plain whitespace retained" plain result.content)

let () = Alcotest.run "original tool result source" ["canonical source",[
  Alcotest.test_case "full result in direct and autonomous turns" `Quick test_full_result;
  Alcotest.test_case "binding pending absence and conflicts" `Quick test_binding_failures;
  Alcotest.test_case "unique occurrence and complete run" `Quick test_occurrence_failures;
  Alcotest.test_case "full redaction and whitespace" `Quick test_full_redaction]]
