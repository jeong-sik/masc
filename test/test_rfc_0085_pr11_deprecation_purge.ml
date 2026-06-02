open Alcotest

(** RFC-0085 PR-11 — env-var deprecation mechanism completely removed
    from Env_config_core public surface.

    Verifies 0 callers of 6 deprecation API entries. *)

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
