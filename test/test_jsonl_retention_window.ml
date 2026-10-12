(** One retention window decides which JSONL day files get deleted.

    Two readers act on it: the startup prune and the periodic maintenance
    prune. They used to spell [MASC_JSONL_RETENTION_DAYS] and its default
    separately, so a default changed in one place would have let one prune
    delete files the other still expected to keep.

    They now share {!Server_maintenance_toml_config.resolve_retention_days}:
    process env, then runtime.toml [maintenance], then the documented
    default. This suite pins the getter's contract (the documented default,
    an honoured override, malformed input falling back instead of
    overriding) and the TOML table's contract (absent means default,
    unknown keys and bad values fail the table, never guess). *)

open Alcotest

module Maintenance = Server_maintenance_toml_config

let env_name = "MASC_JSONL_RETENTION_DAYS"

(* The value the .mli documents as the default. Spelled here rather than read
   back from the module so a changed default fails this suite instead of
   passing through it. *)
let documented_default = 30

let with_env value f =
  let prev = Sys.getenv_opt env_name in
  (match value with Some v -> Unix.putenv env_name v | None -> Unix.putenv env_name "");
  Fun.protect
    ~finally:(fun () ->
      match prev with Some v -> Unix.putenv env_name v | None -> Unix.putenv env_name "")
    f

let test_unset_yields_the_documented_default () =
  with_env None @@ fun () ->
  check int "unset falls back to the documented default" documented_default
    (Env_config_core.jsonl_retention_days ())

let test_override_is_honoured () =
  with_env (Some "7") @@ fun () ->
  check int "override wins" 7 (Env_config_core.jsonl_retention_days ())

(* Malformed input is not an override. *)
let test_unparseable_falls_back () =
  with_env (Some "thirty") @@ fun () ->
  check int "non-numeric falls back to the default" documented_default
    (Env_config_core.jsonl_retention_days ())

let check_days_opt = option int

let test_parse_absent_table_yields_none () =
  check check_days_opt "no table means no window" None
    (match Maintenance.parse_string "[memory]\ncategory_cap = 30\n" with
     | Ok days -> days
     | Error _ -> fail "absent table must parse")

let test_parse_present_key_yields_window () =
  check check_days_opt "key parses" (Some 7)
    (match Maintenance.parse_string "[maintenance]\njsonl_retention_days = 7\n" with
     | Ok days -> days
     | Error _ -> fail "valid table must parse")

let test_parse_unknown_key_fails_table () =
  match Maintenance.parse_string "[maintenance]\nretention_dayz = 7\n" with
  | Error [ Maintenance.Unexpected_field key ] ->
    check string "offending key is named" "retention_dayz" key
  | Error _ -> fail "expected one Unexpected_field diagnostic"
  | Ok _ -> fail "unknown key must fail the table"

let test_parse_non_integer_fails_table () =
  match Maintenance.parse_string "[maintenance]\njsonl_retention_days = \"seven\"\n" with
  | Error [ Maintenance.Retention_days_not_an_integer _ ] -> ()
  | Error _ -> fail "expected Retention_days_not_an_integer"
  | Ok _ -> fail "string value must fail the table"

let test_parse_non_positive_fails_table () =
  match Maintenance.parse_string "[maintenance]\njsonl_retention_days = 0\n" with
  | Error [ Maintenance.Retention_days_not_positive value ] ->
    check int "offending value is named" 0 value
  | Error _ -> fail "expected Retention_days_not_positive"
  | Ok _ -> fail "zero must fail the table"

let write_temp_toml name content =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%.0f.toml" name (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content);
  path

let check_source label expected actual =
  check bool label true
    (match (expected, actual) with
     | Maintenance.Env, Maintenance.Env
     | Maintenance.Toml, Maintenance.Toml
     | Maintenance.Default, Maintenance.Default -> true
     | (Maintenance.Env | Maintenance.Toml | Maintenance.Default), _ -> false)

let test_resolve_env_wins_over_toml () =
  let path = write_temp_toml "masc_retention_env_wins" "[maintenance]\njsonl_retention_days = 7\n" in
  with_env (Some "9") @@ fun () ->
  let days, source, diagnostics = Maintenance.resolve_retention_days ~config_path:path in
  check int "env wins" 9 days;
  check_source "source is env" Maintenance.Env source;
  check int "no diagnostics" 0 (List.length diagnostics)

let test_resolve_blank_env_falls_through_to_toml () =
  let path = write_temp_toml "masc_retention_blank_env" "[maintenance]\njsonl_retention_days = 7\n" in
  with_env None @@ fun () ->
  let days, source, diagnostics = Maintenance.resolve_retention_days ~config_path:path in
  check int "toml wins over blank env" 7 days;
  check_source "source is toml" Maintenance.Toml source;
  check int "no diagnostics" 0 (List.length diagnostics)

let test_resolve_missing_file_yields_default_quietly () =
  with_env None @@ fun () ->
  let days, source, diagnostics =
    Maintenance.resolve_retention_days ~config_path:"/nonexistent/masc-runtime.toml"
  in
  check int "missing file falls back to the default" documented_default days;
  check_source "source is default" Maintenance.Default source;
  check int "no diagnostics" 0 (List.length diagnostics)

let test_resolve_broken_toml_yields_default_with_diagnostics () =
  let path = write_temp_toml "masc_retention_broken" "[maintenance]\njsonl_retention_days = \n" in
  with_env None @@ fun () ->
  let days, source, diagnostics = Maintenance.resolve_retention_days ~config_path:path in
  check int "broken toml falls back to the default" documented_default days;
  check_source "source is default" Maintenance.Default source;
  check bool "diagnostics explain the fallback" true (diagnostics <> [])

let () =
  run
    "jsonl_retention_window"
    [ ( "getter"
      , [ test_case "unset yields the documented default" `Quick
            test_unset_yields_the_documented_default
        ; test_case "override is honoured" `Quick test_override_is_honoured
        ; test_case "unparseable falls back" `Quick test_unparseable_falls_back
        ] )
    ; ( "parse"
      , [ test_case "absent table yields none" `Quick test_parse_absent_table_yields_none
        ; test_case "present key yields window" `Quick test_parse_present_key_yields_window
        ; test_case "unknown key fails table" `Quick test_parse_unknown_key_fails_table
        ; test_case "non-integer fails table" `Quick test_parse_non_integer_fails_table
        ; test_case "non-positive fails table" `Quick test_parse_non_positive_fails_table
        ] )
    ; ( "resolve"
      , [ test_case "env wins over toml" `Quick test_resolve_env_wins_over_toml
        ; test_case "blank env falls through to toml" `Quick
            test_resolve_blank_env_falls_through_to_toml
        ; test_case "missing file yields default quietly" `Quick
            test_resolve_missing_file_yields_default_quietly
        ; test_case "broken toml yields default with diagnostics" `Quick
            test_resolve_broken_toml_yields_default_with_diagnostics
        ] )
    ]
