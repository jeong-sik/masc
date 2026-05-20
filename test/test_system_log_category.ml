(* Tests for [Masc_log.System_log_category] — RFC-0155 PR-1 scout. *)

module C = Masc_log.System_log_category

let test_to_string_stable () =
  Alcotest.(check string)
    "task_ownership label"
    "task_ownership_ambiguity_current_task_unset"
    (C.to_string C.Task_ownership_ambiguity_current_task_unset);
  Alcotest.(check string) "fd_pressure label" "host_fd_pressure"
    (C.to_string C.Host_fd_pressure);
  Alcotest.(check string) "other_boundary label" "other:lex_error"
    (C.to_string (C.Other_boundary_unclassified { hint = "lex_error" }))

let test_round_trip_known_variants () =
  List.iter
    (fun variant ->
      let label = C.to_string variant in
      match C.of_string_opt label with
      | Some recovered when recovered = variant -> ()
      | Some _ ->
          Alcotest.failf "round-trip mismatch for %s" label
      | None -> Alcotest.failf "of_string_opt returned None for %s" label)
    C.all

let test_all_count () =
  (* 13 structural variants; Other_boundary_unclassified excluded. *)
  Alcotest.(check int) "all enumeration size" 13 (List.length C.all)

let test_unknown_string_returns_none () =
  Alcotest.(check (option string))
    "unknown label" None
    (Option.map C.to_string (C.of_string_opt "totally_unknown_category"))

let test_other_not_in_all () =
  (* Other_boundary_unclassified must NOT be in [all]: it requires explicit
     construction at emit boundary with a [hint]. *)
  let any_other =
    List.exists
      (function
        | C.Other_boundary_unclassified _ -> true
        | _ -> false)
      C.all
  in
  Alcotest.(check bool) "Other_boundary_unclassified excluded from all" false
    any_other

let () =
  Alcotest.run "system_log_category"
    [
      ( "labels",
        [
          Alcotest.test_case "to_string stable" `Quick test_to_string_stable;
          Alcotest.test_case "round-trip known variants" `Quick
            test_round_trip_known_variants;
          Alcotest.test_case "all enumeration size" `Quick test_all_count;
          Alcotest.test_case "unknown -> None" `Quick
            test_unknown_string_returns_none;
          Alcotest.test_case "Other excluded from all" `Quick
            test_other_not_in_all;
        ] );
    ]
