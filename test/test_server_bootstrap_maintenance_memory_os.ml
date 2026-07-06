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

let message_text (m : Atypes.message) =
  m.content
  |> List.filter_map (function
    | Atypes.Text s -> Some s
    | _ -> None)
  |> String.concat "\n"

let now = 1_000_000.0

let fact claim =
  { Types.claim
  ; category = Types.Fact
  ; external_ref = None
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

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      Unix.rmdir path)
    else Sys.remove path
;;

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

let with_file_shaped_keepers_config f =
  let base = Filename.temp_file "consolidation-tick-config-" ".tmp" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  let config_dir = Filename.concat base "config" in
  Unix.mkdir config_dir 0o755;
  let keepers_path = Filename.concat config_dir "keepers" in
  write_file keepers_path "not a keepers directory";
  let previous = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" previous;
      Config_dir_resolver.reset ();
      rm_rf base)
    (fun () ->
       Unix.putenv "MASC_CONFIG_DIR" config_dir;
       Config_dir_resolver.reset ();
       f ~keepers_path)
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
              ~max_facts:8
              ~max_episodes:2
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
            ~provider_cfg:(provider_cfg ())
            ~now
            ();
          let after_count = List.length (Io.read_facts_all ~keeper_id) in
          Alcotest.(check int) "store unchanged when too few facts" 1 after_count))))
;;

let test_parallel_timeout_per_keeper () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
        with_temp_keepers (fun () ->
          (* Two keepers each have enough facts to be considered for consolidation. *)
          List.iter (Io.append_fact ~keeper_id:"keeper-slow") [ fact "slow 1"; fact "slow 2" ];
          List.iter (Io.append_fact ~keeper_id:"keeper-fast") [ fact "fast 1"; fact "fast 2" ];
          let slow_count_before = List.length (Io.read_facts_all ~keeper_id:"keeper-slow") in
          let fast_count_before = List.length (Io.read_facts_all ~keeper_id:"keeper-fast") in
          Alcotest.(check int) "slow keeper accumulated" 2 slow_count_before;
          Alcotest.(check int) "fast keeper accumulated" 2 fast_count_before;
          let slow_complete ~sw:_ ~net:_ ?clock ~config:_ ~messages:_ () =
            (match clock with
             | Some clock -> Eio.Time.sleep clock 2.0
             | None -> ());
            Ok (fake_response "{\"groups\":[],\"drop_indices\":[]}")
          in
          let fast_complete = fake_complete "{\"groups\":[],\"drop_indices\":[]}" in
          let complete ~sw ~net ?clock ~config ~messages () =
            if List.exists
                 (fun (m : Agent_sdk.Types.message) ->
                    String.contains (message_text m) 'f')
                 messages
            then fast_complete ~sw ~net ?clock ~config ~messages ()
            else slow_complete ~sw ~net ?clock ~config ~messages ()
          in
          let start = Unix.gettimeofday () in
          Server_bootstrap_maintenance.run_memory_os_consolidation_tick
            ~complete
            ~timeout_sec:0.1
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~provider_cfg:(provider_cfg ())
            ~now
            ();
          let elapsed = Unix.gettimeofday () -. start in
          (* The slow keeper should hit the 0.1s timeout and the fast keeper should
             complete; the total elapsed time must be far below the slow keeper's
             2.0s sleep, proving per-keeper timeout and parallel scheduling. *)
          Alcotest.(check bool) "tick returns before slow keeper sleep" true (elapsed < 1.0);
          (* The fast keeper store should be unchanged (no groups). The slow keeper
             may or may not have been rewritten depending on timing; we only assert
             that the fast path completed. *)
          let fast_count_after = List.length (Io.read_facts_all ~keeper_id:"keeper-fast") in
          Alcotest.(check int) "fast keeper unchanged" fast_count_before fast_count_after))))
;;

let test_fact_store_discovery_failure_is_typed_for_tick () =
  with_file_shaped_keepers_config (fun ~keepers_path ->
    match
      Server_bootstrap_maintenance.For_testing.memory_os_fact_store_keeper_ids_for_tick
        ~site:"unit-test"
    with
    | Ok keeper_ids ->
      Alcotest.failf
        "expected keeper discovery failure, got %d keeper ids"
        (List.length keeper_ids)
    | Error error ->
      Alcotest.(check bool)
        "error mentions keepers path"
        true
        (String_util.contains_substring_ci error keepers_path))
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
            "parallel per-keeper timeout"
            `Quick
            test_parallel_timeout_per_keeper
        ; Alcotest.test_case
            "fact-store discovery failure is typed for tick"
            `Quick
            test_fact_store_discovery_failure_is_typed_for_tick
        ] )
    ]
;;
