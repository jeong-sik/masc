(** Tests for masc_verify_handoff tool.

    Post-pruning: masc_verify_handoff was removed from the tool registry.
    We assert the negative contract — dispatching the tool fails because
    its schema and handler are gone. *)

open Alcotest
module Mcp_eio = Masc_mcp.Mcp_server_eio

let temp_dir () =
  let dir = Filename.temp_file "test_verify_handoff_tool_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  rm dir
;;

let test_verify_handoff_removed_from_registry () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
       let success, _body =
         Mcp_eio.execute_tool_eio
           ~sw
           ~clock
           state
           ~name:"masc_verify_handoff"
           ~arguments:(`Assoc [ "original", `String "x"; "received", `String "y" ])
       in
       (* Tool was pruned from registry — dispatch should fail. *)
       check bool "tool dispatch fails after prune" false success)
;;

let () =
  run
    "verify_handoff tool"
    [ ( "tool"
      , [ test_case
            "tools/call contract (pruned)"
            `Quick
            test_verify_handoff_removed_from_registry
        ] )
    ]
;;
