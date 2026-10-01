module Item = Keeper_portrait_item

let ( let* ) = Result.bind

type price = Unpriced | Priced of int
type entry = { item : Item.t; price : price }
type account = {
  balance_milli : int;
  owned_items : Item.t list;
  catalog : entry list;
}
type t = Off | Disabled of string | Ready of account

let exact_keys expected fields =
  List.sort String.compare (List.map fst fields)
  = List.sort String.compare expected

let object_fields ~context ~keys = function
  | `Assoc fields when exact_keys keys fields -> Ok fields
  | _ -> Error (context ^ " has missing, extra, or duplicate fields")

let field key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error ("missing Item field " ^ key)

let string key fields =
  let* value = field key fields in
  match value with
  | `String value -> Ok value
  | _ -> Error ("Item field " ^ key ^ " must be a string")

let nonnegative_amount key fields =
  let* value = field key fields in
  match value with
  | `String amount
    when amount <> ""
         && (String.length amount = 1 || amount.[0] <> '0')
         && String.for_all (function '0' .. '9' -> true | _ -> false) amount ->
    (match int_of_string_opt amount with
     | Some value when value >= 0 -> Ok value
     | _ -> Error ("Item field " ^ key ^ " is too large"))
  | _ -> Error ("Item field " ^ key ^ " must be a canonical decimal amount")

let item_of_id id =
  match Item.of_id id with
  | Some item -> Ok item
  | None -> Error ("unknown Item id " ^ id)

let decode_list ~context decode = function
  | `List values ->
    let rec loop reversed = function
      | [] -> Ok (List.rev reversed)
      | value :: rest ->
        let* item = decode value in
        loop (item :: reversed) rest
    in
    loop [] values
  | _ -> Error (context ^ " must be a list")

let unique_items ~context items =
  let ids = List.map Item.id items in
  if List.length ids = List.length (List.sort_uniq String.compare ids)
  then Ok ()
  else Error (context ^ " contains duplicate items")

let decode_entry json =
  match json with
  | `Assoc fields ->
    let* status = string "price_status" fields in
    let* price =
      match status with
      | "unpriced" ->
        let* _ = object_fields ~context:"Item catalog entry"
          ~keys:[ "id"; "slot"; "price_status" ] json in
        Ok Unpriced
      | "priced" ->
        let* _ = object_fields ~context:"Item catalog entry"
          ~keys:[ "id"; "slot"; "price_status"; "price_milli" ] json in
        let* amount = nonnegative_amount "price_milli" fields in
        Ok (Priced amount)
      | _ -> Error ("unknown Item price status " ^ status)
    in
    let* id = string "id" fields in
    let* item = item_of_id id in
    let* slot = string "slot" fields in
    if String.equal slot (Item.slot_id (Item.slot item))
    then Ok { item; price }
    else Error ("wrong slot for Item " ^ id)
  | _ -> Error "Item catalog entry must be an object"

let decode_owned = function
  | `String id -> item_of_id id
  | _ -> Error "owned Item id must be a string"

let decode ~keeper_name json =
  let* initial =
    match json with
    | `Assoc fields -> Ok fields
    | _ -> Error "Item account must be an object"
  in
  let* status = string "status" initial in
  let* fields =
    object_fields ~context:"Item account"
      ~keys:(match status with
        | "off" -> [ "status"; "keeper"; "account_revision" ]
        | "disabled" -> [ "status"; "keeper"; "reason"; "account_revision" ]
        | "ready" ->
          [ "status"; "keeper"; "balance_milli"; "owned_items"; "catalog"; "account_revision" ]
        | _ -> [])
      json
  in
  let* revision = field "account_revision" fields in
  let* revision = match status,revision with
    | "off",`Null -> Ok None
    | ("ready" | "disabled"),`String value when String.length value=64
        && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) value -> Ok (Some value)
    | _ -> Error "Item account revision is missing or malformed for its status" in
  let* reported_keeper = string "keeper" fields in
  if not (String.equal keeper_name reported_keeper)
  then Error "Item account belongs to another Keeper"
  else
    match status with
    | "off" -> Ok (revision, Off)
    | "disabled" ->
      let* reason = string "reason" fields in
      Ok (revision, Disabled reason)
    | "ready" ->
      let* balance_milli = nonnegative_amount "balance_milli" fields in
      let* owned_json = field "owned_items" fields in
      let* owned_items = decode_list ~context:"owned_items" decode_owned owned_json in
      let* () = unique_items ~context:"owned_items" owned_items in
      let* catalog_json = field "catalog" fields in
      let* catalog = decode_list ~context:"catalog" decode_entry catalog_json in
      let catalog_items = List.map (fun entry -> entry.item) catalog in
      let* () = unique_items ~context:"catalog" catalog_items in
      let ids items = List.sort String.compare (List.map Item.id items) in
      if ids catalog_items <> ids Item.all
      then Error "Item catalog is incomplete"
      else if not (List.for_all (fun item -> List.mem (Item.id item) (ids catalog_items)) owned_items)
      then Error "owned Item is absent from catalog"
      else Ok (revision, Ready { balance_milli; owned_items; catalog })
    | _ -> Error ("unknown Item account status " ^ status)

let match_revision ~expected_revision (revision, account) =
  let* expected_revision = expected_revision in
  if revision = expected_revision then Ok account
  else Error "Item account observation changed; refresh the Keeper roster before reading this account"
