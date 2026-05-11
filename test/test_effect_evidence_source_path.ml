(** test_effect_evidence_source_path -- Regression guard for SafeAuto
    source-path propagation at the Mode_enforcer boundary.

    Done criteria (issue: SafeAuto source-path discontinuation boundary):
    - Fails when source_path is absent from the OAS effects artifact.
    - Succeeds when source_path (and optionally source_line) is present.
    - Validates that [Effect_evidence.of_json] is backward compatible with
      legacy effect records that pre-date the evidence layer. *)

module EE = Effect_evidence

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let effect_json ?source_path ?source_line () : Yojson.Safe.t =
  let opt name f = function
    | Some value -> [ name, f value ]
    | None -> []
  in
  `Assoc
    ([ "tool_use_id", `String "tool-1"
     ; "tool_name", `String "fs_edit"
     ; "decision_source", `String "mode_enforcer"
     ]
     @ opt "source_path" (fun path -> `String path) source_path
     @ opt "source_line" (fun line -> `Int line) source_line)
;;

(* ================================================================ *)
(* Effect_evidence unit tests                                        *)
(* ================================================================ *)

(** empty evidence has no source_path. *)
let test_empty_not_populated () =
  Alcotest.(check bool) "empty not populated" false (EE.is_populated EE.empty)
;;

(** Evidence with source_path is populated. *)
let test_with_source_path_populated () =
  let ev = { EE.source_path = Some "lib/foo.ml"; source_line = Some 42 } in
  Alcotest.(check bool) "with path populated" true (EE.is_populated ev)
;;

let test_empty_source_path_not_populated () =
  let empty = { EE.source_path = Some ""; source_line = Some 42 } in
  let whitespace = { EE.source_path = Some "  \t"; source_line = Some 42 } in
  Alcotest.(check bool) "empty path not populated" false (EE.is_populated empty);
  Alcotest.(check bool) "whitespace path not populated" false (EE.is_populated whitespace)
;;

(** [of_json] on a JSON object without source_path/source_line returns empty. *)
let test_of_json_missing_fields_returns_empty () =
  let json = `Assoc [ "tool_name", `String "x" ] in
  let ev = EE.of_json json in
  Alcotest.(check bool) "no path => empty" false (EE.is_populated ev);
  Alcotest.(check (option string)) "source_path None" None ev.source_path;
  Alcotest.(check (option int)) "source_line None" None ev.source_line
;;

(** [of_json] parses source_path correctly. *)
let test_of_json_parses_source_path () =
  let json =
    `Assoc [ "source_path", `String "lib/exec/exec_gate.ml"; "source_line", `Int 87 ]
  in
  let ev = EE.of_json json in
  Alcotest.(check bool) "populated" true (EE.is_populated ev);
  Alcotest.(check (option string))
    "source_path"
    (Some "lib/exec/exec_gate.ml")
    ev.source_path;
  Alcotest.(check (option int)) "source_line" (Some 87) ev.source_line
;;

let test_of_json_normalizes_empty_source_path () =
  let json = `Assoc [ "source_path", `String "  "; "source_line", `Int 87 ] in
  let ev = EE.of_json json in
  Alcotest.(check bool) "blank path not populated" false (EE.is_populated ev);
  Alcotest.(check (option string)) "source_path normalized to None" None ev.source_path;
  Alcotest.(check (option int)) "source_line preserved" (Some 87) ev.source_line
;;

(** [of_json] with only source_path (no source_line) works. *)
let test_of_json_path_only () =
  let json = `Assoc [ "source_path", `String "lib/violation_record.ml" ] in
  let ev = EE.of_json json in
  Alcotest.(check bool) "populated" true (EE.is_populated ev);
  Alcotest.(check (option int)) "source_line None" None ev.source_line
;;

(** [to_json_fields] is empty for [empty]. *)
let test_to_json_fields_empty () =
  let fields = EE.to_json_fields EE.empty in
  Alcotest.(check int) "no fields for empty" 0 (List.length fields)
;;

(** [to_json_fields] includes source_path and source_line when set. *)
let test_to_json_fields_populated () =
  let ev = { EE.source_path = Some "lib/foo.ml"; source_line = Some 7 } in
  let fields = EE.to_json_fields ev in
  Alcotest.(check int) "2 fields" 2 (List.length fields);
  (* Fields are sorted alphabetically: source_line < source_path *)
  let keys = List.map fst fields in
  Alcotest.(check (list string)) "sorted keys" [ "source_line"; "source_path" ] keys
;;

(* ================================================================ *)
(* Effects artifact tests                                           *)
(* ================================================================ *)

(** Parsing effects.json gives source-path evidence when any row has it. *)
let test_of_json_list_effects_artifact () =
  let e1 = effect_json ~source_path:"lib/mode_enforcer.ml" ~source_line:410 () in
  let e2 = effect_json () in
  match EE.of_json_list (`List [ e1; e2 ]) with
  | Error e -> Alcotest.fail ("parse failed: " ^ e)
  | Ok events ->
    Alcotest.(check int) "2 records" 2 (List.length events);
    Alcotest.(check bool) "any source_path" true (EE.any_source_path_present events)
;;

(** [of_json_list] on non-array returns Error. *)
let test_of_json_list_non_array () =
  match EE.of_json_list (`Assoc []) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error for non-array input"
;;

(** [check_any_source_path_present] returns [Ok ()] when source_path is present. *)
let test_check_any_source_path_present_ok () =
  match
    EE.of_json_list (`List [ effect_json ~source_path:"lib/mode_enforcer.ml" () ])
  with
  | Error e -> Alcotest.fail ("parse failed: " ^ e)
  | Ok events ->
    (match EE.check_any_source_path_present events with
     | Ok () -> ()
     | Error msg -> Alcotest.fail ("expected Ok, got Error: " ^ msg))
;;

(** REGRESSION: effects evidence without source_path must be visible as
    missing boundary evidence instead of silently passing. *)
let test_check_any_source_path_present_fails_when_absent () =
  match EE.of_json_list (`List [ effect_json (); effect_json () ]) with
  | Error e -> Alcotest.fail ("parse failed: " ^ e)
  | Ok events ->
    (match EE.check_any_source_path_present events with
     | Error _ -> ()
     | Ok () ->
       Alcotest.fail
         "check_any_source_path_present returned Ok for effects without source_path")
;;

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run
    "effect_evidence_source_path"
    [ ( "effect_evidence"
      , [ Alcotest.test_case "empty not populated" `Quick test_empty_not_populated
        ; Alcotest.test_case
            "with source_path populated"
            `Quick
            test_with_source_path_populated
        ; Alcotest.test_case
            "empty source_path not populated"
            `Quick
            test_empty_source_path_not_populated
        ; Alcotest.test_case
            "of_json missing fields returns empty"
            `Quick
            test_of_json_missing_fields_returns_empty
        ; Alcotest.test_case
            "of_json parses source_path"
            `Quick
            test_of_json_parses_source_path
        ; Alcotest.test_case
            "of_json normalizes empty source_path"
            `Quick
            test_of_json_normalizes_empty_source_path
        ; Alcotest.test_case
            "of_json path only (no source_line)"
            `Quick
            test_of_json_path_only
        ; Alcotest.test_case "to_json_fields empty" `Quick test_to_json_fields_empty
        ; Alcotest.test_case
            "to_json_fields populated"
            `Quick
            test_to_json_fields_populated
        ] )
    ; ( "effects_artifact"
      , [ Alcotest.test_case
            "of_json_list effects artifact"
            `Quick
            test_of_json_list_effects_artifact
        ; Alcotest.test_case
            "of_json_list non-array error"
            `Quick
            test_of_json_list_non_array
        ; Alcotest.test_case
            "check_any_source_path_present Ok"
            `Quick
            test_check_any_source_path_present_ok
        ; Alcotest.test_case
            "check_any_source_path_present fails when absent"
            `Quick
            test_check_any_source_path_present_fails_when_absent
        ] )
    ]
;;
