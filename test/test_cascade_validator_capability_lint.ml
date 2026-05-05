(** RFC-0027 PR-3: cascade_catalog_validator capability lint.

    Verifies that when a cascade declares
    [_required_capability_profile] in cascade.json, the validator
    flags model entries that fail
    {!Cascade_capability_profile.provider_satisfies_profile}, gated
    by the [MASC_CAPABILITY_LINT] env variable. *)

open Alcotest

module Validator = Masc_mcp.Cascade_catalog_validator

let with_temp_json contents f =
  let dir = Filename.temp_file "cascade-cap-lint-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let path = Filename.concat dir "cascade.json" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f path)

(* sangsu_models contains gemini_cli (no HTTP headers) but cascade
   demands [tool_strict] which requires http_headers — must flag. *)
let mismatch_json =
  {|{"sangsu_models": [
        {"model": "gemini_cli:gemini-3-flash-preview", "weight": 1}
      ],
      "sangsu_required_capability_profile": "tool_strict"}|}

(* Same model with [lite] profile -> satisfied (gemini_cli has runtime
   MCP, just no HTTP headers, which lite does not require). *)
let satisfied_json =
  {|{"sangsu_models": [
        {"model": "gemini_cli:gemini-3-flash-preview", "weight": 1}
      ],
      "sangsu_required_capability_profile": "lite"}|}

(* Profile field omitted -> no capability lint at all (legacy). *)
let no_profile_json =
  {|{"sangsu_models": [
        {"model": "gemini_cli:gemini-3-flash-preview", "weight": 1}
      ]}|}

let with_env name value f =
  let prior = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let count_capability_issues issues =
  List.length
    (List.filter
       (fun (i : Validator.issue) ->
         (* match on message text — capability lint emits a stable prefix *)
         match i.message with
         | s when String.length s >= 23
                  && String.sub s 0 23 = "Cascade preset sangsu d" ->
             true
         | _ -> false)
       issues)

let test_warn_default_flags_mismatch () =
  with_temp_json mismatch_json @@ fun path ->
  with_env "MASC_CAPABILITY_LINT" "" @@ fun () ->
  let issues = Validator.diagnose_catalog ~config_path:path in
  let cap = count_capability_issues issues in
  check int "default warn surfaces 1 capability issue" 1 cap;
  let issue =
    List.find
      (fun (i : Validator.issue) ->
        i.profile = Some "sangsu" && count_capability_issues [ i ] = 1)
      issues
  in
  check bool "default severity is warn" true
    (issue.severity = Validator.Catalog_warn)

let test_off_silences_lint () =
  with_temp_json mismatch_json @@ fun path ->
  with_env "MASC_CAPABILITY_LINT" "off" @@ fun () ->
  let issues = Validator.diagnose_catalog ~config_path:path in
  check int "off mode emits 0 capability issues" 0
    (count_capability_issues issues)

let test_error_mode_promotes_severity () =
  with_temp_json mismatch_json @@ fun path ->
  with_env "MASC_CAPABILITY_LINT" "error" @@ fun () ->
  let issues = Validator.diagnose_catalog ~config_path:path in
  let cap = count_capability_issues issues in
  check int "error mode still surfaces 1 capability issue" 1 cap;
  let issue =
    List.find
      (fun (i : Validator.issue) ->
        i.profile = Some "sangsu" && count_capability_issues [ i ] = 1)
      issues
  in
  check bool "error severity is Catalog_error" true
    (issue.severity = Validator.Catalog_error)

let test_satisfied_profile_no_issues () =
  with_temp_json satisfied_json @@ fun path ->
  with_env "MASC_CAPABILITY_LINT" "warn" @@ fun () ->
  let issues = Validator.diagnose_catalog ~config_path:path in
  check int "lite satisfied -> 0 capability issues" 0
    (count_capability_issues issues)

let test_no_profile_field_no_lint () =
  with_temp_json no_profile_json @@ fun path ->
  with_env "MASC_CAPABILITY_LINT" "error" @@ fun () ->
  (* Even with error mode, omitted field means no lint. *)
  let issues = Validator.diagnose_catalog ~config_path:path in
  check int "no required_capability_profile -> 0 capability issues" 0
    (count_capability_issues issues)

let () =
  run "Cascade_validator_capability_lint"
    [
      ( "warn default behavior",
        [
          test_case "mismatch surfaces warn-severity issue" `Quick
            test_warn_default_flags_mismatch;
        ] );
      ( "lint mode toggles",
        [
          test_case "off mode silences entirely" `Quick test_off_silences_lint;
          test_case "error mode promotes severity" `Quick
            test_error_mode_promotes_severity;
        ] );
      ( "no false positives",
        [
          test_case "satisfied profile -> no issue" `Quick
            test_satisfied_profile_no_issues;
          test_case "omitted field -> no issue" `Quick
            test_no_profile_field_no_lint;
        ] );
    ]
