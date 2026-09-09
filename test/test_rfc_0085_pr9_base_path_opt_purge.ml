open Alcotest

(** RFC-0085 PR-9 — Verify Env_config_core.base_path_opt /
    base_path_raw_opt have 0 external callers; Host_config.t
    surfaces both [base_path] (normalised) and [base_path_raw] (raw). *)

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

let test_base_path_opt_callers_zero () =
  let files = walk_dirs [ "lib"; "bin" ] in
  let total =
    List.fold_left
      (fun acc f ->
        if String.equal (Filename.basename f) "env_config_core.ml"
        then acc (* file-private internal uses OK *)
        else
          acc
          + Ast_grep.count_calls ~module_path:f ~callee:"Env_config_core.base_path_opt"
          + Ast_grep.count_calls ~module_path:f ~callee:"Env_config.base_path_opt")
      0
      files
  in
  check int "external Env_config_core.base_path_opt callers = 0" 0 total
;;

let test_base_path_raw_opt_callers_zero () =
  let files = walk_dirs [ "lib"; "bin" ] in
  let total =
    List.fold_left
      (fun acc f ->
        if String.equal (Filename.basename f) "env_config_core.ml"
        then acc
        else acc + Ast_grep.count_calls ~module_path:f ~callee:"Env_config_core.base_path_raw_opt")
      0
      files
  in
  check int "external Env_config_core.base_path_raw_opt callers = 0" 0 total
;;

let test_host_config_base_path_used () =
  let n =
    Ast_grep.count_calls
      ~module_path:"lib/voice_config/voice_config.ml"
      ~callee:"Host_config.from_env"
  in
  if n < 1
  then failf "voice_config.ml must use Host_config.from_env >= 1; got %d" n
;;

let () =
  run
    "rfc-0085-pr-9-base-path-opt-purge"
    [ ( "Env_config_core public surface"
      , [ test_case "base_path_opt purge" `Quick test_base_path_opt_callers_zero
        ; test_case "base_path_raw_opt purge" `Quick test_base_path_raw_opt_callers_zero
        ] )
    ; ( "Host_config adoption"
      , [ test_case "voice_config uses host_config" `Quick test_host_config_base_path_used ]
      )
    ]
;;
