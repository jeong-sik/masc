(** Every descriptor whose internal name has a catalog row carries that row's
    description, byte for byte.

    The model reads [Keeper_tool_descriptor.t.description]
    ([Keeper_tools_agent_core_bundle]); the dashboard's tools view reads the
    catalog ([Config.raw_all_tool_schemas], the config/tools/*.toml rows). When
    a descriptor holds its own literal, the dashboard shows a sentence the
    Keeper never received. That happened to keeper_time_now and five keeper_*
    tools (#32494, #32525, #32528) and then to Execute, whose literal still
    said a script line is not handed to a shell after #32087 made it one
    (#32546). The per-tool parity suites compare the TOML with the decoded
    record and never reach the descriptor, which is why none of them noticed.

    This walks the descriptor list instead of pinning names, so a descriptor
    added later with a literal fails here without anyone listing it. *)

open Alcotest
module Descriptor = Masc.Keeper_tool_descriptor

let catalog_row name =
  List.find_opt
    (fun (row : Masc_domain.tool_schema) -> String.equal row.name name)
    Masc.Config.raw_all_tool_schemas
;;

(* Internal names that have a catalog row, and the rows whose description
   the descriptor does not repeat. *)
let compare_against_catalog () =
  List.fold_left
    (fun (compared, mismatches) (descriptor : Descriptor.t) ->
       match catalog_row descriptor.internal_name with
       | None -> compared, mismatches
       | Some row ->
         let compared = descriptor.internal_name :: compared in
         if String.equal row.description descriptor.description
         then compared, mismatches
         else
           ( compared
           , Printf.sprintf
               "%s\n  descriptor: %S\n  catalog:    %S"
               descriptor.internal_name
               descriptor.description
               row.description
             :: mismatches ))
    ([], [])
    (Descriptor.all_descriptors ())
;;

let test_catalogued_descriptors_repeat_their_row () =
  let _, mismatches = compare_against_catalog () in
  check
    (list string)
    "descriptors whose description differs from their catalog row"
    []
    (List.rev mismatches)
;;

(* An empty comparison would pass the test above for nothing. The two tools
   that were caught carrying literals must be among the compared ones. *)
let test_the_comparison_covers_execute_and_time_now () =
  let compared, _ = compare_against_catalog () in
  let compared = List.sort_uniq String.compare compared in
  check
    (list string)
    "compared internal names include the two past offenders"
    [ "keeper_time_now"; "tool_execute" ]
    (List.filter
       (fun name -> List.mem name [ "keeper_time_now"; "tool_execute" ])
       compared)
;;

let () =
  run
    "descriptor description from catalog"
    [ ( "catalogued descriptors"
      , [ test_case "repeat their catalog row" `Quick test_catalogued_descriptors_repeat_their_row
        ; test_case
            "comparison covers execute and time_now"
            `Quick
            test_the_comparison_covers_execute_and_time_now
        ] )
    ]
;;
