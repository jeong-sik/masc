(** Tests for the per-model context-growth thresholds (masc#54868).

    Pinned invariants:

    1. [context-rollover-threshold = 0.75] parses to [Some 0.75].
    2. [tail-window-atoms = 90] parses to [Some 90].
    3. [compaction-keep-ratio = 0.5] parses to [Some 0.5].
    4. Absent thresholds parse to [None]; consumers keep the fallback
       (0.80 rollover, 60 atoms, 0.25 keep ratio).
    5. A rollover/keep value outside [0.0, 1.0] fails the parse (fail-closed).
    6. A non-number value fails the parse.
    7. A non-positive [tail-window-atoms] fails the parse (fail-closed).
    8. A non-integer [tail-window-atoms] fails the parse. *)

open Alcotest

module Schema = Runtime_schema
module Toml = Runtime_toml

let parse_string_or_fail s =
  match Toml.parse_string s with
  | Ok cfg -> cfg
  | Error errs ->
    let rendered =
      errs
      |> List.map (fun (e : Toml.parse_error) ->
        Printf.sprintf "[%s] %s" e.path e.message)
      |> String.concat "; "
    in
    failf "parse_string failed: %s" rendered
;;

let parse_string_expect_error label s =
  match Toml.parse_string s with
  | Ok _ -> failf "%s: expected parse error, got Ok" label
  | Error _ -> ()
;;

let model_thresholds cfg id =
  match List.find_opt (fun (m : Schema.model_spec) -> String.equal m.id id) cfg.Schema.models with
  | Some m ->
      ( m.Schema.context_rollover_threshold
      , m.Schema.tail_window_atoms
      , m.Schema.compaction_keep_ratio )
  | None -> failf "model %S absent from parsed config" id
;;

let model_toml ~extra_lines =
  Printf.sprintf "[models.m]\nmax-context = 200000\n%s" extra_lines
;;

let test_thresholds_parse () =
  let cfg =
    parse_string_or_fail
      (model_toml
         ~extra_lines:
           "context-rollover-threshold = 0.75\ntail-window-atoms = 90\ncompaction-keep-ratio = 0.5\n")
  in
  let rollover, atoms, keep = model_thresholds cfg "m" in
  check (option (float 0.0001)) "rollover parses" (Some 0.75) rollover;
  check (option int) "tail atoms parse" (Some 90) atoms;
  check (option (float 0.0001)) "keep ratio parses" (Some 0.5) keep
;;

let test_absent_thresholds_are_none () =
  let cfg = parse_string_or_fail (model_toml ~extra_lines:"") in
  let rollover, atoms, keep = model_thresholds cfg "m" in
  check (option (float 0.0001)) "absent rollover" None rollover;
  check (option int) "absent tail atoms" None atoms;
  check (option (float 0.0001)) "absent keep ratio" None keep
;;

let test_ratio_out_of_range_fails_closed () =
  parse_string_expect_error "context-rollover-threshold = 0.0 (non-positive)"
    (model_toml ~extra_lines:"context-rollover-threshold = 0.0\n");
  parse_string_expect_error "context-rollover-threshold = 1.1 (above 1.0 ceiling)"
    (model_toml ~extra_lines:"context-rollover-threshold = 1.1\n");
  parse_string_expect_error "compaction-keep-ratio = -0.1 (below 0.0 floor)"
    (model_toml ~extra_lines:"compaction-keep-ratio = -0.1\n");
  parse_string_expect_error "compaction-keep-ratio = 1.0 (keeps 100%, never shrinks)"
    (model_toml ~extra_lines:"compaction-keep-ratio = 1.0\n")
;;

let test_non_number_fails_closed () =
  parse_string_expect_error "context-rollover-threshold = \"wide\" (not a number)"
    (model_toml ~extra_lines:"context-rollover-threshold = \"wide\"\n");
  parse_string_expect_error "compaction-keep-ratio = \"narrow\" (not a number)"
    (model_toml ~extra_lines:"compaction-keep-ratio = \"narrow\"\n")
;;

let test_tail_atoms_invalid_fails_closed () =
  parse_string_expect_error "tail-window-atoms = 0 (not positive)"
    (model_toml ~extra_lines:"tail-window-atoms = 0\n");
  parse_string_expect_error "tail-window-atoms = 1.5 (not integer)"
    (model_toml ~extra_lines:"tail-window-atoms = 1.5\n");
  parse_string_expect_error "tail-window-atoms = -4 (negative)"
    (model_toml ~extra_lines:"tail-window-atoms = -4\n")
;;

let () =
  run "runtime_context_threshold_toml"
    [ ("valid values"
      , [ test_case "thresholds parse" `Quick test_thresholds_parse
        ; test_case "absent thresholds are None" `Quick test_absent_thresholds_are_none
        ])
    ; ("invalid values fail closed"
      , [ test_case "ratio out-of-range fails parse" `Quick test_ratio_out_of_range_fails_closed
        ; test_case "non-number fails parse" `Quick test_non_number_fails_closed
        ; test_case "tail atoms invalid fails parse" `Quick test_tail_atoms_invalid_fails_closed
        ])
    ]
;;
