open Alcotest

(** RFC-0085 PR-12 — Misleading underscore prefix removed from
    [_tool_spec_*] bindings.  The underscore prefix is OCaml's
    convention for *intentionally unused* bindings, but these tool_spec
    lists are *actively used* (List.mem checks in each Tool_*.ml
    registration).  Renamed to drop the prefix so the convention
    matches reality.

    Original PR-12 test scanned [count_string_literals], which only
    examines [Pconst_string] nodes — identifiers are NOT string
    literals, so the test passed trivially regardless of the rename.
    This revision uses [count_value_bindings_with_prefix], which
    inspects [Ppat_var] nodes (actual identifier bindings). *)

let rec walk_ml_files dir acc =
  let entries = try Sys.readdir dir with Sys_error _ -> [||] in
  Array.fold_left
    (fun acc name ->
      let p = Filename.concat dir name in
      if (try Sys.is_directory p with Sys_error _ -> false)
      then walk_ml_files p acc
      else if Filename.check_suffix p ".ml"
      then p :: acc
      else acc)
    acc
    entries
;;

let test_no_underscore_prefix_bindings () =
  let files = walk_ml_files "lib" [] in
  let offenders =
    List.filter_map
      (fun f ->
        let n =
          Ast_grep.count_value_bindings_with_prefix
            ~module_path:f
            ~prefix:"_tool_spec_"
        in
        if n > 0 then Some (f, n) else None)
      files
  in
  match offenders with
  | [] -> ()
  | xs ->
    let msg =
      String.concat
        "; "
        (List.map (fun (f, n) -> Printf.sprintf "%s=%d" f n) xs)
    in
    failf "_tool_spec_* prefix bindings still present: %s" msg
;;

let test_renamed_bindings_present () =
  let files = walk_ml_files "lib" [] in
  let total =
    List.fold_left
      (fun acc f ->
        acc
        + Ast_grep.count_value_bindings_with_prefix
            ~module_path:f
            ~prefix:"tool_spec_")
      0
      files
  in
  if total < 1
  then failf "expected ≥1 [tool_spec_*] active binding post-rename; got %d" total
;;

let test_list_mem_callers_preserved () =
  let n =
    Ast_grep.count_calls ~module_path:"lib/tool_worktree.ml" ~callee:"List.mem"
  in
  if n < 1
  then failf "tool_worktree.ml expected List.mem caller; got %d" n
;;

let () =
  run
    "rfc-0085-pr-12-tool-spec-rename"
    [ ( "identifier purge"
      , [ test_case
            "no _tool_spec_ underscore-prefix bindings"
            `Quick
            test_no_underscore_prefix_bindings
        ; test_case
            "renamed tool_spec_ bindings exist"
            `Quick
            test_renamed_bindings_present
        ; test_case
            "List.mem callers preserved"
            `Quick
            test_list_mem_callers_preserved
        ] )
    ]
;;
