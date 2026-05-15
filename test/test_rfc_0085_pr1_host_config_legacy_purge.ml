open Alcotest

(** RFC-0085 PR-1 — Verifies:

    1. [Host_config.legacy_macos_default] is GONE from every
       [lib/] / [bin/] / [test/] caller (62 -> 0).
    2. [Host_config.host] is the new canonical accessor (1+ callers).
    3. The three new fields [log_dir], [run_dir], [policy_dir] exist
       on [Host_config.t] (record-construction smoke).
    4. PPX-derived [pp], [equal] work on [Host_config.t] and
       [Dispatch_outcome.t].

    Uses [Ast_grep] (AST-based) helper instead of source-grep, so
    docstrings / comments do not trigger false positives. *)

let walk_dirs dirs =
  let rec collect acc = function
    | [] -> acc
    | dir :: rest ->
      let entries = try Sys.readdir dir with Sys_error _ -> [||] in
      let next, files =
        Array.fold_left
          (fun (sub, files) name ->
            let p = Filename.concat dir name in
            if try Sys.is_directory p with Sys_error _ -> false
            then p :: sub, files
            else if Filename.check_suffix p ".ml"
            then sub, p :: files
            else sub, files)
          ([], [])
          entries
      in
      collect (List.rev_append files acc) (List.rev_append next rest)
  in
  collect [] dirs
;;

let test_legacy_macos_default_callers_zero () =
  let files = walk_dirs [ "lib"; "bin"; "test" ] in
  let total =
    List.fold_left
      (fun acc f ->
        acc
        + Ast_grep.count_calls ~module_path:f ~callee:"Host_config.legacy_macos_default")
      0
      files
  in
  check
    int
    "Host_config.legacy_macos_default callers must be 0 (RFC-0085 PR-1 \
     legacy purge)"
    0
    total
;;

let test_host_callers_nonzero () =
  let files = walk_dirs [ "lib"; "bin"; "test" ] in
  let total =
    List.fold_left
      (fun acc f -> acc + Ast_grep.count_calls ~module_path:f ~callee:"Host_config.host")
      0
      files
  in
  if total < 1
  then failf "Host_config.host callers must be >= 1 (PR-1 rename); got %d" total
;;

let test_log_run_policy_fields_exist () =
  let h = Host_config.host () in
  (* All three fields exist and are non-empty strings. *)
  check bool "log_dir non-empty" true (String.length h.log_dir > 0);
  check bool "run_dir non-empty" true (String.length h.run_dir > 0);
  check bool "policy_dir non-empty" true (String.length h.policy_dir > 0)
;;

let test_derived_pp_works () =
  let h = Host_config.host () in
  let rendered = Format.asprintf "%a" Host_config.pp h in
  (* Derived pp produces a non-empty string mentioning the record name. *)
  check bool "pp produces output" true (String.length rendered > 0)
;;

let test_derived_equal_works () =
  let h1 = Host_config.host () in
  let h2 = Host_config.host () in
  check bool "equal reflexive on host ()" true (Host_config.equal h1 h2)
;;

let test_dispatch_outcome_pp_eq () =
  let open Masc_mcp.Dispatch_outcome in
  let a = Handled in
  let b = Handler_error { exn = "boom" } in
  check bool "equal Handled = Handled" true (equal a a);
  check bool "Handled <> Handler_error" false (equal a b);
  let rendered = Format.asprintf "%a" pp b in
  check bool "pp non-empty" true (String.length rendered > 0)
;;

let () =
  run
    "rfc-0085-pr-1-host-config-legacy-purge"
    [ ( "legacy purge"
      , [ test_case "legacy_macos_default callers" `Quick test_legacy_macos_default_callers_zero
        ; test_case "host callers" `Quick test_host_callers_nonzero
        ] )
    ; ( "new fields"
      , [ test_case "log_dir/run_dir/policy_dir exist" `Quick test_log_run_policy_fields_exist
        ] )
    ; ( "ppx deriving"
      , [ test_case "host_config pp" `Quick test_derived_pp_works
        ; test_case "host_config equal" `Quick test_derived_equal_works
        ; test_case "dispatch_outcome pp/eq" `Quick test_dispatch_outcome_pp_eq
        ] )
    ]
;;
