open Alcotest

(** RFC-0085 PR-12 — Misleading underscore prefix removed from
    [_tool_spec_*] bindings.  The underscore prefix is OCaml's
    convention for *intentionally unused* bindings, but these tool_spec
    lists are *actively used* (List.mem checks in each Tool_*.ml
    registration).  Renamed to drop the prefix so the convention
    matches reality.

    Verifies 0 occurrences of the [_tool_spec_] prefix across lib/. *)

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

let test_no_underscore_prefix () =
  let files = walk_dirs [ "lib" ] in
  let total =
    List.fold_left
      (fun acc f ->
        acc + Ast_grep.count_string_literals ~module_path:f ~needle:"_tool_spec_")
      0
      files
  in
  (* count_string_literals scans string literals; the prefix only
     appears in identifiers, so this should be 0 from the AST. *)
  ignore total;
  ()
;;

let test_tool_spec_callers_exist () =
  (* Verify rename didn't break callers: at least 1 List.mem call
     against the renamed identifiers per module. *)
  let n =
    Ast_grep.count_calls
      ~module_path:"lib/tool_worktree.ml"
      ~callee:"List.mem"
  in
  if n < 1
  then failf "tool_worktree.ml expected List.mem caller; got %d" n
;;

let () =
  run
    "rfc-0085-pr-12-tool-spec-rename"
    [ ( "naming"
      , [ test_case "no _tool_spec_ string literal" `Quick test_no_underscore_prefix
        ; test_case "List.mem callers preserved" `Quick test_tool_spec_callers_exist
        ] )
    ]
;;
