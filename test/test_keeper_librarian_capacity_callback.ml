open Masc
module Runtime = Keeper_librarian_runtime
module Fixture = Exact_output_fixture
module Runs = Exact_lane_run_registry

let test_callback ?(cli_errors = []) ?expected_limit ~base_path ~registry ~keeper_id ~first_overflow ~status ~expected () =
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
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Runtime.run_best_effort ~cli_runner
    ~on_cli_input_limit:(fun limit ->
      incr refused;
      observed_limit := Some (limit.Keeper_lane_cli_oneshot.runtime_id, limit.capacity.max_chars))
    ~on_context_committed:(fun _ -> committed := true)
    ~base_path ~keepers_dir ~keeper_id input;
  Alcotest.(check int) "only a CLI slot reports an input limit" expected !refused;
  Option.iter (fun expected -> Alcotest.(check (option (pair string int)))
    "limit retains the actual refusing runtime" (Some expected) !observed_limit) expected_limit;
  Alcotest.(check (list string)) "CLI candidates ran in order"
    (List.map fst cli_errors) !cli_calls;
  Alcotest.(check int) "terminal provider really received the request" 1 !posts;
  Option.iter (fun (_, count) -> Alcotest.(check int)
    "body-refused first provider really ran" 1 !count) first;
  Alcotest.(check bool) "refused request never commits Memory" false !committed;
  let runs = Runs.list_runs registry |> List.filter
    (fun (run : Runs.run) -> String.equal run.actor keeper_id) in
  match runs with
  | [run] -> Alcotest.(check string) "terminal failure remains observable" "failed"
      (Runs.status_label run.status)
  | _ -> Alcotest.fail "expected one recorded Librarian run"

let test_named_provider_input_refusals () =
  let module E = Agent_core.Exact_output in
  let module I = Keeper_exact_input_refusal in
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
      {message="original Codex context refusal";tool_effect_attempted;response_emitted=false}) in
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

let () =
  let base_path = Filename.temp_dir "librarian-capacity-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let registry = Runs.create ~path:(Filename.concat base_path Runs.storage_filename) () in
  (match Runs.install_global registry with
   | Ok () -> () | Error Runs.Already_installed -> Alcotest.fail "registry already installed");
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Prompt_defaults.init ();
  let case name first_overflow status expected =
    Alcotest.test_case name `Quick
      (test_callback ~base_path ~registry ~keeper_id:name ~first_overflow ~status ~expected) in
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
  let cli_case ?(first_overflow = false) ?expected_limit name cli_errors expected =
    Alcotest.test_case name `Quick (fun () ->
      Fixture.with_official_client_runtimes @@ fun () ->
      test_callback ~cli_errors ?expected_limit ~base_path ~registry ~keeper_id:name
        ~first_overflow ~status:`Too_many_requests ~expected ()) in
  Alcotest.run "Librarian capacity callbacks"
    ["size verdict", [Alcotest.test_case "named input refusal is separate from descent evidence" `Quick
       test_named_provider_input_refusals;
       Alcotest.test_case "original native context flags remain admission authority" `Quick
         test_native_context_receipt_flags;
       Alcotest.test_case "a held CLI observation survives the stored form" `Quick
         test_held_cli_observation_round_trips];
     "actual HTTP outcomes", [
      (* An API slot states its limit in provider prose, which this process
         cannot read back into a number, so it reports none. *)
      case "capacity-final" false `Request_entity_too_large 0;
      case "quota-final" false `Too_many_requests 0;
      case "capacity-then-quota" true `Too_many_requests 0;
      case "capacity-then-auth" true `Unauthorized 0;
      case "capacity-then-capacity" true `Request_entity_too_large 0;
      case "empty-completion-final" false `OK 0];
    "HTTP to CLI outcomes", [
      (* Typed capacity survives later quota failures in either walk order. *)
      cli_case "quota-then-cli-capacity" [Fixture.cli_primary_runtime, capacity] 1;
      cli_case "quota-then-cli-generic-rpc" [Fixture.cli_primary_runtime, generic] 0;
      cli_case ~expected_limit:(Fixture.cli_primary_runtime, 17) "cli-capacity-then-quota"
        [Fixture.cli_primary_runtime, capacity; Fixture.cli_secondary_runtime, quota] 1;
      cli_case ~expected_limit:(Fixture.cli_primary_runtime, 17) "cli-capacity-then-generic-rpc"
        [Fixture.cli_primary_runtime, capacity; Fixture.cli_secondary_runtime, generic] 1;
      cli_case ~expected_limit:(Fixture.cli_secondary_runtime, 17) "cli-quota-then-capacity"
        [Fixture.cli_primary_runtime, quota; Fixture.cli_secondary_runtime, capacity] 1;
      cli_case ~expected_limit:(Fixture.cli_secondary_runtime, 21) "cli-two-capacities"
        [Fixture.cli_primary_runtime, capacity; Fixture.cli_secondary_runtime, larger_capacity] 1;
      cli_case ~expected_limit:(Fixture.cli_primary_runtime, 21) "cli-two-capacities-reversed"
        [Fixture.cli_primary_runtime, larger_capacity; Fixture.cli_secondary_runtime, capacity] 1;
      cli_case ~expected_limit:(Fixture.cli_primary_runtime, 17) "cli-equal-capacities-keep-first"
        [Fixture.cli_primary_runtime, capacity; Fixture.cli_secondary_runtime, capacity] 1;
      cli_case ~expected_limit:(Fixture.cli_secondary_runtime, 17) "cli-equal-capacities-reversed"
        [Fixture.cli_secondary_runtime, capacity; Fixture.cli_primary_runtime, capacity] 1;
      (* The API walk that sent the pass to the official client met a size
         refusal. The client's own failure names no limit. *)
      cli_case ~first_overflow:true "capacity-then-quota-then-cli-generic-rpc"
        [Fixture.cli_primary_runtime, generic] 0]]
