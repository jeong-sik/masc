open Alcotest

let catalog_rel = "docs/schema-surfaces/operator-output-surfaces.v1.json"

let rec find_repo_root dir =
  if Sys.file_exists (Filename.concat dir "dune-project")
  then dir
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir then fail "could not locate dune-project" else find_repo_root parent)
;;

let source_path rel = Filename.concat (find_repo_root (Sys.getcwd ())) rel

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let require_string field json =
  match member field json with
  | Some (`String value) -> value
  | _ -> failf "missing string field: %s" field
;;

let require_int field json =
  match member field json with
  | Some (`Int value) -> value
  | _ -> failf "missing int field: %s" field
;;

let require_list field json =
  match member field json with
  | Some (`List values) -> values
  | _ -> failf "missing list field: %s" field
;;

let require_string_list field json =
  require_list field json
  |> List.map (function
    | `String value -> value
    | _ -> failf "field %s must be a string list" field)
;;

let catalog () = Yojson.Safe.from_file (source_path catalog_rel)
let surfaces json = require_list "surfaces" json

let allowed_kinds =
  [ "event_bus"
  ; "http_response"
  ; "json_schema"
  ; "jsonl_artifact"
  ; "ocaml_interface"
  ; "runtime_protocol"
  ; "sse_event"
  ; "tool_schema"
  ; "typescript_schema"
  ]
;;

let allowed_stability = [ "stable"; "evolving"; "internal"; "operator_internal" ]

let test_catalog_shape () =
  let json = catalog () in
  check int "version" 1 (require_int "version" json);
  let rows = surfaces json in
  check bool "has surfaces" true (List.length rows >= 8);
  let ids = List.map (require_string "id") rows in
  check (list string) "ids unique" (List.sort String.compare ids) (List.sort_uniq String.compare ids);
  List.iter
    (fun row ->
      let id = require_string "id" row in
      check bool (id ^ " kind allowed") true (List.mem (require_string "kind" row) allowed_kinds);
      check
        bool
        (id ^ " stability allowed")
        true
        (List.mem (require_string "stability" row) allowed_stability);
      check bool (id ^ " owner present") true (String.length (require_string "owner" row) > 0);
      check bool (id ^ " sources present") true (require_string_list "schema_source" row <> []);
      check bool (id ^ " tests present") true (require_string_list "tests" row <> []);
      ignore (require_string_list "external_refs" row))
    rows
;;

let test_required_surfaces_present () =
  let ids = catalog () |> surfaces |> List.map (require_string "id") in
  List.iter
    (fun id -> check bool ("required surface: " ^ id) true (List.mem id ids))
    [ "masc.keeper_composite.http.v1"
    ; "masc.dashboard_sse.v1"
    ; "masc.keeper_runtime_manifest.jsonl.v1"
    ; "masc.keeper_execution_receipt.jsonl.v1"
    ; "masc.keeper_tool_call_log.jsonl.v1"
    ; "masc.runtime_contract_projection.v1"
    ; "masc.mcp_openapi_tool_schema.v1"
    ; "masc.oas_bridge_events.v1"
    ]
;;

let test_local_paths_exist () =
  catalog ()
  |> surfaces
  |> List.iter (fun row ->
    let id = require_string "id" row in
    let paths = require_string_list "schema_source" row @ require_string_list "tests" row in
    List.iter
      (fun rel -> check bool (id ^ " path exists: " ^ rel) true (Sys.file_exists (source_path rel)))
      paths)
;;

let test_oas_refs_are_external () =
  catalog ()
  |> surfaces
  |> List.iter (fun row ->
    let id = require_string "id" row in
    require_string_list "external_refs" row
    |> List.iter (fun ref_id ->
      check bool (id ^ " external ref is OAS: " ^ ref_id) true (String.starts_with ~prefix:"oas." ref_id)))
;;

let () =
  run
    "Schema_surface_index"
    [ ( "catalog"
      , [ test_case "shape" `Quick test_catalog_shape
        ; test_case "required surfaces" `Quick test_required_surfaces_present
        ; test_case "local paths exist" `Quick test_local_paths_exist
        ; test_case "OAS refs are external" `Quick test_oas_refs_are_external
        ] )
    ]
;;
