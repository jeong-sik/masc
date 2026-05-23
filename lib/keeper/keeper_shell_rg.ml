open Keeper_types
open Keeper_exec_shared

let handle
      ~op
      ~(meta : keeper_meta)
      ~(config : Coord.config)
      ~(args : Yojson.Safe.t)
      ?turn_sandbox_factory
      ~root
      ~raw_path
  =
  let pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
  if pattern = ""
  then error_json_for_op ~op "pattern is required for rg. Good: pattern='handle_request'. Bad: pattern=''."
  else (
    match Keeper_shell_runtime.read_target ~config ~meta ~args ~root with
    | Error e -> Keeper_shell_runtime.path_error ~op ~meta ~raw_path e
    | Ok target ->
      let limit = shell_readonly_limit args in
      let file_type = Safe_ops.json_string ~default:"" "type" args |> String.trim in
      let glob = Safe_ops.json_string ~default:"" "glob" args |> String.trim in
      let make_argv base path =
        let base_argv = [ base; "-n"; "-m"; string_of_int limit ] in
        let type_argv = if file_type <> "" then [ "--type"; file_type ] else [] in
        let glob_argv = if glob <> "" then [ "--glob"; glob ] else [] in
        base_argv @ type_argv @ glob_argv @ [ pattern; path ]
      in
      let rg_available = Keeper_shell_shared.shell_command_available "rg" in
      let grep_available = Keeper_shell_shared.shell_command_available "grep" in
      let host_base =
        if rg_available then "rg"
        else if grep_available then "grep"
        else ""
      in
      if host_base = ""
      then Keeper_shell_runtime.path_error ~op ~meta ~raw_path
        "rg executable not found, and grep fallback is unavailable"
      else if (not rg_available) && (file_type <> "" || glob <> "")
      then Keeper_shell_runtime.path_error ~op ~meta ~raw_path
        "rg executable not found; grep fallback only supports pattern and path"
      else
        let host_argv =
          if host_base = "rg"
          then make_argv "rg" target
          else [ "grep"; "-R"; "-n"; "-I"; "-m"; string_of_int limit; "--"; pattern; target ]
        in
        match
          Keeper_shell_runtime.run_readonly_op ~config ~meta ?turn_sandbox_factory ~op ~target
            ~ok_exit_codes:[ 0; 1 ]
            ~host_argv
            ~docker_argv:(fun cpath -> make_argv "rg" cpath)
            ~max_bytes:1_000_000
            ~timeout_sec:Keeper_shell_shared.read_timeout_sec
            ()
        with
        | Error response -> response
        | Ok (via, st, out) ->
          (* rg exit codes: 0=matches found, 1=no matches (not an error), 2+=real error.
             Treat exit 1 as success with empty results — "no match" is a valid answer. *)
          Keeper_shell_runtime.readonly_json_string
            (Keeper_shell_runtime.readonly_json_fields
               ~ok_when:(fun st -> st = Unix.WEXITED 0 || st = Unix.WEXITED 1)
               ~op ~path:target ~via ~status:st
               ~output_field:"matches"
               ~output:(lines_to_json ~limit out)
               ~extra:[ "pattern", `String pattern ]
               ()))
;;
