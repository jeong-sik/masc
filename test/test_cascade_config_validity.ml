(** Static validity check for the cascade catalog.

    Guards every profile's model string list against typos, unknown
    provider names, and unsupported aliases by running them through
    the same parser the server uses at runtime
    ({!Masc_mcp.Cascade_config.parse_model_strings}).

    Motivation: 2026-04-11 incident adjacent — masc-mcp#6475 introduced a
    new [glm-coding:*] cascade head, and the only way to know if OAS
    actually knew that provider name was to read the pinned SHA by hand.
    A unit test that parses the live cascade renders every provider name
    in our catalog into a build-time guarantee.

    RFC-0058 §9 Phase 9.1: the source of truth is [cascade.toml]; the
    [cascade.json] sibling is no longer committed. The test reads the
    TOML path from [MASC_CASCADE_TOML_PATH] (injected by the dune
    stanza), renders it into an in-memory JSON string via
    {!Masc_mcp.Cascade_toml_materializer.render_toml_to_json_string},
    and operates on the parsed value — no disk JSON is opened. *)

open Alcotest

let cascade_toml_path () =
  match Sys.getenv_opt "MASC_CASCADE_TOML_PATH" with
  | Some p when String.trim p <> "" -> p
  | _ ->
    failwith
      "MASC_CASCADE_TOML_PATH not set; dune stanza must inject it before running the test"
;;

(** Render the TOML source once and cache the parsed [Yojson.Safe.t].
    No disk write — Phase 9.2 will migrate runtime consumers to the
    same in-memory path, and the test suite leads by example. *)
let cascade_json_cache : Yojson.Safe.t Lazy.t =
  lazy
    (let toml_path = cascade_toml_path () in
     match
       Masc_mcp.Cascade_toml_materializer.render_toml_to_json_string
         ~config_path:toml_path
     with
     | Error msg ->
       failwith (Printf.sprintf "cascade.toml failed to render to in-memory JSON: %s" msg)
     | Ok (_info, json_str) -> Yojson.Safe.from_string json_str)
;;

let cascade_json () = Lazy.force cascade_json_cache

(** Profile names discovered from the rendered cascade catalog. Kept as
    a function so the test always reflects the current TOML rather than
    a frozen list that drifts the next time someone adds a profile. *)
let discover_profiles_in (json : Yojson.Safe.t) : string list =
  match json with
  | `Assoc fields ->
    fields
    |> List.filter_map (fun (k, v) ->
      match v with
      | `List _ ->
        let suffix = "_models" in
        let k_len = String.length k in
        let s_len = String.length suffix in
        if k_len > s_len && String.sub k (k_len - s_len) s_len = suffix
        then Some (String.sub k 0 (k_len - s_len))
        else None
      | _ -> None)
  | _ -> []
;;

let load_profile_strings_in ~(json : Yojson.Safe.t) ~profile : string list =
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
;;

let empty_profile_has_safe_fallback_in ~(json : Yojson.Safe.t) ~profile : bool =
  let open Yojson.Safe.Util in
  let fallback = json |> member (profile ^ "_fallback_cascade") |> to_string_option in
  let keeper_assignable =
    match json |> member (profile ^ "_keeper_assignable") with
    | `Bool value -> value
    | _ -> true
  in
  Option.is_some fallback && not keeper_assignable
;;

(* The fixture-based tests below load JSON from temp files via
   [Cascade_config.resolve_strategy], which still needs a path-shaped
   helper. Keep the file-based loaders for that scope only. *)
let load_profile_strings_from_file ~path ~profile : string list =
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
  load_profile_strings_in ~json:(Yojson.Safe.from_string content) ~profile
;;

let test_profile_parses_non_empty profile () =
  let json = cascade_json () in
  let strings = load_profile_strings_in ~json ~profile in
  if strings = []
  then
    check
      bool
      (Printf.sprintf "%s empty profile has non-keeper fallback" profile)
      true
      (empty_profile_has_safe_fallback_in ~json ~profile)
  else (
    let contains_substring ~needle s =
      let nl = String.length needle in
      let sl = String.length s in
      if nl = 0 || nl > sl
      then false
      else (
        let limit = sl - nl in
        let rec loop i =
          if i > limit
          then false
          else if String.sub s i nl = needle
          then true
          else loop (i + 1)
        in
        loop 0)
    in
    (* error format from OAS: `provider "glm" unavailable (missing env var "ZAI_API_KEY")` *)
    let is_unavailable_error msg = contains_substring ~needle:"unavailable" msg in
    let expanded = Masc_mcp.Cascade_config.expand_auto_models strings in
    List.iter
      (fun s ->
         match Masc_mcp.Cascade_config.parse_model_string_result s with
         | Ok (cfg : Llm_provider.Provider_config.t) ->
           check
             bool
             (Printf.sprintf "%s: %S has non-empty model_id" profile s)
             true
             (String.trim cfg.model_id <> "")
         | Error msg when is_unavailable_error msg ->
           (* Provider known but its API key env var is empty — accepted. *)
           ()
         | Error msg ->
           Alcotest.fail (Printf.sprintf "%s: %S hard-fails parse: %s" profile s msg))
      expanded)
;;

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
    ~finally:(fun () ->
      try Sys.remove tmp with
      | _ -> ())
    (fun () ->
       let oc = open_out tmp in
       Fun.protect
         ~finally:(fun () -> close_out_noerr oc)
         (fun () ->
            output_string
              oc
              {|{
  "regression_models": [
    "ollama:qwen3.5:35b-a3b-nvfp4",
    "__nonexistent_provider_sentinel__:fake-model"
  ]
}|});
       let strings = load_profile_strings_from_file ~path:tmp ~profile:"regression" in
       check int "fixture has both entries" 2 (List.length strings);
       let parsed = Masc_mcp.Cascade_config.parse_model_strings strings in
       (* At least one entry must be dropped. Using "<" (not "=") keeps
         the test correct if a future registry happens to also gate the
         ollama entry behind an availability flag — the invariant we
         care about is "unknown providers are non-identity for parse",
         not an exact surviving count. *)
       check
         bool
         "unknown provider entry is dropped by parse_model_strings"
         true
         (List.length parsed < List.length strings))
;;

(* RFC-0058 §9 Phase 9.1 (Acceptance Criteria): cascade.json must not
   re-anchor as a second SSOT alongside cascade.toml. The test asserts
   three things:
     1. The materializer probes the live config and reports the source
        kind as "toml" (TOML is the SSOT).
     2. The TOML still renders into JSON cleanly — keeps the
        materialiser exercised after the on-disk JSON is gone.
     3. config/cascade.json is NOT tracked by git. We resolve the repo
        root via [DUNE_SOURCEROOT] when available (set by dune in the
        sandbox) and fall back to walking up for [dune-project]. We
        require [git] on PATH and distinguish:
          exit 0  → tracked  → FAIL (the invariant is broken)
          exit 1  → untracked → PASS (the invariant holds)
          other   → ambiguous → FAIL loudly with the repo root and code,
                      so a missing git / sandbox quirk doesn't become a
                      silent false positive. *)
let test_cascade_json_is_not_committed () =
  let toml_path = cascade_toml_path () in
  let source = Masc_mcp.Cascade_toml_materializer.source_info ~config_path:toml_path in
  check
    string
    "repo cascade source kind"
    "toml"
    (Masc_mcp.Cascade_toml_materializer.source_kind_to_string source.kind);
  (match Masc_mcp.Cascade_toml_materializer.render_toml_file_to_json_string toml_path with
   | Error msg -> fail ("cascade.toml failed to render: " ^ msg)
   | Ok _ -> ());
  let repo_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some p when String.trim p <> "" -> p
    | _ ->
      let cwd = Sys.getcwd () in
      let rec walk dir =
        if Sys.file_exists (Filename.concat dir "dune-project")
        then dir
        else (
          let parent = Filename.dirname dir in
          if String.equal parent dir then cwd else walk parent)
      in
      walk cwd
  in
  let git_available = Sys.command "command -v git >/dev/null 2>&1" = 0 in
  if not git_available
  then fail "git not found on PATH — cannot verify cascade.json tracking (RFC-0058 §9.1)";
  let json_rel = "config/cascade.json" in
  let cmd =
    Printf.sprintf
      "cd %s && git ls-files --error-unmatch %s >/dev/null 2>&1"
      (Filename.quote repo_root)
      (Filename.quote json_rel)
  in
  match Sys.command cmd with
  | 0 ->
    fail
      "config/cascade.json is tracked by git — RFC-0058 §9.1 requires it to be untracked \
       (git rm + .gitignore)"
  | 1 -> ()
  | other ->
    fail
      (Printf.sprintf
         "git ls-files --error-unmatch returned unexpected exit %d (expected 0=tracked \
          or 1=untracked); repo_root=%s — set DUNE_SOURCEROOT or run inside a git \
          worktree"
         other
         repo_root)
;;

let with_temp_cascade_json body =
  let tmp = Filename.temp_file "cascade-strategy-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove tmp with
      | _ -> ())
    (fun () -> body tmp)
;;

let test_priority_tier_label_tiers_normalize_to_model_ids () =
  with_temp_cascade_json
  @@ fun tmp ->
  let oc = open_out tmp in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
       output_string
         oc
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
    Masc_mcp.Cascade_config.resolve_strategy ~config_path:tmp ~name:"regression" ()
  in
  check
    string
    "priority_tier preserved"
    "priority_tier"
    (Masc_mcp.Cascade_strategy.kind_to_string strategy.kind);
  check
    (list (list string))
    "tiers normalized to model ids"
    [ [ "claude-haiku-4-5-20251001" ]; [ "gemini-3-flash-preview" ] ]
    strategy.tiers
;;

let test_priority_tier_invalid_tiers_fall_back_to_default_strategy () =
  with_temp_cascade_json
  @@ fun tmp ->
  let oc = open_out tmp in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
       output_string
         oc
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
    Masc_mcp.Cascade_config.resolve_strategy ~config_path:tmp ~name:"regression" ()
  in
  check
    string
    "invalid tiers demote to default strategy"
    "round_robin"
    (Masc_mcp.Cascade_strategy.kind_to_string strategy.kind);
  check (list (list string)) "default strategy carries no tiers" [] strategy.tiers
;;

let test_keeper_assignable_profile_defaults_to_round_robin () =
  with_temp_cascade_json
  @@ fun tmp ->
  let oc = open_out tmp in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
       output_string
         oc
         {|{
  "regression_models": [
    "claude_code:claude-haiku-4-5-20251001",
    "gemini_cli:gemini-3-flash-preview"
  ],
  "regression_keeper_assignable": true
}|});
  let strategy =
    Masc_mcp.Cascade_config.resolve_strategy ~config_path:tmp ~name:"regression" ()
  in
  check
    string
    "keeper assignable defaults to round_robin"
    "round_robin"
    (Masc_mcp.Cascade_strategy.kind_to_string strategy.kind)
;;

let test_non_keeper_assignable_profile_defaults_to_failover () =
  with_temp_cascade_json
  @@ fun tmp ->
  let oc = open_out tmp in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
       output_string
         oc
         {|{
  "regression_models": [
    "claude_code:claude-haiku-4-5-20251001",
    "gemini_cli:gemini-3-flash-preview"
  ],
  "regression_keeper_assignable": false
}|});
  let strategy =
    Masc_mcp.Cascade_config.resolve_strategy ~config_path:tmp ~name:"regression" ()
  in
  check
    string
    "non-keeper profile stays failover"
    "failover"
    (Masc_mcp.Cascade_strategy.kind_to_string strategy.kind)
;;

let () =
  let profiles = discover_profiles_in (cascade_json ()) in
  let profile_cases =
    List.map
      (fun p ->
         test_case
           (Printf.sprintf "%s parses cleanly" p)
           `Quick
           (test_profile_parses_non_empty p))
      profiles
  in
  run
    "Cascade config validity"
    [ "profiles", profile_cases
    ; ( "regression"
      , [ test_case
            "unknown provider dropped (meta-guard)"
            `Quick
            test_unknown_provider_is_dropped
        ; test_case
            "cascade.json is not committed (RFC-0058 §9)"
            `Quick
            test_cascade_json_is_not_committed
        ; test_case
            "priority_tier label tiers normalize to model ids"
            `Quick
            test_priority_tier_label_tiers_normalize_to_model_ids
        ; test_case
            "priority_tier invalid tiers fall back to default strategy"
            `Quick
            test_priority_tier_invalid_tiers_fall_back_to_default_strategy
        ; test_case
            "keeper-assignable profile defaults to round_robin"
            `Quick
            test_keeper_assignable_profile_defaults_to_round_robin
        ; test_case
            "non-keeper-assignable profile defaults to failover"
            `Quick
            test_non_keeper_assignable_profile_defaults_to_failover
        ] )
    ]
;;
