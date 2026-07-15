open Alcotest

module Mcp_eio = Masc.Mcp_server_eio
module Config = Masc.Config
module Workspace = Masc.Workspace

let temp_dir () =
  let dir = Filename.temp_file "test_tool_contract_truth_" "" in
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

let response_tools response =
  let open Yojson.Safe.Util in
  response |> member "result" |> member "tools" |> to_list

let tool_string_field tool field =
  match tool with
  | `Assoc fields -> (
      match List.assoc_opt field fields with
      | Some (`String value) -> value
      | _ -> fail ("missing string field: " ^ field))
  | _ -> fail "tool must be object"

let find_tool_exn tools name =
  List.find
    (function
      | `Assoc fields -> (
          match List.assoc_opt "name" fields with
          | Some (`String tool_name) -> String.equal tool_name name
          | _ -> false)
      | _ -> false)
    tools

let tool_names tools =
  tools
  |> List.filter_map (function
       | `Assoc fields -> (
           match List.assoc_opt "name" fields with
           | Some (`String name) -> Some name
           | _ -> None)
       | _ -> None)

let tools_list_response ~clock ~sw ?(include_hidden = false) ?names state =
  let names_json =
    match names with
    | Some values -> [ ("names", `List (List.map (fun value -> `String value) values)) ]
    | None -> []
  in
  let hidden_json =
    if include_hidden then [ ("include_hidden", `Bool true) ] else []
  in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 1);
          ("method", `String "tools/list");
          ("params", `Assoc (names_json @ hidden_json));
        ])
  in
  Mcp_eio.handle_request ~clock ~sw state request

let test_public_tools_expose_only_truthful_statuses () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let tools = tools_list_response ~clock ~sw state |> response_tools in
      List.iter
        (fun tool ->
          let status = tool_string_field tool "implementationStatus" in
          check bool ("truthful public status: " ^ tool_string_field tool "name")
            true
            (String.equal status "real" || String.equal status "adapter"))
        tools)

let test_keeper_lifecycle_front_door_is_public () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let tools = tools_list_response ~clock ~sw state |> response_tools in
      let names = tool_names tools in
      List.iter
        (fun name ->
          check bool (name ^ " visible in default tools/list") true
            (List.mem name names))
        [
          "masc_keeper_list";
          "masc_keeper_status";
          "masc_keeper_up";
          "masc_keeper_down";
        ];
      check bool "async keeper delegation remains hidden by default" false
        (List.mem "masc_keeper_delegate" names))

let test_selected_tools_report_contract_status () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let tools =
        tools_list_response ~clock ~sw ~include_hidden:true
          ~names:
            [
              "masc_transition";
            ]
          state
        |> response_tools
      in
      let canonical = find_tool_exn tools "masc_transition" in
      check string "transition real" "real"
        (tool_string_field canonical "implementationStatus"))

let () =
  run "tool contract truth"
    [
      ( "public",
        [
          test_case "public tools stay truthful" `Quick
            test_public_tools_expose_only_truthful_statuses;
          test_case "keeper lifecycle front door is public" `Quick
            test_keeper_lifecycle_front_door_is_public;
        ] );
      ("hidden", [ test_case "selected tools expose implementation status" `Quick test_selected_tools_report_contract_status ]);
    ]
