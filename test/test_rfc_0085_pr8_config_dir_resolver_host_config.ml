open Alcotest

(** RFC-0085 PR-8 — config_dir_resolver + tool_code_write env-derived path
    reads migrated from Env_config_core to Host_config.from_env.

    Verifies:
    1. Env_config_core.config_dir_opt has 0 callers (function removed).
    2. Env_config_core.personas_dir_opt has 0 callers (function removed).
    3. config_dir_resolver.ml invokes Host_config.from_env at least 4 times
       (initial bindings + 3 sanitiser current readers).
    4. tool_code_write.ml invokes Host_config.from_env at least once. *)

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

let test_config_dir_opt_callers_zero () =
  let files = walk_dirs [ "lib"; "bin" ] in
  let total =
    List.fold_left
      (fun acc f ->
        acc
        + Ast_grep.count_calls
            ~module_path:f
            ~callee:"Env_config_core.config_dir_opt")
      0
      files
  in
  check int "Env_config_core.config_dir_opt callers = 0" 0 total
;;

let test_personas_dir_opt_callers_zero () =
  let files = walk_dirs [ "lib"; "bin" ] in
  let total =
    List.fold_left
      (fun acc f ->
        acc
        + Ast_grep.count_calls
            ~module_path:f
            ~callee:"Env_config_core.personas_dir_opt")
      0
      files
  in
  check int "Env_config_core.personas_dir_opt callers = 0" 0 total
;;

let test_config_dir_resolver_uses_host_config_from_env () =
  let n =
    Ast_grep.count_calls
      ~module_path:"lib/config_dir_resolver.ml"
      ~callee:"Host_config.from_env"
  in
  if n < 4
  then
    failf
      "config_dir_resolver.ml must call Host_config.from_env >= 4 (3 \
       sanitiser current readers + 3 initial bindings); got %d"
      n
;;

let test_tool_code_write_uses_host_config_from_env () =
  let n =
    Ast_grep.count_calls
      ~module_path:"lib/tool_code_write.ml"
      ~callee:"Host_config.from_env"
  in
  if n < 1
  then
    failf "tool_code_write.ml must call Host_config.from_env >= 1; got %d" n
;;

let () =
  run
    "rfc-0085-pr-8-config-dir-resolver-host-config"
    [ ( "Env_config_core purge"
      , [ test_case
            "config_dir_opt callers = 0"
            `Quick
            test_config_dir_opt_callers_zero
        ; test_case
            "personas_dir_opt callers = 0"
            `Quick
            test_personas_dir_opt_callers_zero
        ] )
    ; ( "Host_config.from_env adoption"
      , [ test_case
            "config_dir_resolver migrated"
            `Quick
            test_config_dir_resolver_uses_host_config_from_env
        ; test_case
            "tool_code_write migrated"
            `Quick
            test_tool_code_write_uses_host_config_from_env
        ] )
    ]
;;
