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
  let name_pattern =
    let pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
    if pattern <> ""
    then pattern
    else Safe_ops.json_string ~default:"" "name" args |> String.trim
  in
  if name_pattern = ""
  then error_json_for_op ~op "pattern is required for find. Good: pattern='*.ml'. Bad: pattern=''."
  else (
    match Keeper_shell_runtime.read_target ~config ~meta ~args ~base_path:root () with
    | Error e -> Keeper_shell_runtime.path_error ~op ~meta ~raw_path e
    | Ok target ->
      let limit = shell_readonly_limit args in
      let make_argv path =
        [ "find"; path; "-maxdepth"; "5"; "-name"; name_pattern;
          "-not"; "-path"; "*/.git/*";
          "-not"; "-path"; "*/_build/*";
          "-not"; "-path"; "*/.masc/*"  ]
      in
      match
        Keeper_shell_runtime.run_readonly_op ~config ~meta ?turn_sandbox_factory ~op ~target
          ~host_argv:(make_argv target)
          ~docker_argv:(fun cpath -> make_argv cpath)
          ~max_bytes:1_000_000
          ~timeout_sec:Keeper_shell_timeout.read_timeout_sec
          ()
      with
      | Error response -> response
      | Ok (via, st, out) ->
        Keeper_shell_runtime.readonly_json_string
          (Keeper_shell_runtime.readonly_json_fields ~op ~path:target ~via
             ~status:st ~output_field:"files"
             ~output:(lines_to_json ~limit out)
             ~extra:[ "name", `String name_pattern ]
             ()))
;;
