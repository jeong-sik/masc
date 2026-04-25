(* #9959: [Keeper_usage_trust.classify] flags cache silence on
   Anthropic-resolved turns where input_tokens crosses the cache
   floor (10k) but both [cache_creation_input_tokens] and
   [cache_read_input_tokens] are zero — the production scan saw
   this on 100% of [claude_code:*] turns despite Anthropic's
   default-on prompt caching. *)

module KUT = Masc_mcp.Keeper_usage_trust

let usage ~input ~output ~cc ~cr : Agent_sdk.Types.api_usage =
  { input_tokens = input;
    output_tokens = output;
    cache_creation_input_tokens = cc;
    cache_read_input_tokens = cr;
    cost_usd = None }

let classify_with_cache ?(model = "claude_code:auto")
    ?(resolved_model_id = "claude-sonnet-4-6")
    ?(context_max = 200_000) ~input ~cc ~cr () =
  KUT.classify
    ~usage_reported:true
    ~usage:(usage ~input ~output:1024 ~cc ~cr)
    ~model_used:model
    ~resolved_model_id
    ~context_max

let has_reason expected trust =
  List.mem expected (KUT.reasons trust)

let test_cache_silence_on_anthropic_above_floor () =
  let trust =
    classify_with_cache ~input:50_000 ~cc:0 ~cr:0 ()
  in
  Alcotest.(check bool)
    "anthropic_cache_silence reason added"
    true (has_reason "anthropic_cache_silence" trust)

let test_cache_silence_below_floor_ignored () =
  (* 5k input is below the 10k cache floor — silence is not yet
     diagnostic because Anthropic caching may not engage. *)
  let trust =
    classify_with_cache ~input:5_000 ~cc:0 ~cr:0 ()
  in
  Alcotest.(check bool)
    "no anthropic_cache_silence below floor"
    false (has_reason "anthropic_cache_silence" trust)

let test_cache_silence_with_cache_read_ignored () =
  (* Cache read > 0 means Anthropic IS caching — no silence. *)
  let trust =
    classify_with_cache ~input:50_000 ~cc:0 ~cr:12_000 ()
  in
  Alcotest.(check bool)
    "no silence when cache_read > 0"
    false (has_reason "anthropic_cache_silence" trust)

let test_cache_silence_non_anthropic_ignored () =
  (* Ollama/codex/kimi turns have their own usage shape — cache
     silence is not diagnostic for them. *)
  let trust =
    classify_with_cache
      ~model:"ollama:qwen3.6"
      ~resolved_model_id:"qwen3.6:27b-coding-nvfp4"
      ~input:50_000 ~cc:0 ~cr:0 ()
  in
  Alcotest.(check bool)
    "no silence on non-anthropic"
    false (has_reason "anthropic_cache_silence" trust)

let test_cache_silence_on_bare_claude_id () =
  (* "claude-sonnet-4-6" is recognised even without "claude_code:"
     prefix because [resolved_model_id] is the canonical id. *)
  let trust =
    classify_with_cache
      ~model:"unknown"
      ~resolved_model_id:"claude-opus-4-7"
      ~input:50_000 ~cc:0 ~cr:0 ()
  in
  Alcotest.(check bool)
    "silence detected on bare anthropic canonical id"
    true (has_reason "anthropic_cache_silence" trust)

let test_existing_reasons_preserved () =
  (* Cache silence does not mask other anomalies — input_tokens_gt_1m
     and zero_token_usage_reported still surface alongside it where
     applicable. *)
  let trust =
    classify_with_cache ~input:1_500_000 ~cc:0 ~cr:0 ()
  in
  Alcotest.(check bool) "input_tokens_gt_1m preserved"
    true (has_reason "input_tokens_gt_1m" trust);
  Alcotest.(check bool) "anthropic_cache_silence also added"
    true (has_reason "anthropic_cache_silence" trust)

let () =
  Alcotest.run "usage_trust_anthropic_cache_silence" [
    "cache_silence", [
      Alcotest.test_case "above floor on anthropic → flag" `Quick
        test_cache_silence_on_anthropic_above_floor;
      Alcotest.test_case "below floor → no flag" `Quick
        test_cache_silence_below_floor_ignored;
      Alcotest.test_case "cache_read > 0 → no flag" `Quick
        test_cache_silence_with_cache_read_ignored;
      Alcotest.test_case "non-anthropic → no flag" `Quick
        test_cache_silence_non_anthropic_ignored;
      Alcotest.test_case "bare canonical anthropic id → flag" `Quick
        test_cache_silence_on_bare_claude_id;
      Alcotest.test_case "co-exists with other reasons" `Quick
        test_existing_reasons_preserved;
    ];
  ]
