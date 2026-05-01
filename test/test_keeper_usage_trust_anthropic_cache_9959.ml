(* test/test_keeper_usage_trust_anthropic_cache_9959.ml

   #9959 facet 1: Anthropic prompt caching silently disabled.
   1078/1078 turn rows on 2026-04-24 (every claude_code:auto
   turn over a full day) reported
   [cache_creation_input_tokens = cache_read_input_tokens = 0]
   despite typical keeper system prompts running 5K-30K tokens.

   The classify function previously did not flag this — caches
   at zero are normal on tiny prompts (below the
   [anthropic_cache_min_input_tokens = 1024] threshold for
   sonnet/opus).  This test set pins the new
   [anthropic_caching_likely_disabled] reason added to
   [Keeper_usage_trust.classify]:

     - Fires when the model is Anthropic-routed AND
       [input_tokens >= 1024] AND
       [cache_creation + cache_read = 0].
     - Does NOT fire on tiny prompts (below threshold) — those
       are correctly normal even on Anthropic.
     - Does NOT fire on non-Anthropic providers (ollama, gemini,
       codex_cli) — they have no Anthropic-style cache surface
       to begin with, so cache_creation = cache_read = 0 is the
       only valid state.
     - Does NOT fire when caching IS working (cache_read > 0
       OR cache_creation > 0).
*)

module T = Masc_mcp.Keeper_usage_trust

let mk_usage
    ?(cache_creation = 0) ?(cache_read = 0) ?(cost_usd = None)
    ~input ~output () : Agent_sdk.Types.api_usage =
  {
    input_tokens = input;
    output_tokens = output;
    cache_creation_input_tokens = cache_creation;
    cache_read_input_tokens = cache_read;
    cost_usd;
  }

let provider_kind_of_spec spec =
  match Masc_mcp.Provider_kind_resolver.kind_of_spec spec with
  | Some kind -> kind
  | None -> Alcotest.failf "expected provider kind for %S" spec

let anthropic_kind =
  provider_kind_of_spec "claude:claude-sonnet-4-6"

let openai_compat_kind =
  provider_kind_of_spec "openrouter:anthropic/claude-3.5"

let classify_without_kind ~model ~usage =
  T.classify ~usage_reported:true ~usage
    ~model_used:model ~resolved_model_id:model
    ~context_max:200_000

let classify_with_kind ~provider_kind ~model ~usage =
  T.classify_with_provider_kind ~provider_kind:(Some provider_kind)
    ~usage_reported:true ~usage
    ~model_used:model ~resolved_model_id:model
    ~context_max:200_000

let reasons_of trust =
  match trust with
  | T.Usage_untrusted reasons -> reasons
  | T.Usage_trusted | T.Usage_missing -> []

let has_reason trust r = List.mem r (reasons_of trust)

(* Threshold sanity: the constant is [1024] (Anthropic
   sonnet/opus minimum). Pinning this avoids accidental drift
   to e.g. 2048 or 4096 which would silently start ignoring
   real cache failures on smaller-but-cacheable prompts. *)
let test_threshold_is_1024 () =
  Alcotest.(check int) "anthropic cache threshold = 1024"
    1024 T.anthropic_cache_min_input_tokens

(* Helper: model_uses_anthropic_caching is provider-kind based. Typed
   telemetry is authoritative; without it only explicit provider:model labels
   resolve through the provider registry. Bare model substrings do not count. *)
let test_model_detector_recognizes_anthropic () =
  let yes m =
    Alcotest.(check bool) (Printf.sprintf "%s -> Anthropic" m) true
      (T.model_uses_anthropic_caching ~model_used:m ~resolved_model_id:m)
  in
  let yes_kind kind m =
    Alcotest.(check bool) (Printf.sprintf "%s -> Anthropic" m) true
      (T.model_uses_anthropic_caching_with_provider_kind
         ~provider_kind:(Some kind) ~model_used:m ~resolved_model_id:m)
  in
  let no m =
    Alcotest.(check bool) (Printf.sprintf "%s -> not Anthropic" m) false
      (T.model_uses_anthropic_caching ~model_used:m ~resolved_model_id:m)
  in
  let no_kind kind m =
    Alcotest.(check bool) (Printf.sprintf "%s -> not Anthropic" m) false
      (T.model_uses_anthropic_caching_with_provider_kind
         ~provider_kind:(Some kind) ~model_used:m ~resolved_model_id:m)
  in
  yes "claude:claude-sonnet-4-6";
  yes_kind anthropic_kind "Claude-3-Opus";
  no "Claude-3-Opus";
  no "anthropic/claude-haiku";
  no "openrouter:anthropic/claude-3.5";
  no_kind openai_compat_kind "anthropic/claude-haiku";
  no "qwen3-coder";
  no "gpt-5.3";
  no "gemini-2.5-pro";
  no "ollama-local";
  no "kimi-for-coding"

(* Anthropic + cacheable prompt (>= 1024 tokens) + zero caches
   = #9959 facet 1.  Classify must flag. *)
let test_anthropic_with_zero_cache_above_threshold_flags () =
  let usage = mk_usage ~input:5000 ~output:500 () in
  let t =
    classify_with_kind
      ~provider_kind:anthropic_kind
      ~model:"claude-sonnet-4-6" ~usage
  in
  Alcotest.(check bool)
    "anthropic_caching_likely_disabled flagged"
    true (has_reason t "anthropic_caching_likely_disabled");
  Alcotest.(check bool)
    "trust is untrusted because of cache anomaly"
    false (T.is_trusted t)

(* Boundary case: input_tokens exactly 1024 should fire.
   Anthropic's threshold is "at least 1024" so 1024 is the
   first cacheable size. *)
let test_threshold_boundary_1024_inclusive () =
  let usage = mk_usage ~input:1024 ~output:50 () in
  let t =
    classify_with_kind
      ~provider_kind:anthropic_kind
      ~model:"claude_code:auto" ~usage
  in
  Alcotest.(check bool)
    "1024 tokens: cache anomaly fires"
    true (has_reason t "anthropic_caching_likely_disabled")

(* Below threshold: tiny keepalive prompts legitimately have
   zero caches and must NOT be flagged. *)
let test_below_threshold_does_not_flag () =
  let usage = mk_usage ~input:1023 ~output:50 () in
  let t =
    classify_with_kind
      ~provider_kind:anthropic_kind
      ~model:"claude_code:auto" ~usage
  in
  Alcotest.(check bool)
    "1023 tokens: cache anomaly does NOT fire"
    false (has_reason t "anthropic_caching_likely_disabled")

(* Non-Anthropic providers must not be flagged regardless of
   cache fields — they don't expose Anthropic-style caching. *)
let test_non_anthropic_does_not_flag () =
  let usage = mk_usage ~input:50_000 ~output:1_000 () in
  List.iter (fun model ->
    let t = classify_without_kind ~model ~usage in
    Alcotest.(check bool)
      (Printf.sprintf "%s: no anthropic anomaly" model)
      false (has_reason t "anthropic_caching_likely_disabled"))
    [ "qwen3-coder"; "gpt-5.3-codex"; "gemini-2.5-pro";
      "ollama-local"; "kimi-for-coding"; "ramarama";
      "openrouter:anthropic/claude-3.5" ]

(* Caching working as intended: cache_read > 0 — no anomaly. *)
let test_cache_read_positive_does_not_flag () =
  let usage = mk_usage ~input:5000 ~output:500
    ~cache_creation:0 ~cache_read:4500 () in
  let t =
    classify_with_kind
      ~provider_kind:anthropic_kind
      ~model:"claude-sonnet-4-6" ~usage
  in
  Alcotest.(check bool)
    "cache_read > 0 means caching is working"
    false (has_reason t "anthropic_caching_likely_disabled")

(* First-turn caching: cache_creation > 0, cache_read = 0 is
   the cold-cache case.  No anomaly. *)
let test_cache_creation_positive_does_not_flag () =
  let usage = mk_usage ~input:5000 ~output:500
    ~cache_creation:4500 ~cache_read:0 () in
  let t =
    classify_with_kind
      ~provider_kind:anthropic_kind
      ~model:"claude-sonnet-4-6" ~usage
  in
  Alcotest.(check bool)
    "cache_creation > 0 (cold cache) is not an anomaly"
    false (has_reason t "anthropic_caching_likely_disabled")

(* Existing reasons still fire for unrelated anomalies; the new
   reason composes additively with negative_*, gt_1m, etc. *)
let test_multiple_anomalies_compose () =
  let usage = mk_usage ~input:1_500_000 ~output:500 () in
  let t =
    classify_with_kind
      ~provider_kind:anthropic_kind
      ~model:"claude_code:auto" ~usage
  in
  Alcotest.(check bool) "input_tokens_gt_1m present"
    true (has_reason t "input_tokens_gt_1m");
  Alcotest.(check bool) "anthropic_caching_likely_disabled present"
    true (has_reason t "anthropic_caching_likely_disabled");
  Alcotest.(check bool) "trust untrusted" false (T.is_trusted t)

let () =
  Alcotest.run "keeper_usage_trust_anthropic_cache_9959"
    [
      ( "threshold-constant",
        [
          Alcotest.test_case "1024 tokens" `Quick test_threshold_is_1024;
        ] );
      ( "model-detector",
        [
          Alcotest.test_case "provider-kind contract" `Quick
            test_model_detector_recognizes_anthropic;
        ] );
      ( "fires-when-it-should",
        [
          Alcotest.test_case "anthropic + 0 cache above threshold" `Quick
            test_anthropic_with_zero_cache_above_threshold_flags;
          Alcotest.test_case "boundary 1024 inclusive" `Quick
            test_threshold_boundary_1024_inclusive;
        ] );
      ( "false-positive-prevention",
        [
          Alcotest.test_case "below threshold: silent" `Quick
            test_below_threshold_does_not_flag;
          Alcotest.test_case "non-anthropic: silent" `Quick
            test_non_anthropic_does_not_flag;
          Alcotest.test_case "cache_read > 0: silent" `Quick
            test_cache_read_positive_does_not_flag;
          Alcotest.test_case "cache_creation > 0: silent" `Quick
            test_cache_creation_positive_does_not_flag;
        ] );
      ( "composition",
        [
          Alcotest.test_case "stacks with input_tokens_gt_1m" `Quick
            test_multiple_anomalies_compose;
        ] );
    ]
