(** Structural contract for the running-Keeper TOML reconcile call.

    A running Keeper reaches [ensure_keeper_meta] directly on every supervisor
    sweep. Observation of an earlier failure must not become an admission
    decision for the next attempt. *)

let find_substring_from text needle start =
  let needle_length = String.length needle in
  let text_length = String.length text in
  let rec loop index =
    if index + needle_length > text_length
    then None
    else if String.equal (String.sub text index needle_length) needle
    then Some index
    else loop (index + 1)
  in
  loop start
;;

let source_slice ~start_marker ~end_marker =
  let relative_path = "lib/keeper/keeper_runtime.ml" in
  let source =
    Masc_test_deps.read_file (Masc_test_deps.source_path relative_path)
  in
  match find_substring_from source start_marker 0 with
  | None -> Alcotest.failf "missing start marker in %s" relative_path
  | Some start ->
    (match find_substring_from source end_marker start with
     | None -> Alcotest.failf "missing end marker in %s" relative_path
     | Some stop -> String.sub source start (stop - start))
;;

let test_running_keeper_attempts_reconcile_directly () =
  let running_branch =
    source_slice
      ~start_marker:"| Keeper_state_machine.Running ->"
      ~end_marker:"| Keeper_state_machine.Offline"
  in
  let direct_attempt =
    "| Keeper_state_machine.Running ->\n\
     \                  (match\n\
     \                     remember_boot_meta_result"
  in
  Alcotest.(check bool)
    "running branch begins with the reconcile attempt"
    true
    (Option.is_some (find_substring_from running_branch direct_attempt 0));
  Alcotest.(check bool)
    "attempt records the typed reconcile result"
    true
    (Option.is_some
       (find_substring_from
          running_branch
          "(ensure_keeper_meta_with_cause ctx.config entry.name)"
          0))
;;

let () =
  Alcotest.run
    "keeper_running_reconcile_attempt"
    [ ( "supervisor sweep"
      , [ Alcotest.test_case
            "running Keeper always attempts reconcile"
            `Quick
            test_running_keeper_attempts_reconcile_directly
        ] )
    ]
;;
