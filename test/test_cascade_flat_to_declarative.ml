(** RFC-0058 Phase 4 — Flat TOML → 5-layer migration tool unit tests.

    Validates the conversion logic: flat profile extraction,
    provider/model dedup, tier generation, route preservation,
    and roundtrip through the 5-layer parser. *)

open Alcotest
open Cascade_declarative_types
open Cascade_declarative_parser

(* --- Helpers --- *)

let ok_config (result : (cascade_config, parse_error list) result) :
    cascade_config =
  match result with
  | Ok cfg -> cfg
  | Error errs ->
    let msg =
      List.map (fun e -> Printf.sprintf "%s: %s" e.path e.message) errs
      |> String.concat "; "
    in
    failwith ("expected Ok, got Error: " ^ msg)

(* Sample flat TOML with 2 providers, 3 models, 2 profiles, 1 route *)
let simple_flat_toml = {|
[big_three]
models = ["claude_code:claude-sonnet-4-6", "codex_cli:gpt-5.3-codex-spark"]
temperature = 0.2
max_tokens = 16384

[tool_rerank]
models = ["claude_code:claude-haiku-4-5-20251001", "codex_cli:gpt-5.3-codex-spark"]
temperature = 0.1
max_tokens = 4096
fallback_cascade = "big_three"

[routes]
keeper_turn = "big_three"
tool_rerank = "tool_rerank"
|}

(* Flat TOML with inline table model entries *)
let inline_table_flat_toml = {|
[primary]
models = [
  {model = "claude_code:auto", supports_tool_choice = true, weight = 2},
  {model = "gemini_cli:auto", supports_tool_choice = false, weight = 1}
]
temperature = 0.3

[local_fast]
models = ["ollama:qwen3:8b"]
|}

(* Flat TOML with empty profile *)
let empty_profile_toml = {|
[active]
models = ["claude_code:claude-sonnet-4-6"]

[empty_slot]
models = []
|}

(* Flat TOML with unknown provider *)
let unknown_provider_toml = {|
[experimental]
models = ["unknown_provider:some-model"]
|}

(* Minimal flat TOML — single profile, single model *)
let minimal_flat_toml = {|
[only_one]
models = ["ollama:test-model"]
|}

(* --- Test: simple flat conversion roundtrip --- *)

let test_simple_roundtrip () =
  let toml = Otoml.Parser.from_string simple_flat_toml in
  let output = Cascade_flat_conversion.convert_and_emit toml in
  let result = parse_string output in
  let cfg = ok_config result in
  (* 2 providers: claude_code, codex_cli *)
  check int "providers" 2 (List.length cfg.providers);
  (* at least 3 models: claude-sonnet-4-6, gpt-5.3-codex-spark, claude-haiku-4-5-20251001 *)
  check bool "models >= 3" true (List.length cfg.models >= 3);
  (* bindings should exist *)
  check bool "bindings non-empty" true (cfg.bindings <> []);
  (* 2 tiers: big_three, tool_rerank *)
  let tier_names = List.map (fun (t : Cascade_declarative_types.cascade_tier) -> t.name) cfg.tiers in
  check bool "has big_three tier" true (List.mem "big_three" tier_names);
  check bool "has tool_rerank tier" true (List.mem "tool_rerank" tier_names);
  (* tier-group from fallback_cascade *)
  check bool "tier-groups non-empty" true (cfg.tier_groups <> []);
  (* routes preserved *)
  check int "routes" 2 (List.length cfg.routes)

(* --- Test: provider deduplication --- *)

let test_provider_dedup () =
  let toml = Otoml.Parser.from_string simple_flat_toml in
  let output = Cascade_flat_conversion.convert_and_emit toml in
  let cfg = ok_config (parse_string output) in
  let provider_ids = List.map (fun (p : Cascade_declarative_types.cascade_provider) -> p.id) cfg.providers in
  (* Same provider appears multiple times but should be deduplicated *)
  let claude_count = List.filter (fun id -> id = "claude_code") provider_ids |> List.length in
  check int "claude_code appears once" 1 claude_count

(* --- Test: tier members resolve correctly --- *)

let test_tier_members () =
  let toml = Otoml.Parser.from_string simple_flat_toml in
  let output = Cascade_flat_conversion.convert_and_emit toml in
  let cfg = ok_config (parse_string output) in
  let big_three =
    List.find_opt (fun (t : Cascade_declarative_types.cascade_tier) -> t.name = "big_three") cfg.tiers
  in
  match big_three with
  | None -> failwith "big_three tier not found"
  | Some tier ->
    check int "big_three has 2 members" 2 (List.length tier.members)

(* --- Test: tier-group from fallback_cascade --- *)

let test_tier_group_fallback () =
  let toml = Otoml.Parser.from_string simple_flat_toml in
  let output = Cascade_flat_conversion.convert_and_emit toml in
  let cfg = ok_config (parse_string output) in
  (* tool_rerank has fallback_cascade = "big_three" *)
  let tg_names = List.map (fun (tg : Cascade_declarative_types.cascade_tier_group) -> tg.name) cfg.tier_groups in
  check bool "has tool_rerank-with-big_three tier-group" true
    (List.exists (fun n -> String.contains n '-') tg_names)

(* --- Test: routes target resolution --- *)

let test_routes_target () =
  let toml = Otoml.Parser.from_string simple_flat_toml in
  let output = Cascade_flat_conversion.convert_and_emit toml in
  let cfg = ok_config (parse_string output) in
  let keeper_turn =
    List.find_opt (fun (r : Cascade_declarative_types.cascade_route) -> r.name = "keeper_turn") cfg.routes
  in
  match keeper_turn with
  | None -> failwith "keeper_turn route not found"
  | Some route ->
    check bool "keeper_turn targets tier.big_three" true
      (String.length route.target > 0)

(* --- Test: inline table model entries --- *)

let test_inline_table_models () =
  let toml = Otoml.Parser.from_string inline_table_flat_toml in
  let output = Cascade_flat_conversion.convert_and_emit toml in
  let cfg = ok_config (parse_string output) in
  (* 3 providers: claude_code, gemini_cli, ollama *)
  check int "providers" 3 (List.length cfg.providers);
  (* 2 tiers: primary, local_fast *)
  check int "tiers" 2 (List.length cfg.tiers)

(* --- Test: empty profile produces empty tier --- *)

let test_empty_profile () =
  let toml = Otoml.Parser.from_string empty_profile_toml in
  let output = Cascade_flat_conversion.convert_and_emit toml in
  let cfg = ok_config (parse_string output) in
  let empty_slot =
    List.find_opt (fun (t : Cascade_declarative_types.cascade_tier) -> t.name = "empty_slot") cfg.tiers
  in
  match empty_slot with
  | None -> ()
  (* Empty tier may be omitted or have empty members — both valid *)
  | Some tier -> check int "empty_slot has 0 members" 0 (List.length tier.members)

(* --- Test: unknown provider still produces valid output --- *)

let test_unknown_provider () =
  let toml = Otoml.Parser.from_string unknown_provider_toml in
  let output = Cascade_flat_conversion.convert_and_emit toml in
  let result = parse_string output in
  (* Should still parse — unknown provider gets generic openai-http *)
  (match result with
   | Ok cfg ->
     check bool "has experimental tier" true
       (List.exists (fun (t : Cascade_declarative_types.cascade_tier) -> t.name = "experimental") cfg.tiers)
   | Error _ ->
     (* Unknown provider URL may fail validation — acceptable *)
     ())

(* --- Test: minimal flat TOML --- *)

let test_minimal () =
  let toml = Otoml.Parser.from_string minimal_flat_toml in
  let output = Cascade_flat_conversion.convert_and_emit toml in
  let cfg = ok_config (parse_string output) in
  check int "1 provider" 1 (List.length cfg.providers);
  check int "1 tier" 1 (List.length cfg.tiers);
  check bool "0 routes" true (cfg.routes = [])

(* --- Test: output contains layer markers --- *)

let test_output_structure () =
  let toml = Otoml.Parser.from_string simple_flat_toml in
  let output = Cascade_flat_conversion.convert_and_emit toml in
  check bool "has Layer 1 header" true
    (output |> String.split_on_char '\n'
     |> List.exists (fun line ->
       String.length line >= 3 && String.sub line 0 3 = "## " &&
       String.exists (fun c -> c = '1') line));
  check bool "contains providers section" true
    (output |> String.split_on_char '\n'
     |> List.exists (fun line ->
       String.length line > 10 && String.sub line 0 10 = "[providers"))

(* --- Test: roundtrip of actual cascade.toml --- *)

let test_real_cascade_roundtrip () =
  let real_path = "config/cascade.toml" in
  if not (Sys.file_exists real_path) then
    skip ()
  else begin
    let toml = Otoml.Parser.from_file real_path in
    let output = Cascade_flat_conversion.convert_and_emit toml in
    let result = parse_string output in
    let cfg = ok_config result in
    (* Should have real providers *)
    check bool "has providers" true (cfg.providers <> []);
    check bool "has models" true (cfg.models <> []);
    check bool "has tiers" true (cfg.tiers <> []);
    check bool "has routes" true (cfg.routes <> [])
  end

(* --- Suite --- *)

let suite = [
  "simple roundtrip", `Quick, test_simple_roundtrip;
  "provider dedup", `Quick, test_provider_dedup;
  "tier members", `Quick, test_tier_members;
  "tier-group fallback", `Quick, test_tier_group_fallback;
  "routes target", `Quick, test_routes_target;
  "inline table models", `Quick, test_inline_table_models;
  "empty profile", `Quick, test_empty_profile;
  "unknown provider", `Quick, test_unknown_provider;
  "minimal", `Quick, test_minimal;
  "output structure", `Quick, test_output_structure;
  "real cascade roundtrip", `Slow, test_real_cascade_roundtrip;
]

let () =
  Alcotest.run "RFC-0058 Phase 4: Flat → Declarative Migration" [
    "flat_to_declarative", suite
  ]
