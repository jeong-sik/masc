(* test/test_cost_ledger_pricing_model_10318.ml

   #10318 — pin the cost ledger pricing-model resolution and cost-status
   decision contracts.

   Pre-fix [costs.jsonl] showed:
   - 100% [cost_usd=0] across 1697 entries
   - 33% empty [model] field (alias "auto" or bare empty string)
   - 52% [provider="unknown"]

   Two merged fixes address the pricing side:
   - [pricing_model_for_ledger]: resolves "auto"/empty/unknown_provider
     model labels to the OAS telemetry [canonical_model_id] so the
     pricing catalog lookup uses the real model id rather than the alias.
   - [cost_status_for_event]: pure decision tree that classifies every
     zero-cost path so the operator can tell "unpriced model" from
     "known free provider" from "provider unknown" at a glance.

   These tests pin those two contracts plus the diagnostic helpers
   [model_resolution_source_for_ledger] and [pricing_catalog_status]
   that annotate each JSONL row with the resolution provenance. *)

open Alcotest

module H  = Masc_mcp.Keeper_hooks_oas

(* ------------------------------------------------------------------ *)
(* Helpers                                                             *)
(* ------------------------------------------------------------------ *)

let make_telemetry ?canonical_model_id () : Agent_sdk.Types.inference_telemetry =
  { system_fingerprint         = None
  ; timings                    = None
  ; reasoning_tokens           = None
  ; reasoning_tokens_estimated = false
  ; request_latency_ms         = Some 0
  ; peak_memory_gb             = None
  ; provider_kind              = None
  ; reasoning_effort           = None
  ; canonical_model_id
  ; effective_context_window   = None
  ; provider_internal_action_count = None
  ; ttfrc_ms = None
  ; prefill_ms = None
  }

(* ------------------------------------------------------------------ *)
(* pricing_model_for_ledger                                            *)
(* ------------------------------------------------------------------ *)

(* A normal, non-aliased model id is returned verbatim regardless of
   what telemetry says — raw ground truth takes precedence. *)
let test_normal_model_returned_verbatim () =
  let tel = make_telemetry ~canonical_model_id:"openai:gpt-5.3-codex" () in
  let pm  = H.pricing_model_for_ledger
              ~model:"claude-sonnet-4-6" ~telemetry:(Some tel) in
  check string "non-auto model: verbatim" "claude-sonnet-4-6" pm

(* When the response model is the "auto" alias, the canonical id from
   telemetry is used for pricing — this is the primary fix for the
   33% mis-priced "auto" entries in costs.jsonl. *)
let test_auto_alias_resolved_via_telemetry () =
  let tel = make_telemetry ~canonical_model_id:"openai:gpt-5.3-codex" () in
  let pm  = H.pricing_model_for_ledger ~model:"auto" ~telemetry:(Some tel) in
  check string "auto + telemetry → canonical"
    "openai:gpt-5.3-codex" pm

(* Compound "provider:auto" aliases also resolve to canonical. *)
let test_provider_auto_alias_resolved () =
  let tel = make_telemetry ~canonical_model_id:"openai:gpt-5.3-codex" () in
  let pm  = H.pricing_model_for_ledger
              ~model:"openai:auto" ~telemetry:(Some tel) in
  check string "provider:auto + telemetry → canonical"
    "openai:gpt-5.3-codex" pm

(* When model is "auto" but telemetry has no canonical_model_id, the
   raw alias is returned (which will produce a pricing_catalog_miss —
   the observable signal that says "add telemetry propagation"). *)
let test_auto_without_telemetry_returns_raw () =
  let pm = H.pricing_model_for_ledger ~model:"auto" ~telemetry:None in
  check string "auto + no telemetry → raw alias" "auto" pm

(* Empty model falls back to telemetry canonical when available. *)
let test_empty_model_resolved_via_telemetry () =
  let tel = make_telemetry ~canonical_model_id:"anthropic:claude-opus-4-7" () in
  let pm  = H.pricing_model_for_ledger ~model:"" ~telemetry:(Some tel) in
  check string "empty model + telemetry → canonical"
    "anthropic:claude-opus-4-7" pm

(* Empty model, no telemetry → empty string trimmed to empty (will
   produce pricing_catalog_miss; not a silent incorrect zero). *)
let test_empty_model_no_telemetry_returns_empty () =
  let pm = H.pricing_model_for_ledger ~model:"" ~telemetry:None in
  check string "empty model + no telemetry → empty" "" pm

(* unknown_model_sentinel from [resolve_after_turn_model] also maps to
   telemetry canonical when available — sentinel is a marker, not a
   real model id. *)
let test_unknown_sentinel_resolved_via_telemetry () =
  let sentinel = H.unknown_model_sentinel in
  let tel = make_telemetry ~canonical_model_id:"openai:gpt-5-mini" () in
  let pm  = H.pricing_model_for_ledger
              ~model:sentinel ~telemetry:(Some tel) in
  check string "unknown_sentinel + telemetry → canonical"
    "openai:gpt-5-mini" pm

(* ------------------------------------------------------------------ *)
(* model_resolution_source_for_ledger                                  *)
(* ------------------------------------------------------------------ *)

let test_source_raw_when_model_unchanged () =
  let src = H.model_resolution_source_for_ledger
              ~model:"claude-sonnet-4-6"
              ~pricing_model:"claude-sonnet-4-6" in
  check string "same model → raw" "raw" src

let test_source_alias_when_auto_resolved () =
  let src = H.model_resolution_source_for_ledger
              ~model:"auto"
              ~pricing_model:"openai:gpt-5.3-codex" in
  check string "auto resolved → telemetry_canonical_alias"
    "telemetry_canonical_alias" src

let test_source_empty_when_empty_resolved () =
  let src = H.model_resolution_source_for_ledger
              ~model:""
              ~pricing_model:"anthropic:claude-opus-4-7" in
  check string "empty resolved → telemetry_canonical_empty"
    "telemetry_canonical_empty" src

let test_source_unknown_when_sentinel_resolved () =
  let src = H.model_resolution_source_for_ledger
              ~model:H.unknown_model_sentinel
              ~pricing_model:"openai:gpt-5-mini" in
  check string "sentinel resolved → telemetry_canonical_unknown"
    "telemetry_canonical_unknown" src

(* ------------------------------------------------------------------ *)
(* pricing_catalog_status                                              *)
(* ------------------------------------------------------------------ *)

let test_catalog_status_hit_paid () =
  let status = H.pricing_catalog_status ~pricing_model:"claude-sonnet-4-6" in
  check string "known paid model → hit_paid" "hit_paid" status

let test_catalog_status_hit_free () =
  (* ollama / local models are in the catalog as free ($0/M).
     Must be "hit_free", not "miss" — so operators can distinguish
     "legitimately free" from "not in catalog". *)
  let status = H.pricing_catalog_status
                 ~pricing_model:"qwen3.6:35b-a3b-mlx-bf16-64k" in
  check string "known free (ollama) model → hit_free" "hit_free" status

let test_catalog_status_miss () =
  let status = H.pricing_catalog_status
                 ~pricing_model:"catalog-probe-unknown-model-10318" in
  check string "unknown model → miss" "miss" status

let test_catalog_status_unresolved_for_auto_alias () =
  (* "auto" is not in the pricing catalog; once the pricing_model is
     "auto" (because telemetry was missing), the status must stay distinct
     from real catalog misses so the operator knows to fix telemetry
     propagation. *)
  let status = H.pricing_catalog_status ~pricing_model:"auto" in
  check string "auto alias → alias_unresolved" "alias_unresolved" status

let test_catalog_status_known_unpriced_codex_spark () =
  let status =
    H.pricing_catalog_status ~pricing_model:"gpt-5.3-codex-spark"
  in
  check string "codex spark preview → known_unpriced" "known_unpriced" status

(* ------------------------------------------------------------------ *)
(* cost_status_for_event                                               *)
(* ------------------------------------------------------------------ *)

let check_status ~msg ~provider ~pricing_model ~usage_missing
    ~usage_trusted ~input_tokens ~output_tokens ~cost_usd expected =
  let s = H.cost_status_for_event
            ~provider ~pricing_model ~usage_missing ~usage_trusted
            ~input_tokens ~output_tokens ~cost_usd in
  check string msg expected (H.cost_status_to_string s)

(* usage_missing gates everything else — the most actionable upstream
   failure (provider adapter didn't surface usage at all). *)
let test_status_usage_missing_wins () =
  check_status
    ~msg:"usage_missing: dominant"
    ~provider:"openai" ~pricing_model:"gpt-5-mini"
    ~usage_missing:true ~usage_trusted:false
    ~input_tokens:1000 ~output_tokens:500
    ~cost_usd:0.0
    "usage_missing"

(* usage_untrusted gates unmetered / provider_unknown / unpriced paths. *)
let test_status_usage_untrusted_wins () =
  check_status
    ~msg:"usage_untrusted: dominates over unmetered"
    ~provider:"ollama" ~pricing_model:"llama3"
    ~usage_missing:false ~usage_trusted:false
    ~input_tokens:100 ~output_tokens:50
    ~cost_usd:0.0
    "usage_untrusted"

(* Zero tokens on a trusted call before provider/catalog checks. *)
let test_status_no_tokens () =
  check_status
    ~msg:"no tokens → no_tokens"
    ~provider:"openai" ~pricing_model:"gpt-5-mini"
    ~usage_missing:false ~usage_trusted:true
    ~input_tokens:0 ~output_tokens:0
    ~cost_usd:0.0
    "no_tokens"

(* Trusted + positive cost → priced (the happy path). *)
let test_status_priced_when_positive_cost () =
  check_status
    ~msg:"trusted + cost > 0 → priced"
    ~provider:"openai" ~pricing_model:"gpt-5-mini"
    ~usage_missing:false ~usage_trusted:true
    ~input_tokens:1000 ~output_tokens:500
    ~cost_usd:0.01
    "priced"

(* Trusted + unmetered provider (ollama) + zero cost → known_free. *)
let test_status_known_free_for_unmetered () =
  check_status
    ~msg:"ollama + trusted + 0 cost → known_free"
    ~provider:"ollama" ~pricing_model:"llama3"
    ~usage_missing:false ~usage_trusted:true
    ~input_tokens:100 ~output_tokens:50
    ~cost_usd:0.0
    "known_free"

(* Trusted + tokens + provider "unknown" (no prefix, no telemetry). *)
let test_status_provider_unknown () =
  check_status
    ~msg:"provider=unknown → provider_unknown"
    ~provider:"unknown" ~pricing_model:"kimi-for-coding"
    ~usage_missing:false ~usage_trusted:true
    ~input_tokens:500 ~output_tokens:200
    ~cost_usd:0.0
    "provider_unknown"

(* Trusted + known paid provider + model not in catalog → unpriced_model.
   This is the dominant path for entries with model="kimi-for-coding"
   (403 entries in the original issue data) that had provider correctly
   identified as "glm-coding" but no pricing entry. *)
let test_status_unpriced_model () =
  check_status
    ~msg:"known provider + model not in catalog → unpriced_model"
    ~provider:"openai" ~pricing_model:"unpriced-probe-10318"
    ~usage_missing:false ~usage_trusted:true
    ~input_tokens:500 ~output_tokens:200
    ~cost_usd:0.0
    "unpriced_model"

let test_status_auto_alias_unresolved_model () =
  check_status
    ~msg:"known provider + auto alias → unresolved_model_alias"
    ~provider:"openai" ~pricing_model:"auto"
    ~usage_missing:false ~usage_trusted:true
    ~input_tokens:500 ~output_tokens:200
    ~cost_usd:0.0
    "unresolved_model_alias"

let test_status_known_unpriced_codex_spark () =
  check_status
    ~msg:"known provider + codex spark preview → known_unpriced_model"
    ~provider:"openai" ~pricing_model:"gpt-5.3-codex-spark"
    ~usage_missing:false ~usage_trusted:true
    ~input_tokens:500 ~output_tokens:200
    ~cost_usd:0.0
    "known_unpriced_model"

(* Trusted + known-paid provider + model in catalog + zero cost (despite
   tokens) → priced status because the catalog hit means we estimated
   and got a positive value (test with real model + real tokens).
   This tests the "priced" path even when cost_usd argument is >0. *)
let test_status_priced_path_with_real_model () =
  check_status
    ~msg:"real model + positive cost_usd → priced"
    ~provider:"anthropic" ~pricing_model:"claude-sonnet-4-6"
    ~usage_missing:false ~usage_trusted:true
    ~input_tokens:100_000 ~output_tokens:50_000
    ~cost_usd:1.05
    "priced"

(* known-free pricing entry for a paid provider model (e.g., a model
   that is in the catalog with zero pricing) produces known_free, not
   unpriced_model. This ensures the two zero-cost paths remain
   distinguishable. *)
let test_status_known_free_via_catalog () =
  (* qwen3.6:35b has $0/M pricing in the catalog → known_free *)
  check_status
    ~msg:"catalog-free model + zero cost → known_free"
    ~provider:"ollama" ~pricing_model:"qwen3.6:35b-a3b-mlx-bf16-64k"
    ~usage_missing:false ~usage_trusted:true
    ~input_tokens:100 ~output_tokens:50
    ~cost_usd:0.0
    "known_free"

(* ------------------------------------------------------------------ *)
(* cost_status_to_string / cost_status_reason round-trips             *)
(* ------------------------------------------------------------------ *)

(* Verify that [cost_status_to_string] + [cost_status_reason] never
   produce empty strings for any reachable variant, so JSONL rows
   are always self-describing. *)
let test_status_strings_non_empty () =
  let variants =
    [ H.Cost_reported_or_estimated
    ; H.Cost_known_free
    ; H.Cost_known_unpriced_model
    ; H.Cost_no_tokens
    ; H.Cost_usage_missing
    ; H.Cost_usage_untrusted
    ; H.Cost_provider_unknown
    ; H.Cost_unresolved_model_alias
    ; H.Cost_unpriced_model
    ]
  in
  List.iter (fun v ->
    let label = H.cost_status_to_string v in
    check bool (Printf.sprintf "%s: label non-empty" label)
      true (String.length label > 0);
    let reason = H.cost_status_reason v in
    check bool (Printf.sprintf "%s: reason non-empty" label)
      true (String.length reason > 0)
  ) variants

(* ------------------------------------------------------------------ *)
(* Test runner                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  run "cost_ledger_pricing_model_10318"
    [ ( "pricing_model_for_ledger",
        [ test_case "normal model verbatim"        `Quick test_normal_model_returned_verbatim
        ; test_case "auto resolved via telemetry"  `Quick test_auto_alias_resolved_via_telemetry
        ; test_case "provider:auto resolved"       `Quick test_provider_auto_alias_resolved
        ; test_case "auto without telemetry → raw" `Quick test_auto_without_telemetry_returns_raw
        ; test_case "empty model via telemetry"    `Quick test_empty_model_resolved_via_telemetry
        ; test_case "empty model no telemetry"     `Quick test_empty_model_no_telemetry_returns_empty
        ; test_case "unknown sentinel via telemetry" `Quick test_unknown_sentinel_resolved_via_telemetry
        ] )
    ; ( "model_resolution_source_for_ledger",
        [ test_case "raw when unchanged"           `Quick test_source_raw_when_model_unchanged
        ; test_case "alias when auto resolved"     `Quick test_source_alias_when_auto_resolved
        ; test_case "empty_resolved"               `Quick test_source_empty_when_empty_resolved
        ; test_case "unknown_sentinel resolved"    `Quick test_source_unknown_when_sentinel_resolved
        ] )
    ; ( "pricing_catalog_status",
        [ test_case "known paid → hit_paid"        `Quick test_catalog_status_hit_paid
        ; test_case "known free (ollama) → hit_free" `Quick test_catalog_status_hit_free
        ; test_case "unknown model → miss"         `Quick test_catalog_status_miss
        ; test_case "auto alias → alias_unresolved" `Quick test_catalog_status_unresolved_for_auto_alias
        ; test_case "codex spark preview → known_unpriced" `Quick test_catalog_status_known_unpriced_codex_spark
        ] )
    ; ( "cost_status_for_event",
        [ test_case "usage_missing wins"           `Quick test_status_usage_missing_wins
        ; test_case "usage_untrusted wins"         `Quick test_status_usage_untrusted_wins
        ; test_case "no tokens"                    `Quick test_status_no_tokens
        ; test_case "priced when positive cost"    `Quick test_status_priced_when_positive_cost
        ; test_case "known_free unmetered"         `Quick test_status_known_free_for_unmetered
        ; test_case "provider_unknown"             `Quick test_status_provider_unknown
        ; test_case "unpriced_model"               `Quick test_status_unpriced_model
        ; test_case "auto alias unresolved"        `Quick test_status_auto_alias_unresolved_model
        ; test_case "codex spark known unpriced"   `Quick test_status_known_unpriced_codex_spark
        ; test_case "priced real model"            `Quick test_status_priced_path_with_real_model
        ; test_case "known_free via catalog"       `Quick test_status_known_free_via_catalog
        ] )
    ; ( "cost_status_strings",
        [ test_case "all variants produce non-empty strings" `Quick
            test_status_strings_non_empty
        ] )
    ]
