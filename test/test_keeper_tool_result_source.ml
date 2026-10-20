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

let row kind = `Assoc ["ts",`Float (Unix.gettimeofday ());
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
      worker_run_id="worker-original";path=Filename.concat
        (Keeper_types_support.keeper_raw_trace_dir config keeper) "turn-proof.jsonl";
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
    f config record)

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
  List.iter (fun kind -> with_record kind (fun _config record ->
    let result = read (target record) (records content) |> get in
    Alcotest.(check string) "entire retained result, beyond preview" content result.content;
    Alcotest.(check int) "original byte count" (String.length content) result.recorded_bytes;
    Alcotest.(check int) "exact start" 3 result.start_seq;
    Alcotest.(check int) "exact finish" 4 result.finish_seq;
    Alcotest.(check bool) "producer tool outcome" false result.is_error))
    [Turn_record.Direct;Turn_record.Autonomous]

let test_binding_failures () = with_record Direct (fun _config record ->
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

let test_occurrence_failures () = with_record Direct (fun _config record ->
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

let test_full_redaction () = with_record Direct (fun _config record ->
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

let write_raw record rows =
  let run=match record.Turn_record.raw_trace_run_ref with Some run -> run
    | None -> Alcotest.fail "missing fixture run" in
  Fs_compat.mkdir_p (Filename.dirname run.path);
  let content=String.concat "\n" (List.map (fun raw ->
    Agent_core.Raw_trace.record_to_yojson raw |> Yojson.Safe.to_string) rows)^"\n" in
  Fs_compat.save_file run.path content;
  run.path,content
let retained_output () =
  let output=String.concat "\n" (List.init 120 (fun index ->
    Printf.sprintf "원문 %03d · C → C# → D 🙂 \" %s" (index+1) (String.make 600 'q'))) ^ "\n" in
  Yojson.Safe.to_string (`Assoc ["output",`String output])
let test_owned_stream_and_pages () = with_record Direct (fun config record ->
  let content=retained_output () in
  ignore (write_raw record (records content));
  let reading=match Keeper_tool_result_file.read ~config ~keeper (target record) with
    | Ok reading -> reading | Error detail -> Alcotest.fail detail in
  Alcotest.(check string) "every record byte survives chunk boundaries" content reading.body.content;
  let module Page=Keeper_tool_result_page in
  let identity : Page.identity={source_id=reading.source_id;sha256=reading.sha256;
    recorded_bytes=reading.body.recorded_bytes;is_error=reading.body.is_error} in
  let buffer=Buffer.create 4096 in
  let rec pages previous offset =
    let request : Keeper_artifact_read.request={sha256=reading.sha256;offset;max_bytes=37} in
    let page=match Keeper_artifact_read.page
        ~envelope:(Page.page_envelope ~keeper ~execution_id:(Ids.Execution_id.to_string id) identity)
        request reading.body.content with
      | Ok page -> page | Error detail -> Alcotest.fail detail in
    let json=Page.to_json ~keeper ~execution_id:(Ids.Execution_id.to_string id) (Page.Page (identity,page)) in
    let response=Page.of_json ~keeper ~execution_id:(Ids.Execution_id.to_string id) json in
    let identity,page=match response with Ok (Page.Page (identity,page)) -> identity,page
      | Ok (Pending | Unavailable _) | Error _ -> Alcotest.fail "page protocol decode failed" in
    (match Page.validate_continuation ~offset ~previous identity page with
     | Ok () -> () | Error detail -> Alcotest.fail detail);
    let bytes=match Page.bytes page with Ok bytes -> bytes | Error detail -> Alcotest.fail detail in
    Buffer.add_string buffer bytes;
    if page.eof then
      (match Page.verify_body identity page (Buffer.contents buffer) with
       | Ok () -> () | Error detail -> Alcotest.fail detail)
    else pages (Some (identity,page)) page.next_offset in
  pages None 0;
  Alcotest.(check string) "all UTF8 and escapes reassembled from byte pages" content (Buffer.contents buffer))
let test_changed_owned_source () = with_record Direct (fun config record ->
  let path,content=write_raw record (records (retained_output ())) in
  let original ()=match Keeper_tool_result_file.read ~config ~keeper (target record) with
    | Ok reading -> reading | Error detail -> Alcotest.fail detail in
  let first=original () in
  Fs_compat.save_file_atomic path content;
  let second=original () in
  Alcotest.(check bool) "replacement changes source identity even for identical body" true
    (not (String.equal first.source_id second.source_id));
  List.iter (fun mutate ->
    Fs_compat.save_file path content;
    let changed=ref false in
    let range ~offset ~max_bytes path =
      let observed=Fs_compat.load_owned_regular_file_range ~ownership_root:config.base_path
          ~offset ~max_bytes path in
      if not !changed then (changed:=true;mutate path);
      observed in
    Alcotest.(check bool) "mid-read mutation refuses complete result" true
      (Result.is_error (Keeper_tool_result_file.For_testing.read ~read_range:range
        ~config ~keeper (target record)))) [
      (fun path -> Fs_compat.save_file_atomic path content);
      (fun path -> Fs_compat.save_file path (content ^ "\n"));
      (fun path -> Fs_compat.save_file path "");
      (fun path -> Unix.unlink path)];
  Fs_compat.save_file path content;
  let saved=path^".saved" in Unix.rename path saved; Unix.symlink saved path;
  Alcotest.(check bool) "symlink is never a source handle" true
    (Result.is_error (Keeper_tool_result_file.read ~config ~keeper (target record))))
let test_page_failures () =
  let module Page=Keeper_tool_result_page in
  let sha=Digestif.SHA256.(to_hex (digest_string "🙂x")) in
  let identity : Page.identity={source_id=sha;sha256=sha;recorded_bytes=5;is_error=false} in
  let request : Keeper_artifact_read.request={sha256=sha;offset=0;max_bytes=1} in
  let first=match Keeper_artifact_read.page request "🙂x" with
    | Ok page -> page | Error detail -> Alcotest.fail detail in
  Alcotest.(check string) "single UTF8 byte uses reversible base64" "\240"
    (match Page.bytes first with Ok bytes -> bytes | Error detail -> Alcotest.fail detail);
  List.iter (fun request -> Alcotest.(check bool) "invalid direct bound refused" true
    (Result.is_error (Keeper_artifact_read.page request "🙂x")))
    [{request with offset=(-1)};{request with offset=max_int};{request with max_bytes=0}];
  let envelope value=`Assoc ["padding",`String (String.make Common.max_tool_result_wire_bytes 'x');"page",value] in
  Alcotest.(check bool) "oversized envelope cannot stall at empty non-EOF page" true
    (Result.is_error (Keeper_artifact_read.page ~envelope request "🙂x"));
  let forged={first with Keeper_artifact_read.next_offset=0} in
  Alcotest.(check bool) "no-progress reply is refused" true
    (Result.is_error (Page.validate_continuation ~offset:0 ~previous:None identity forged));
  let changed={identity with Page.source_id=String.make 64 '0'} in
  Alcotest.(check bool) "new source cannot continue old bytes" true
    (Result.is_error (Page.validate_continuation ~offset:first.next_offset
      ~previous:(Some (identity,first)) changed
      {first with offset=first.next_offset;next_offset=first.next_offset+1}));
  Alcotest.(check bool) "wrong final body cannot satisfy digest" true
    (Result.is_error (Page.verify_body identity {first with eof=true;total_bytes=5} "other"))
let test_server_exact_body () = with_record Direct (fun config record ->
  let ledger=Dated_jsonl.open_store (Dated_jsonl.Store.at
    (Workspace.dated_store_root config) Dated_jsonl.Store.Root.Tool_calls) in
  Dated_jsonl.append ledger (row Direct);
  ignore (write_raw record (records "all original output"));
  let preconditions=Uri.encoded_of_query ["expected_base_path",[config.base_path];
    "expected_masc_root",[Filename.concat config.base_path Common.masc_dirname]] in
  let request query=Httpun.Request.create ~target:("/api/v1/keepers/"^keeper^
    "/tool-result?execution_id="^Ids.Execution_id.to_string id^"&"^preconditions^query) `GET in
  let status,json=Server_keeper_tool_result.response ~config ~keeper (request "&max_bytes=7") in
  Alcotest.(check bool) "exact endpoint page" true (status=`OK);
  let identity,page=match Keeper_tool_result_page.of_json ~keeper
      ~execution_id:(Ids.Execution_id.to_string id) json with
    | Ok (Page (identity,page)) -> identity,page
    | _ -> Alcotest.fail "expected original body page" in
  let invalid_queries=["&offset=1";"&max_bytes=0";"&offset=-1";"&offset=1&offset=2";
    "&path=/private/other";"&source_id=bad"] in
  List.iter (fun query -> let status,_=Server_keeper_tool_result.response ~config ~keeper (request query) in
    Alcotest.(check bool) "malformed request refused" true (status=`Bad_request)) invalid_queries;
  let status,_=Server_keeper_tool_result.response ~config ~keeper
      (request (Printf.sprintf "&offset=%d&source_id=%s" page.next_offset identity.source_id)) in
  Alcotest.(check bool) "same source continues" true (status=`OK);
  let path,_=write_raw record (records "changed original output") in
  ignore path;
  let status,_=Server_keeper_tool_result.response ~config ~keeper
      (request (Printf.sprintf "&offset=%d&source_id=%s" page.next_offset identity.source_id)) in
  Alcotest.(check bool) "source change is a conflict" true (status=`Conflict))

let () = Alcotest.run "original tool result source" ["canonical source",[
  Alcotest.test_case "full result in direct and autonomous turns" `Quick test_full_result;
  Alcotest.test_case "binding pending absence and conflicts" `Quick test_binding_failures;
  Alcotest.test_case "unique occurrence and complete run" `Quick test_occurrence_failures;
  Alcotest.test_case "full redaction and whitespace" `Quick test_full_redaction;
  Alcotest.test_case "owned chunk scan and UTF8 pages" `Quick test_owned_stream_and_pages;
  Alcotest.test_case "source changes and symlinks" `Quick test_changed_owned_source;
  Alcotest.test_case "page progress and source validation" `Quick test_page_failures;
  Alcotest.test_case "server exact original body route" `Quick test_server_exact_body]]
