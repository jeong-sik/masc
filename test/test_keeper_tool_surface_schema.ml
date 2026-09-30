(** Provider validity of the model-visible tool schemas. *)

open Alcotest

(* Gemini refuses a whole request when any tool declares an array without
   [items]: #39061's two bare arrays failed every Antigravity turn once #38588
   declared every Antigravity tool eagerly. Tool_definition_toml refuses that
   shape at load; this walks the whole model-visible surface, including the
   schemas built in OCaml, which the loader never sees. *)
let arrays_without_items schema =
  let rec walk path acc = function
    | `Assoc fields ->
      let is_array =
        match List.assoc_opt "type" fields with
        | Some (`String "array") -> true
        | Some (`List types) -> List.mem (`String "array") types
        | Some _ | None -> false
      in
      let acc =
        if is_array && not (List.mem_assoc "items" fields)
        then String.concat "." (List.rev path) :: acc
        else acc
      in
      List.fold_left (fun acc (key, value) -> walk (key :: path) acc value) acc fields
    | `List values -> List.fold_left (walk path) acc values
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ -> acc
  in
  List.rev (walk [] [] schema)
;;

let test_every_model_visible_array_declares_items () =
  check (list string) "the walker names a bare array"
    [ "properties.rows.items.properties.tags" ]
    (arrays_without_items
       (`Assoc
         [ "type", `String "object"
         ; ( "properties"
           , `Assoc
               [ ( "rows"
                 , `Assoc
                     [ "type", `String "array"
                     ; ( "items"
                       , `Assoc
                           [ "type", `String "object"
                           ; ( "properties"
                             , `Assoc [ "tags", `Assoc [ "type", `String "array" ] ] )
                           ] )
                     ] )
               ] )
         ]));
  let offenders =
    List.concat_map
      (fun (schema : Masc_domain.tool_schema) ->
         List.map (fun path -> schema.name ^ ": " ^ path)
           (arrays_without_items schema.input_schema))
      (Masc.Keeper_tool_descriptor.model_visible_schemas ())
  in
  check (list string) "model-visible arrays without items" [] offenders
;;

let () =
  run
    "keeper_tool_surface_schema"
    [ ( "provider schema validity"
      , [ test_case "every array declares items" `Quick
            test_every_model_visible_array_declares_items
        ] )
    ]
;;
