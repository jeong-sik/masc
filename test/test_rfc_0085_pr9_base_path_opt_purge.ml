open Alcotest

(** RFC-0085 PR-9 — Verify Env_config_core.base_path_opt /
    base_path_raw_opt have 0 external callers; Host_config.t
    surfaces both [base_path] (normalised) and [base_path_raw] (raw). *)

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
      ~module_path:"lib/voice/voice_config.ml"
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
