open Alcotest

let catalog_rel = "docs/schema-surfaces/runtime-output-surfaces.v1.json"

let rec find_repo_root dir =
  if Sys.file_exists (Filename.concat dir "dune-project")
  then dir
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir
    then fail "could not locate dune-project"
    else find_repo_root parent)
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

let allowed_stability =
  [ "stable"; "evolving"; "internal"; "operator_internal"; "frozen" ]
;;

let has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix
;;

let test_catalog_shape () =
  let json = catalog () in
  check int "version" 1 (require_int "version" json);
  let rows = surfaces json in
  check bool "has surfaces" true (rows <> []);
  let ids = List.map (require_string "id") rows in
  let sorted = List.sort String.compare ids in
  check (list string) "ids unique" sorted (List.sort_uniq String.compare ids);
  List.iter
    (fun row ->
       let id = require_string "id" row in
       let historical =
         match member "removed_in" row with
         | Some (`String s) when String.length s > 0 -> true
         | _ -> false
       in
       check
         bool
         (id ^ " kind allowed")
         true
         (List.mem (require_string "kind" row) allowed_kinds);
       check
         bool
         (id ^ " stability allowed")
         true
         (List.mem (require_string "stability" row) allowed_stability);
       check
         bool
         (id ^ " owner present")
         true
         (String.length (require_string "owner" row) > 0);
       check
         bool
         (id ^ " sources present")
         true
         (historical || require_string_list "schema_source" row <> []);
       check
         bool
         (id ^ " tests present")
         true
         (historical || require_string_list "tests" row <> []))
    rows
;;

let test_required_surfaces_present () =
  let ids = catalog () |> surfaces |> List.map (require_string "id") in
  List.iter
    (fun id -> check bool ("required surface: " ^ id) true (List.mem id ids))
    [ "oas.event_bus.v1"
    ; "oas.runtime_protocol.v2"
    ; "oas.runtime_sync_window.v1"
    ; "oas.runtime_report.v1"
    ; "oas.runtime_proof.v1"
    ; "oas.runtime_telemetry_report.v1"
    ; "oas.runtime_evidence_bundle.v1"
    ; "oas.raw_trace_record.v1"
    ; "oas.raw_trace_manifest.v1"
    ; "oas.structured_schema.v1"
    ]
;;

let test_local_paths_exist () =
  catalog ()
  |> surfaces
  |> List.iter (fun row ->
    let id = require_string "id" row in
    let paths =
      require_string_list "schema_source" row @ require_string_list "tests" row
    in
    List.iter
      (fun rel ->
         if not (has_prefix ~prefix:"external:" rel)
         then
           check
             bool
             (id ^ " path exists: " ^ rel)
             true
             (Sys.file_exists (source_path rel)))
      paths)
;;

let () =
  run
    "Schema_surface_index"
    [ ( "catalog"
      , [ test_case "shape" `Quick test_catalog_shape
        ; test_case "required surfaces" `Quick test_required_surfaces_present
        ; test_case "local paths exist" `Quick test_local_paths_exist
        ] )
    ]
;;
