open Alcotest

module Mcp_eio = Masc_mcp.Mcp_server_eio
module Tool_catalog = Masc_mcp.Tool_catalog

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

let tools_list_response ~clock ~sw state =
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 1);
          ("method", `String "tools/list");
          ("params", `Assoc []);
        ])
  in
  Mcp_eio.handle_request ~clock ~sw state request

let tool_has_field tool field =
  match tool with
  | `Assoc fields -> List.mem_assoc field fields
  | _ -> false

let test_visible_tools_hide_internal_metadata () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let tools = tools_list_response ~clock ~sw state |> response_tools in
      let status_tool =
        match tools with
        | tool :: _ -> tool
        | [] -> fail "expected visible tools on default /mcp surface"
      in
      check bool "standard tools expose title" true
        (tool_string_field status_tool "title" <> "");
      check bool "standard tools expose annotations" true
        (Yojson.Safe.Util.member "annotations" status_tool <> `Null);
      check bool "visibility metadata hidden" false
        (tool_has_field status_tool "visibility");
      check bool "implementationStatus hidden" false
        (tool_has_field status_tool "implementationStatus");
      check bool "hidden utility omitted" false
        (List.exists
           (function
             | `Assoc fields ->
                 List.assoc_opt "name" fields = Some (`String "masc_post_create")
             | _ -> false)
           tools))

let test_tool_catalog_retains_contract_truth () =
  let archive_meta = Tool_catalog.metadata "masc_archive_save" in
  let claim_meta = Tool_catalog.metadata "masc_claim" in
  let runtime_meta = Tool_catalog.metadata "masc_runtime_verify" in
  let runtime_alias_meta = Tool_catalog.metadata "masc_llama_runtime_verify" in
  check string "archive_save placeholder" "placeholder"
    (Tool_catalog.implementation_status_to_string archive_meta.implementation_status);
  check bool "archive_save not callable on default mcp" false
    (Tool_catalog.is_default_mcp_callable "masc_archive_save");
  check string "claim deprecated" "deprecated"
    (Tool_catalog.lifecycle_to_string claim_meta.lifecycle);
  check bool "claim not callable on default mcp" false
    (Tool_catalog.is_default_mcp_callable "masc_claim");
  check string "runtime verify active" "active"
    (Tool_catalog.lifecycle_to_string runtime_meta.lifecycle);
  check bool "runtime verify callable" true
    (Tool_catalog.is_default_mcp_callable "masc_runtime_verify");
  check string "runtime alias deprecated" "deprecated"
    (Tool_catalog.lifecycle_to_string runtime_alias_meta.lifecycle);
  check bool "runtime alias not callable" false
    (Tool_catalog.is_default_mcp_callable "masc_llama_runtime_verify")

let () =
  run "tool contract truth"
    [
      ("visible", [ test_case "visible tools hide internal metadata" `Quick test_visible_tools_hide_internal_metadata ]);
      ("catalog", [ test_case "tool catalog retains contract truth" `Quick test_tool_catalog_retains_contract_truth ]);
    ]
