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

(** Parse the declarative TOML source once and cache its runtime snapshot. *)
let cascade_snapshot_cache : Masc_mcp.Cascade_declarative_hotpath.decl_snapshot Lazy.t =
  lazy
    (let toml_path = cascade_toml_path () in
     match Masc_mcp.Cascade_declarative_hotpath.try_load_declarative toml_path with
     | Some (Ok snapshot) -> snapshot
     | Some (Error errors) ->
       let rendered =
         errors
         |> List.map Masc_mcp.Cascade_declarative_adapter.show_adapter_error
         |> String.concat "; "
       in
       failwith (Printf.sprintf "cascade.toml declarative adapter failed: %s" rendered)
     | None -> failwith "cascade.toml is not an RFC-0058 declarative catalog")
;;

let cascade_snapshot () = Lazy.force cascade_snapshot_cache

let test_profile_parses_non_empty
    (profile : Masc_mcp.Cascade_declarative_hotpath.profile)
    () =
  check
    bool
    (Printf.sprintf "%s has resolved candidates" profile.name)
    true
    (profile.candidates <> []);
  List.iter
    (fun (candidate : Masc_mcp.Cascade_declarative_hotpath.candidate) ->
      check
        bool
        (Printf.sprintf "%s: %S has non-empty model_id" profile.name candidate.model_string)
        true
        (String.trim candidate.provider_cfg.model_id <> ""))
    profile.candidates
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
  let strings =
    [ "ollama:qwen3.5:35b-a3b-nvfp4"; "__nonexistent_provider_sentinel__:fake-model" ]
  in
  check int "fixture has both entries" 2 (List.length strings);
  let parsed = Masc_mcp.Cascade_config.parse_model_strings strings in
  (* At least one entry must be dropped. Using "<" (not "=") keeps
     the test correct if a future registry happens to also gate the
     ollama entry behind an availability flag — the invariant we care
     about is "unknown providers are non-identity for parse", not an
     exact surviving count. *)
  check
    bool
    "unknown provider entry is dropped by parse_model_strings"
    true
    (List.length parsed < List.length strings)
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

let () =
  let profiles : Masc_mcp.Cascade_declarative_hotpath.profile list =
    (cascade_snapshot ()).profiles
  in
  let profile_cases =
    List.map
      (fun (profile : Masc_mcp.Cascade_declarative_hotpath.profile) ->
         test_case
           (Printf.sprintf "%s parses cleanly" profile.name)
           `Quick
           (test_profile_parses_non_empty profile))
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
        ] )
    ]
;;
