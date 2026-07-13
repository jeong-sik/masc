(** Tests for Keeper_memory_os_consolidation_runtime — the read -> prompt -> LLM -> parse
    -> apply -> write-back loop driven with a fake completion (no real provider). *)

module Types = Masc.Keeper_memory_os_types
module Io = Masc.Keeper_memory_os_io
module Consolidation = Masc.Keeper_memory_os_consolidation
module Runtime = Masc.Keeper_memory_os_consolidation_runtime
module Structured_schema = Masc.Keeper_structured_output_schema
module Agent_sdk_response = Masc.Agent_sdk_response
module Atypes = Agent_sdk.Types

let now = 1_000_000.0
let unconfigured_runtime_id = "test.unconfigured"

let contains substring s =
  let sub_len = String.length substring in
  let str_len = String.length s in
  let rec aux i =
    if i + sub_len > str_len
    then false
    else if String.sub s i sub_len = substring
    then true
    else aux (i + 1)
  in
  if sub_len = 0 then true else aux 0
;;

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

(* A fake completion that ignores its inputs and returns [canned] as the model's
   text response, so the loop is exercised end to end without a provider. *)
let fake_response canned =
  { Llm_provider.Types.id = "fake"
  ; model = "fake"
  ; stop_reason = Llm_provider.Types.EndTurn
  ; content = [ Atypes.Text canned ]
  ; usage = None
  ; telemetry = None
  }
;;

let fake_complete canned : Runtime.complete_fn =
  fun ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ () -> Ok (fake_response canned)
;;

let fake_complete_with_config inspect canned : Runtime.complete_fn =
  fun ~sw:_ ~net:_ ?clock:_ ~config ~messages () ->
  inspect config messages;
  Ok (fake_response canned)
;;

let text_of_message (message : Atypes.message) =
  message.content
  |> List.filter_map (function
    | Atypes.Text text -> Some text
    | _ -> None)
  |> String.concat "\n"
;;

(* The fake completion ignores the config, so any valid one works. *)
let provider_cfg ?max_tokens () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Anthropic
    ~model_id:"fake"
    ~base_url:"http://localhost"
    ?max_tokens
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
    | None ->
      Alcotest.fail "DUNE_SOURCEROOT is required to locate config/prompts in tests"
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
            ~clock:(Eio.Stdenv.clock env)
            ~runtime_id:unconfigured_runtime_id
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

let test_consolidate_judges_single_fact () =
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
            ~clock:(Eio.Stdenv.clock env)
            ~runtime_id:unconfigured_runtime_id
            ~provider_cfg:(provider_cfg ())
            ~now
            ~keeper_id
            ()
        in
        match outcome with
        | Runtime.Consolidated { before; after } ->
          Alcotest.(check int) "before" 1 before;
          Alcotest.(check int) "after" 1 after
        | _ -> Alcotest.fail "expected Consolidated"))))
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
            ~clock:(Eio.Stdenv.clock env)
            ~runtime_id:unconfigured_runtime_id
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
            ~clock:(Eio.Stdenv.clock env)
            ~runtime_id:unconfigured_runtime_id
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

let append_raw_fact_line ~keeper_id line =
  let oc =
    open_out_gen [ Open_append; Open_creat; Open_text ] 0o644 (Io.facts_path ~keeper_id)
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
       output_string oc line;
       output_char oc '\n')
;;

let test_consolidate_rejects_malformed_fact_store () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
      with_temp_keepers (fun () ->
        let keeper_id = "keeper-1" in
        List.iter
          (Io.append_fact ~keeper_id)
          [ fact "a"; fact "b"; fact "c"; fact "d" ];
        append_raw_fact_line ~keeper_id "{not-json";
        let outcome =
          Runtime.consolidate_keeper
            ~complete:(fake_complete "{}")
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~runtime_id:unconfigured_runtime_id
            ~provider_cfg:(provider_cfg ())
            ~now
            ~keeper_id
            ()
        in
        match outcome with
        | Runtime.Unparseable msg ->
          Alcotest.(check bool)
            "strict read failure reported"
            true
            (String.contains msg ':')
        | _ -> Alcotest.fail "expected Unparseable for malformed fact store"))))
;;

let test_consolidate_classifies_empty_provider_response () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
      with_temp_keepers (fun () ->
        let keeper_id = "keeper-1" in
        List.iter
          (Io.append_fact ~keeper_id)
          [ fact "a"; fact "b"; fact "c"; fact "d" ];
        let outcome =
          Runtime.consolidate_keeper
            ~complete:(fake_complete "   ")
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~runtime_id:unconfigured_runtime_id
            ~provider_cfg:(provider_cfg ())
            ~now
            ~keeper_id
            ()
        in
        match outcome with
        | Runtime.Empty_response -> ()
        | _ -> Alcotest.fail "expected Empty_response for blank provider output"))))
;;

let test_consolidate_classifies_invalid_structured_response () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
      with_temp_keepers (fun () ->
        let keeper_id = "keeper-1" in
        List.iter
          (Io.append_fact ~keeper_id)
          [ fact "a"; fact "b"; fact "c"; fact "d" ];
        let outcome =
          Runtime.consolidate_keeper
            ~complete:(fake_complete "not json {{{")
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~runtime_id:unconfigured_runtime_id
            ~provider_cfg:(provider_cfg ())
            ~now
            ~keeper_id
            ()
        in
        match outcome with
        | Runtime.Invalid_structured_response detail ->
          Alcotest.(check bool)
            "detail keeps typed rejection wrapper"
            true
            (contains
               "consolidation provider returned invalid structured response"
               detail);
          Alcotest.(check bool)
            "detail keeps JSON parser reason"
            true
            (contains "JSON parse error" detail)
        | _ ->
          Alcotest.fail
            "expected Invalid_structured_response for malformed provider output"))))
;;

let test_consolidate_requires_clock_before_provider_call () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
      with_temp_keepers (fun () ->
        let keeper_id = "keeper-1" in
        List.iter
          (Io.append_fact ~keeper_id)
          [ fact "a"; fact "b"; fact "c"; fact "d" ];
        let called = ref false in
        let complete : Runtime.complete_fn =
          fun ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ () ->
          called := true;
          Ok (fake_response {|{"groups":[],"drop_indices":[]}|})
        in
        let outcome =
          Runtime.consolidate_keeper
            ~complete
            ~timeout_sec:1.0
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~runtime_id:unconfigured_runtime_id
            ~provider_cfg:(provider_cfg ())
            ~now
            ~keeper_id
            ()
        in
        Alcotest.(check bool) "provider was not called" false !called;
        match outcome with
        | Runtime.Transport_failed msg ->
          Alcotest.(check bool)
            "message names unavailable clock"
            true
            (contains "clock unavailable" msg);
          Alcotest.(check bool)
            "message names timeout"
            true
            (contains "timeout_sec=1.0" msg)
        | _ -> Alcotest.fail "expected Transport_failed for missing clock"))))
;;

let test_consolidate_respects_provider_config_and_prompt_template () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      with_prompts (fun () ->
      with_temp_keepers (fun () ->
        let keeper_id = "keeper-1" in
        let facts = [ fact "a"; fact "b"; fact "c"; fact "d" ] in
        List.iter (Io.append_fact ~keeper_id) facts;
        let seen_max_tokens = ref None in
        let plan =
          {|{"groups":[{"member_indices":[0,1],"consolidated_claim":"ab","category":"fact"}],"drop_indices":[]}|}
        in
        let seen_response_format = ref None in
        let seen_output_schema = ref None in
        let seen_prompt_matches_template = ref false in
        let expected_prompt =
          match
            Prompt_registry.render_prompt_template
              Keeper_prompt_names.librarian_memory_consolidation
              [ "numbered_facts", Consolidation.render_numbered_facts facts ]
          with
          | Ok text -> String.trim text
          | Error msg -> Alcotest.failf "failed to render expected prompt: %s" msg
        in
        let complete =
          fake_complete_with_config
            (fun config messages ->
               seen_max_tokens := config.Llm_provider.Provider_config.max_tokens;
               seen_response_format := Some config.Llm_provider.Provider_config.response_format;
               seen_output_schema := config.Llm_provider.Provider_config.output_schema;
               let rendered_prompt =
                 messages
                 |> List.map text_of_message
                 |> String.concat "\n"
                 |> String.trim
               in
               seen_prompt_matches_template := String.equal expected_prompt rendered_prompt)
            plan
        in
        let outcome =
          Runtime.consolidate_keeper
            ~complete
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~runtime_id:unconfigured_runtime_id
            ~provider_cfg:(provider_cfg ~max_tokens:512 ())
            ~now
            ~keeper_id
            ()
        in
        (match outcome with
         | Runtime.Consolidated _ -> ()
         | _ -> Alcotest.fail "expected Consolidated");
        Alcotest.(check (option int))
          "configured max_tokens cap is preserved"
          (Some 512)
          !seen_max_tokens;
        let expected_schema = Structured_schema.consolidation_plan_output_schema in
        Alcotest.(check (option bool))
          "json schema response format requested"
          (Some true)
          (Option.map
             (function
               | Atypes.JsonSchema schema -> Yojson.Safe.equal schema expected_schema
               | Atypes.JsonMode | Atypes.Off -> false)
             !seen_response_format);
        Alcotest.(check (option bool))
          "output schema mirrors response format"
          (Some true)
          (Option.map (Yojson.Safe.equal expected_schema) !seen_output_schema);
        Alcotest.(check bool)
          "prompt registry output is passed through verbatim"
          true
          !seen_prompt_matches_template))))
;;

let () =
  Alcotest.run
    "keeper_memory_os_consolidation_runtime"
    [ ( "loop"
      , [ Alcotest.test_case "applies the model's plan" `Quick test_consolidate_applies_plan
        ; Alcotest.test_case "judges a single fact" `Quick test_consolidate_judges_single_fact
	        ; Alcotest.test_case "dry-run preserves the store" `Quick test_consolidate_dry_run_preserves_store
        ; Alcotest.test_case "rejects stale snapshots" `Quick test_consolidate_rejects_stale_snapshot
        ; Alcotest.test_case "rejects malformed fact store" `Quick test_consolidate_rejects_malformed_fact_store
        ; Alcotest.test_case
            "classifies empty provider response"
            `Quick
            test_consolidate_classifies_empty_provider_response
        ; Alcotest.test_case
            "classifies invalid structured provider response"
            `Quick
            test_consolidate_classifies_invalid_structured_response
        ; Alcotest.test_case
            "requires clock before provider call"
            `Quick
            test_consolidate_requires_clock_before_provider_call
        ; Alcotest.test_case
            "respects provider config and prompt template"
            `Quick
            test_consolidate_respects_provider_config_and_prompt_template
	        ] )
    ]
;;
