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
   consolidation prompt. [Masc_test_deps.source_path] locates the repo root the same
   way every other prompt-reading test does: DUNE_SOURCEROOT under dune, else a
   walk up from cwd (find_project_root). This keeps the executable runnable both
   under `dune test` and as a bare `_build/default/test/*.exe`. *)
let with_prompts f =
  let prompts_dir = Masc_test_deps.source_path "config/prompts" in
  Fun.protect ~finally:Prompt_registry.clear (fun () ->
    Prompt_registry.clear ();
    Prompt_registry.set_markdown_dir prompts_dir;
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
        (* Total: with no output schema requested there is nothing a provider
           capability can reject, so the resolver returns a config directly. *)
        let resolved_cfg =
          Runtime.resolve_provider_for_consolidation (provider_cfg ~max_tokens:512 ())
        in
        let outcome =
          Runtime.consolidate_keeper
            ~complete
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~runtime_id:unconfigured_runtime_id
            ~provider_cfg:resolved_cfg
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
        (* The contract lives in the prompt and the parser, not in a wire
           response_format. Pinning [Off] keeps the request identical across
           providers: reintroducing a schema demand would make every
           json_object-only endpoint (GLM/DeepSeek/Kimi) fail capability
           validation and silently fall back to this same prompt path. *)
        Alcotest.(check (option bool))
          "no response format is requested"
          (Some true)
          (Option.map
             (function
               | Atypes.Off -> true
               | Atypes.JsonMode | Atypes.JsonSchema _ -> false)
             !seen_response_format);
        Alcotest.(check bool)
          "no output schema is attached"
          true
          (Option.is_none !seen_output_schema);
        Alcotest.(check bool)
          "prompt registry output is passed through verbatim"
          true
          !seen_prompt_matches_template))))
;;

(* Capability independence: a provider that declares json_object but not native
   json_schema (GLM/DeepSeek/Kimi) gets exactly the request every other provider
   gets. Tier selection existed only to decide how to ask for a schema; with no
   schema requested, a declared capability — which this repo has recorded as
   sometimes false (ollama.com cloud, 2026-07-02 probe) — can no longer change
   what goes on the wire. The tuning that does matter is still asserted below. *)
let test_resolver_is_capability_independent () =
  let json_object_only_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"json-object-only"
      ~base_url:"https://json-object-only.invalid/v1"
      ~model_capabilities_override:
        { Llm_provider.Capabilities.openai_compat_chat_extended_capabilities with
          supports_structured_output = false
        }
      ()
  in
  let resolved = Runtime.resolve_provider_for_consolidation json_object_only_cfg in
  Alcotest.(check bool)
    "json_object-only provider still gets no response format"
    true
    (match resolved.Llm_provider.Provider_config.response_format with
     | Atypes.Off -> true
     | Atypes.JsonMode | Atypes.JsonSchema _ -> false);
  Alcotest.(check bool)
    "no output_schema is attached"
    true
    (Option.is_none resolved.Llm_provider.Provider_config.output_schema);
  Alcotest.(check (option bool))
    "thinking is disabled for the consolidation request"
    (Some false)
    resolved.Llm_provider.Provider_config.enable_thinking;
  Alcotest.(check (option bool))
    "thinking output is not preserved"
    (Some false)
    resolved.Llm_provider.Provider_config.preserve_thinking
;;

(* With no wire response format, the prompt is the only place the output
   contract is stated, so it must keep saying the reply is JSON — a prompt that
   stopped asking for JSON would leave [plan_of_json] rejecting every reply.
   (This assertion previously existed for a different reason: the
   OpenAI-compatible json_object tier 400s when the messages lack a literal
   "json" token. That tier is gone; the contract reason outlives it.) *)
let test_consolidation_prompt_carries_json_token () =
  with_prompts (fun () ->
    let facts = [ fact "a"; fact "b" ] in
    match
      Prompt_registry.render_prompt_template
        Keeper_prompt_names.librarian_memory_consolidation
        [ "numbered_facts", Consolidation.render_numbered_facts facts ]
    with
    | Error msg -> Alcotest.failf "failed to render consolidation prompt: %s" msg
    | Ok rendered ->
      Alcotest.(check bool)
        "consolidation prompt states the json contract"
        true
        (contains "json" (String.lowercase_ascii rendered)))
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
    ; ( "output_contract"
      , [ Alcotest.test_case
            "resolver output does not depend on provider capability"
            `Quick
            test_resolver_is_capability_independent
        ; Alcotest.test_case
            "consolidation prompt carries the json token"
            `Quick
            test_consolidation_prompt_carries_json_token
        ] )
    ]
;;
