module Lib = Masc_mcp

open Alcotest

let test_list_masc_tools_exposes_board_and_keeper_schemas () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Switch.run (fun sw ->
        match
          Lib.Worker_runtime.list_masc_tools ~sw ~auth_token:None
            ~session_id:"worker-test"
            ~names:
              (Some
                 [
                   "masc_board_post";
                   "masc_board_list";
                 ])
            ()
        with
        | Ok schemas ->
            let names =
              List.map (fun (schema : Types.tool_schema) -> schema.name) schemas
            in
            check bool "masc_board_post" true (List.mem "masc_board_post" names);
            check bool "masc_board_list" true (List.mem "masc_board_list" names)
        | Error err -> failf "expected schema lookup to succeed: %s" err)

let () =
  Alcotest.run "worker_runtime"
    [
      ( "tool_schemas",
        [ test_case "includes board and keeper tools for local workers" `Quick
            test_list_masc_tools_exposes_board_and_keeper_schemas ] );
    ]
