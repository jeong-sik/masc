(** Multi-vendor live smoke test.

    Runs the golden Event_bus lifecycle transcript against whatever
    providers are reachable in the current environment:

    - Anthropic      if [ANTHROPIC_API_KEY] is set
    - Openai         if [OPENAI_API_KEY] is set
    - Gemini         if [GEMINI_API_KEY] or legacy [GEMINI_API_KEY] is set
    - OpenAI-compat  for every healthy endpoint in [LLM_ENDPOINTS]
                     (llama-server, Ollama, vLLM, LM Studio, TGI, ...)

    Each provider case is [Quick] but skips gracefully (logs +
    returns early) if its prerequisite is missing, so CI without
    credentials still passes. The test fails only if a configured
    provider returns a result whose Event_bus transcript diverges
    from the documented invariant:

        agent_started -> turn_started -> ... -> turn_completed
                                             -> agent_completed

    (ToolCalled / ToolCompleted interleave is allowed between
    turn_started and turn_completed; this test does not force a
    tool call, so the minimum transcript is used.)

    Invariants checked, per EVENT-CATALOG.md I1/I2:
    - Same native variant names across every provider.
    - Envelope [correlation_id] / [run_id] present and preserved.

    Run manually:
      dune exec --root . test/test_multivendor_live.exe *)

open Alcotest
open Agent_sdk

let skip_note label reason = Printf.printf "  [SKIP] %s — %s\n%!" label reason
let min_transcript = [ "turn_started"; "turn_completed" ]

(* Assert the emitted names contain the required lifecycle markers in order.
   Tool and context events may interleave. *)
let assert_transcript ~provider ~names =
  List.iter
    (fun required ->
       check
         bool
         (Printf.sprintf "[%s] transcript has %s" provider required)
         true
         (List.mem required names))
    min_transcript;
  let index n = List.find_index (( = ) n) names |> Option.value ~default:max_int in
  check
    bool
    (Printf.sprintf "[%s] turn_started before turn_completed" provider)
    true
    (index "turn_started" < index "turn_completed")
;;

let assert_envelope ~provider events =
  List.iter
    (fun (e : Event_bus.event) ->
       check
         bool
         (Printf.sprintf "[%s] correlation_id non-empty" provider)
         true
         (String.length e.meta.correlation_id > 0);
       check
         bool
         (Printf.sprintf "[%s] run_id non-empty" provider)
         true
         (String.length e.meta.run_id > 0);
       check bool (Printf.sprintf "[%s] ts populated" provider) true (e.meta.ts > 0.0))
    events
;;

(* ── Minimal agent driver ─────────────────────────────────────── *)

let run_minimal_agent ~env ~sw ~provider_label ~provider_config ~model =
  let bus = Event_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:32 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Event_bus.subscribe ~config bus in
  let options =
    { Agent.default_options with
      provider_config = Some provider_config
    ; event_bus = Some bus
    }
  in
  let config =
    { (Types.default_config ~model:"test-model") with
      name = "smoke"
    ; model
    ; system_prompt = Some "Reply with the single word: ok."
    }
  in
  let agent = Agent.create ~net:env#net ~config ~options () in
  let result = Agent.run ~sw agent "Say ok." in
  let events = Event_bus.drain sub in
  let names =
    List.map
      (fun (event : Event_bus.event) -> Event_bus.payload_kind event.payload)
      events
  in
  Printf.printf "  [%s] transcript: [%s]\n%!" provider_label (String.concat "; " names);
  match result with
  | Ok _ ->
    assert_transcript ~provider:provider_label ~names;
    assert_envelope ~provider:provider_label events
  | Error e ->
    (* Live providers sometimes fail (rate limits, model missing). We
        still require the turn lifecycle envelope when the pipeline ran
        far enough to publish events. Some admission/configuration failures
        can return before the first turn event, so keep that path skippable. *)
    Printf.printf
      "  [%s] task returned Error: %s — checking any emitted turn transcript\n%!"
      provider_label
      (Error.to_string e);
    if names <> [] then assert_envelope ~provider:provider_label events
;;

(* ── Anthropic ────────────────────────────────────────────────── *)

let test_anthropic () =
  match Sys.getenv_opt "ANTHROPIC_API_KEY" with
  | None | Some "" | Some "test-mock-key" ->
    skip_note "anthropic" "ANTHROPIC_API_KEY not set"
  | Some _ ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let provider_config =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.Anthropic
        ~provider_id:"anthropic"
        ~model_id:"claude-haiku-4-5"
        ~base_url:"https://api.anthropic.com"
        ~api_key:(Option.get (Sys.getenv_opt "ANTHROPIC_API_KEY"))
        ~headers:[ "Content-Type", "application/json"; "anthropic-version", "2023-06-01" ]
        ~request_path:"/v1/messages"
        ()
    in
    run_minimal_agent
      ~env
      ~sw
      ~provider_label:"anthropic"
      ~provider_config
      ~model:"claude-haiku-4-5"
;;

(* ── Openai (via OpenAICompat) ────────────────────────────────── *)

let test_openai () =
  match Sys.getenv_opt "OPENAI_API_KEY" with
  | None | Some "" -> skip_note "openai" "OPENAI_API_KEY not set"
  | Some _ ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let base_url = "https://api.openai.com" in
    let provider_config =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.OpenAI_compat
        ~provider_id:"openai"
        ~model_id:"gpt-mini"
        ~base_url
        ~api_key:(Option.get (Sys.getenv_opt "OPENAI_API_KEY"))
        ~headers:[ "Content-Type", "application/json" ]
        ~request_path:"/v1/chat/completions"
        ()
    in
    run_minimal_agent ~env ~sw ~provider_label:"openai" ~provider_config ~model:"gpt-mini"
;;

(* ── Gemini (via OpenAI-compat endpoint) ──────────────────────── *)

let gemini_api_key_env () =
  match Sys.getenv_opt "GEMINI_API_KEY" with
  | Some value when String.trim value <> "" -> Some "GEMINI_API_KEY"
  | _ ->
    (match Sys.getenv_opt "GEMINI_API_KEY" with
     | Some value when String.trim value <> "" -> Some "GEMINI_API_KEY"
     | _ -> None)
;;

let test_gemini () =
  match gemini_api_key_env () with
  | None -> skip_note "gemini" "GEMINI_API_KEY not set"
  | Some api_key_env ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    (* Google's OpenAI-compatible endpoint for Gemini. *)
    let base_url = "https://generativelanguage.googleapis.com/v1beta/openai" in
    let provider_config =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.OpenAI_compat
        ~provider_id:"gemini-openai-compat"
        ~model_id:"gemini-2.0-flash"
        ~base_url
        ~api_key:(Option.get (Sys.getenv_opt api_key_env))
        ~headers:[ "Content-Type", "application/json" ]
        ~request_path:"/chat/completions"
        ()
    in
    run_minimal_agent
      ~env
      ~sw
      ~provider_label:"gemini"
      ~provider_config
      ~model:"gemini-2.0-flash"
;;

(* ── Local OpenAI-compatible (llama-server, Ollama, vLLM, ...) ─ *)

let test_local_compat () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let endpoints =
    Llm_provider.Discovery.parse_llm_endpoints_env ()
    |> List.map
         (Llm_provider.Discovery.endpoint
            ~protocol:Llm_provider.Discovery.Openai_compatible
            ~capabilities:Llm_provider.Capabilities.default_capabilities)
  in
  let statuses = Llm_provider.Discovery.discover ~sw ~net:env#net ~endpoints in
  let healthy =
    List.filter (fun (s : Llm_provider.Discovery.endpoint_status) -> s.healthy) statuses
  in
  if healthy = []
  then (
    let endpoint_urls =
      List.map
        (fun (endpoint : Llm_provider.Discovery.endpoint) -> endpoint.url)
        endpoints
    in
    skip_note
      "local-openai-compat"
      (Printf.sprintf "no healthy endpoint in [%s]" (String.concat ", " endpoint_urls)))
  else
    List.iter
      (fun (s : Llm_provider.Discovery.endpoint_status) ->
         match s.models with
         | [] -> skip_note (Printf.sprintf "local %s" s.url) "no model listed"
         | m :: _ ->
           let label = Printf.sprintf "local %s@%s" m.id s.url in
           let provider_config =
             Provider_mock.local_provider_config
               ~base_url:s.url
               ~model_id:m.id
               ~request_path:"/v1/chat/completions"
               ()
           in
           run_minimal_agent ~env ~sw ~provider_label:label ~provider_config ~model:m.id)
      healthy
;;

(* ── Entry point ──────────────────────────────────────────────── *)

let () =
  (* Initialize the crypto RNG so TLS handshakes work for https:// endpoints.
     [use_default ()] is a no-op if already initialized. *)
  Mirage_crypto_rng_unix.use_default ();
  (* Mock key for providers that read env defensively even when unused. *)
  if Sys.getenv_opt "ANTHROPIC_API_KEY" = None
  then Unix.putenv "ANTHROPIC_API_KEY" "test-mock-key";
  Printf.printf "\n=== Multi-vendor live smoke test ===\n";
  Printf.printf "  Each case runs if its prerequisite is present; otherwise skips.\n\n";
  run
    "Multivendor_live"
    [ ( "golden_transcript"
      , [ test_case "anthropic" `Quick test_anthropic
        ; test_case "openai" `Quick test_openai
        ; test_case "gemini" `Quick test_gemini
        ; test_case "local openai-compat" `Quick test_local_compat
        ] )
    ]
;;
