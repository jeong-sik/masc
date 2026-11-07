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

let[@inline always] lookup (json : Yojson.Safe.t) (key : string) : Yojson.Safe.t option =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let[@inline always] string json key : string extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`String s) -> Found s
  | Some other ->
    Wrong_shape { expected = "string"; got = yojson_variant_name other }
;;

let[@inline always] int json key : int extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`Int i) -> Found i
  | Some other ->
    Wrong_shape { expected = "int"; got = yojson_variant_name other }
;;

let[@inline always] bool json key : bool extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`Bool b) -> Found b
  | Some other ->
    Wrong_shape { expected = "bool"; got = yojson_variant_name other }
;;

let[@inline always] float json key : float extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`Float f) -> Found f
  | Some (`Int i) -> Found (float_of_int i)
  | Some other ->
    Wrong_shape { expected = "float"; got = yojson_variant_name other }
;;

let[@inline always] assoc json key : (string * Yojson.Safe.t) list extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`Assoc fields) -> Found fields
  | Some other ->
    Wrong_shape { expected = "assoc"; got = yojson_variant_name other }
;;

let[@inline always] list json key : Yojson.Safe.t list extraction =
  match lookup json key with
  | None -> Field_absent
  | Some (`List items) -> Found items
  | Some other ->
    Wrong_shape { expected = "list"; got = yojson_variant_name other }
;;

let[@inline always] to_option = function
  | Found v -> Some v
  | Field_absent -> None
  | Wrong_shape _ -> None
;;

(* Fast zero-allocation extractors for optional fields *)
let[@inline always] string_opt json key : string option =
  match lookup json key with
  | Some (`String s) -> Some s
  | _ -> None
;;

let[@inline always] int_opt json key : int option =
  match lookup json key with
  | Some (`Int i) -> Some i
  | _ -> None
;;

let[@inline always] bool_opt json key : bool option =
  match lookup json key with
  | Some (`Bool b) -> Some b
  | _ -> None
;;

let[@inline always] float_opt json key : float option =
  match lookup json key with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None
;;

let[@inline always] assoc_opt json key : (string * Yojson.Safe.t) list option =
  match lookup json key with
  | Some (`Assoc fields) -> Some fields
  | _ -> None
;;

let[@inline always] list_opt json key : Yojson.Safe.t list option =
  match lookup json key with
  | Some (`List items) -> Some items
  | _ -> None
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
