(** JSON utilities for MASC.

    Centralized Yojson.Safe helpers to reduce code duplication.
    Replaces 177+ `let open Yojson.Safe.Util in` occurrences.

    Usage:
    {[
      open Json_util
      let name = get_string_with_default json ~key:"name" ~default:""
      let age = get_int json "age" |> Option.value ~default:0
    ]}
*)

(** Field extraction with type coercion *)

let get_string : Yojson.Safe.t -> string -> string option = fun json key ->
  try
    match Yojson.Safe.Util.member key json with
    | `String s -> Some s
    | _ -> None
  with
  | Yojson.Safe.Util.Type_error _ -> None

let get_string_with_default json ~key ~default =
  try
    match Yojson.Safe.Util.member key json with
    | `String s -> s
    | _ -> default
  with
  | Yojson.Safe.Util.Type_error _ -> default

(** Like [get_string] but rejects whitespace-only strings.  Returns
    [Some] only when the field is a non-empty string after [String.trim].
    Several modules carried bespoke [json_string_field] helpers with
    this exact filter (typed-LLM output, keeper contract introspection,
    etc.) — this is the SSOT for that pattern. *)
let get_string_nonempty json key : string option =
  try
    match Yojson.Safe.Util.member key json with
    | `String s when String.trim s <> "" -> Some s
    | _ -> None
  with
  | Yojson.Safe.Util.Type_error _ -> None

let get_int : Yojson.Safe.t -> string -> int option = fun json key ->
  try
    match Yojson.Safe.Util.member key json with
    | `Int n -> Some n
    | `Intlit s -> int_of_string_opt s
    | _ -> None
  with
  | Yojson.Safe.Util.Type_error _ -> None

let get_float : Yojson.Safe.t -> string -> float option = fun json key ->
  try
    match Yojson.Safe.Util.member key json with
    | `Float f -> Some f
    | `Int n -> Some (Float.of_int n)
    | _ -> None
  with
  | Yojson.Safe.Util.Type_error _ -> None

let get_bool : Yojson.Safe.t -> string -> bool option = fun json key ->
  try
    match Yojson.Safe.Util.member key json with
    | `Bool b -> Some b
    | _ -> None
  with
  | Yojson.Safe.Util.Type_error _ -> None

let get_string_list : Yojson.Safe.t -> string -> string list = fun json key ->
  try
    match Yojson.Safe.Util.member key json with
    | `List xs ->
      List.filter_map
        (function `String s when String.trim s <> "" -> Some s | _ -> None)
        xs
    | _ -> []
  with
  | Yojson.Safe.Util.Type_error _ -> []

let get_object : Yojson.Safe.t -> string -> Yojson.Safe.t option = fun json key ->
  try
    match Yojson.Safe.Util.member key json with
    | `Assoc _ as json' -> Some json'
    | _ -> None
  with
  | Yojson.Safe.Util.Type_error _ -> None

let get_array : Yojson.Safe.t -> string -> Yojson.Safe.t option = fun json key ->
  try
    match Yojson.Safe.Util.member key json with
    | `List _ as json' -> Some json'
    | _ -> None
  with
  | Yojson.Safe.Util.Type_error _ -> None

(** {1 Required field extraction (Result-returning)} *)

let require_string json key : (string, string) result =
  try
    match Yojson.Safe.Util.member key json with
    | `String s -> Ok s
    | `Null -> Error (Printf.sprintf "required field '%s' is null" key)
    | #Yojson.Safe.t -> Error (Printf.sprintf "field '%s' is not a string" key)
  with
  | Yojson.Safe.Util.Type_error _ ->
    Error (Printf.sprintf "required field '%s' is missing" key)

let require_int json key : (int, string) result =
  try
    match Yojson.Safe.Util.member key json with
    | `Int n -> Ok n
    | `Intlit s ->
      (match int_of_string_opt s with
       | Some n -> Ok n
       | None -> Error (Printf.sprintf "field '%s' has non-integer intlit: %s" key s))
    | `Null -> Error (Printf.sprintf "required field '%s' is null" key)
    | #Yojson.Safe.t -> Error (Printf.sprintf "field '%s' is not an int" key)
  with
  | Yojson.Safe.Util.Type_error _ -> Error (Printf.sprintf "required field '%s' is missing" key)

let require_float json key : (float, string) result =
  try
    match Yojson.Safe.Util.member key json with
    | `Float f -> Ok f
    | `Int n -> Ok (Float.of_int n)
    | `Null -> Error (Printf.sprintf "required field '%s' is null" key)
    | #Yojson.Safe.t -> Error (Printf.sprintf "field '%s' is not a float" key)
  with
  | Yojson.Safe.Util.Type_error _ ->
    Error (Printf.sprintf "required field '%s' is missing" key)

let require_bool json key : (bool, string) result =
  try
    match Yojson.Safe.Util.member key json with
    | `Bool b -> Ok b
    | `Null -> Error (Printf.sprintf "required field '%s' is null" key)
    | #Yojson.Safe.t -> Error (Printf.sprintf "field '%s' is not a bool" key)
  with
  | Yojson.Safe.Util.Type_error _ ->
    Error (Printf.sprintf "required field '%s' is missing" key)

(** Value-level type discrimination — returns the JSON variant name as
    a lowercase string.  Used in parse-error diagnostics across 5+ modules. *)
(* The mapping itself lives in [Json_kind], a yojson-only leaf, so the
   libraries that cannot take masc_core reach the same answer. *)
let kind_name = Shared_types.Json_kind.name

(** Construction helpers *)

let json_string_list xs = `List (List.map (fun s -> `String s) xs)

let string_assoc_to_json fields =
  `Assoc (List.map (fun (key, value) -> (key, `String value)) fields)

let string_assoc_of_json = function
  | `Assoc fields ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | (key, `String value) :: rest -> collect ((key, value) :: acc) rest
      | (key, value) :: _ ->
        Error
          (Printf.sprintf
             "string object field %S must be a string, got %s"
             key
             (kind_name value))
    in
    collect [] fields
  | value ->
    Error (Printf.sprintf "expected string object, got %s" (kind_name value))

let string_field_if_present key = function
  | None -> []
  | Some value -> [ (key, `String value) ]

(** {1 Option serialization helpers}

    Canonical [None -> `Null] converters for building JSON.
    Use these instead of per-module [let int_opt_to_json = ...] definitions. *)

let option_to_yojson (f : 'a -> Yojson.Safe.t) : 'a option -> Yojson.Safe.t = function
  | Some value -> f value
  | None -> `Null

let int_option_to_yojson : int option -> Yojson.Safe.t = function
  | Some n -> `Int n
  | None -> `Null

let string_option_to_yojson : string option -> Yojson.Safe.t = function
  | Some s -> `String s
  | None -> `Null

let excerpt ?(max = 160) (json : Yojson.Safe.t) : string =
  let s = Yojson.Safe.to_string json in
  if String.length s > max then String.sub s 0 max ^ "..." else s

let int_opt_to_json : int option -> Yojson.Safe.t = function
  | Some n -> `Int n
  | None -> `Null

let string_opt_to_json : string option -> Yojson.Safe.t = function
  | Some s -> `String s
  | None -> `Null

let string_opt_to_json_trimmed : string option -> Yojson.Safe.t = function
  | Some s ->
    let trimmed = String.trim s in
    if trimmed <> "" then `String trimmed else `Null
  | None -> `Null

(** Ratio of two ints as a JSON float, or [`Null] when the denominator
    is 0 (no NaN reaches the wire). *)
let int_ratio_json numerator denominator =
  if denominator = 0
  then `Null
  else `Float (float_of_int numerator /. float_of_int denominator)

let float_opt_to_json : float option -> Yojson.Safe.t = function
  | Some f -> `Float f
  | None -> `Null

let bool_opt_to_json : bool option -> Yojson.Safe.t = function
  | Some b -> `Bool b
  | None -> `Null

let string_opt_field name (opt : string option) : string * Yojson.Safe.t =
  (name, string_opt_to_json opt)


(** {1 Assoc field extraction}

    Canonical [Assoc] field accessors for building typed JSON parsers.
    Replaces per-module [assoc_member_opt] / [assoc_string_opt] etc. *)

let assoc_member_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let assoc_string_opt name json =
  match assoc_member_opt name json with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None

let assoc_int_opt name json =
  match assoc_member_opt name json with
  | Some (`Int value) -> Some value
  | Some (`Intlit raw) -> int_of_string_opt raw
  | _ -> None

let assoc_bool_opt name json =
  match assoc_member_opt name json with
  | Some (`Bool value) -> Some value
  | _ -> None

let assoc_object_opt name json =
  match assoc_member_opt name json with
  | Some (`Assoc _ as obj) -> Some obj
  | _ -> None

(** Scans a JSON array for the first [`Assoc] row whose [field] member is
    the string [value].  Rows that are not objects, and rows without a
    string [field], are skipped. *)
let find_assoc_row_by_string_field ~field ~value = function
  | `List rows ->
    List.find_map
      (function
        | (`Assoc _ as row) -> (
          match assoc_member_opt field row with
          | Some (`String candidate) when String.equal candidate value -> Some row
          | _ -> None)
        | _ -> None)
      rows
  | _ -> None

let json_string_list_member name json =
  try
    match Yojson.Safe.Util.member name json with
    | `List values ->
    values
      |> List.filter_map (function
        | `String value ->
          let trimmed = String.trim value in
          if trimmed <> "" then Some trimmed else None
        | _ -> None)
    | _ -> []
  with
  | Yojson.Safe.Util.Type_error _ -> []


(** {1 Assoc field validation (Result-returning)}

    These operate on an already-destructured [`Assoc] field list rather
    than on a whole [Yojson.Safe.t] (that is the [require_*] family
    above).  [surface] names the object in the error message, so a
    failure reads ["<surface>.<field> is required"]. *)

let reject_unknown_fields ~surface ~allowed fields =
  let rec duplicate seen = function
    | [] -> None
    | (key, _) :: rest ->
      if List.mem key seen then Some key else duplicate (key :: seen) rest
  in
  match duplicate [] fields with
  | Some field -> Error (Printf.sprintf "%s contains duplicate field %s" surface field)
  | None ->
    (match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
     | None -> Ok ()
     | Some (field, _) ->
       Error (Printf.sprintf "%s contains unsupported field %s" surface field))

let require_field_string ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some (`String _) ->
    Error (Printf.sprintf "%s.%s must be non-blank" surface field)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)

let require_field_float ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (Float.of_int value)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a number" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)

let require_field_positive_int ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`Int value) when value > 0 -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a positive integer" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)

let require_field_string_list ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`List values) ->
    let rec parse index acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> parse (index + 1) (value :: acc) rest
      | _ :: _ ->
        Error
          (Printf.sprintf "%s.%s[%d] must be a string" surface field index)
    in
    parse 0 [] values
  | Some _ -> Error (Printf.sprintf "%s.%s must be an array" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)


(** List utilities *)

let dedupe_keep_order xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: rest ->
        if List.mem x seen then
          loop seen acc rest
        else
          loop (x :: seen) (x :: acc) rest
  in
  loop [] [] xs

let normalize_string_list items =
  items
  |> List.map String.trim
  |> List.filter (fun item -> not (String.equal item ""))
  |> dedupe_keep_order
