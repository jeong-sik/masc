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
  else
    Keeper_shell_runtime.with_read_target ~config ~meta ~args ~root ~op ~raw_path
      (fun target ->
        let limit = shell_readonly_limit args in
        let make_argv path =
          [ "find"; path; "-maxdepth"; "5"; "-name"; name_pattern;
            "-not"; "-path"; "*/.git/*";
            "-not"; "-path"; "*/_build/*";
            "-not"; "-path"; "*/.masc/*"  ]
        in
        Keeper_shell_runtime.run_readonly_json_op ~config ~meta ?turn_sandbox_factory ~op ~target
          ~host_argv:(make_argv target)
          ~docker_argv:(fun cpath -> make_argv cpath)
          ~timeout_sec:Keeper_shell_shared.read_timeout_sec
          ~output_field:"files"
          ~output_of_out:(lines_to_json ~limit)
          ~extra:[ "name", `String name_pattern ]
          ())
;;
