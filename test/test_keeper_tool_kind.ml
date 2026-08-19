(** RFC-0386: the closed tool-kind classification is declared, strict on
    parse, and visible in route/discovery evidence. Composition and batch
    kinds come from the catalog/surface declarations — never from matching on
    tool-name strings. *)

open Alcotest

module Descriptor = Masc.Keeper_tool_descriptor
module Catalog = Masc.Keeper_tool_composition_catalog
module Surface = Masc.Keeper_tool_composition_surface

let tool_kind_testable =
  testable
    (fun fmt kind ->
       Format.pp_print_string fmt (Descriptor.tool_kind_to_string kind))
    ( = )
;;

let all_tool_kinds =
  [ Descriptor.Atomic_tool
  ; Descriptor.Composition_tool
  ; Descriptor.Async_composition_tool
  ; Descriptor.Batch_plan_tool
  ]
;;

let test_tool_kind_string_round_trip () =
  List.iter
    (fun kind ->
       match
         Descriptor.tool_kind_of_string (Descriptor.tool_kind_to_string kind)
       with
       | Ok parsed -> check tool_kind_testable "round trip" kind parsed
       | Error detail -> fail detail)
    all_tool_kinds
;;

let test_tool_kind_strings_are_distinct () =
  let rendered = List.map Descriptor.tool_kind_to_string all_tool_kinds in
  check
    int
    "kind strings do not collide"
    (List.length all_tool_kinds)
    (List.length (List.sort_uniq String.compare rendered))
;;

let test_tool_kind_of_string_rejects_unknown () =
  match Descriptor.tool_kind_of_string "multitool" with
  | Error _ -> ()
  | Ok kind ->
    failf
      "unknown tool kind string was accepted as %s"
      (Descriptor.tool_kind_to_string kind)
;;

let test_descriptors_declare_atomic_kind () =
  let descriptors = Descriptor.all_descriptors () in
  check bool "descriptor registry is not empty" true (descriptors <> []);
  List.iter
    (fun (d : Descriptor.t) ->
       check
         tool_kind_testable
         (Printf.sprintf "descriptor %s declares atomic kind" d.Descriptor.id)
         Descriptor.Atomic_tool
         d.Descriptor.tool_kind)
    descriptors
;;

let test_route_evidence_carries_tool_kind () =
  Descriptor.all_descriptors ()
  |> List.iter (fun (d : Descriptor.t) ->
       match Descriptor.route_evidence_json d with
       | `Assoc fields ->
         (match List.assoc_opt "tool_kind" fields with
          | Some (`String "atomic") -> ()
          | Some other ->
            failf
              "route evidence for %s carries a non-atomic tool kind: %s"
              d.Descriptor.id
              (Yojson.Safe.to_string other)
          | None ->
            failf "route evidence for %s omits tool_kind" d.Descriptor.id)
       | _ -> fail "route evidence is not a JSON object")
;;

let test_discovery_fields_carry_tool_kind () =
  Descriptor.all_descriptors ()
  |> List.iter (fun (d : Descriptor.t) ->
       match List.assoc_opt "tool_kind" (Descriptor.discovery_fields d) with
       | Some (`String "atomic") -> ()
       | Some other ->
         failf
           "discovery fields for %s carry a non-atomic tool kind: %s"
           d.Descriptor.id
           (Yojson.Safe.to_string other)
       | None ->
         failf "discovery fields for %s omit tool_kind" d.Descriptor.id)
;;

let inline_and_async_catalog =
  {|[[compositions]]
name = "clock-inline"
execution = "inline"
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions]]
name = "clock-background"
execution = "async"
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
;;

let test_catalog_entries_declare_tool_kind () =
  let catalog =
    match Catalog.parse inline_and_async_catalog with
    | Ok catalog -> catalog
    | Error error -> fail (Catalog.error_to_string error)
  in
  let entry name =
    match Catalog.find catalog name with
    | Some entry -> entry
    | None -> failf "composition lookup missed exact name: %s" name
  in
  check
    tool_kind_testable
    "inline composition is a composition tool"
    Descriptor.Composition_tool
    (Catalog.tool_kind (entry "clock-inline"));
  check
    tool_kind_testable
    "async composition is an async composition tool"
    Descriptor.Async_composition_tool
    (Catalog.tool_kind (entry "clock-background"))
;;

let test_async_controls_and_plan_execute_declare_kinds () =
  check
    tool_kind_testable
    "status control is an async composition tool"
    Descriptor.Async_composition_tool
    Catalog.status_tool_kind;
  check
    tool_kind_testable
    "cancel control is an async composition tool"
    Descriptor.Async_composition_tool
    Catalog.cancel_tool_kind;
  check
    tool_kind_testable
    "plan execute is a batch plan tool"
    Descriptor.Batch_plan_tool
    Surface.plan_execute_tool_kind
;;

let () =
  run
    "keeper_tool_kind"
    [ ( "tool_kind"
      , [ test_case
            "string round trip"
            `Quick
            test_tool_kind_string_round_trip
        ; test_case
            "kind strings are distinct"
            `Quick
            test_tool_kind_strings_are_distinct
        ; test_case
            "rejects unknown kind string"
            `Quick
            test_tool_kind_of_string_rejects_unknown
        ; test_case
            "descriptors declare atomic kind"
            `Quick
            test_descriptors_declare_atomic_kind
        ; test_case
            "route evidence carries tool kind"
            `Quick
            test_route_evidence_carries_tool_kind
        ; test_case
            "discovery fields carry tool kind"
            `Quick
            test_discovery_fields_carry_tool_kind
        ; test_case
            "catalog entries declare tool kind"
            `Quick
            test_catalog_entries_declare_tool_kind
        ; test_case
            "async controls and plan execute declare kinds"
            `Quick
            test_async_controls_and_plan_execute_declare_kinds
        ] )
    ]
;;
