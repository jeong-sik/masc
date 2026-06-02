(** Regression tests for [Keeper_checkpoint_store.classify_sdk_error]
    after RFC-0089 G4 (#15514 sibling): typed ENOENT classification at
    the OS boundary.

    Background: on 2026-04-12 /loop observed a keeper logging 334 copies
    of [OAS checkpoint I/O error: file load failed on trace-...: Eio.Io
    Fs Not_found Unix_error (No such file or directory, "openat", ...)]
    in a tight retry loop. The root fix in #6654 used four string-prefix
    matches + a substring fallback on [FileOpFailed.detail] to recognise
    cold-start absence — a string classifier workaround (CLAUDE.md
    §워크어라운드 #2).

    Replacement (RFC-0089 G4): the SDK provides
    [Agent_sdk.Checkpoint_store.exists : t -> string -> bool], so the
    keeper-side load path now branches on that [bool] *before* invoking
    [load]. Any [sdk_error] reaching [classify_sdk_error] is therefore by
    construction a real I/O / serialization / SDK fault, never a missing
    file. The classifier consequently has no [Not_found] arm.

    These tests pin the invariant: classify_sdk_error must never return
    [Not_found], regardless of the rendered detail string. Cold-start
    [Not_found] coverage is end-to-end behaviour of [load_oas] /
    [load_oas_history_file] and is exercised separately via the
    [Fs_compat.file_exists] / [Checkpoint_store.exists] branches. *)

module Store = Masc_mcp.Keeper_checkpoint_store

(* Alcotest testable for [Store.checkpoint_load_error]. We only need
   equality + a pretty printer for failure diagnostics; the variants
   carry [string] payloads which is fine for value-level comparison. *)
let pp_err fmt = function
  | Store.Not_found -> Format.fprintf fmt "Not_found"
  | Store.Store_error s -> Format.fprintf fmt "Store_error(%s)" s
  | Store.Parse_error s -> Format.fprintf fmt "Parse_error(%s)" s
  | Store.Io_error s -> Format.fprintf fmt "Io_error(%s)" s
  | Store.Sdk_other_error s -> Format.fprintf fmt "Sdk_other_error(%s)" s

let load_err = Alcotest.testable pp_err ( = )

let is_not_found = function Store.Not_found -> true | _ -> false
let is_io_error = function Store.Io_error _ -> true | _ -> false
let is_store_error = function Store.Store_error _ -> true | _ -> false
let is_parse_error = function Store.Parse_error _ -> true | _ -> false
let is_sdk_other = function Store.Sdk_other_error _ -> true | _ -> false

(* ─── Invariant: classify_sdk_error never returns Not_found ──────── *)

let check_not_not_found name detail =
  let e = Agent_sdk.Error.Io (FileOpFailed { op = "load"; path = "p"; detail }) in
  Alcotest.(check bool) name false (is_not_found (Store.classify_sdk_error e))

let test_legacy_no_such_file_underscore () =
  (* Previously string-matched as Not_found via the "no_such_file" prefix. *)
  check_not_not_found "legacy no_such_file underscore prefix routes to Io_error"
    "no_such_file: trace-xyz"

let test_legacy_no_such_file_space () =
  check_not_not_found "legacy 'No such file' phrase routes to Io_error"
    "No such file or directory"

let test_legacy_unix_error_enoent () =
  check_not_not_found "legacy Unix_error(ENOENT prefix routes to Io_error"
    "Unix_error (ENOENT, \"openat\", \"/tmp/x\")"

let test_eio_io_fs_not_found_rendered () =
  (* Exact detail string from /tmp/masc-6647-restart2.log. Under the new
     contract this case is *unreachable* in practice (the [exists] gate
     filters it), but if it does reach the classifier — e.g. a TOCTOU
     race where the file was removed between [exists] and [load] — it is
     a genuine [Io_error], not a cold-start absence. *)
  check_not_not_found
    "Eio.Io Fs Not_found rendered form routes to Io_error (not Not_found)"
    "Eio.Io Fs Not_found Unix_error (No such file or directory, \
     \"openat\", \"/p/trace.json\")"

(* ─── Categorical routing on typed sdk_error variants ────────────── *)

let test_io_file_op_failed_routes_io_error () =
  let e =
    Agent_sdk.Error.Io
      (FileOpFailed { op = "load"; path = "/p/x"; detail = "EACCES" })
  in
  Alcotest.check load_err "FileOpFailed routes to Io_error"
    (Store.Io_error "file load failed on /p/x: EACCES")
    (Store.classify_sdk_error e)

let test_io_validation_failed_routes_store_error () =
  let e = Agent_sdk.Error.Io (ValidationFailed { detail = "bad schema" }) in
  Alcotest.(check bool) "ValidationFailed routes to Store_error" true
    (is_store_error (Store.classify_sdk_error e))

let test_serialization_json_routes_parse_error () =
  let e =
    Agent_sdk.Error.Serialization (JsonParseError { detail = "EOF" })
  in
  Alcotest.(check bool) "JsonParseError routes to Parse_error" true
    (is_parse_error (Store.classify_sdk_error e))

let test_serialization_version_routes_parse_error () =
  let e =
    Agent_sdk.Error.Serialization
      (VersionMismatch { expected = 2; got = 1 })
  in
  Alcotest.(check bool) "VersionMismatch routes to Parse_error" true
    (is_parse_error (Store.classify_sdk_error e))

let test_serialization_unknown_variant_routes_parse_error () =
  let e =
    Agent_sdk.Error.Serialization
      (UnknownVariant { type_name = "role"; value = "alien" })
  in
  Alcotest.(check bool) "UnknownVariant routes to Parse_error" true
    (is_parse_error (Store.classify_sdk_error e))

let test_internal_routes_sdk_other_error () =
  let e = Agent_sdk.Error.Internal "kaboom" in
  Alcotest.(check bool) "Internal routes to Sdk_other_error" true
    (is_sdk_other (Store.classify_sdk_error e))

(* Negative-control: a permission failure must remain Io_error (not
   Not_found, not Parse_error). *)
let test_permission_denied_routes_io_error () =
  let e =
    Agent_sdk.Error.Io
      (FileOpFailed
         { op = "load"; path = "/p"; detail =
             "Unix_error (EACCES, \"openat\", \"/p/trace.json\")" })
  in
  Alcotest.(check bool) "EACCES routes to Io_error" true
    (is_io_error (Store.classify_sdk_error e))

let () =
  Alcotest.run "Keeper_checkpoint_classify"
    [
      ( "classify_sdk_error: no Not_found arm (RFC-0089 G4)",
        [
          Alcotest.test_case "legacy no_such_file underscore is Io_error" `Quick
            test_legacy_no_such_file_underscore;
          Alcotest.test_case "legacy 'No such file' is Io_error" `Quick
            test_legacy_no_such_file_space;
          Alcotest.test_case "legacy Unix_error(ENOENT is Io_error" `Quick
            test_legacy_unix_error_enoent;
          Alcotest.test_case "Eio.Io Fs Not_found rendered is Io_error" `Quick
            test_eio_io_fs_not_found_rendered;
        ] );
      ( "classify_sdk_error: typed variant routing",
        [
          Alcotest.test_case "FileOpFailed -> Io_error" `Quick
            test_io_file_op_failed_routes_io_error;
          Alcotest.test_case "ValidationFailed -> Store_error" `Quick
            test_io_validation_failed_routes_store_error;
          Alcotest.test_case "JsonParseError -> Parse_error" `Quick
            test_serialization_json_routes_parse_error;
          Alcotest.test_case "VersionMismatch -> Parse_error" `Quick
            test_serialization_version_routes_parse_error;
          Alcotest.test_case "UnknownVariant -> Parse_error" `Quick
            test_serialization_unknown_variant_routes_parse_error;
          Alcotest.test_case "Internal -> Sdk_other_error" `Quick
            test_internal_routes_sdk_other_error;
          Alcotest.test_case "EACCES (FileOpFailed) -> Io_error" `Quick
            test_permission_denied_routes_io_error;
        ] );
    ]
