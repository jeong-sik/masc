type t = string

let of_string value =
  match String.trim value with
  | "" -> None
  | name -> Some (String.lowercase_ascii name)
;;

let to_string name = name
let equal = String.equal
let compare = String.compare
let to_yojson name = `String name

let of_yojson json =
  match Candle_json.as_string json with
  | Error _ as error -> error
  | Ok text ->
    (match of_string text with
     | None -> Error "keeper name is blank"
     | Some name when String.equal name text -> Ok name
     | Some name -> Error (Printf.sprintf "keeper name %S is not canonical (%S)" text name))
;;
