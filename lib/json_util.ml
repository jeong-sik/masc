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

let get_int : Yojson.Safe.t -> string -> int option = fun json key ->
  match Yojson.Safe.Util.member key json with
  | `Int n -> Some n
  | `Intlit s -> (
      try Some (int_of_string s) with _ -> None)
  | _ -> None

let get_int_with_default json ~key ~default =
  match Yojson.Safe.Util.member key json with
  | `Int n -> n
  | `Intlit s -> (
      try int_of_string s with _ -> default)
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

(** Construction helpers *)

let json_string_list xs = `List (List.map (fun s -> `String s) xs)

let json_assoc_list kv =
  `Assoc (List.map (fun (k, v) -> (k, `String v)) kv)

let parse_json_or_string s =
  try Yojson.Safe.from_string s with _ -> `String s

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
