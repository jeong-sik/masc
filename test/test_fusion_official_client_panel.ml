open Alcotest

(* The panel split in Fusion_panel keys entirely on [is_official_client]: a true
   sends the panelist to the spawn path, a false sends it to build_agent. Before
   this existed, official-client panelists reached build_agent, failed provider
   resolution, and never answered — a panel made only of them ended in
   Panels_unavailable, and a mixed panel completed on quorum with those seats
   silently empty.

   Pinning the predicate alone would not notice the split being dropped from
   fusion_panel.ml, so the last test drives Fusion_panel.run for real and judges
   by whether the client process was spawned, not by what the error said.

   The repo seed has its claude_code provider commented out, so the fixture
   declares its own rather than asserting against a config that happens not to
   have one today. *)

let fixture ~claude_cli =
  Printf.sprintf
    {|
[runtime]
default = "stub-http.stub-model"

[providers.stub-http]
display-name = "Stub HTTP"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[providers.claude_code]
display-name = "Claude Code Max Subscription"
protocol = "claude-code"
command = "%s"
is-non-interactive = true

[models.stub-model]
api-name = "gpt-5.4"
max-context = 200000
tools-support = true
streaming = true

[stub-http.stub-model]

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude_code."claude-sonnet-5"]

[models."claude-opus-5"]
api-name = "claude-opus-5"
max-context = 1000000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude_code."claude-opus-5"]

[runtime.lanes.fusion-judge]
candidates = ["claude_code.claude-opus-5", "claude_code.claude-sonnet-5"]
|}
    claude_cli
;;

(* The judge prompt is rendered from the registry, so resolution must point at
   the repo's own prompt files or the render raises inside the dune sandbox. *)
let () =
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  Masc.Prompt_defaults.init ()
;;

let official_client_runtime = "claude_code.claude-sonnet-5"
let agent_core_runtime = "stub-http.stub-model"
let judge_lane = "fusion-judge"
let judge_lane_first = "claude_code.claude-opus-5"

let write_file ~path ~perm contents =
  let channel = open_out_gen [ Open_creat; Open_trunc; Open_wronly ] perm path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)
;;

(* A stand-in for the Claude Code CLI that records the fact of its own execution
   and nothing else. The marker path is baked into the script because the claude
   adapter runs the client under a restricted environment allowlist, so a value
   passed through the environment would not survive to the child. *)
let stub_cli_script ~marker = Printf.sprintf "#!/bin/sh\n: > '%s'\nexit 0\n" marker

let with_initialized_runtime ~claude_cli f =
  let path = Filename.temp_file "fusion-official-client" ".toml" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       write_file ~path ~perm:0o600 (fixture ~claude_cli);
       match Runtime.init_default ~config_path:path with
       | Error detail -> failf "fixture runtime must initialize: %s" detail
       | Ok () -> f ())
;;

(* /usr/bin/true is enough for the tests that only read the runtime table: they
   classify a runtime without executing it. *)
let with_classification_runtime f = with_initialized_runtime ~claude_cli:"/usr/bin/true" f

let test_official_client_runtime_is_routed_to_the_spawn_path () =
  with_classification_runtime (fun () ->
    check
      bool
      "a claude-code binding is an official-client panelist"
      true
      (Masc.Fusion_official_client.is_official_client ~runtime_id:official_client_runtime))
;;

let test_agent_core_runtime_stays_on_the_async_agent_path () =
  with_classification_runtime (fun () ->
    check
      bool
      "an HTTP binding is not an official-client panelist"
      false
      (Masc.Fusion_official_client.is_official_client ~runtime_id:agent_core_runtime))
;;

(* An unknown id must not be claimed by this path. The Agent_core path already
   reports it precisely ("no provider config"); routing it here would replace
   that message with a spawn-side one that names the wrong subsystem. *)
let test_unknown_runtime_is_not_claimed_by_the_spawn_path () =
  with_classification_runtime (fun () ->
    check
      bool
      "an unconfigured id is left to the Agent_core path to report"
      false
      (Masc.Fusion_official_client.is_official_client ~runtime_id:"nope.not-configured"))
;;

let test_official_client_panel_honors_no_deadline () =
  with_classification_runtime (fun () ->
    check bool "turn-timeout-s = 0 removes the panel turn deadline" true
      (Option.is_none
         (Masc.Fusion_official_client.For_testing.resolved_timeout_s
            ~runtime_id:official_client_runtime
            ~override_s:None
            ~default_timeout_s:300.0)))
;;

let test_unbounded_claude_panel_keeps_login_probe_bounded () =
  let turn_config =
    { (Runtime_claude_code.default_config ~cwd:"/tmp") with timeout_s = None }
  in
  let probe_config =
    Masc.Fusion_official_client.For_testing.bounded_claude_probe_config
      ~fallback_timeout_s:17.0
      turn_config
  in
  match probe_config.timeout_s with
  | Some seconds -> check (float 0.0) "probe fallback" 17.0 seconds
  | None -> fail "unbounded panel turn leaked into the Claude login probe"
;;

let panel_group models : Fusion_policy.panel_group =
  { models
  ; label = ""
  ; system_prompt = "Answer in one word."
  ; web_tools = false
  ; max_output_tokens = None
        ; timeout_s = None
  }
;;

(* Judged by the marker, not by the error text. The stub CLI emits no result
   event, so this panelist fails either way — what separates "routed to the
   spawn path" from "routed to build_agent" is whether the client ran at all.
   Delete the official branch in fusion_panel.ml and the marker stops
   appearing. *)
let test_official_client_panelist_reaches_its_client () =
  let base_dir = Filename.temp_dir "fusion-official-client-run" "" in
  let marker = Filename.concat base_dir "spawned" in
  let claude_cli = Filename.concat base_dir "stub-claude" in
  let observed_trace = ref None in
  write_file ~path:claude_cli ~perm:0o700 (stub_cli_script ~marker);
  with_initialized_runtime ~claude_cli (fun () ->
    let outcomes =
      Eio_main.run (fun env ->
        Eio_context.set_env env;
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~mono_clock:(Eio.Stdenv.mono_clock env)
            ~sw
            (fun () ->
               Masc.Fusion_panel.run
                 ~base_dir
                 ~sw
                 ~net:(Eio.Stdenv.net env)
                 ~groups:[ panel_group [ official_client_runtime ] ]
                 ~prompt:"ping"
                 ~on_tool_trace:(fun trace -> observed_trace := Some trace)
                 ())))
    in
    check bool "the official client was executed" true (Sys.file_exists marker);
    (* One declared panelist stays one reported outcome. A panelist dropped
       rather than run is the failure mode that survives a quorum. *)
    check int "the panelist is accounted for in the outcomes" 1 (List.length outcomes);
    match !observed_trace with
    | Some
        { Fusion_types.observed_actors = []
        ; events = []
        ; dropped_events = 0
        ; gaps =
            [ { actor = Fusion_types.Panel_actor actor
              ; reason = Fusion_types.Official_client_uninstrumented
              }
            ]
        } ->
      check string "official-client trace gap names the actor"
        official_client_runtime actor
    | Some _ -> fail "official-client execution must publish one explicit trace gap"
    | None -> fail "official-client execution did not publish Tool trace coverage")
;;

(* A judge seat is routed by the same predicate as a panel seat. Judged by the
   marker, as above: the stub emits no result event, so the judge fails either
   way, and what separates the two routes is whether the client ran at all.
   Remove the official branch from fusion_judge.ml and the marker stops
   appearing while the failure turns into [Build_error]. *)
let test_official_client_judge_reaches_its_client () =
  let base_dir = Filename.temp_dir "fusion-official-client-judge" "" in
  let marker = Filename.concat base_dir "spawned" in
  let claude_cli = Filename.concat base_dir "stub-claude" in
  let observed_trace = ref None in
  let actor =
    Fusion_types.Judge_actor
      { role = Fusion_types.Single; identity = official_client_runtime }
  in
  write_file ~path:claude_cli ~perm:0o700 (stub_cli_script ~marker);
  with_initialized_runtime ~claude_cli (fun () ->
    let result =
      Eio_main.run (fun env ->
        Eio_context.set_env env;
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~mono_clock:(Eio.Stdenv.mono_clock env)
            ~sw
            (fun () ->
               Masc.Fusion_judge.run
                 ~base_dir
                 ~sw
                 ~net:(Eio.Stdenv.net env)
                 ~judge_system_prompt:"Judge the panel."
                 ~judge_model:official_client_runtime
                 ~question:"ping"
                 ~panel:
                   [ Fusion_types.Answered
                       { model = agent_core_runtime
                       ; answer = "pong"
                       ; usage = Fusion_types.zero_usage
                       }
                   ]
                 ~web_tools:false
                 ~tool_trace:(actor, fun trace -> observed_trace := Some trace)
                 ())))
    in
    check bool "the official client was executed" true (Sys.file_exists marker);
    (match result with
     | Ok _ -> fail "the stub client emits no result, so no synthesis can come back"
     | Error (Fusion_types.Build_error detail, _) ->
       failf "an official-client judge must not reach build_agent: %s" detail
     | Error (_, usage) ->
       check bool "an official client reports no token usage" true
         (Fusion_types.equal_usage usage Fusion_types.zero_usage));
    match !observed_trace with
    | Some
        { Fusion_types.observed_actors = []
        ; events = []
        ; dropped_events = 0
        ; gaps = [ { actor = gap_actor; reason = Fusion_types.Official_client_uninstrumented } ]
        } ->
      check bool "the trace gap names the judge actor" true
        (Fusion_types.equal_tool_trace_actor actor gap_actor)
    | Some _ -> fail "an official-client judge must publish one explicit trace gap"
    | None -> fail "an official-client judge did not publish Tool trace coverage")
;;

(* Each client's own timeout reaches Fusion as [Timeout], and every other
   client failure stays [Provider_error]. The detail line keeps what the
   projection folds away. *)
let test_client_timeouts_project_to_timeout () =
  let project failure =
    Masc.Fusion_official_client.panel_failure ~runtime_id:official_client_runtime failure
  in
  let is_timeout failure =
    Fusion_types.equal_panel_failure (project failure) Fusion_types.Timeout
  in
  check bool "Claude turn timeout" true
    (is_timeout (Masc.Fusion_official_client.Claude_failure (Runtime_claude_code.Timeout 3.0)));
  check bool "Claude admission timeout" true
    (is_timeout
       (Masc.Fusion_official_client.Claude_admission_failure (Runtime_claude_code.Timeout 3.0)));
  check bool "Codex timeout" true
    (is_timeout
       (Masc.Fusion_official_client.Codex_failure
          (Runtime_codex_app_server.Timeout { seconds = 3.0; turn_accepted = false })));
  check bool "Antigravity timeout" true
    (is_timeout
       (Masc.Fusion_official_client.Antigravity_failure (Runtime_antigravity.Timeout 3.0)));
  let turn_failed =
    Masc.Fusion_official_client.Claude_failure (Runtime_claude_code.Turn_failed "boom")
  in
  (match project turn_failed with
   | Fusion_types.Provider_error _ -> ()
   | other ->
     failf "a non-timeout client failure must stay Provider_error, got %s"
       (Fusion_types.show_panel_failure other));
  let detail =
    Masc.Fusion_official_client.failure_detail ~runtime_id:official_client_runtime
      (Masc.Fusion_official_client.Claude_failure (Runtime_claude_code.Timeout 3.0))
  in
  check bool "the detail line names the runtime" true
    (String.starts_with ~prefix:(official_client_runtime ^ ": ") detail);
  check bool "the detail line keeps more than the projection" true
    (not (String.equal detail (official_client_runtime ^ ": timeout")))
;;

(* A stand-in that appends one line per execution, so a test can count how
   many times the client ran across several candidates. *)
let appending_cli_script ~log = Printf.sprintf "#!/bin/sh\necho spawned >> '%s'\nexit 0\n" log

let count_lines path =
  if not (Sys.file_exists path)
  then 0
  else (
    let channel = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () ->
         let rec count n =
           match input_line channel with
           | _ -> count (n + 1)
           | exception End_of_file -> n
         in
         count 0))
;;

let with_eio f =
  Eio_main.run (fun env ->
    Eio_context.set_env env;
    Eio.Switch.run (fun sw ->
      Eio_context.with_test_env
        ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~sw
        (fun () -> f ~sw ~net:(Eio.Stdenv.net env))))
;;

let sample_panel =
  [ Fusion_types.Answered
      { model = agent_core_runtime; answer = "pong"; usage = Fusion_types.zero_usage }
  ]
;;

let run_single_judge ~base_dir ~route ~on_route =
  with_eio (fun ~sw ~net ->
    Masc.Fusion_judge.run
      ~base_dir
      ~sw
      ~net
      ~judge_system_prompt:"Judge the panel."
      ~judge_model:route
      ~question:"ping"
      ~panel:sample_panel
      ~web_tools:false
      ~seat_route:(Fusion_types.Single, on_route)
      ())
;;

(* A judge seat naming a lane tries every candidate, in the lane's order, when
   each one fails. The spawn count is compared with a baseline measured on a
   one-candidate seat in the same test rather than with an assumed number of
   processes per candidate. *)
let test_judge_lane_walks_candidates_in_order () =
  let base_dir = Filename.temp_dir "fusion-judge-lane" "" in
  let log = Filename.concat base_dir "spawns" in
  let claude_cli = Filename.concat base_dir "stub-claude" in
  write_file ~path:claude_cli ~perm:0o700 (appending_cli_script ~log);
  with_initialized_runtime ~claude_cli (fun () ->
    let _baseline = run_single_judge ~base_dir ~route:official_client_runtime ~on_route:ignore in
    let per_candidate = count_lines log in
    check bool "a one-candidate seat runs its client" true (per_candidate > 0);
    let recorded = ref None in
    let result =
      run_single_judge ~base_dir ~route:judge_lane ~on_route:(fun route -> recorded := Some route)
    in
    check int "both lane candidates ran their client" (3 * per_candidate) (count_lines log);
    (match result with
     | Ok _ -> fail "the stub clients emit no result, so no synthesis can come back"
     | Error _ -> ());
    match !recorded with
    | Some
        { Fusion_types.seat = Fusion_types.Judge_seat Fusion_types.Single
        ; route
        ; answered_by = None
        ; failed_attempts
        } ->
      check string "the seat route is the lane name" judge_lane route;
      check
        (list string)
        "candidates are tried in lane order"
        [ judge_lane_first; official_client_runtime ]
        (List.map
           (fun (attempt : Fusion_types.seat_attempt) -> attempt.attempt_runtime)
           failed_attempts)
    | Some other -> failf "unexpected seat route %s" (Fusion_types.show_seat_route other)
    | None -> fail "the judge seat did not report its route")
;;

(* A route that names neither a lane nor a runtime fails the seat without an
   attempt, and says so in the typed reason rather than as a build error. *)
let test_unknown_route_fails_without_an_attempt () =
  with_classification_runtime (fun () ->
    let routes = ref [] in
    let outcomes =
      with_eio (fun ~sw ~net ->
        Masc.Fusion_panel.run
          ~base_dir:(Filename.get_temp_dir_name ())
          ~sw
          ~net
          ~groups:[ panel_group [ "nope.not-configured" ] ]
          ~prompt:"ping"
          ~on_seat_routes:(fun seat_routes -> routes := seat_routes)
          ())
    in
    (match outcomes with
     | [ Fusion_types.Failed { reason = Fusion_types.Unknown_route "nope.not-configured"; _ } ]
       -> ()
     | other ->
       failf "expected one Unknown_route failure, got [%s]"
         (String.concat "; " (List.map Fusion_types.show_panel_outcome other)));
    match !routes with
    | [ { Fusion_types.route = "nope.not-configured"; answered_by = None; failed_attempts = []; _ } ]
      -> ()
    | other ->
      failf "expected one unattempted seat route, got [%s]"
        (String.concat "; " (List.map Fusion_types.show_seat_route other)))
;;

(* The walk stops at the first answer and never calls a later candidate. *)
let test_walk_stops_at_the_first_answer () =
  let tried = ref [] in
  let attempt runtime =
    tried := runtime :: !tried;
    if String.equal runtime "b" then Ok "answer" else Error ("failed " ^ runtime)
  in
  (match Masc.Fusion_seat.walk { Masc.Fusion_seat.first = "a"; rest = [ "b"; "c" ] } ~attempt with
   | Masc.Fusion_seat.Answered { answer; runtime; failed } ->
     check string "the answer is the answering candidate's" "answer" answer;
     check string "the answering candidate is named" "b" runtime;
     check (list (pair string string)) "earlier failures are kept" [ "a", "failed a" ] failed
   | Masc.Fusion_seat.Exhausted _ -> fail "candidate b answers");
  check (list string) "a later candidate is never tried" [ "a"; "b" ] (List.rev !tried);
  match
    Masc.Fusion_seat.walk
      { Masc.Fusion_seat.first = "a"; rest = [ "b" ] }
      ~attempt:(fun runtime -> Error runtime)
  with
  | Masc.Fusion_seat.Exhausted { last; failed } ->
    check string "the last failure is the last candidate's" "b" last;
    check (list (pair string string)) "every attempt is kept in order" [ "a", "a"; "b", "b" ] failed
  | Masc.Fusion_seat.Answered _ -> fail "no candidate answers"
;;

(* The message has to name which handle is absent. It did not, and that cost a
   build cycle: publishing Eio_context.set_env in bin/fusion_run left the text
   identical, so the clock being the other half was invisible until the code was
   read. Each arm is asserted separately — a single "some message came back"
   check would pass with all three arms collapsed into one string. *)
let detail_for ~env ~clock =
  match
    Masc.Fusion_official_client.For_testing.missing_handle_detail
      ~env_present:env
      ~clock_present:clock
  with
  | Some detail -> detail
  | None -> "<none>"
;;

let test_both_handles_present_has_no_complaint () =
  check
    (option string)
    "a resolvable context produces no failure detail"
    None
    (Masc.Fusion_official_client.For_testing.missing_handle_detail
       ~env_present:true
       ~clock_present:true)
;;

let test_each_absent_handle_is_named () =
  let neither = detail_for ~env:false ~clock:false in
  let env_missing = detail_for ~env:false ~clock:true in
  let clock_missing = detail_for ~env:true ~clock:false in
  check bool "the three arms are distinct" true
    (neither <> env_missing && env_missing <> clock_missing && neither <> clock_missing);
  let mentions haystack needle =
    let n = String.length needle in
    let rec scan i =
      i + n <= String.length haystack
      && (String.sub haystack i n = needle || scan (i + 1))
    in
    scan 0
  in
  check bool "a missing env names env" true (mentions env_missing "env");
  check bool "a missing env does not blame the clock" false (mentions env_missing "clock");
  check bool "a missing clock names clock" true (mentions clock_missing "clock");
  check bool "both absent names both" true
    (mentions neither "env" && mentions neither "clock")
;;

let () =
  run
    "fusion official-client panel"
    [ ( "panelist routing"
      , [ test_case
            "official-client runtime is routed to the spawn path"
            `Quick
            test_official_client_runtime_is_routed_to_the_spawn_path
        ; test_case
            "Agent_core runtime stays on the Async_agent path"
            `Quick
            test_agent_core_runtime_stays_on_the_async_agent_path
        ; test_case
            "unknown runtime is not claimed by the spawn path"
            `Quick
            test_unknown_runtime_is_not_claimed_by_the_spawn_path
        ; test_case
            "official-client panel honors no deadline"
            `Quick
            test_official_client_panel_honors_no_deadline
        ; test_case
            "unbounded Claude panel keeps login probe bounded"
            `Quick
            test_unbounded_claude_panel_keeps_login_probe_bounded
        ; test_case
            "client timeouts project to Timeout"
            `Quick
            test_client_timeouts_project_to_timeout
        ] )
    ; ( "eio context diagnostics"
      , [ test_case
            "both handles present produces no complaint"
            `Quick
            test_both_handles_present_has_no_complaint
        ; test_case
            "each absent handle is named"
            `Quick
            test_each_absent_handle_is_named
        ] )
    ; ( "panel execution"
      , [ test_case
            "official-client panelist reaches its client"
            `Quick
            test_official_client_panelist_reaches_its_client
        ; test_case
            "official-client judge reaches its client"
            `Quick
            test_official_client_judge_reaches_its_client
        ] )
    ; ( "seat routes"
      , [ test_case
            "judge lane walks candidates in order"
            `Quick
            test_judge_lane_walks_candidates_in_order
        ; test_case
            "unknown route fails without an attempt"
            `Quick
            test_unknown_route_fails_without_an_attempt
        ; test_case
            "walk stops at the first answer"
            `Quick
            test_walk_stops_at_the_first_answer
        ] )
    ]
;;
