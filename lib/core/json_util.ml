(** JSON utilities for MASC-MCP.

    Centralized Yojson.Safe helpers to reduce code duplication.
    Replaces 177+ `let open Yojson.Safe.Util in` occurrences.

    Usage:
    {[
      open Json_util
      let name = get_string_opt json "name" |> Option.value ~default:""
      let age = get_int_opt json "age" |> Option.value ~default:0
    ]}
*)

(** Field extraction with type coercion *)

let get_string : Yojson.Safe.t -> string -> string option = fun json key ->
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None

let get_string_with_default json ~key ~default =
  match Yojson.Safe.Util.member key json with
  | `String s -> s
  | _ -> default

(** Like [get_string] but rejects whitespace-only strings.  Returns
    [Some] only when the field is a non-empty string after [String.trim].
    Several modules carried bespoke [json_string_field] helpers with
    this exact filter (typed-LLM output, keeper contract introspection,
    etc.) — this is the SSOT for that pattern. *)
let get_string_nonempty json key : string option =
  match Yojson.Safe.Util.member key json with
  | `String s when String.trim s <> "" -> Some s
  | _ -> None

let get_int : Yojson.Safe.t -> string -> int option = fun json key ->
  match Yojson.Safe.Util.member key json with
  | `Int n -> Some n
  | `Intlit s -> int_of_string_opt s
  | _ -> None

let get_int_with_default json ~key ~default =
  match Yojson.Safe.Util.member key json with
  | `Int n -> n
  | `Intlit s -> Option.value ~default (int_of_string_opt s)
  | _ -> default

let get_float : Yojson.Safe.t -> string -> float option = fun json key ->
  match Yojson.Safe.Util.member key json with
  | `Float f -> Some f
  | `Int n -> Some (Float.of_int n)
  | _ -> None

let get_bool : Yojson.Safe.t -> string -> bool option = fun json key ->
  match Yojson.Safe.Util.member key json with
  | `Bool b -> Some b
  | _ -> None

let get_string_list : Yojson.Safe.t -> string -> string list = fun json key ->
  match Yojson.Safe.Util.member key json with
  | `List xs ->
      List.filter_map
        (function `String s when String.trim s <> "" -> Some s | _ -> None)
        xs
  | _ -> []

let get_object : Yojson.Safe.t -> string -> Yojson.Safe.t option = fun json key ->
  match Yojson.Safe.Util.member key json with
  | `Assoc _ as json' -> Some json'
  | _ -> None

let get_array : Yojson.Safe.t -> string -> Yojson.Safe.t option = fun json key ->
  match Yojson.Safe.Util.member key json with
  | `List _ as json' -> Some json'
  | _ -> None

(** {1 Required field extraction (Result-returning)}

    Unlike [get_*] which return [option], these return [(value, string) result]
    with a descriptive error message identifying the missing or mistyped field. *)

let require_string json key : (string, string) result =
  match Yojson.Safe.Util.member key json with
  | `String s -> Ok s
  | `Null -> Error (Printf.sprintf "required field '%s' is null" key)
  | #Yojson.Safe.t -> Error (Printf.sprintf "field '%s' is not a string" key)

let require_int json key : (int, string) result =
  match Yojson.Safe.Util.member key json with
  | `Int n -> Ok n
  | `Intlit s ->
      (match int_of_string_opt s with
       | Some n -> Ok n
       | None -> Error (Printf.sprintf "field '%s' has non-integer intlit: %s" key s))
  | `Null -> Error (Printf.sprintf "required field '%s' is null" key)
  | #Yojson.Safe.t -> Error (Printf.sprintf "field '%s' is not an int" key)

let require_float json key : (float, string) result =
  match Yojson.Safe.Util.member key json with
  | `Float f -> Ok f
  | `Int n -> Ok (Float.of_int n)
  | `Null -> Error (Printf.sprintf "required field '%s' is null" key)
  | #Yojson.Safe.t -> Error (Printf.sprintf "field '%s' is not a float" key)

let require_bool json key : (bool, string) result =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> Ok b
  | `Null -> Error (Printf.sprintf "required field '%s' is null" key)
  | #Yojson.Safe.t -> Error (Printf.sprintf "field '%s' is not a bool" key)

(** Construction helpers *)

let json_string_list xs = `List (List.map (fun s -> `String s) xs)

let json_assoc_list kv =
  `Assoc (List.map (fun (k, v) -> (k, `String v)) kv)

let parse_json_or_string s =
  try Yojson.Safe.from_string s with Yojson.Json_error _ -> `String s

(** {1 Option serialization helpers}

    Canonical [None -> `Null] converters for building JSON.
    Use these instead of per-module [let int_opt_to_json = ...] definitions. *)

let option_to_yojson (f : 'a -> Yojson.Safe.t) : 'a option -> Yojson.Safe.t = function
  | Some value -> f value
  | None -> `Null

let int_opt_to_json : int option -> Yojson.Safe.t = function
  | Some n -> `Int n
  | None -> `Null

let string_opt_to_json : string option -> Yojson.Safe.t = function
  | Some s -> `String s
  | None -> `Null

let float_opt_to_json : float option -> Yojson.Safe.t = function
  | Some f -> `Float f
  | None -> `Null

let bool_opt_to_json : bool option -> Yojson.Safe.t = function
  | Some b -> `Bool b
  | None -> `Null

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
