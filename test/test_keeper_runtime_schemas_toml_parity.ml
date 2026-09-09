(** The publication order of [Keeper_runtime_schemas_toml.schemas], and the
    keeper_artifact_read bounds and keeper_analyze_image enum against their owners.

    Two of the four build values from an owner module rather than literals:
    keeper_artifact_read takes its max_bytes bounds and default from
    [Keeper_artifact_read], and analyze_image takes its media-type enum from
    [Keeper_vision_tool]. A TOML literal would cut that derivation, so they
    stay in OCaml until each has a test pinning the file against its owner, the
    way [test_operator_surface_toml_parity] pins the masc_config category enum.

    One value moved rather than being pinned: masc_fusion_status declared an
    empty ["required"], which says nothing an absent one does not -- both
    readers fold them together. Every tool that emitted one was cleaned in the
    same campaign, and this pin carries the cleaned value.

    The descriptions and schemas this suite also pinned were literals read off
    the same published values before the declarations moved into
    [config/tools/*.toml] -- one producer against a snapshot of itself. Those
    cases are gone; what stays reads the published value. *)

open Alcotest


(* name, description, input_schema (keys sorted), in the order
   Keeper_runtime_schemas_toml.schemas publishes. The three provider Files
   tools are #33639 (RFC-0430 Phase 3); keeper_analyze_image carries the
   runtime_id parameter #34561 added. *)
let expected =
  [ "keeper_artifact_read"
  ; "masc_fusion"
  ; "masc_fusion_status"
  ; "masc_file_upload"
  ; "masc_file_delete"
  ; "masc_file_list"
  ; "keeper_analyze_image"
  ]
;;

let published = Masc.Keeper_runtime_schemas_toml.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Keeper_runtime_schemas_toml.schemas")
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Keeper_runtime_schemas_toml.schemas in order"
    expected
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;


(* The pin the migration to TOML was supposed to arrive with. Two of these
   schemas declare numbers an OCaml module owns, and moving them into a file
   cut the derivation without leaving anything to notice a divergence. It
   diverged: #32748 lowered keeper_artifact_read's bound to 16,384 and the
   file kept advertising 65,536, so the schema told a model it could ask for
   four times what the handler accepts. These compare the published
   declaration against the owner rather than against a second literal. *)
let declared schema_name ~field ~key =
  match (find schema_name).input_schema with
  | `Assoc top ->
    (match List.assoc_opt "properties" top with
     | Some (`Assoc properties) ->
       (match List.assoc_opt field properties with
        | Some (`Assoc declaration) -> List.assoc_opt key declaration
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let declared_int schema_name ~field ~key =
  match declared schema_name ~field ~key with
  | Some (`Int value) -> Some value
  | _ -> None
;;

let test_artifact_read_bounds_match_their_owner () =
  check
    (option int)
    "keeper_artifact_read declares Keeper_artifact_read.maximum_max_bytes"
    (Some Masc.Keeper_artifact_read.maximum_max_bytes)
    (declared_int "keeper_artifact_read" ~field:"max_bytes" ~key:"maximum");
  check
    (option int)
    "keeper_artifact_read declares Keeper_artifact_read.default_max_bytes"
    (Some Masc.Keeper_artifact_read.default_max_bytes)
    (declared_int "keeper_artifact_read" ~field:"max_bytes" ~key:"default")
;;

let test_analyze_image_enum_matches_its_owner () =
  let declared_types =
    match declared "keeper_analyze_image" ~field:"media_type" ~key:"enum" with
    | Some (`List items) ->
      List.filter_map (function `String value -> Some value | _ -> None) items
    | _ -> []
  in
  check
    (list string)
    "keeper_analyze_image declares Keeper_vision_tool.supported_image_media_types"
    Masc.Keeper_vision_tool.supported_image_media_types
    declared_types
;;

let () =
  run
    "keeper_runtime_schemas_toml_parity"
    [ ( "order"
      , [ test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ; ( "owner_derivation"
      , [ test_case
            "keeper_artifact_read bounds match their owner"
            `Quick
            test_artifact_read_bounds_match_their_owner
        ; test_case
            "keeper_analyze_image enum matches its owner"
            `Quick
            test_analyze_image_enum_matches_its_owner
        ] )
    ]
;;
