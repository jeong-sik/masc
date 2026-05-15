open Alcotest

(** RFC-0085 PR-10 — home + assets_dir env readers absorbed into
    Host_config.t. *)

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

let test_home_dir_opt_callers_zero () =
  let n = count_external_callers ~callee:"Env_config_core.home_dir_opt" in
  let n2 = count_external_callers ~callee:"Env_config.home_dir_opt" in
  check int "external home_dir_opt callers = 0" 0 (n + n2)
;;

let test_assets_dir_opt_callers_zero () =
  let n = count_external_callers ~callee:"Env_config_core.assets_dir_opt" in
  let n2 = count_external_callers ~callee:"Env_config.assets_dir_opt" in
  check int "external assets_dir_opt callers = 0" 0 (n + n2)
;;

let test_host_config_has_home_and_assets () =
  let h = Host_config.host () in
  (* fields exist as option types; just touch them *)
  let _ = h.home in
  let _ = h.assets_dir in
  ()
;;

let () =
  run
    "rfc-0085-pr-10-home-assets-purge"
    [ ( "Env_config_core surface"
      , [ test_case "home_dir_opt callers = 0" `Quick test_home_dir_opt_callers_zero
        ; test_case "assets_dir_opt callers = 0" `Quick test_assets_dir_opt_callers_zero
        ] )
    ; ( "Host_config record"
      , [ test_case "home + assets_dir fields exist" `Quick test_host_config_has_home_and_assets ]
      )
    ]
;;
