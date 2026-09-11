(** The publication order of [Tool_schemas_schedule.schemas], the fields
    masc_schedule_update shares with create, and what the deferred listing says.

    [masc_schedule_create] has since moved on purpose: the payload envelope was
    replaced by the fields it wrapped, and the two the runtime cannot proceed
    without are now declared mandatory. Its entry is the shape after that
    change, not the pre-migration one. The other three are still the original
    pins.

    The enum arrays are literals in TOML -- nothing there can read an OCaml
    variant. [test_enum_mirror_sync] already compares each of the six against
    Schedule_contract_values, so the owners stay the owners and a drifted
    literal fails there rather than shipping a schema that never offers the
    value.

    [masc_schedule_update] was added after the migration. It deliberately
    shares the create field set and makes [schedule_id] mandatory; a separate
    structural assertion below pins that relationship instead of pretending
    it has pre-migration bytes.

    The descriptions and schemas this suite also pinned were literals read off
    the same published values before the declarations moved into
    [config/tools/*.toml] -- one producer against a snapshot of itself. Those
    cases are gone; what stays reads the published value. *)

open Alcotest


let published = Tool_schemas_schedule.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_schemas_schedule.schemas")
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_schemas_schedule.schemas in order"
    [ "masc_schedule_create"
    ; "masc_schedule_update"
    ; "masc_schedule_list"
    ; "masc_schedule_get"
    ; "masc_schedule_cancel"
    ; "masc_schedule_note_add"
    ; "masc_schedule_notes_list"
    ]
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let object_fields key schema =
  match Yojson.Safe.Util.member key schema with
  | `Assoc fields -> List.map fst fields |> List.sort_uniq String.compare
  | _ -> []
;;

let required_fields schema =
  match Yojson.Safe.Util.member "required" schema with
  | `List values ->
    List.filter_map (function `String value -> Some value | _ -> None) values
  | _ -> []
;;

let test_update_reuses_create_fields_and_requires_identity () =
  let create = (find "masc_schedule_create").input_schema in
  let update = (find "masc_schedule_update").input_schema in
  check (list string) "same editable fields"
    (object_fields "properties" create)
    (object_fields "properties" update);
  check (list string) "update additionally requires the stable id"
    [ "schedule_id"; "keeper_name"; "message" ]
    (required_fields update)
;;

(* [masc_schedule_create] is deferred: until the model asks for its schema,
   the listing carries only the first line of its description, cut at the
   listing's 80-byte cap ([Keeper_identity_tool_search.summary_of]). That
   line is the only
   thing a Keeper deciding how to wait for a later time ever reads, so it is
   pinned here next to the prose it summarises. *)
let test_the_deferred_listing_names_the_wait () =
  check
    string
    "masc_schedule_create summary"
    "Wake a Keeper at a later time; the way to wait instead of polling the clock."
    (Masc.Keeper_identity_tool_search.summary_of (find "masc_schedule_create").description)
;;

let () =
  run
    "schedule_tool_toml_parity"
    [ ( "surface"
      , [ test_case "published order" `Quick test_the_published_order_is_unchanged
        ; test_case "update shares fields and requires identity" `Quick
            test_update_reuses_create_fields_and_requires_identity
        ; test_case "deferred listing names the wait" `Quick
            test_the_deferred_listing_names_the_wait
        ] )
    ]
;;
