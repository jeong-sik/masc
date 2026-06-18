(** Tests for Keeper_memory_os_consolidation_runtime — the read -> prompt -> LLM -> parse
    -> apply -> write-back loop driven with a fake completion (no real provider). *)

module Types = Masc.Keeper_memory_os_types
module Io = Masc.Keeper_memory_os_io
module Runtime = Masc.Keeper_memory_os_consolidation_runtime
module Atypes = Agent_sdk.Types

let now = 1_000_000.0

let fact claim =
  { Types.claim
  ; category = Types.Fact
  ; source = { Types.trace_id = "t"; turn = 1; tool_call_id = None }
  ; observed_by = []
  ; first_seen = now
  ; valid_until = None
  ; last_verified_at = Some now
  ; schema_version = Types.schema_version
  }
;;

(* A fake completion that ignores its inputs and returns [canned] as the model's
   text response, so the loop is exercised end to end without a provider. *)
let fake_complete canned : Runtime.complete_fn =
  fun ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ () ->
  Ok
    { Llm_provider.Types.id = "fake"
    ; model = "fake"
    ; stop_reason = Llm_provider.Types.EndTurn
    ; content = [ Atypes.Text canned ]
    ; usage = None
    ; telemetry = None
    }
;;

(* The fake completion ignores the config, so any valid one works. *)
let provider_cfg () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Anthropic
    ~model_id:"fake"
    ~base_url:"http://localhost"
    ()
;;

let with_temp_keepers f =
  let marker = Filename.temp_file "consolidation-runtime-" ".tmp" in
  Sys.remove marker;
  Io.For_testing.with_keepers_dir marker (fun () -> f ())
;;

(* Load the on-disk prompt templates so messages_for_consolidation can render the
   consolidation prompt. DUNE_SOURCEROOT points at the repo root under dune. *)
let with_prompts f =
  let root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some r -> r
    | None -> "."
  in
  Fun.protect ~finally:Prompt_registry.clear (fun () ->
    Prompt_registry.clear ();
    Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
    Masc.Prompt_defaults.init ();
    f ())
;;

(* The model groups the two duplicate claims into one; the store is rewritten with
   the consolidated fact plus the untouched distinct fact. *)
let test_consolidate_applies_plan () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
      with_temp_keepers (fun () ->
        let keeper_id = "keeper-1" in
        List.iter
          (Io.append_fact ~keeper_id)
          [ fact "deploy uses blue-green"
          ; fact "deployment is blue-green based"
          ; fact "build runs on dune 3.x"
          ; fact "tests live under test/"
          ];
        let plan =
          {|{"groups":[{"member_indices":[0,1],"consolidated_claim":"deploys via blue-green","category":"fact"}],"drop_indices":[]}|}
        in
        let outcome =
          Runtime.consolidate_keeper
            ~complete:(fake_complete plan)
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~provider_cfg:(provider_cfg ())
            ~now
            ~keeper_id
            ()
        in
        (match outcome with
         | Runtime.Consolidated { before; after } ->
           Alcotest.(check int) "before" 4 before;
           Alcotest.(check int) "after (two merged into one)" 3 after
         | _ -> Alcotest.fail "expected Consolidated");
        let claims =
          Io.read_facts_all ~keeper_id
          |> List.map (fun f -> f.Types.claim)
          |> List.sort String.compare
        in
        Alcotest.(check (list string))
          "store rewritten with the consolidated set"
          [ "build runs on dune 3.x"; "deploys via blue-green"; "tests live under test/" ]
          claims))))
;;

(* Below the minimum fact count, the pass skips the LLM and leaves the store. *)
let test_consolidate_skips_too_few () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
      with_temp_keepers (fun () ->
        let keeper_id = "keeper-1" in
        Io.append_fact ~keeper_id (fact "lonely fact");
        let outcome =
          Runtime.consolidate_keeper
            ~complete:(fake_complete "{}")
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~provider_cfg:(provider_cfg ())
            ~now
            ~keeper_id
            ()
        in
        match outcome with
        | Runtime.Skipped_too_few n -> Alcotest.(check int) "reported count" 1 n
        | _ -> Alcotest.fail "expected Skipped_too_few"))))
;;

(* dry_run computes the plan but does not rewrite the store. *)
let test_consolidate_dry_run_preserves_store () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
      with_temp_keepers (fun () ->
        let keeper_id = "keeper-1" in
        List.iter
          (Io.append_fact ~keeper_id)
          [ fact "a"; fact "b"; fact "c"; fact "d" ];
        let plan =
          {|{"groups":[{"member_indices":[0,1,2,3],"consolidated_claim":"abcd","category":"fact"}],"drop_indices":[]}|}
        in
        let _ =
          Runtime.consolidate_keeper
            ~complete:(fake_complete plan)
            ~dry_run:true
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~provider_cfg:(provider_cfg ())
            ~now
            ~keeper_id
            ()
        in
        Alcotest.(check int)
          "dry-run leaves all four facts"
          4
          (List.length (Io.read_facts_all ~keeper_id))))))
;;

let test_consolidate_rejects_stale_snapshot () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
      with_temp_keepers (fun () ->
        let keeper_id = "keeper-1" in
        List.iter
          (Io.append_fact ~keeper_id)
          [ fact "a"; fact "b"; fact "c"; fact "d" ];
        let complete : Runtime.complete_fn =
          fun ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ () ->
          Io.append_fact ~keeper_id (fact "new fact while model was judging");
          Ok
            { Llm_provider.Types.id = "fake"
            ; model = "fake"
            ; stop_reason = Llm_provider.Types.EndTurn
            ; content =
                [ Atypes.Text
                    {|{"groups":[{"member_indices":[0,1],"consolidated_claim":"ab","category":"fact"}],"drop_indices":[]}|}
                ]
            ; usage = None
            ; telemetry = None
            }
        in
        let outcome =
          Runtime.consolidate_keeper
            ~complete
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~provider_cfg:(provider_cfg ())
            ~now
            ~keeper_id
            ()
        in
        (match outcome with
         | Runtime.Snapshot_changed { before; current } ->
           Alcotest.(check int) "judged snapshot size" 4 before;
           Alcotest.(check int) "current snapshot size" 5 current
         | _ -> Alcotest.fail "expected Snapshot_changed");
        let claims =
          Io.read_facts_all ~keeper_id
          |> List.map (fun f -> f.Types.claim)
          |> List.sort String.compare
        in
        Alcotest.(check (list string))
          "store is not overwritten by stale survivors"
          [ "a"; "b"; "c"; "d"; "new fact while model was judging" ]
          claims))))
;;

let () =
  Alcotest.run
    "keeper_memory_os_consolidation_runtime"
    [ ( "loop"
      , [ Alcotest.test_case "applies the model's plan" `Quick test_consolidate_applies_plan
        ; Alcotest.test_case "skips when too few facts" `Quick test_consolidate_skips_too_few
        ; Alcotest.test_case "dry-run preserves the store" `Quick test_consolidate_dry_run_preserves_store
        ; Alcotest.test_case "rejects stale snapshots" `Quick test_consolidate_rejects_stale_snapshot
        ] )
    ]
;;
