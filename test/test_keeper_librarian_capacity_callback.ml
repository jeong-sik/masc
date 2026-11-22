open Masc
module Runtime = Keeper_librarian_runtime
module Fixture = Exact_output_fixture
module Runs = Exact_lane_run_registry

let test_callback ?(cli_errors = []) ?expected_limit ?shows_size ?same_failure ~base_path ~registry ~keeper_id ~first_overflow ~status ~expected () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = env#net and clock = env#clock in
  Eio_context.with_test_env ~net ~clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let start_server status =
  let posts = ref 0 in
  let socket = Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | _ -> Alcotest.fail "missing loopback port" in
  let handler _ _ body =
    ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all));
    incr posts;
    let body = match status with
      | `Request_entity_too_large -> {|{"error":{"message":"fixture body limit","type":"invalid_request_error"}}|}
      | `Too_many_requests -> {|{"error":{"message":"fixture quota","type":"rate_limit_error"}}|}
      (* A 200 whose one choice carries nothing: the provider answered empty. *)
      | `OK ->
        {|{"id":"fixture","object":"chat.completion","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":0,"total_tokens":1}}|}
      | _ -> {|{"error":{"message":"fixture authorization","type":"authentication_error"}}|} in
    Cohttp_eio.Server.respond_string ~status ~body () in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port, posts in
  let first = if first_overflow then Some (start_server `Request_entity_too_large) else None in
  let base_url, posts = start_server status in
  let terminal : Fixture.target_fixture = {id = "capacity-terminal"; base_url} in
  let targets = match first with
    | None -> [terminal]
    | Some (base_url, _) -> [{Fixture.id = "capacity-first"; base_url}; terminal] in
  let resolver = Fixture.resolver_snapshot ~source:"capacity-callback-fixture" targets in
  (match Runtime_exact_output_registry.publish
      ~lanes:[{Runtime_schema.owner = Runtime_schema.Builtin Standalone_lane.Librarian;
        enabled = true; slot_ids = List.map (fun (target : Fixture.target_fixture) -> target.id) targets;
        cli_slot_ids = List.map fst cli_errors;
        max_output_tokens = Some 4_096; thinking = None}] resolver with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Runtime_exact_output_registry.publication_error_to_string error));
  let input : Keeper_librarian.input =
    { turn_ref = Ids.Turn_ref.make ~trace_id:keeper_id ~absolute_turn:1
    ; goal_context = Keeper_librarian.No_task
    ; keeper_id = Masc_test_deps.keeper_id_fixture keeper_id
    ; keeper_instructions = "Preserve evidence."
    ; working_context = Keeper_librarian_context.empty } in
  let cli_calls = ref [] in
  let cli_runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    cli_calls := !cli_calls @ [runtime_id];
    Error (List.assoc runtime_id cli_errors) in
  let refused = ref 0 and committed = ref false and observed_limit = ref None in
  let verdict = ref None and same = ref None and provider_refusals = ref [] in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Runtime.run_best_effort ~cli_runner
    ~on_cli_input_limit:(fun limit ->
      incr refused;
      observed_limit := Some (limit.Keeper_lane_cli_oneshot.runtime_id, limit.capacity.max_chars))
    ~on_not_committed:(fun outcome ->
      provider_refusals := List.sort_uniq compare
        (!provider_refusals @ outcome.Runtime.provider_input_refusals);
      let shows_size = outcome.Runtime.walk_shows_size in
      verdict := Some (match !verdict with None -> shows_size | Some earlier -> earlier || shows_size);
      let met = outcome.Runtime.smaller_range_meets_same_failure in
      same := Some (match !same with None -> met | Some earlier -> earlier || met))
    ~on_context_committed:(fun _ -> committed := true)
    ~base_path ~keepers_dir ~keeper_id input;
  Alcotest.(check int) "only a CLI slot reports an input limit" expected !refused;
  Option.iter (fun expected -> Alcotest.(check (option (pair string int)))
    "limit retains the actual refusing runtime" (Some expected) !observed_limit) expected_limit;
  (* The verdict the continuity pass reads to decide whether to read less. It
     is taken from every failure of the walk, so the same set of causes
     answers the same way in either order. *)
  Option.iter
    (fun shows_size ->
       Alcotest.(check (option bool))
         "the walk's size verdict" (Some shows_size) !verdict)
    shows_size;
  (* What a recursive splitter reads as a veto: the walk also met a failure a
     smaller range meets the same way. *)
  Option.iter
    (fun met ->
       Alcotest.(check (option bool))
         "the walk also met a size-independent failure" (Some met) !same)
    same_failure;
  Alcotest.(check (list string)) "CLI candidates ran in order"
    (List.map fst cli_errors) !cli_calls;
  Alcotest.(check int) "terminal provider really received the request" 1 !posts;
  Option.iter (fun (_, count) -> Alcotest.(check int)
    "body-refused first provider really ran" 1 !count) first;
  Alcotest.(check bool) "refused request never commits Memory" false !committed;
  let expected_refusals =
    if first_overflow || status = `Request_entity_too_large
    then [Keeper_librarian_input_refusal.Request_body_refused]
    else [] in
  Alcotest.(check (list string)) "named HTTP body refusal survives subsequent slots and CLI fallback"
    (List.map Keeper_librarian_input_refusal.to_string expected_refusals)
    (List.map Keeper_librarian_input_refusal.to_string !provider_refusals);
  let runs = Runs.list_runs registry |> List.filter
    (fun (run : Runs.run) -> String.equal run.actor keeper_id) in
  match runs with
  | [run] -> Alcotest.(check string) "terminal failure remains observable" "failed"
      (Runs.status_label run.status)
  | _ -> Alcotest.fail "expected one recorded Librarian run"

(* The size verdict, cause by cause. A walk reads less when any of its
   failures answers true, so this table is the whole rule: a row that flips
   changes what a keeper reads after a refusal. *)
let test_named_provider_input_refusals () =
  let module E = Agent_core.Exact_output in
  let module I = Keeper_librarian_input_refusal in
  let refused refusal = E.Provider_response_refused
    { http_status = 400; refusal; retry_after_s = None } in
  List.iter (fun (label, cause, expected) ->
    Alcotest.(check (list string)) label
      (List.map I.to_string expected)
      (List.map I.to_string (Runtime.For_testing.cause_input_refusals cause)))
    [ "named context overflow", refused E.Context_overflow, [I.Context_overflow]
    ; "named input capacity", refused E.Input_capacity, [I.Input_capacity]
    ; "named request body refusal", refused E.Request_body_refused, [I.Request_body_refused]
    ; "unknown invalid request cannot become a named size refusal", refused E.Invalid_request, []
    ; "missing refusal body cannot become a named size refusal", refused E.Refusal_body_not_received, []
    ; "timeout cannot become a named size refusal", refused E.Timeout, []
    ; "quota cannot become a named size refusal", refused E.Rate_limited, []
    ; "invalid answer cannot become a named size refusal", E.Invalid_json_output, []
    ];
  let module Http = Agent_core.Llm_provider.Http_client in
  let context_error = Http.ProviderFailure
    {kind=Http.Context_overflow {limit=None};message="fixture"} in
  Alcotest.(check (list string)) "an unsent context failure is not a provider refusal" []
    (List.map I.to_string (Runtime.For_testing.cause_input_refusals
      (E.Completion_failed {error=context_error;dispatch=E.No_generation_dispatch})));
  List.iter (fun cause ->
    let module Shared = Keeper_exact_walk_failure in
    let original=Shared.of_cause cause in
    let decoded=match Shared.api_observation cause |> Shared.api_observation_to_yojson
        |> Shared.api_observation_of_yojson with
      | Ok observed -> Shared.of_api_observation observed
      | Error detail -> Alcotest.fail detail in
    Alcotest.(check bool) "named actual causes survive the strict shared receipt source codec" true
      (original=decoded))
    [refused E.Context_overflow;refused E.Input_capacity;refused E.Request_body_refused;
     refused E.Rate_limited;E.Invalid_json_output;
     E.Completion_failed {error=context_error;dispatch=E.No_generation_dispatch};
     E.Window_reached {output=E.No_output};E.Window_reached {output=E.Partial_output}]

let test_native_context_receipt_flags () =
  let module Shared = Keeper_exact_walk_failure in
  let runtime_id = Fixture.cli_primary_runtime in
  let codex tool_effect_attempted = Fusion_official_client.Codex_failure
    (Runtime_codex_app_server.Context_window_exceeded
      {message="original Codex context refusal";tool_effect_attempted}) in
  let claude tool_effect_attempted response_emitted = Fusion_official_client.Claude_failure
    (Runtime_claude_code.Context_window_exceeded
      {message="original Claude context refusal";tool_effect_attempted;response_emitted}) in
  List.iter (fun (cause,expected) ->
    let failure=Keeper_lane_cli_oneshot.Execution_failed {runtime_id;cause} in
    let json=Shared.cli_observation failure |> Shared.cli_observation_to_yojson in
    let decoded=match Shared.cli_observation_of_yojson json with
      | Ok decoded -> decoded | Error detail -> Alcotest.fail detail in
    let evidence=Shared.of_cli_observation decoded in
    Alcotest.(check bool) "restored native flags decide admission" expected
      (Shared.refuses_input_capacity evidence);
    Alcotest.(check bool) "unsafe native context cannot permit a smaller range" (not expected)
      evidence.size_independent_execution_failure;
    Alcotest.(check bool) "unsettled native execution is rederived from the retained flags" (not expected)
      evidence.unsettled_native_execution;
    List.iter (fun combined ->
      Alcotest.(check bool) "native veto survives another slot's named capacity in either order"
        (not expected) combined.Shared.unsettled_native_execution)
      [Shared.combine evidence Shared.input_capacity_refusal;
       Shared.combine Shared.input_capacity_refusal evidence];
    Alcotest.(check bool) "context refusal is not a measured character limit" false
      (Shared.shows_range_size evidence);
    Alcotest.(check bool) "original typed context flags and reason survive roundtrip" true
      (Yojson.Safe.equal json (Shared.cli_observation_to_yojson decoded));
    let without_flags = match json with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
          if key="cause" then key,(match value with
            | `List [tag;`Assoc flags] -> `List [tag;`Assoc
                (List.filter (fun (name,_) -> name<>"tool_effect_attempted") flags)]
            | _ -> Alcotest.fail "context flags missing from original source proof")
          else key,value) fields)
      | _ -> Alcotest.fail "missing original native observation" in
    Alcotest.(check bool) "missing safety evidence refuses instead of granting admission" true
      (Result.is_error (Shared.cli_observation_of_yojson without_flags)))
    [codex false,true;codex true,false;
     claude false false,true;claude false true,false;
     claude true false,false;claude true true,false]

(* RFC-exact-lane-waits-for-a-stated-reset: a held CLI slot is kept in a
   receipt as its own cause. The store writes a whole second as an integer
   (Lane_addon_action.canonical), and Claude Code states its resets in whole
   seconds, so the reader takes that form back. The slot was not called, so it
   reads as undispatched and carries the held evidence alone. *)
let test_held_cli_observation_round_trips () =
  let module Shared = Keeper_exact_walk_failure in
  let runtime_id = Fixture.cli_primary_runtime in
  let observation until =
    Shared.cli_observation (Keeper_lane_cli_oneshot.Held {runtime_id; until})
    |> Shared.cli_observation_to_yojson in
  List.iter (fun until ->
    let json = observation until in
    let stored = match Lane_addon_action.canonical json with
      | Ok stored -> stored | Error detail -> Alcotest.fail detail in
    let decoded = match Shared.cli_observation_of_yojson stored with
      | Ok decoded -> decoded | Error detail -> Alcotest.fail detail in
    Alcotest.(check bool) "a held slot was not dispatched" false (Shared.cli_was_dispatched decoded);
    Alcotest.(check bool) "a held slot carries the held evidence alone" true
      (Shared.of_cli_observation decoded = Shared.held);
    Alcotest.(check bool) "the stored form reads back as what was written" true
      (Yojson.Safe.equal json (Shared.cli_observation_to_yojson decoded)))
    [1_794_268_800.0; 1_794_268_800.125];
  List.iter (fun until ->
    Alcotest.(check bool) "a held time that cannot be a stated reset is refused" true
      (Result.is_error (Shared.cli_observation_of_yojson (observation until))))
    [0.0; -1.0; Float.nan; Float.infinity]

let test_size_verdict_table () =
  let module E = Agent_core.Exact_output in
  (* The verdict reads the refusal and never the status it arrived with. *)
  let any_status = 400 in
  let refused refusal = E.Provider_response_refused { http_status = any_status; refusal; retry_after_s = None } in
  let module Http = Agent_core.Llm_provider.Http_client in
  let module Types = Agent_core.Llm_provider.Types in
  let sent error = E.Completion_failed { error; dispatch = E.Generation_dispatch_started } in
  let unsent error = E.Completion_failed { error; dispatch = E.No_generation_dispatch } in
  let failed kind = sent (Http.ProviderFailure { kind; message = "" }) in
  let network kind = sent (Http.NetworkError { message = ""; kind }) in
  let timed_out phase = sent (Http.TimeoutError { message = ""; phase }) in
  let empty stop_reason = failed (Http.Empty_completion { stop_reason }) in
  List.iter
    (fun (name, cause, expected) ->
       Alcotest.(check bool) name expected (Runtime.For_testing.cause_shows_size cause))
    [ "context overflow", refused E.Context_overflow, true
    ; "input capacity", refused E.Input_capacity, true
    ; "request body refused", refused E.Request_body_refused, true
    ; "timeout", refused E.Timeout, true
    ; "invalid request, reason unknown", refused E.Invalid_request, true
    ; "refusal body not received", refused E.Refusal_body_not_received, true
    ; "rate limited", refused E.Rate_limited, false
    ; "overloaded", refused E.Overloaded, false
    ; "server error", refused E.Server_error, false
    ; "network error", refused E.Network_error, false
    ; "connection not opened", refused E.Connect_failed, false
    ; "authentication failed", refused E.Auth_failed, false
    ; "authorization refused", refused E.Authorization_refused, false
    ; "payment required", refused E.Payment_required, false
    ; "model not found", refused E.Not_found, false
    (* A provider error that is not an HTTP refusal, read by its typed kind
       (#37899). On 2026-09-22 msx-retro-mania's walk narrowed from 130 to 16
       atoms on quota and empty-response failures while its keeper's request
       kept growing. *)
    ; "completion failed, context overflow", failed (Http.Context_overflow { limit = None }), true
    ; ( "completion failed, response too large"
      , failed (Http.Response_body_too_large { limit_bytes = 1 })
      , true )
    ; "completion failed, empty at the context window", empty Types.ContextWindowExceeded, true
    ; "completion failed, empty at the output budget", empty Types.MaxTokens, true
    ; "completion failed, empty at end of turn", empty Types.EndTurn, false
    ; "completion failed, empty for a reason not named", empty (Types.Unknown "x"), false
    ; "completion failed, hard quota", failed (Http.Hard_quota { retry_after = None }), false
    ; ( "completion failed, capacity exhausted"
      , failed
          (Http.Capacity_exhausted
             { scope = Http.Failure_scope_account; retry_after = None; model = None })
      , false )
    ; ( "completion failed, unclassified provider failure"
      , failed (Http.Unknown_provider_failure { reason = None })
      , false )
    ; "completion failed, dns failure", network Http.Dns_failure, false
    ; "completion failed, no route to the network or host", network Http.Unreachable, false
    ; "completion failed, connection refused", network Http.Connection_refused, false
    ; "completion failed, tls failure", network Http.Tls_error, false
    ; "completion failed, peer reset", network Http.Connection_reset, false
    ; "completion failed, peer closed", network Http.End_of_file, false
    ; "completion failed, unclassified network failure", network Http.Unknown, false
    (* Deadlines on a sent request: those on the provider's handling of the
       whole request count, those that say nothing about its size do not. *)
    ; "completion failed, sent, whole-call deadline", timed_out Http.Wall_clock, true
    ; "completion failed, sent, awaiting headers", timed_out Http.Http_operation, true
    ; "completion failed, sent, awaiting first token", timed_out Http.First_token, true
    ; ( "completion failed, sent, idle stream"
      , timed_out (Http.Stream_idle Http.Streaming_answer)
      , false )
    ; "completion failed, sent, deadline not named", timed_out Http.Unknown_timeout, false
    ; "completion failed, queued past its deadline", timed_out Http.Queue, false
    ; "completion failed, capacity backpressure", timed_out Http.Capacity_backpressure, false
    (* The transport reports a connect deadline as [Http_operation]. A request
       that was never sent was judged by no provider. *)
    ; ( "completion failed, connect deadline, not sent"
      , unsent (Http.TimeoutError { message = ""; phase = Http.Http_operation })
      , false )
    (* RFC #52028 §2.3: a connection that did not open sent nothing. *)
    ; ( "completion failed, connection not opened, not sent"
      , unsent (Http.Connect_failed { message = ""; kind = Http.Connection_refused })
      , false )
    ; ( "completion failed, context overflow, not sent"
      , unsent (Http.ProviderFailure { kind = Http.Context_overflow { limit = None }; message = "" })
      , false )
    ; ( "completion failed, provider terminal"
      , sent (Http.ProviderTerminal { kind = Http.Session_conflict; message = "" })
      , false )
    ; "completion failed, wiring rejected", sent (Http.AcceptRejected { reason = "" }), false
    ; "output limit", E.Output_limit_reached, true
    ; "window reached, no output", E.Window_reached { output = E.No_output }, true
    ; "window reached, partial output", E.Window_reached { output = E.Partial_output }, true
    ; "incomplete output", E.Incomplete_output { stop = E.End_turn }, true
    ; "missing output", E.Missing_output, true
    ; "ambiguous output", E.Ambiguous_output 2, true
    ; "unexpected output content", E.Unexpected_output_content, true
    ; "invalid json output", E.Invalid_json_output, false
    ; "response body deadline exceeded", E.Response_body_deadline_exceeded, true
    ]

(* Unclassified execution failures still cannot narrow input. Typed Codex
   character-capacity evidence is tested through the actual fallback walk. *)
let test_cli_size_verdict_table () =
  let module L = Keeper_lane_cli_oneshot in
  let runtime_id = Fixture.cli_primary_runtime in
  List.iter
    (fun (name, failure, expected) ->
       Alcotest.(check bool) name expected (Runtime.For_testing.cli_failure_shows_size failure))
    [ "an answer that is not JSON", L.Invalid_json_output { runtime_id; detail = "truncated" }, false
    ; "an answer the domain refused", L.Invalid_domain_output { runtime_id; detail = "schema" }, false
    ; "an id this module cannot run", L.Not_an_official_client { runtime_id }, false
    ; "an id this module cannot find", L.Unknown_runtime { runtime_id }, false
    ; "a client that failed without saying why",
      L.Execution_failed
        { runtime_id; cause = Fusion_official_client.Setup_failure "quota" },
      false
    ]

(* A candidate turned away before dispatch. Only a projection over the slot's
   window is about the range; the rest answer a smaller range the same way. *)
let test_disposition_size_verdict_table () =
  let module E = Agent_core.Exact_output in
  let over_the_window : E.candidate_rejection_disposition =
    E.Input_capacity
      (E.Token_measurement_required { accepted_through_tokens = 1; rejected_from_tokens = Some 2 })
  in
  List.iter
    (fun (name, (disposition : E.candidate_rejection_disposition), expected) ->
       Alcotest.(check bool) name expected
         (Runtime.For_testing.disposition_shows_size disposition))
    [ "a projection over the slot's window", over_the_window, true
    ; "a slot that is unavailable", E.Runtime_slot_unavailable, false
    ; "a runtime contract that refused", E.Runtime_contract_rejected, false
    ; "an input contract that refused", E.Input_contract_rejected, false
    ; "an output requirement that refused", E.Output_requirement_rejected, false
    ; "a request that could not be prepared", E.Request_preparation_failed, false
    ]

let () =
  let base_path = Filename.temp_dir "librarian-capacity-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let registry = Runs.create ~path:(Filename.concat base_path Runs.storage_filename) () in
  (match Runs.install_global registry with
   | Ok () -> () | Error Runs.Already_installed -> Alcotest.fail "registry already installed");
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Prompt_defaults.init ();
  let case ?same_failure name first_overflow status expected shows_size =
    Alcotest.test_case name `Quick
      (test_callback ~shows_size ?same_failure ~base_path ~registry ~keeper_id:name ~first_overflow ~status
         ~expected) in
  let codex_error data = Fusion_official_client.Codex_failure
    (Runtime_codex_app_server.Rpc_error
      { method_ = "turn/start"; code = Some (-32602);
        message = "Input exceeds the maximum length of 1048576 characters.";
        data }) in
  let capacity = codex_error (Some (`Assoc [
    "input_error_code", `String "input_too_large";
    "actual_chars", `Int 23; "max_chars", `Int 17])) in
  let larger_capacity = codex_error (Some (`Assoc [
    "input_error_code", `String "input_too_large";
    "actual_chars", `Int 23; "max_chars", `Int 21])) in
  let generic = codex_error None in
  let quota = Fusion_official_client.Setup_failure "quota" in
  let cli_case ?(first_overflow = false) ?expected_limit name cli_errors expected shows_size =
    Alcotest.test_case name `Quick (fun () ->
      Fixture.with_official_client_runtimes @@ fun () ->
      test_callback ~cli_errors ?expected_limit ~shows_size ~base_path ~registry ~keeper_id:name
        ~first_overflow ~status:`Too_many_requests ~expected ()) in
  Alcotest.run "Librarian capacity callbacks"
    ["size verdict", [Alcotest.test_case "named input refusal is separate from descent evidence" `Quick
       test_named_provider_input_refusals;
       Alcotest.test_case "original native context flags remain admission authority" `Quick
         test_native_context_receipt_flags;
       Alcotest.test_case "a held CLI observation survives the stored form" `Quick
         test_held_cli_observation_round_trips;
       Alcotest.test_case "every provider cause, one row each" `Quick
       test_size_verdict_table;
       Alcotest.test_case "every official-client failure, one row each" `Quick
         test_cli_size_verdict_table;
       Alcotest.test_case "every pre-dispatch rejection, one row each" `Quick
         test_disposition_size_verdict_table];
     "actual HTTP outcomes", [
      (* An API slot states its limit in provider prose, which this process
         cannot read back into a number, so it reports none. The pass does
         not need one: a size refusal is evidence enough to read less. *)
      (* A body a provider refused for its size says so whether it came
         first or last; a quota or an authorization refusal never does. The
         four together are the order matrix: a verdict taken from the walk's
         last cause alone would answer rows two and three differently. *)
      (* The second verdict is what the admission worker reads before it
         splits: size with a quota or an operator refusal in the same walk is
         deferred whole, so the refusing provider is not asked once per part. *)
      case ~same_failure:false "capacity-final" false `Request_entity_too_large 0 true;
      case ~same_failure:true "quota-final" false `Too_many_requests 0 false;
      case ~same_failure:true "capacity-then-quota" true `Too_many_requests 0 true;
      case ~same_failure:true "capacity-then-auth" true `Unauthorized 0 true;
      case ~same_failure:false "capacity-then-capacity" true `Request_entity_too_large 0 true;
      (* An empty answer that ended its turn says nothing about size: a
         smaller range meets the same provider (#37899). *)
      case "empty-completion-final" false `OK 0 false];
    "HTTP to CLI outcomes", [
      (* Typed capacity survives later quota failures in either walk order. *)
      cli_case "quota-then-cli-capacity" [Fixture.cli_primary_runtime, capacity] 1 true;
      cli_case "quota-then-cli-generic-rpc" [Fixture.cli_primary_runtime, generic] 0 false;
      cli_case ~expected_limit:(Fixture.cli_primary_runtime, 17) "cli-capacity-then-quota"
        [Fixture.cli_primary_runtime, capacity; Fixture.cli_secondary_runtime, quota] 1 true;
      cli_case ~expected_limit:(Fixture.cli_primary_runtime, 17) "cli-capacity-then-generic-rpc"
        [Fixture.cli_primary_runtime, capacity; Fixture.cli_secondary_runtime, generic] 1 true;
      cli_case ~expected_limit:(Fixture.cli_secondary_runtime, 17) "cli-quota-then-capacity"
        [Fixture.cli_primary_runtime, quota; Fixture.cli_secondary_runtime, capacity] 1 true;
      cli_case ~expected_limit:(Fixture.cli_secondary_runtime, 21) "cli-two-capacities"
        [Fixture.cli_primary_runtime, capacity; Fixture.cli_secondary_runtime, larger_capacity] 1 true;
      cli_case ~expected_limit:(Fixture.cli_primary_runtime, 21) "cli-two-capacities-reversed"
        [Fixture.cli_primary_runtime, larger_capacity; Fixture.cli_secondary_runtime, capacity] 1 true;
      cli_case ~expected_limit:(Fixture.cli_primary_runtime, 17) "cli-equal-capacities-keep-first"
        [Fixture.cli_primary_runtime, capacity; Fixture.cli_secondary_runtime, capacity] 1 true;
      cli_case ~expected_limit:(Fixture.cli_secondary_runtime, 17) "cli-equal-capacities-reversed"
        [Fixture.cli_secondary_runtime, capacity; Fixture.cli_primary_runtime, capacity] 1 true;
      (* The API walk that sent the pass to the official client met a size
         refusal. The client's own failure says nothing, and the verdict
         still comes from the walk before it. *)
      cli_case ~first_overflow:true "capacity-then-quota-then-cli-generic-rpc"
        [Fixture.cli_primary_runtime, generic] 0 true]]
