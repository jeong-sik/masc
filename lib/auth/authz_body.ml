(* HIGH-RISK-UNREVIEWED: this module writes the bytes that the hashes of the
   authorization log cover. A change to what it writes makes every line already
   on disk fail verification. *)

type t =
  | Null
  | Bool of bool
  | Int of int
  | String of string
  | List of t list
  | Object of (string * t) list

type error =
  | Float_not_allowed
  | Integer_out_of_range
  | Invalid_utf8
  | Repeated_name of string

let error_to_string = function
  | Float_not_allowed -> "a float is not allowed in a body"
  | Integer_out_of_range -> "an integer is outside the range every reader reads exactly"
  | Invalid_utf8 -> "text is not valid UTF-8"
  | Repeated_name name -> Printf.sprintf "the member name %S appears twice in one object" name
;;

let ( let* ) = Result.bind

(* 2^53 - 1: the upper end of the range [-(2^53) + 1, 2^53 - 1], in which
   implementations that read numbers as doubles agree on every integer
   (RFC 8259 section 6). *)
let max_interoperable_int = (1 lsl 53) - 1

let null = Null
let bool value = Bool value

let int value =
  if -max_interoperable_int <= value && value <= max_interoperable_int
  then Ok (Int value)
  else Error Integer_out_of_range
;;

let string text = if String.is_valid_utf_8 text then Ok (String text) else Error Invalid_utf8
let list items = List items

(* The smallest name that appears twice, so the answer does not depend on how
   the caller ordered the members. *)
let first_repeated_name names =
  let rec scan = function
    | first :: (second :: _ as rest) -> if String.equal first second then Some first else scan rest
    | [] | [ _ ] -> None
  in
  scan (List.sort String.compare names)
;;

let object_ members =
  let names = List.map fst members in
  if not (List.for_all String.is_valid_utf_8 names)
  then Error Invalid_utf8
  else (
    match first_repeated_name names with
    | Some name -> Error (Repeated_name name)
    | None -> Ok (Object members))
;;

(* Not tail recursive: the stack grows with the length of the list. A bound on
   the size of a body belongs to the layer that accepts one. *)
let rec all convert = function
  | [] -> Ok []
  | first :: rest ->
    let* first = convert first in
    let* rest = all convert rest in
    Ok (first :: rest)
;;

let rec of_yojson (json : Yojson.Safe.t) =
  match json with
  | `Null -> Ok Null
  | `Bool value -> Ok (Bool value)
  | `Int value -> int value
  | `Intlit _ -> Error Integer_out_of_range
  | `Float _ -> Error Float_not_allowed
  | `String text -> string text
  | `List items ->
    let* items = all of_yojson items in
    Ok (List items)
  | `Assoc members ->
    let* members =
      all
        (fun (name, value) ->
          let* value = of_yojson value in
          Ok (name, value))
        members
    in
    object_ members
;;

let rec to_yojson = function
  | Null -> `Null
  | Bool value -> `Bool value
  | Int value -> `Int value
  | String text -> `String text
  | List items -> `List (List.map to_yojson items)
  | Object members -> `Assoc (List.map (fun (name, value) -> name, to_yojson value) members)
;;

(* RFC 8785 section 3.2.2.2: only the characters below the space are control
   characters here. DEL is written as it is, as JSON.stringify and Python do. *)
let first_printable_code = 0x20

let add_escaped buffer text =
  Buffer.add_char buffer '"';
  String.iter
    (fun char ->
      match char with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\b' -> Buffer.add_string buffer "\\b"
      | '\012' -> Buffer.add_string buffer "\\f"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | char when Char.code char < first_printable_code ->
        Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code char))
      | char -> Buffer.add_char buffer char)
    text;
  Buffer.add_char buffer '"'
;;

let add_separated buffer ~opening ~closing add_item items =
  Buffer.add_char buffer opening;
  List.iteri
    (fun index item ->
      if index > 0 then Buffer.add_char buffer ',';
      add_item item)
    items;
  Buffer.add_char buffer closing
;;

let rec add buffer = function
  | Null -> Buffer.add_string buffer "null"
  | Bool true -> Buffer.add_string buffer "true"
  | Bool false -> Buffer.add_string buffer "false"
  | Int value -> Buffer.add_string buffer (string_of_int value)
  | String text -> add_escaped buffer text
  | List items -> add_separated buffer ~opening:'[' ~closing:']' (add buffer) items
  | Object members ->
    add_separated
      buffer
      ~opening:'{'
      ~closing:'}'
      (fun (name, value) ->
        add_escaped buffer name;
        Buffer.add_char buffer ':';
        add buffer value)
      members
;;

let to_string value =
  let buffer = Buffer.create 64 in
  add buffer value;
  Buffer.contents buffer
;;

let string_literal text =
  let buffer = Buffer.create (String.length text + 2) in
  add_escaped buffer text;
  Buffer.contents buffer
;;
