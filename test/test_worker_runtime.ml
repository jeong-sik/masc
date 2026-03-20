module Lib = Masc_mcp

open Alcotest

let test_list_masc_tools_exposes_board_and_lodge_schemas () =
  Eio_main.run @@ fun _env ->
    Eio.Switch.run (fun sw ->
        match
          Lib.Worker_runtime.list_masc_tools ~sw ~auth_token:None
            ~session_id:"worker-test"
            ~names:
              (Some
                 [
                   "masc_board_post";
                   "masc_board_list";
                   "lodge_search";
                   "lodge_profile";
                   "lodge_research";
                 ])
            ()
        with
        | Ok schemas ->
            let names =
              List.map (fun (schema : Lib.Types.tool_schema) -> schema.name) schemas
            in
            check bool "masc_board_post" true (List.mem "masc_board_post" names);
            check bool "masc_board_list" true (List.mem "masc_board_list" names);
            check bool "lodge_search" true (List.mem "lodge_search" names);
            check bool "lodge_profile" true (List.mem "lodge_profile" names);
            check bool "lodge_research" true (List.mem "lodge_research" names)
        | Error err -> failf "expected schema lookup to succeed: %s" err)

let () =
  Alcotest.run "worker_runtime"
    [
      ( "tool_schemas",
        [ test_case "includes board and lodge tools for local workers" `Quick
            test_list_masc_tools_exposes_board_and_lodge_schemas ] );
    ]
