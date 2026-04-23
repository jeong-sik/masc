(** Static validity check for config/cascade.json.

    Guards every profile's model string list against typos, unknown
    provider names, and unsupported aliases by running them through
    the same parser the server uses at runtime
    ({!Masc_mcp.Cascade_config.parse_model_strings}).

    Motivation: 2026-04-11 incident adjacent — masc-mcp#6475 introduced a
    new [glm-coding:*] cascade head, and the only way to know if OAS
    actually knew that provider name was to read the pinned SHA by hand.
    A unit test that parses the live cascade.json turns "the pinned OAS
    understands every provider name in our cascade" from a manual audit
    into a build-time guarantee.

    The path to cascade.json is injected via the [MASC_CASCADE_JSON_PATH]
    env var set in the dune stanza — no hardcoded path in the test body.
    Profile keys follow cascade.json convention: each entry is named
    [<profile>_models] in the JSON. *)

open Alcotest

let cascade_path () =
  match Sys.getenv_opt "MASC_CASCADE_JSON_PATH" with
  | Some p when String.trim p <> "" -> p
  | _ ->
    failwith
      "MASC_CASCADE_JSON_PATH not set; dune stanza must inject it \
       before running the test"

(** Profile names discovered from cascade.json. Kept as a function so
    the test can always reflect the current on-disk file rather than a
    frozen list that drifts the next time someone adds a profile. *)
let discover_profiles path : string list =
  let ic = open_in path in
  let content =
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let len = in_channel_length ic in
        let buf = Bytes.create len in
        really_input ic buf 0 len;
        Bytes.to_string buf)
  in
  let json = Yojson.Safe.from_string content in
  match json with
  | `Assoc fields ->
    fields
    |> List.filter_map (fun (k, v) ->
           match v with
           | `List _ ->
             let suffix = "_models" in
             let k_len = String.length k in
             let s_len = String.length suffix in
             if k_len > s_len
                && String.sub k (k_len - s_len) s_len = suffix
             then Some (String.sub k 0 (k_len - s_len))
             else None
           | _ -> None)
  | _ -> []

let load_profile_strings ~path ~profile : string list =
  let ic = open_in path in
  let content =
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let len = in_channel_length ic in
        let buf = Bytes.create len in
        really_input ic buf 0 len;
        Bytes.to_string buf)
  in
  let json = Yojson.Safe.from_string content in
  let open Yojson.Safe.Util in
  let key = profile ^ "_models" in
  match json |> member key with
  | `List items ->
    List.filter_map
      (function
        | `String s -> Some (String.trim s)
        | `Assoc _ as obj ->
          (* Weighted entry: {"model": "provider:id", "weight": N} *)
          (match obj |> member "model" with
           | `String s when String.trim s <> "" -> Some (String.trim s)
           | _ -> None)
        | _ -> None)
      items
  | _ -> []

let test_profile_parses_non_empty profile () =
  let path = cascade_path () in
  let strings = load_profile_strings ~path ~profile in
  check bool
    (Printf.sprintf "%s has entries" profile)
    true
    (strings <> []);
  (* Use parse_model_string_result per entry so we can distinguish
     "unknown provider / invalid spec" (hard failure — real typo) from
     "provider unavailable" (soft — just means the API key env var is
     unset in this test run). The former must fail the test; the latter
     is acceptable because this static check never calls the API. *)
  let contains_substring ~needle s =
    let nl = String.length needle in
    let sl = String.length s in
    if nl = 0 || nl > sl then false
    else
      let limit = sl - nl in
      let rec loop i =
        if i > limit then false
        else if String.sub s i nl = needle then true
        else loop (i + 1)
      in
      loop 0
  in
  (* error format from OAS: `provider "glm" unavailable (missing env var "ZAI_API_KEY")` *)
  let is_unavailable_error msg =
    contains_substring ~needle:"unavailable" msg
  in
  let expanded =
    Masc_mcp.Cascade_config.expand_auto_models strings
  in
  List.iter
    (fun s ->
      match Masc_mcp.Cascade_config.parse_model_string_result s with
      | Ok (cfg : Llm_provider.Provider_config.t) ->
        check bool
          (Printf.sprintf "%s: %S has non-empty model_id" profile s)
          true
          (String.trim cfg.model_id <> "")
      | Error msg when is_unavailable_error msg ->
        (* Provider known but its API key env var is empty — accepted. *)
        ()
      | Error msg ->
        Alcotest.fail
          (Printf.sprintf "%s: %S hard-fails parse: %s" profile s msg))
    expanded

(** Meta / regression guard: prove that the happy-path assertion in
    [test_profile_parses_non_empty] is NOT vacuous.

    The happy-path test asserts
      [List.length parsed = List.length strings]
    which would trivially pass if OAS [parse_model_strings] silently
    accepted every string (even known-bad provider names). This negative
    fixture feeds [parse_model_strings] a two-element profile where one
    entry uses a deliberately unknown provider name that cannot collide
    with any real registry entry. We assert the parser drops it — i.e.
    [List.length parsed < List.length strings]. If this ever becomes
    equal, the happy-path guarantee is broken and both tests will fire
    loudly. *)
let test_unknown_provider_is_dropped () =
  let tmp = Filename.temp_file "cascade-negative-" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove tmp with _ -> ())
    (fun () ->
      let oc = open_out tmp in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          output_string oc
            {|{
  "regression_models": [
    "ollama:qwen3.5:35b-a3b-nvfp4",
    "__nonexistent_provider_sentinel__:fake-model"
  ]
}|});
      let strings =
        load_profile_strings ~path:tmp ~profile:"regression"
      in
      check int "fixture has both entries" 2 (List.length strings);
      let parsed =
        Masc_mcp.Cascade_config.parse_model_strings strings
      in
      (* At least one entry must be dropped. Using "<" (not "=") keeps
         the test correct if a future registry happens to also gate the
         ollama entry behind an availability flag — the invariant we
         care about is "unknown providers are non-identity for parse",
         not an exact surviving count. *)
      check bool
        "unknown provider entry is dropped by parse_model_strings"
        true
        (List.length parsed < List.length strings))

let with_temp_cascade_json body =
  let tmp = Filename.temp_file "cascade-strategy-" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove tmp with _ -> ())
    (fun () -> body tmp)

let test_priority_tier_label_tiers_normalize_to_model_ids () =
  with_temp_cascade_json @@ fun tmp ->
  let oc = open_out tmp in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc
        {|{
  "regression_models": [
    "claude_code:claude-haiku-4-5-20251001",
    "gemini_cli:gemini-3-flash-preview"
  ],
  "regression_strategy": "priority_tier",
  "regression_tiers": [
    ["claude_code:claude-haiku-4-5-20251001"],
    ["gemini_cli:gemini-3-flash-preview"]
  ]
}|});
  let strategy =
    Masc_mcp.Cascade_config.resolve_strategy
      ~config_path:tmp ~name:"regression" ()
  in
  check string "priority_tier preserved"
    "priority_tier"
    (Masc_mcp.Cascade_strategy.kind_to_string strategy.kind);
  check (list (list string)) "tiers normalized to model ids"
    [ [ "claude-haiku-4-5-20251001" ]; [ "gemini-3-flash-preview" ] ]
    strategy.tiers

let test_priority_tier_invalid_tiers_fall_back_to_failover () =
  with_temp_cascade_json @@ fun tmp ->
  let oc = open_out tmp in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc
        {|{
  "regression_models": [
    "claude_code:claude-haiku-4-5-20251001"
  ],
  "regression_strategy": "priority_tier",
  "regression_tiers": [
    ["codex_cli:auto"]
  ]
}|});
  let strategy =
    Masc_mcp.Cascade_config.resolve_strategy
      ~config_path:tmp ~name:"regression" ()
  in
  check string "invalid tiers demote to failover"
    "failover"
    (Masc_mcp.Cascade_strategy.kind_to_string strategy.kind);
  check (list (list string)) "failover carries no tiers" [] strategy.tiers

let () =
  let path = cascade_path () in
  let profiles = discover_profiles path in
  let profile_cases =
    List.map
      (fun p ->
        test_case
          (Printf.sprintf "%s parses cleanly" p)
          `Quick
          (test_profile_parses_non_empty p))
      profiles
  in
  run "Cascade config validity"
    [
      "profiles", profile_cases;
      ( "regression",
        [
          test_case
            "unknown provider dropped (meta-guard)"
            `Quick
            test_unknown_provider_is_dropped;
          test_case
            "priority_tier label tiers normalize to model ids"
            `Quick
            test_priority_tier_label_tiers_normalize_to_model_ids;
          test_case
            "priority_tier invalid tiers fall back to failover"
            `Quick
            test_priority_tier_invalid_tiers_fall_back_to_failover;
        ] );
    ]
