open Alcotest

module Mcp_eio = Masc_mcp.Mcp_server_eio

let temp_dir () =
  let dir = Filename.temp_file "test_verify_handoff_tool_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  rm dir

let test_verify_handoff_tool_call () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let success, body =
        Mcp_eio.execute_tool_eio ~sw ~clock state ~name:"masc_verify_handoff"
          ~arguments:
            (`Assoc
              [
                ( "original",
                  `String
                    "Task completed: Implemented user authentication with JWT tokens and OAuth2 support." );
                ( "received",
                  `String
                    "Task completed: Implemented user authentication using JWT tokens and OAuth2 support." );
              ])
      in
      check bool "tool succeeds" true success;
      match Yojson.Safe.from_string body with
      | `Assoc fields ->
          check bool "passed" true
            (match List.assoc_opt "passed" fields with
            | Some (`Bool value) -> value
            | _ -> false);
          check string "verdict" "verified"
            (match List.assoc_opt "verdict" fields with
            | Some (`String value) -> value
            | _ -> "");
          check string "drift type" "none"
            (match List.assoc_opt "drift_type" fields with
            | Some (`String value) -> value
            | _ -> "")
      | _ -> fail "expected json object")

let () =
  run "verify_handoff tool"
    [
      ("tool", [ test_case "tools/call contract" `Quick test_verify_handoff_tool_call ]);
    ]
