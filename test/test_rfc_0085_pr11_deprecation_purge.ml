open Alcotest

(** RFC-0085 PR-11 — env-var deprecation mechanism completely removed
    from Env_config_core public surface.

    Verifies 0 callers of 6 deprecation API entries. *)

let walk_dirs dirs =
  let rec collect acc = function
    | [] -> acc
    | dir :: rest ->
      let entries = Sys.readdir dir in
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
  (* [dirs] are repo-relative. Dune runs this binary from
     [_build/default/test], where they do not exist: the swallowed
     [Sys_error] answered [[||]], every "count must be 0" assertion below
     compared 0 to 0, and the guard passed after reading no files.
     [Ast_grep.source_root] is the root the same library already resolves
     its own reads against (#34385). *)
  let root = Ast_grep.source_root () in
  match collect [] (List.map (Filename.concat root) dirs) with
  | [] ->
    failwith
      (Printf.sprintf
         "no .ml sources under %s in %s -- the guard would compare 0 to 0"
         (String.concat ", " dirs)
         root)
  | files -> files
;;

let count_external_callers ~callee =
  let files = walk_dirs [ "lib"; "bin" ] in
  List.fold_left
    (fun acc f ->
      if String.equal (Filename.basename f) "env_config_core.ml"
      then acc
      else acc + Ast_grep.count_calls ~module_path:f ~callee)
    0
    files
;;

let test_no_warn_deprecated_callers () =
  check int "Env_config_core.warn_deprecated callers = 0" 0
    (count_external_callers ~callee:"Env_config_core.warn_deprecated")
;;

let test_no_deprecated_opt_callers () =
  check int "Env_config_core.deprecated_opt callers = 0" 0
    (count_external_callers ~callee:"Env_config_core.deprecated_opt")
;;

let test_no_resolve_deprecated_callers () =
  check int "Env_config_core.resolve_deprecated callers = 0" 0
    (count_external_callers ~callee:"Env_config_core.resolve_deprecated")
;;

let test_no_get_int_deprecated_callers () =
  check int "Env_config_core.get_int_deprecated callers = 0" 0
    (count_external_callers ~callee:"Env_config_core.get_int_deprecated")
;;

let test_no_get_float_deprecated_callers () =
  check int "Env_config_core.get_float_deprecated callers = 0" 0
    (count_external_callers ~callee:"Env_config_core.get_float_deprecated")
;;

let test_no_get_bool_deprecated_callers () =
  check int "Env_config_core.get_bool_deprecated callers = 0" 0
    (count_external_callers ~callee:"Env_config_core.get_bool_deprecated")
;;

let () =
  run
    "rfc-0085-pr-11-deprecation-purge"
    [ ( "deprecation API callers = 0"
      , [ test_case "warn_deprecated" `Quick test_no_warn_deprecated_callers
        ; test_case "deprecated_opt" `Quick test_no_deprecated_opt_callers
        ; test_case "resolve_deprecated" `Quick test_no_resolve_deprecated_callers
        ; test_case "get_int_deprecated" `Quick test_no_get_int_deprecated_callers
        ; test_case "get_float_deprecated" `Quick test_no_get_float_deprecated_callers
        ; test_case "get_bool_deprecated" `Quick test_no_get_bool_deprecated_callers
        ] )
    ]
;;
