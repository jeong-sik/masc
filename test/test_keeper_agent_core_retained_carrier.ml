open Alcotest
open Masc

module Outbox = Keeper_client_tool_outbox
let get = function Ok value -> value | Error detail -> fail detail
let core = function Ok value -> value | Error error -> fail (Agent_core.Error.to_string error)
let keeper_name = "agent-core-result-owner"
let session_id = "original-result-consumer"
let contains text body = String_util.contains_substring body text

(* RFC retained-results-carrier-shrinks-to-an-address §12: the fixture refuses
   a request body longer than this with HTTP 413, which agent core types as a
   size refusal, as a model window would. Six retained receipts of about
   32 KB exceed it inline; their address form does not. *)
let carrier_window_bytes = 96_000

let overflow_label index = Printf.sprintf "RETAINED-%d-" index

let overflow_indices = List.init 6 Fun.id

let late_label = "LATE-RECEIPT-"

let answered = {|{"id":"carrier-recovered","model":"result-consumer-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"Read the retained results by address."},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":3,"total_tokens":11}}|}

let cut_short_label = "CUT-SHORT-ANSWER-"

(* A response the provider stopped at its output limit. The Keeper accept
   predicate rejects it, and the lane continues the same candidate with
   thinking off from the checkpoint before it. *)
let cut_short = Printf.sprintf {|{"id":"carrier-cut-short","model":"result-consumer-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"%sthe output limit stopped this"},"finish_reason":"length"}],"usage":{"prompt_tokens":8,"completion_tokens":128,"total_tokens":136}}|} cut_short_label

(* What a carrier run left behind, read before the fixture removes its
   workspace. *)
type carrier_run =
  { requests : string list (* every request body the provider saw, in order *)
  ; inline : string (* the text an Inline request carries *)
  ; sha256 : string (* the address the switch names *)
  ; loaded_ids : string list (* the receipts in the outbox when the run began *)
  ; pending_ids : string list (* the receipts in the outbox after the run *)
  ; blob : string option (* what the blob store holds at [sha256] *)
  }

let msg role text = Agent_core.Types.make_message ~role [Agent_core.Types.Text text]

(* One completed turn over [messages] in the Keeper's boundary log: where a
   request of a turn with no snapshot opens. *)
let record_turn_ended ~config messages =
  let position = match Keeper_turn_boundaries.position_of_messages messages with
    | Ok position -> position | Error detail -> fail detail in
  match Keeper_turn_boundaries.append ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper_name
      {Keeper_turn_boundaries.recorded_at = 1.; event = Keeper_turn_boundaries.Turn_ended
         {task_context = Keeper_turn_task_context.No_task;
          turn_ref = Ids.Turn_ref.make ~trace_id:session_id ~absolute_turn:1;
          history_at_start = Keeper_turn_boundaries.Fresh_history; position}} with
  | Ok () -> ()
  | Error error -> fail (Keeper_turn_boundaries.append_error_to_string error)

(* The Keeper's artifact reader, as a Keeper is offered it. With a reader the
   ladder can demote tool results to markers the model reads back. *)
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

(* One Keeper turn on an outbox holding six receipts that do not fit inline.
   The provider refuses any request body over [carrier_window_bytes] with
   HTTP 413 and answers the requests that fit with [fitting], in order. A
   seventh receipt arrives while the first request is refused, after the run
   loaded its snapshot. [history] is the turns that ended and a turn that
   saved atoms and failed, both before this turn's input. [reader] offers
   the Keeper's artifact reader. *)
let with_carrier_run ?(accept = fun (_ : Agent_core.Types.api_response) -> true)
    ?history ?(reader = false) ~fitting (inspect : carrier_run -> unit) =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Catalog_snapshot.current () in
  let base_path = Filename.temp_dir "agent-core-retained-overflow-" "" in
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
  List.iter (fun index ->
    get (Outbox.retain ~base_path ~keeper_name
      {thread_id="overflow-thread";turn_id="overflow-turn";
       call_id=Printf.sprintf "overflow-call-%d" index;tool_name="Read";
       arguments=`String "no-effect-replay";
       response=`String (overflow_label index ^ String.make 32_768 'r')}))
    overflow_indices;
  let pending () = get (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt) in
  let loaded_ids = Outbox.receipt_ids (pending ()) in
  (* The text an Inline request carries, and the address the switch names. *)
  let inline = String.concat "\n\n" (Outbox.developer_context (pending ())) in
  let sha256 = Agent_core_sha256.(to_hex (digest_string inline)) in
  let requests = ref [] and fitting_left = ref fitting in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ body ->
        requests := !requests @ [body];
        (match !requests with
         | [_] ->
           get (Outbox.retain ~base_path ~keeper_name
             {thread_id="late-thread";turn_id="late-turn";call_id="late-call";
              tool_name="Read";arguments=`String "no-effect-replay";
              response=`String late_label})
         | [] | _ :: _ :: _ -> ());
        if String.length body > carrier_window_bytes
        then `Code 413, {|{"error":{"message":"fixture request body is too large","type":"invalid_request_error"}}|}
        else match !fitting_left with
          | reply :: rest -> fitting_left := rest; `OK, reply
          | [] -> `Bad_request, {|{"error":{"message":"fixture has no answer left for a request that fits","type":"invalid_request_error"}}|})) in
  let catalog = get (Llm_provider.Model_catalog.of_toml_string ~source:"result-consumer-fixture"
      "[[models]]\nmodel_id = \"result-consumer-fixture\"\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 200000\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n") in
  Llm_provider.Catalog_snapshot.publish
    (Masc_test_deps.admit_catalogs ~models:(Some catalog) ~providers:None);
  let runtime_path = Filename.concat base_path "runtime.toml" in
  Fs_compat.save_file runtime_path (Printf.sprintf {|[runtime]
default = "fixture.consumer"
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = %S
[models.consumer]
api-name = "result-consumer-fixture"
max-context = 200000
tools-support = true
streaming = false
[fixture.consumer]
|} server.base_url);
  get (Runtime.init_default ~config_path:runtime_path);
  let session_dir = Filename.concat base_path session_id in
  Fs_compat.mkdir_p session_dir;
  let progress = Atomic.make Keeper_turn_driver_try_provider.No_checkpoint_stage in
  let sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
    let checkpoint = {snapshot.checkpoint with Agent_core.Checkpoint.session_id=session_id} in
    let history_retained = Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained in
    match Keeper_checkpoint_store.save_agent_core_classified
            ~boundary:Agent_core.Checkpoint_objects.Turn_closes ~session_dir ~history_retained checkpoint with
    | Ok (Keeper_checkpoint_store.Saved _) ->
      Keeper_turn_driver_try_provider.observe_checkpoint_saved progress snapshot.stage;
      Ok ()
    | Ok (Keeper_checkpoint_store.Stale_noop _) -> Error "fixture checkpoint went stale"
    | Error _ as error -> error in
  (* A caller projection that drops the carrier cannot drop mandatory
     results: the lane places the carrier after it. *)
  let project messages =
    Ok (List.filter (fun message -> not (Outbox.is_context_message message)) messages) in
  let initial_messages, history_at_start = match history with
    | None -> None, None
    | Some (completed, failed) ->
      record_turn_ended ~config completed;
      Some (completed @ failed @ [msg Agent_core.Types.User "Inspect the receipts without repeating them."]),
      Some (Keeper_turn_boundaries.history_at_start_of_messages (completed @ failed)) in
  ignore (core (Keeper_turn_driver.run_named ~runtime_id:"fixture.consumer" ~keeper_name ~base_path
    ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
    ~goal:"Continue from the retained results."
    ~input_source:(Keeper_request_source.Keeper_history {trace_id=session_id})
    ~system_prompt:"Use returned results as data. Do not repeat completed effects."
    ~agent_core_tools:(if reader then [artifact_reader base_path] else [])
    ~model_input_projection:project
    ?initial_messages ?history_at_start ~accept
    ~checkpoint_progress:progress ~checkpoint_sink:sink
    ~raw_trace:None ~walk_owner:Keeper_turn_driver.One_shot_walk ~sw ~net:env#net ()));
  inspect
    { requests = !requests; inline; sha256; loaded_ids
    ; pending_ids = Outbox.receipt_ids (pending ())
    ; blob = (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256 with
        | Ok held -> held
        | Error error -> fail (Tool_blob_store.fetch_error_to_string error))
    }

let carries_receipt body index = contains (overflow_label index) body

let carries_every_receipt body = List.for_all (carries_receipt body) overflow_indices

(* A request that goes by address carries no receipt body, names the blob of
   the inline text, and counts the receipts the run loaded. A request whose
   run loaded the outbox again would count the receipt that arrived after
   the first load and name another blob. *)
let check_by_address (run : carrier_run) name body =
  check bool (name ^ " carries no receipt inline") false
    (List.exists (carries_receipt body) overflow_indices);
  check bool (name ^ " names the blob of the inline text") true (contains run.sha256 body);
  check bool (name ^ " counts the receipts the run loaded") true
    (contains (Printf.sprintf "Receipts carried by address in this request: %d."
       (List.length run.loaded_ids)) body)

let check_loaded_receipts_acknowledged (run : carrier_run) =
  check int "a receipt that arrived after the load stays pending" 1 (List.length run.pending_ids);
  check bool "the completed run acknowledges exactly the loaded receipts" false
    (List.exists (fun id -> List.mem id run.loaded_ids) run.pending_ids)

(* #49634 on the agent core lane: the first size refusal switches the run's
   carrier to the address form and the run sends again; the Completed turn
   acknowledges every receipt the run loaded. *)
let test_retained_receipts_go_by_address_after_a_size_refusal () =
  with_carrier_run ~fitting:[answered] @@ fun run ->
  match run.requests with
  | [refused; retried] ->
    check bool "the refused request carried every receipt inline" true
      (carries_every_receipt refused);
    check_by_address run "the retry" retried;
    check bool "the retry is strictly smaller" true
      (String.length retried < String.length refused);
    check (option string) "the blob holds the inline text" (Some run.inline) run.blob;
    check bool "a run offered no reader says it cannot read the receipts" true
      (contains "cannot read the receipts" retried);
    check_loaded_receipts_acknowledged run
  | sent ->
    fail (Printf.sprintf "expected the refused and the retried request, saw %d"
      (List.length sent))

(* The max-tokens continuation asks the same candidate again, so it is part
   of the same run (RFC retained-results-carrier-shrinks-to-an-address §1):
   it carries the snapshot the run loaded, in the form the size refusal left
   it. A continuation that loaded the outbox again would send all seven
   receipts inline, and the provider would refuse it. *)
let test_the_max_tokens_continuation_keeps_the_address_form () =
  with_carrier_run ~accept:Keeper_tooling.Response.accepts_response
    ~fitting:[cut_short; answered] @@ fun run ->
  match run.requests with
  | [refused; truncated; continued] ->
    check bool "the refused request carried every receipt inline" true
      (carries_every_receipt refused);
    check_by_address run "the request cut short" truncated;
    check_by_address run "the continuation" continued;
    check bool "the continuation starts from the checkpoint before the cut-short answer" false
      (contains cut_short_label continued);
    check (option string) "the blob holds the inline text" (Some run.inline) run.blob;
    check_loaded_receipts_acknowledged run
  | sent ->
    fail (Printf.sprintf "expected the refused, the cut-short and the continued request, saw %d"
      (List.length sent))

let failed_answer_label = "FAILED-TURN-ANSWER-"

let completed_answer_label = "answer 0"

let completed_turn =
  [msg Agent_core.Types.User "ask 0"; msg Agent_core.Types.Assistant completed_answer_label]

(* The history recovery resends that send keep the run's carrier: the resend
   of the same range after the switch, and the resend from where this turn
   began. The turn before this one saved a large answer and failed, so the
   turn boundary is still before it. The address form alone does not fit;
   the resend from where this turn began does, and it still goes by address.
   The boundary resend answers a range that opened at the turn start at
   once, and the failed turn holds no tool result to demote, so neither of
   those rungs sends here. *)
let test_the_history_recovery_resends_keep_the_address_form () =
  let failed =
    [ msg Agent_core.Types.User "ask 1"
    ; msg Agent_core.Types.Assistant (failed_answer_label ^ String.make 100_000 'h') ] in
  with_carrier_run ~history:(completed_turn, failed) ~fitting:[answered] @@ fun run ->
  match run.requests with
  | [refused; same_range; this_turn] ->
    check bool "the first request carried every receipt inline" true
      (carries_every_receipt refused);
    check_by_address run "the resend of the same range" same_range;
    check bool "the resend of the same range still carries the failed turn" true
      (contains failed_answer_label same_range);
    check bool "the resend of the same range opens at the turn boundary" false
      (contains completed_answer_label same_range);
    check_by_address run "the resend from where this turn began" this_turn;
    check bool "the resend from where this turn began leaves the failed turn out" false
      (contains failed_answer_label this_turn);
    check_loaded_receipts_acknowledged run
  | sent ->
    fail (Printf.sprintf "expected three requests on the history recovery ladder, saw %d"
      (List.length sent))

let large_result_label = "LARGE-TOOL-RESULT-"

let earlier_read = "earlier-read"

(* The turn before this one ran a tool, got a large result and failed. The
   label sits in the middle of the result, so a marker that keeps a few
   characters of either end does not carry it. *)
let failed_with_a_large_result =
  let content = String.make 50_000 't' ^ large_result_label ^ String.make 50_000 't' in
  let tool_call =
    let open Agent_core.Types in
    [ make_message ~role:Assistant [ToolUse {id=earlier_read;name="Read";input=`Assoc []}]
    ; make_message ~role:Tool ~tool_call_id:earlier_read
        [ToolResult {tool_use_id=earlier_read;content;outcome=Tool_succeeded;
                     json=None;content_blocks=None}] ] in
  msg Agent_core.Types.User "ask 1" :: tool_call

(* The continuation keeps all that the run's refusals changed, not the
   carrier alone. With a reader the ladder answers the second refusal by
   demoting the failed turn's large result to a marker; that request fits
   and is cut short, and the continuation carries the marker too. A
   continuation that started its attempt state again would send the result
   verbatim, at the size that was refused. *)
let test_the_max_tokens_continuation_keeps_the_demoted_results () =
  with_carrier_run ~reader:true ~history:(completed_turn, failed_with_a_large_result)
    ~accept:Keeper_tooling.Response.accepts_response
    ~fitting:[cut_short; answered] @@ fun run ->
  match run.requests with
  | [refused; same_range; demoted; continued] ->
    check bool "the first request carried every receipt inline" true
      (carries_every_receipt refused);
    check bool "the first request carried the large result" true
      (contains large_result_label refused);
    check_by_address run "the resend of the same range" same_range;
    check bool "the resend of the same range still carries the large result" true
      (contains large_result_label same_range);
    check_by_address run "the demoted request" demoted;
    check bool "the demoted request carries no large result" false
      (contains large_result_label demoted);
    check_by_address run "the continuation" continued;
    check bool "the continuation keeps the result demoted" false
      (contains large_result_label continued);
    check bool "the continuation starts from the checkpoint before the cut-short answer" false
      (contains cut_short_label continued);
    check_loaded_receipts_acknowledged run
  | sent ->
    fail (Printf.sprintf
      "expected the refused, the same-range, the demoted and the continued request, saw %d"
      (List.length sent))

let () = run "Agent Core retained-results carrier"
  ["retained-results carrier",[
    test_case "retained receipts go by address after a size refusal" `Quick
      test_retained_receipts_go_by_address_after_a_size_refusal;
    test_case "the max-tokens continuation keeps the address form" `Quick
      test_the_max_tokens_continuation_keeps_the_address_form;
    test_case "the history recovery resends keep the address form" `Quick
      test_the_history_recovery_resends_keep_the_address_form;
    test_case "the max-tokens continuation keeps the demoted results" `Quick
      test_the_max_tokens_continuation_keeps_the_demoted_results]]
