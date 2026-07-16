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
        ] )
    ]
;;
