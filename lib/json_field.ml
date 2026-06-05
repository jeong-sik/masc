type 'a extraction =
  | Found of 'a
  | Field_absent
  | Wrong_shape of { expected : string; got : string }

let yojson_variant_name : Yojson.Safe.t -> string = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ -> "int"
  | `Intlit _ -> "intlit"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "assoc"
  | `List _ -> "list"

let lookup (json : Yojson.Safe.t) (key : string) : Yojson.Safe.t option =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let string json key : string extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`String s) -> Found s
  | Some other ->
    Wrong_shape { expected = "string"; got = yojson_variant_name other }
;;

let int json key : int extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`Int i) -> Found i
  | Some other ->
    Wrong_shape { expected = "int"; got = yojson_variant_name other }
;;

let bool json key : bool extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`Bool b) -> Found b
  | Some other ->
    Wrong_shape { expected = "bool"; got = yojson_variant_name other }
;;

let float json key : float extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`Float f) -> Found f
  | Some (`Int i) -> Found (float_of_int i)
  | Some other ->
    Wrong_shape { expected = "float"; got = yojson_variant_name other }
;;

let assoc json key : (string * Yojson.Safe.t) list extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`Assoc fields) -> Found fields
  | Some other ->
    Wrong_shape { expected = "assoc"; got = yojson_variant_name other }
;;

let list json key : Yojson.Safe.t list extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`List items) -> Found items
  | Some other ->
    Wrong_shape { expected = "list"; got = yojson_variant_name other }
;;

let to_option = function
  | Found v -> Some v
  | Field_absent -> None
  | Wrong_shape _ -> None
;;

let log_wrong_shape ~label = function
  | Found v -> Some v
  | Field_absent -> None
  | Wrong_shape { expected; got } ->
    Log.Misc.warn
      "[json_field] %s: expected %s, got %s — schema drift on upstream payload"
      label expected got;
    None
;;

let require = function
  | Found v -> Ok v
  | Field_absent -> Error "json_field: field absent"
  | Wrong_shape { expected; got } ->
    Error
      (Printf.sprintf
         "json_field: wrong shape (expected %s, got %s)"
         expected
         got)
;;
