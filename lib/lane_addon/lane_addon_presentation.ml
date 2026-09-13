type format = Text | Number | Boolean | Json
type reading = {
  lane_id : string; path : string list; label : string;
  unit : string option; format : format;
}
type t = { description : string option; readings : reading list }
let empty = {description=None; readings=[]}
let ( let* ) = Result.bind
let text = function
  | `String value when String.trim value <> ""
      && not (String.exists (fun c -> Char.code c < 32 || Char.code c = 127) value) -> Ok value
  | _ -> Error "presentation text must be non-blank and single-line"
let object_ allowed = function
  | `Assoc fields when List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields))
      && List.for_all (fun (key,_) -> List.mem key allowed) fields -> Ok fields
  | _ -> Error "unknown or duplicate presentation field"
let get fields key parse = match List.assoc_opt key fields with
  | Some value -> parse value | None -> Error ("missing presentation " ^ key)
let optional fields key = match List.assoc_opt key fields with
  | None | Some `Null -> Ok None | Some value -> Result.map Option.some (text value)
let rec array parse = function
  | `List [] -> Ok []
  | `List (value :: rest) -> let* value = parse value in
      let* rest = array parse (`List rest) in Ok (value :: rest)
  | _ -> Error "presentation requires an array"
let reading value =
  let* fields = object_ ["lane_id";"path";"label";"unit";"format"] value in
  let* lane_id = get fields "lane_id" text in
  let* path = get fields "path" (array text) in
  let* () = if path=[] then Error "presentation path must not be empty" else Ok () in
  let* label = get fields "label" text in
  let* unit = optional fields "unit" in
  let* format = get fields "format" (function
    | `String "text" -> Ok Text | `String "number" -> Ok Number
    | `String "boolean" -> Ok Boolean | `String "json" -> Ok Json
    | _ -> Error "unknown presentation format") in
  Ok {lane_id;path;label;unit;format}
let of_json value =
  let* fields = object_ ["description";"readings"] value in
  let* description = optional fields "description" in
  let* readings = match List.assoc_opt "readings" fields with
    | None -> Ok [] | Some value -> array reading value in
  let identities = List.map (fun r -> r.lane_id,r.path) readings in
  if List.length identities <> List.length (List.sort_uniq Stdlib.compare identities)
  then Error "duplicate presentation reading"
  else Ok {description;readings}
let to_json t =
  let optional = function None -> `Null | Some value -> `String value in
  `Assoc ["description",optional t.description; "readings",`List (List.map (fun r ->
    `Assoc ["lane_id",`String r.lane_id;"path",`List (List.map (fun s -> `String s) r.path);
      "label",`String r.label;"unit",optional r.unit;"format",`String (match r.format with
        Text -> "text" | Number -> "number" | Boolean -> "boolean" | Json -> "json")]) t.readings)]
let render reading fields =
  let rec resolve value = function
    | [] -> Ok value
    | key :: rest -> (match value with
      | `Assoc values -> (match List.assoc_opt key values with
        | Some value -> resolve value rest | None -> Error "field unavailable")
      | _ -> Error "field path does not address an object") in
  let* value = resolve fields reading.path in
  let* value = match reading.format,value with
    | Text,`String value -> Ok (Yojson.Safe.to_string (`String value))
    | Number,(`Int _ | `Intlit _) -> Ok (Yojson.Safe.to_string value)
    | Number,`Float number when Float.is_finite number -> Ok (Yojson.Safe.to_string value)
    | Boolean,`Bool _ | Json,_ -> Ok (Yojson.Safe.to_string value)
    | _ -> Error "field does not match declared display format" in
  Ok (reading.label ^ ": " ^ value ^ Option.fold ~none:"" ~some:(fun unit -> " " ^ unit) reading.unit)
