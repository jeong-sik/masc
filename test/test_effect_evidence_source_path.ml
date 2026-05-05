(** test_effect_evidence_source_path — Regression guard for SafeAuto
    source-path propagation at the Mode_enforcer boundary.

    Done criteria (issue: SafeAuto source-path discontinuation boundary):
    - Fails when source_path is absent from a violation payload.
    - Succeeds when source_path (and optionally source_line) is present.
    - Validates that [Effect_evidence.of_json] is backward compatible with
      legacy violation records that pre-date the evidence layer. *)

module EE = Masc_mcp.Effect_evidence
module VR = Masc_mcp.Violation_record

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let base_violation_json
    ?(tool_name = "fs_edit")
    ?(violation_kind = "mutating_in_diagnose")
    ?(effective_mode = "diagnose")
    ?(extra = [])
    () : Yojson.Safe.t =
  `Assoc ([
    ("ts", `Float 1000.0);
    ("tool_name", `String tool_name);
    ("input_summary", `String "truncated");
    ("effective_mode", `String effective_mode);
    ("violation_kind", `String violation_kind);
  ] @ extra)

(* ================================================================ *)
(* Effect_evidence unit tests                                        *)
(* ================================================================ *)

(** empty evidence has no source_path. *)
let test_empty_not_populated () =
  Alcotest.(check bool) "empty not populated" false
    (EE.is_populated EE.empty)

(** Evidence with source_path is populated. *)
let test_with_source_path_populated () =
  let ev = { EE.source_path = Some "lib/foo.ml"; source_line = Some 42 } in
  Alcotest.(check bool) "with path populated" true (EE.is_populated ev)

(** [of_json] on a JSON object without source_path/source_line returns empty. *)
let test_of_json_missing_fields_returns_empty () =
  let json = `Assoc [("tool_name", `String "x")] in
  let ev = EE.of_json json in
  Alcotest.(check bool) "no path => empty" false (EE.is_populated ev);
  Alcotest.(check (option string)) "source_path None" None ev.source_path;
  Alcotest.(check (option int)) "source_line None" None ev.source_line

(** [of_json] parses source_path correctly. *)
let test_of_json_parses_source_path () =
  let json = `Assoc [
    ("source_path", `String "lib/exec/exec_gate.ml");
    ("source_line", `Int 87);
  ] in
  let ev = EE.of_json json in
  Alcotest.(check bool) "populated" true (EE.is_populated ev);
  Alcotest.(check (option string)) "source_path"
    (Some "lib/exec/exec_gate.ml") ev.source_path;
  Alcotest.(check (option int)) "source_line" (Some 87) ev.source_line

(** [of_json] with only source_path (no source_line) works. *)
let test_of_json_path_only () =
  let json = `Assoc [("source_path", `String "lib/violation_record.ml")] in
  let ev = EE.of_json json in
  Alcotest.(check bool) "populated" true (EE.is_populated ev);
  Alcotest.(check (option int)) "source_line None" None ev.source_line

(** [to_json_fields] is empty for [empty]. *)
let test_to_json_fields_empty () =
  let fields = EE.to_json_fields EE.empty in
  Alcotest.(check int) "no fields for empty" 0 (List.length fields)

(** [to_json_fields] includes source_path and source_line when set. *)
let test_to_json_fields_populated () =
  let ev = { EE.source_path = Some "lib/foo.ml"; source_line = Some 7 } in
  let fields = EE.to_json_fields ev in
  Alcotest.(check int) "2 fields" 2 (List.length fields);
  (* Fields are sorted alphabetically: source_line < source_path *)
  let keys = List.map fst fields in
  Alcotest.(check (list string)) "sorted keys"
    ["source_line"; "source_path"] keys

(* ================================================================ *)
(* Violation_record enriched type tests                             *)
(* ================================================================ *)

(** Parsing a violation without source_path/source_line gives empty evidence. *)
let test_of_json_enriched_legacy_record () =
  let json = base_violation_json () in
  match VR.of_json_enriched json with
  | Error e -> Alcotest.fail ("parse failed: " ^ e)
  | Ok ev ->
    Alcotest.(check string) "tool_name" "fs_edit" ev.base.tool_name;
    Alcotest.(check bool) "evidence not populated" false
      (EE.is_populated ev.evidence)

(** Parsing a violation with source_path gives populated evidence. *)
let test_of_json_enriched_with_source_path () =
  let json = base_violation_json
    ~extra:[("source_path", `String "lib/exec/exec_gate.ml");
            ("source_line", `Int 42)] () in
  match VR.of_json_enriched json with
  | Error e -> Alcotest.fail ("parse failed: " ^ e)
  | Ok ev ->
    Alcotest.(check bool) "evidence populated" true
      (EE.is_populated ev.evidence);
    Alcotest.(check (option string)) "source_path"
      (Some "lib/exec/exec_gate.ml") ev.evidence.source_path;
    Alcotest.(check (option int)) "source_line"
      (Some 42) ev.evidence.source_line

(** [check_source_path_present] returns [Ok ()] when source_path is present. *)
let test_check_source_path_present_ok () =
  let json = base_violation_json
    ~extra:[("source_path", `String "lib/mode_enforcer_boundary.ml")] () in
  match VR.of_json_enriched json with
  | Error e -> Alcotest.fail ("parse failed: " ^ e)
  | Ok ev ->
    (match VR.check_source_path_present ev with
     | Ok () -> ()
     | Error msg -> Alcotest.fail ("expected Ok, got Error: " ^ msg))

(** REGRESSION: [check_source_path_present] returns [Error] when source_path
    is absent.  This is the core regression guard for the SafeAuto
    source-path discontinuation boundary.  The test fails if any code path
    produces a violation payload without a source_path, because that means
    the backtrace is lost at the handler boundary. *)
let test_check_source_path_present_fails_when_absent () =
  let json = base_violation_json () in   (* no source_path field *)
  match VR.of_json_enriched json with
  | Error e -> Alcotest.fail ("parse failed: " ^ e)
  | Ok ev ->
    (match VR.check_source_path_present ev with
     | Error _ -> ()  (* expected: source_path absent => Error *)
     | Ok () ->
       Alcotest.fail
         "check_source_path_present returned Ok for a record without \
          source_path — source-path propagation at the Mode_enforcer \
          boundary is broken")

(** [of_json_list_enriched] parses an array correctly. *)
let test_of_json_list_enriched () =
  let v1 = base_violation_json
    ~tool_name:"write"
    ~extra:[("source_path", `String "lib/write_tool.ml"); ("source_line", `Int 10)] () in
  let v2 = base_violation_json ~tool_name:"read" () in
  match VR.of_json_list_enriched (`List [v1; v2]) with
  | Error e -> Alcotest.fail ("parse failed: " ^ e)
  | Ok evs ->
    Alcotest.(check int) "2 records" 2 (List.length evs);
    let e1 = List.nth evs 0 in
    let e2 = List.nth evs 1 in
    Alcotest.(check bool) "e1 populated" true (EE.is_populated e1.evidence);
    Alcotest.(check bool) "e2 not populated" false (EE.is_populated e2.evidence)

(** [of_json_list_enriched] on non-array returns Error. *)
let test_of_json_list_enriched_non_array () =
  match VR.of_json_list_enriched (`Assoc []) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error for non-array input"

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "effect_evidence_source_path"
    [
      ( "effect_evidence",
        [
          Alcotest.test_case "empty not populated" `Quick
            test_empty_not_populated;
          Alcotest.test_case "with source_path populated" `Quick
            test_with_source_path_populated;
          Alcotest.test_case "of_json missing fields returns empty" `Quick
            test_of_json_missing_fields_returns_empty;
          Alcotest.test_case "of_json parses source_path" `Quick
            test_of_json_parses_source_path;
          Alcotest.test_case "of_json path only (no source_line)" `Quick
            test_of_json_path_only;
          Alcotest.test_case "to_json_fields empty" `Quick
            test_to_json_fields_empty;
          Alcotest.test_case "to_json_fields populated" `Quick
            test_to_json_fields_populated;
        ] );
      ( "violation_record_enriched",
        [
          Alcotest.test_case "of_json_enriched legacy record (no source_path)" `Quick
            test_of_json_enriched_legacy_record;
          Alcotest.test_case "of_json_enriched with source_path" `Quick
            test_of_json_enriched_with_source_path;
          Alcotest.test_case "check_source_path_present Ok" `Quick
            test_check_source_path_present_ok;
          Alcotest.test_case "check_source_path_present fails when absent (regression guard)" `Quick
            test_check_source_path_present_fails_when_absent;
          Alcotest.test_case "of_json_list_enriched array" `Quick
            test_of_json_list_enriched;
          Alcotest.test_case "of_json_list_enriched non-array error" `Quick
            test_of_json_list_enriched_non_array;
        ] );
    ]
