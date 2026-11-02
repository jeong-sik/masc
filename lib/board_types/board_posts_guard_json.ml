type t = string

type rejection =
  | Invalid_json of { line : int; detail : string }
  | Field_set_rejected
  | Schema_not_string
  | Unsupported_schema of string
  | Invalid_generation

let schema = "masc.board_posts_initialized.v1"

let of_generation generation =
  let lowercase_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  in
  if String.length generation = 32 && String.for_all lowercase_hex generation
  then Ok generation
  else Error Invalid_generation

let decode_fields schema_value generation_value =
  match schema_value with
  | `String observed when String.equal observed schema ->
    (match generation_value with
     | `String generation -> of_generation generation
     | _ -> Error Invalid_generation)
  | `String observed -> Error (Unsupported_schema observed)
  | _ -> Error Schema_not_string

let decode_row ~line text =
  match Yojson.Safe.from_string text with
  | `Assoc [ ("schema", schema_value); ("generation", generation_value) ]
  | `Assoc [ ("generation", generation_value); ("schema", schema_value) ] ->
    decode_fields schema_value generation_value
  | _ -> Error Field_set_rejected
  | exception Yojson.Json_error detail -> Error (Invalid_json { line; detail })

let generation value = value

let encode_jsonl value =
  Yojson.Safe.to_string
    (`Assoc [ "schema", `String schema; "generation", `String value ])
  ^ "\n"
