(** Reproduction test for the Memory OS accumulate -> consolidate -> recall flow.

    Before the fix, [Server_bootstrap_maintenance.run_memory_os_consolidation_tick]
    did not exist and [Keeper_memory_os_consolidation_runtime.consolidate_keeper]
    had zero production callers, so facts accumulated without consolidation and
    the recall view only grew. This test drives the new maintenance tick helper
    with a fake model and asserts the end-to-end flow works. *)

module Types = Masc.Keeper_memory_os_types
module Io = Masc.Keeper_memory_os_io
module Recall = Masc.Keeper_memory_os_recall
module Atypes = Agent_sdk.Types

let now = 1_000_000.0
let unconfigured_runtime_id = "test.unconfigured"

let fact claim =
  { Types.claim
  ; category = Types.Fact
  ; claim_kind = None
  ; source = { Types.trace_id = "t"; turn = 1; tool_call_id = None }
  ; observed_by = []
  ; first_seen = now
  ; valid_until = None
  ; last_verified_at = Some now
  ; schema_version = Types.schema_version
  ; claim_id = None
  }
;;

let fake_response canned =
  { Llm_provider.Types.id = "fake"
  ; model = "fake"
  ; stop_reason = Llm_provider.Types.EndTurn
  ; content = [ Atypes.Text canned ]
  ; usage = None
  ; telemetry = None
  }
;;

let fake_complete canned : Masc.Keeper_memory_os_consolidation_runtime.complete_fn =
  fun ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ () -> Ok (fake_response canned)
;;

let provider_cfg () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Anthropic
    ~model_id:"fake"
    ~base_url:"http://localhost"
    ()
;;

let with_runtime_config content f =
  let path = Filename.temp_file "memory-os-consolidation-runtime-" ".toml" in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
      Out_channel.with_open_text path (fun channel ->
        Out_channel.output_string channel content);
      match Runtime.init_default ~config_path:path with
      | Error msg -> Alcotest.failf "runtime config should load: %s" msg
      | Ok () -> f ())
;;

let with_temp_keepers f =
  let marker = Filename.temp_file "consolidation-tick-" ".tmp" in
  Sys.remove marker;
  Io.For_testing.with_keepers_dir marker f
;;

let with_prompts f =
  let root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some r -> r
    | None -> "."
  in
  Fun.protect
    ~finally:Prompt_registry.clear
    (fun () ->
       Prompt_registry.clear ();
       Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
       Masc.Prompt_defaults.init ();
       f ())
;;

let test_accumulate_consolidate_recall () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
        with_temp_keepers (fun () ->
          let keeper_id = "keeper-1" in
          (* 1. Accumulate: append five redundant facts. *)
          List.iter
            (Io.append_fact ~keeper_id)
            [ fact "deploy uses blue-green"
            ; fact "deployment is blue-green based"
            ; fact "build runs on dune 3.x"
            ; fact "tests live under test/"
            ; fact "ci runs on github actions"
            ];
          let before_count = List.length (Io.read_facts_all ~keeper_id) in
          Alcotest.(check int) "accumulated facts" 5 before_count;
          (* 2. Consolidate: the model merges the first two claims. *)
          let plan =
            {|{"groups":[{"member_indices":[0,1],"consolidated_claim":"deploys via blue-green","category":"fact"}],"drop_indices":[]}|}
          in
          Server_bootstrap_maintenance.run_memory_os_consolidation_tick
            ~complete:(fake_complete plan)
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~runtime_id:unconfigured_runtime_id
            ~provider_cfg:(provider_cfg ())
            ~now
            ();
          let after_facts = Io.read_facts_all ~keeper_id in
          let after_count = List.length after_facts in
          Alcotest.(check int) "consolidated store size" 4 after_count;
          let claims = after_facts |> List.map (fun f -> f.Types.claim) |> List.sort String.compare in
          Alcotest.(check (list string))
            "consolidated claims"
            [ "build runs on dune 3.x"
            ; "ci runs on github actions"
            ; "deploys via blue-green"
            ; "tests live under test/"
            ]
            claims;
          (* 3. Recall: the consolidated memory is visible. *)
          let block =
            Recall.render_context
              ~keeper_id
              ~now
              ()
          in
          Alcotest.(check int) "recall sees consolidated store" 4 (List.length (Io.read_facts_all ~keeper_id));
          Alcotest.(check bool)
            "recall block includes consolidated claim"
            true
            (String_util.contains_substring block "deploys via blue-green")))))
;;

let test_skips_when_too_few () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
        with_temp_keepers (fun () ->
          let keeper_id = "keeper-1" in
          (* A single fact is below the consolidation threshold. *)
          Io.append_fact ~keeper_id (fact "only one fact");
          let before_count = List.length (Io.read_facts_all ~keeper_id) in
          Alcotest.(check int) "single fact accumulated" 1 before_count;
          Server_bootstrap_maintenance.run_memory_os_consolidation_tick
            ~complete:(fake_complete "{\"groups\":[],\"drop_indices\":[]}")
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~runtime_id:unconfigured_runtime_id
            ~provider_cfg:(provider_cfg ())
            ~now
            ();
          let after_count = List.length (Io.read_facts_all ~keeper_id) in
          Alcotest.(check int) "store unchanged when too few facts" 1 after_count))))
;;

(* The tick must not fan out one provider call per keeper concurrently: every
   call lands on the same runtime, so an N-keeper burst floods that endpoint's
   admission FIFO and starves turn/judge/compaction traffic for the whole
   burst (#25401). The fake yields inside the provider call so any concurrent
   scheduling would be observed as in_flight > 1. *)
let test_tick_serializes_provider_calls () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
        with_temp_keepers (fun () ->
          let keeper_ids = [ "keeper-1"; "keeper-2"; "keeper-3" ] in
          List.iter
            (fun keeper_id ->
               List.iter
                 (Io.append_fact ~keeper_id)
                 [ fact "deploy uses blue-green"
                 ; fact "deployment is blue-green based"
                 ; fact "build runs on dune 3.x"
                 ; fact "tests live under test/"
                 ; fact "ci runs on github actions"
                 ])
            keeper_ids;
          let in_flight = ref 0 in
          let max_in_flight = ref 0 in
          let calls = ref 0 in
          let observing_complete :
                Masc.Keeper_memory_os_consolidation_runtime.complete_fn =
            fun ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ () ->
              incr in_flight;
              incr calls;
              if !in_flight > !max_in_flight then max_in_flight := !in_flight;
              Eio.Fiber.yield ();
              decr in_flight;
              Ok (fake_response {|{"groups":[],"drop_indices":[]}|})
          in
          Server_bootstrap_maintenance.run_memory_os_consolidation_tick
            ~complete:observing_complete
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~runtime_id:unconfigured_runtime_id
            ~provider_cfg:(provider_cfg ())
            ~now
            ();
          Alcotest.(check int) "every keeper consolidated" 3 !calls;
          Alcotest.(check int)
            "provider calls never overlap"
            1
            !max_in_flight))))
;;

let test_consolidation_runtime_uses_typed_route () =
  let config =
    {|
[providers.local]
display-name = "Local"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.chat]
api-name = "chat"
max-context = 1024

[models.consolidation]
api-name = "consolidation"
max-context = 1024

[local.chat]
[local.consolidation]

[runtime]
default = "local.chat"
memory_os_consolidation = "local.consolidation"
|}
  in
  with_runtime_config config (fun () ->
    let snapshot = Runtime.dashboard_runtime_defaults_snapshot () in
    Alcotest.(check (option string))
      "snapshot preserves configured selector"
      (Some "local.consolidation")
      snapshot.memory_os_consolidation_runtime_id;
    match snapshot.memory_os_consolidation with
    | Error msg -> Alcotest.failf "typed consolidation runtime should resolve: %s" msg
    | Ok resolution ->
      Alcotest.(check string)
        "typed task route wins over default"
        "local.consolidation"
        resolution.effective_runtime.Runtime.id;
      Alcotest.(check bool)
        "snapshot records configured source"
        true
        (resolution.resolution_source = Runtime.Consolidation_configured);
      let dashboard =
        Server_dashboard_runtime_defaults_json.resolved_of_snapshot snapshot
      in
      Alcotest.(check (option string))
        "dashboard preserves configured selector"
        (Some "local.consolidation")
        dashboard.memory_os_consolidation_runtime_id;
      (match dashboard.memory_os_consolidation
       with
       | Server_dashboard_runtime_defaults_json.Consolidation_resolved runtime_id ->
         Alcotest.(check string)
           "dashboard preserves configured snapshot route"
           "local.consolidation"
           runtime_id
       | _ -> Alcotest.fail "dashboard changed configured snapshot resolution"))
;;

let test_consolidation_runtime_inherits_default () =
  let config =
    {|
[providers.local]
display-name = "Local"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.chat]
api-name = "chat"
max-context = 1024

[local.chat]

[runtime]
default = "local.chat"
|}
  in
  with_runtime_config config (fun () ->
    let snapshot = Runtime.dashboard_runtime_defaults_snapshot () in
    Alcotest.(check (option string))
      "snapshot preserves absent selector"
      None
      snapshot.memory_os_consolidation_runtime_id;
    match snapshot.memory_os_consolidation with
    | Error msg -> Alcotest.failf "default consolidation runtime should resolve: %s" msg
    | Ok resolution ->
        Alcotest.(check string)
          "absent task route inherits default"
          "local.chat"
          resolution.effective_runtime.Runtime.id;
        Alcotest.(check bool)
          "snapshot records inherited source"
          true
          (resolution.resolution_source
           = Runtime.Consolidation_inherited_default);
        let dashboard =
          Server_dashboard_runtime_defaults_json.resolved_of_snapshot snapshot
        in
        Alcotest.(check (option string))
          "dashboard preserves absent selector"
          None
          dashboard.memory_os_consolidation_runtime_id;
        (match dashboard.memory_os_consolidation
         with
         | Server_dashboard_runtime_defaults_json.Consolidation_inherited runtime_id ->
           Alcotest.(check string)
             "dashboard preserves inherited snapshot route"
             "local.chat"
             runtime_id
         | _ -> Alcotest.fail "dashboard changed inherited snapshot resolution"))
;;

let () =
  Alcotest.run
    "server_bootstrap_maintenance_memory_os"
    [ ( "memory_os"
      , [ Alcotest.test_case
            "accumulate then consolidate then recall"
            `Quick
            test_accumulate_consolidate_recall
        ; Alcotest.test_case
            "skips when too few facts"
            `Quick
            test_skips_when_too_few
        ; Alcotest.test_case
            "tick serializes provider calls"
            `Quick
            test_tick_serializes_provider_calls
        ; Alcotest.test_case
            "typed route selects consolidation runtime"
            `Quick
            test_consolidation_runtime_uses_typed_route
        ; Alcotest.test_case
            "absent route inherits default runtime"
            `Quick
            test_consolidation_runtime_inherits_default
        ] )
    ]
;;
