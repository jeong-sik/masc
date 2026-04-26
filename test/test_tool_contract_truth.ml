open Alcotest
module Mcp_eio = Masc_mcp.Mcp_server_eio
module Config = Masc_mcp.Config
module Coord = Masc_mcp.Coord

let temp_dir () =
  let dir = Filename.temp_file "test_tool_contract_truth_" "" in
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

let response_tools response =
  let open Yojson.Safe.Util in
  response |> member "result" |> member "tools" |> to_list
;;

let tool_string_field tool field =
  match tool with
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | Some (`String value) -> value
     | _ -> fail ("missing string field: " ^ field))
  | _ -> fail "tool must be object"
;;

let find_tool_exn tools name =
  List.find
    (function
      | `Assoc fields ->
        (match List.assoc_opt "name" fields with
         | Some (`String tool_name) -> String.equal tool_name name
         | _ -> false)
      | _ -> false)
    tools
;;

let tools_list_response ~clock ~sw ?(include_hidden = false) ?names state =
  let names_json =
    match names with
    | Some values -> [ "names", `List (List.map (fun value -> `String value) values) ]
    | None -> []
  in
  let hidden_json = if include_hidden then [ "include_hidden", `Bool true ] else [] in
  let request =
    Yojson.Safe.to_string
      (`Assoc
          [ "jsonrpc", `String "2.0"
          ; "id", `Int 1
          ; "method", `String "tools/list"
          ; "params", `Assoc (names_json @ hidden_json)
          ])
  in
  Mcp_eio.handle_request ~clock ~sw state request
;;

let test_visible_tools_expose_only_truthful_statuses () =
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
       let tools = tools_list_response ~clock ~sw state |> response_tools in
       List.iter
         (fun tool ->
            let status = tool_string_field tool "implementationStatus" in
            check
              bool
              ("truthful visible status: " ^ tool_string_field tool "name")
              true
              (String.equal status "real" || String.equal status "adapter"))
         tools)
;;

let test_selected_tools_report_contract_status () =
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
       (* masc_runtime_verify and masc_verify_handoff removed: tools pruned *)
       let tools =
         tools_list_response
           ~clock
           ~sw
           ~include_hidden:true
           ~names:[ "masc_transition" ]
           state
         |> response_tools
       in
       let canonical = find_tool_exn tools "masc_transition" in
       check
         string
         "transition real"
         "real"
         (tool_string_field canonical "implementationStatus"))
;;

let () =
  run
    "tool contract truth"
    [ ( "visible"
      , [ test_case
            "visible tools stay truthful"
            `Quick
            test_visible_tools_expose_only_truthful_statuses
        ] )
    ; ( "hidden"
      , [ test_case
            "selected tools expose implementation status"
            `Quick
            test_selected_tools_report_contract_status
        ] )
    ]
;;
