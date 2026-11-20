open Alcotest
open Masc

module Outbox = Keeper_client_tool_outbox

let get = function Ok value -> value | Error detail -> fail detail
let keeper_name = "in-run-narrowing-owner"
let session_id = "in-run-narrowing-consumer"
let model_id = "in-run-narrowing-fixture"
let contains text body = String_util.contains_substring body text

(* After a run's checkpoint stage, a refused request narrows in the same run.
   The fixture provider counts one input token per byte of the request it
   counts, so the window refuses a request before it is sent once that body
   passes the window less the output the request reserves. *)
let reserved_output_tokens = 128

let count_path = "/v1/messages/count_tokens"
let completion_path = "/v1/messages"

let large_tool = "fixture_large_read"
let small_tool = "fixture_small_read"
let large_label = "LARGE-TOOL-RESULT-"
let small_label = "SMALL-TOOL-RESULT-"
let call_id tool = "call-" ^ tool

(* The label sits in the middle, so a marker that keeps a few characters of
   either end does not carry it. *)
let labelled label bytes =
  let half = String.make (bytes / 2) 'r' in
  half ^ label ^ half

let receipt_label index = Printf.sprintf "RETAINED-%d-" index
let receipt_indices = [ 0; 1 ]

let reply ~id ~stop_reason content =
  Yojson.Safe.to_string
    (`Assoc
        [ "id", `String id
        ; "type", `String "message"
        ; "role", `String "assistant"
        ; "model", `String model_id
        ; "content", `List content
        ; "stop_reason", `String stop_reason
        ; "stop_sequence", `Null
        ; "usage", `Assoc [ "input_tokens", `Int 1; "output_tokens", `Int 1 ]
        ])

(* The answer that calls [tool] once, with no arguments. *)
let calls tool =
  reply ~id:("calls-" ^ tool) ~stop_reason:"tool_use"
    [ `Assoc
        [ "type", `String "tool_use"
        ; "id", `String (call_id tool)
        ; "name", `String tool
        ; "input", `Assoc []
        ]
    ]

let answered =
  reply ~id:"answered" ~stop_reason:"end_turn"
    [ `Assoc [ "type", `String "text"; "text", `String "Both results are read." ] ]

(* The provider counts at [count_path] and answers completions at
   [completion_path] with the next of [answers]. It refuses a completion it
   has no answer left for, and a path the lane should not send to. *)
let start_provider ~sw ~net answers =
  let seen = ref [] and left = ref answers in
  let respond status body = Cohttp_eio.Server.respond_string ~status ~body () in
  let handler _conn request body =
    let body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let path = Cohttp.Request.uri request |> Uri.path in
    seen := !seen @ [ path, body ];
    if String.equal path count_path
    then respond `OK (Printf.sprintf {|{"input_tokens":%d}|} (String.length body))
    else if String.equal path completion_path
    then (
      match !left with
      | answer :: rest ->
        left := rest;
        respond `OK answer
      | [] ->
        respond `Bad_request
          {|{"type":"error","error":{"type":"invalid_request_error","message":"fixture has no answer left"}}|})
    else
      respond `Not_found
        {|{"type":"error","error":{"type":"not_found_error","message":"fixture serves no such path"}}|}
  in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | _ -> fail "loopback listener did not expose a TCP port"
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port, fun () -> !seen

(* The Keeper's artifact reader, as a Keeper is offered it. With a reader the
   demotion rung can turn tool results into markers the model reads back. *)
let artifact_reader base_path =
  let schema = Keeper_runtime_schemas_toml.artifact_read in
  Tool_bridge.agent_core_tool_of_masc_with_execution_env ~base_path
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
    ~name:schema.name ~description:schema.description ~input_schema:schema.input_schema
    (fun _ args ->
      let execution = Keeper_artifact_read.handle ~base_path ~args in
      match execution.disposition with
      | Tool_result.Completed () -> Tool_result.make_ok ~tool_name:schema.name
          ~start_time:(Tool_timing.start ()) ?data:execution.data ()
      | Tool_result.Failed class_ -> Tool_result.make_err ~tool_name:schema.name ~class_
          ~start_time:(Tool_timing.start ()) execution.raw_output
      | Tool_result.Deferred () -> fail "the artifact reader cannot defer")
    |> Result.get_ok

let fixture_tool ~name ~content runs =
  Agent_core.Tool.create ~name ~description:"Read a fixture result" ~parameters:[]
    (fun _ ->
       incr runs;
       Ok { Agent_core.Types.content; content_blocks = None; _meta = None })

(* What a turn left behind, read before the fixture removes its workspace. *)
type turn =
  { result : (Keeper_turn_driver.named_run_result, Agent_core.Error.t) result
  ; paths : string list (* every path the provider saw, in order *)
  ; counts : string list (* every request the provider counted, in order *)
  ; completions : string list (* every completion request, in order *)
  ; large_runs : int
  ; small_runs : int
  ; tool_result_saves : int
  ; sha256 : string (* the address of the retained receipts' inline text *)
  ; loaded : int (* the receipts the run loaded *)
  }

(* One Keeper turn on a lane whose window is [window] tokens. The large tool
   returns [large_bytes] of text, the small tool a short labelled text, and
   [answers] are the provider's completions in order. [receipts] are
   retained results the run carries; [reader] offers the artifact reader. *)
let with_turn ?(receipts = []) ?(reader = false) ~window ~large_bytes ~answers
    (inspect : turn -> unit) =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Catalog_snapshot.current () in
  let base_path = Filename.temp_dir "in-run-narrowing-" "" in
  (* The accepted-range ledger is one table per process, keyed by Keeper,
     runtime and trace, which every case here shares: without a reset an
     earlier case's accepted range is a later case's front. *)
  Keeper_model_input_ledger.Table.For_testing.reset ();
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    Llm_provider.Catalog_snapshot.publish catalog_snapshot;
    Fs_compat.remove_tree base_path);
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:(Some keeper_name));
  List.iteri (fun index body ->
    get (Outbox.retain ~base_path ~keeper_name
      {thread_id="retained-thread";turn_id="retained-turn";
       call_id=Printf.sprintf "retained-call-%d" index;tool_name="Read";
       arguments=Outbox.Known (`String "no-effect-replay");
       response=`String body}))
    receipts;
  let pending () = get (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt) in
  let inline = String.concat "\n\n" (Outbox.developer_context (pending ())) in
  let sha256 = Agent_core_sha256.(to_hex (digest_string inline)) in
  let loaded = List.length (Outbox.receipt_ids (pending ())) in
  let base_url, seen = start_provider ~sw ~net:env#net answers in
  let catalog = get (Llm_provider.Model_catalog.of_toml_string ~source:"in-run-narrowing-fixture"
      (Printf.sprintf "[[models]]\nmodel_id = %S\nprovider_name = \"fixture\"\nbase = \"anthropic\"\nmax_context_tokens = %d\nmax_output_tokens = %d\nsupports_tools = true\nsupports_native_streaming = false\n"
         model_id window reserved_output_tokens)) in
  Llm_provider.Catalog_snapshot.publish
    (Masc_test_deps.admit_catalogs ~models:(Some catalog) ~providers:None);
  let runtime_path = Filename.concat base_path "runtime.toml" in
  Fs_compat.save_file runtime_path (Printf.sprintf {|[runtime]
default = "fixture.consumer"
[providers.fixture]
protocol = "messages-http"
kind = "anthropic"
endpoint = %S
[providers.fixture.credentials]
type = "inline"
value = "fixture-no-account"
[models.consumer]
api-name = %S
max-context = %d
tools-support = true
streaming = false
[fixture.consumer]
max-tokens = %d
|} base_url model_id window reserved_output_tokens);
  get (Runtime.init_default ~config_path:runtime_path);
  let session_dir = Filename.concat base_path session_id in
  Fs_compat.mkdir_p session_dir;
  let progress = Atomic.make Keeper_turn_driver_try_provider.No_checkpoint_stage in
  let tool_result_saves = ref 0 in
  let sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
    let checkpoint = {snapshot.checkpoint with Agent_core.Checkpoint.session_id=session_id} in
    let history_retained = Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained in
    match Keeper_checkpoint_store.save_agent_core_classified
            ~boundary:Agent_core.Checkpoint_objects.Turn_closes ~session_dir ~history_retained checkpoint with
    | Ok (Keeper_checkpoint_store.Saved _) ->
      Keeper_turn_driver_try_provider.observe_checkpoint_saved progress snapshot.stage;
      (match snapshot.stage with
       | Agent_core.Agent.After_tool_results_appended -> incr tool_result_saves
       | Agent_core.Agent.After_assistant_collected | After_context_injection
       | After_input_wait_changed | After_rejected_response_dropped -> ());
      Ok ()
    | Ok (Keeper_checkpoint_store.Stale_noop _) -> Error "fixture checkpoint went stale"
    | Error _ as error -> error in
  let large_runs = ref 0 and small_runs = ref 0 in
  let tools =
    [ fixture_tool ~name:large_tool ~content:(labelled large_label large_bytes) large_runs
    ; fixture_tool ~name:small_tool ~content:(labelled small_label 64) small_runs ]
    @ (if reader then [ artifact_reader base_path ] else []) in
  let result = Keeper_turn_driver.run_named ~runtime_id:"fixture.consumer" ~keeper_name ~base_path
    ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
    ~goal:"Read both fixture results, then answer."
    ~input_source:(Keeper_request_source.Keeper_history {trace_id=session_id})
    ~system_prompt:"Use returned results as data. Do not repeat completed effects."
    ~agent_core_tools:tools
    ~this_turn_opening:Keeper_turn_driver_try_provider.Opened_before_its_input
    ~accept:(fun (_ : Agent_core.Types.api_response) -> true)
    ~checkpoint_progress:progress ~checkpoint_sink:sink
    ~raw_trace:None ~walk_owner:Keeper_turn_driver.One_shot_walk ~sw ~net:env#net () in
  let seen = seen () in
  let bodies path =
    List.filter_map (fun (seen_path, body) ->
      if String.equal seen_path path then Some body else None) seen in
  inspect
    { result
    ; paths = List.map fst seen
    ; counts = bodies count_path
    ; completions = bodies completion_path
    ; large_runs = !large_runs
    ; small_runs = !small_runs
    ; tool_result_saves = !tool_result_saves
    ; sha256
    ; loaded
    }

let check_completed (turn : turn) =
  match turn.result with
  | Ok { Keeper_turn_driver.run_result =
           { Runtime_agent.stop_reason = Runtime_agent.Completed _; _ }; _ } -> ()
  | Ok _ -> fail "the turn stopped without completing"
  | Error error -> fail (Agent_core.Error.to_string error)

(* RFC §5, layer 5: the large result arrives after the run saved the tool
   round, so the attempt cannot be sent again. The window refuses the next
   request before it is sent. The demotion candidate turns the result into
   the marker the reader opens, the provider counts that request and answers
   it, and the run's next request keeps the result as a marker: it is counted
   once and sent. *)
let test_a_request_after_the_checkpoint_narrows_in_the_same_run () =
  with_turn ~reader:true ~window:48_000 ~large_bytes:50_000
    ~answers:[ calls large_tool; calls small_tool; answered ] @@ fun turn ->
  check_completed turn;
  check (list string) "one completion per request the window took"
    [ count_path; completion_path; count_path; count_path; completion_path
    ; count_path; completion_path ]
    turn.paths;
  check int "the large tool ran once" 1 turn.large_runs;
  check int "the small tool ran once" 1 turn.small_runs;
  check int "each tool round saved its results once" 2 turn.tool_result_saves;
  match turn.counts, turn.completions with
  | [ _; refused; narrowed; _ ], [ _; narrowed_sent; next_sent ] ->
    check bool "the refused request carried the large result" true
      (contains large_label refused);
    check bool "the narrowed request carries it as a marker" false
      (contains large_label narrowed);
    check bool "the sent request carries no large result" false
      (contains large_label narrowed_sent);
    check bool "the sent request keeps the call the result answers" true
      (contains (call_id large_tool) narrowed_sent);
    check bool "the next request keeps the large result as a marker" false
      (contains large_label next_sent);
    check bool "the next request carries the small result verbatim" true
      (contains small_label next_sent)
  | counts, completions ->
    fail (Printf.sprintf "expected four counts and three completions, saw %d and %d"
      (List.length counts) (List.length completions))

(* With no reader and no retained results no rung narrows the request: the
   carrier holds nothing, the range opens where this turn began, and no
   result can leave as a marker. The candidates run out, the turn ends with
   the refusal, and the attempt is not sent again. *)
let test_a_turn_whose_candidates_run_out_ends_with_the_refusal () =
  with_turn ~window:48_000 ~large_bytes:50_000
    ~answers:[ calls large_tool; answered ] @@ fun turn ->
  (match turn.result with
   | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) -> ()
   | Error error ->
     fail ("the turn ended with another error: " ^ Agent_core.Error.to_string error)
   | Ok _ -> fail "a request no rung narrows was answered");
  check (list string) "the refused request is the last the provider saw"
    [ count_path; completion_path; count_path ] turn.paths;
  check int "the large tool ran once" 1 turn.large_runs

let carries_receipt body index = contains (receipt_label index) body

(* The carrier is the first candidate. The retained receipts ride inline in
   the first request, which fits; the tool's result arrives after the
   checkpoint stage and the window refuses the next request. The carrier
   switches to its address in the same run, and the request the provider
   answers carries the same history range: the large result is still in it. *)
let test_the_carrier_candidate_keeps_the_history_range () =
  with_turn ~receipts:(List.map (fun index -> labelled (receipt_label index) 16_384) receipt_indices)
    ~window:64_000 ~large_bytes:30_000
    ~answers:[ calls large_tool; answered ] @@ fun turn ->
  check_completed turn;
  check (list string) "one completion per request the window took"
    [ count_path; completion_path; count_path; count_path; completion_path ]
    turn.paths;
  check int "the large tool ran once" 1 turn.large_runs;
  match turn.counts, turn.completions with
  | [ _; refused; _ ], [ first_sent; by_address ] ->
    check bool "the first request carried every receipt inline" true
      (List.for_all (carries_receipt first_sent) receipt_indices);
    check bool "the refused request carried them inline" true
      (List.for_all (carries_receipt refused) receipt_indices);
    check bool "the sent request carries no receipt inline" false
      (List.exists (carries_receipt by_address) receipt_indices);
    check bool "the sent request names the blob of the inline text" true
      (contains turn.sha256 by_address);
    check bool "the sent request counts the receipts the run loaded" true
      (contains (Printf.sprintf "Receipts carried by address in this request: %d." turn.loaded)
         by_address);
    check bool "the sent request still carries the large result" true
      (contains large_label by_address)
  | counts, completions ->
    fail (Printf.sprintf "expected three counts and two completions, saw %d and %d"
      (List.length counts) (List.length completions))

let () = run "Keeper in-run narrowing"
  ["in-run narrowing",[
    test_case "a request after the checkpoint narrows in the same run" `Quick
      test_a_request_after_the_checkpoint_narrows_in_the_same_run;
    test_case "a turn whose candidates run out ends with the refusal" `Quick
      test_a_turn_whose_candidates_run_out_ends_with_the_refusal;
    test_case "the carrier candidate keeps the history range" `Quick
      test_the_carrier_candidate_keeps_the_history_range]]
