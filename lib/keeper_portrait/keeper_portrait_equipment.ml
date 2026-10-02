module Item = Keeper_portrait_item
module Look = Keeper_portrait_look

let to_json equipment =
  `Assoc
    (List.map
       (fun slot ->
         let id = match Item.in_slot equipment slot with
           | Some item -> Item.id item
           | None -> Item.empty_id slot in
         Item.slot_id slot, `String id)
       Item.slots)

let of_json (json : Yojson.Safe.t) =
  let ( let* ) = Result.bind in
  match json with
  | `Assoc fields ->
    let keys = List.map fst fields |> List.sort String.compare in
    let expected = List.map Item.slot_id Item.slots |> List.sort String.compare in
    if keys <> expected then Error "equipment must contain each known slot exactly once"
    else
      List.fold_left (fun result slot ->
        let* equipment = result in
        match List.assoc_opt (Item.slot_id slot) fields with
        | Some (`String id) when String.equal id (Item.empty_id slot) -> Ok equipment
        | Some (`String id) ->
          (match Item.of_id id with
           | Some item when Item.slot item = slot -> Ok (Item.preview item equipment)
           | Some _ | None -> Error ("invalid equipment item for " ^ Item.slot_id slot))
        | Some (`Assoc _ | `List _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _)
        | None -> Error ("equipment slot must be an item id: " ^ Item.slot_id slot))
        (Ok Look.bare) Item.slots
  | `List _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ ->
    Error "equipment must be an object"

let key equipment = Yojson.Safe.to_string (to_json equipment)

type reading = Ready of Look.equipment | Unavailable of string

let reading_to_json = function
  | Ready equipment -> `Assoc ["state", `String "ready"; "equipment", to_json equipment]
  | Unavailable reason -> `Assoc ["state", `String "unavailable"; "reason", `String reason]

let reading_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let keys = List.map fst fields |> List.sort String.compare in
    (match List.assoc_opt "state" fields with
     | Some (`String "ready") when keys = ["equipment"; "state"] ->
       (match List.assoc_opt "equipment" fields with
        | Some equipment -> Result.map (fun value -> Ready value) (of_json equipment)
        | None -> Error "ready portrait needs equipment")
     | Some (`String "unavailable") when keys = ["reason"; "state"] ->
       (match List.assoc_opt "reason" fields with
        | Some (`String reason) when String.trim reason <> "" -> Ok (Unavailable reason)
        | Some (`String _ | `Assoc _ | `List _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _)
        | None -> Error "unavailable portrait needs a nonempty reason")
     | Some (`String _ | `Assoc _ | `List _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _)
     | None -> Error "unknown or malformed portrait state")
  | `List _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ ->
    Error "portrait observation must be an object"
