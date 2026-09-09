open Alcotest

(** RFC-0085 PR-8 — config_dir_resolver env-derived path reads migrated from
    Env_config_core to Host_config.from_env.

    Verifies:
    1. Env_config_core.config_dir_opt has 0 callers (function removed).
    2. config_dir_resolver.ml invokes Host_config.from_env at least 4 times
       (initial bindings + sanitiser current readers). *)

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

let test_config_dir_resolver_uses_host_config_from_env () =
  let n =
    Ast_grep.count_calls
      ~module_path:"lib/config_dir_resolver/config_dir_resolver.ml"
      ~callee:"Host_config.from_env"
  in
  if n < 4
  then
    failf
      "config_dir_resolver.ml must call Host_config.from_env >= 4; got %d"
      n
;;

let () =
  run
    "rfc-0085-pr-8-config-dir-resolver-host-config"
    [ ( "Env_config_core purge"
      , [ test_case
            "config_dir_opt callers = 0"
            `Quick
            test_config_dir_opt_callers_zero
        ] )
    ; ( "Host_config.from_env adoption"
      , [ test_case
            "config_dir_resolver migrated"
            `Quick
            test_config_dir_resolver_uses_host_config_from_env
        ] )
    ]
;;
