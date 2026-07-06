(* Board_attachment_meta — pure-data attachment carrier.
   See lib/board_attachment_meta.mli for the contract. *)

(* Errors *)

type error =
  | Invalid_id of string
  | Invalid_kind of string
  | Invalid_payload of string
  | Missing_field of string
[@@deriving show]

let error_to_string = function
  | Invalid_id s -> Printf.sprintf "Invalid attachment id: %s" s
  | Invalid_kind s -> Printf.sprintf "Invalid attachment kind: %s" s
  | Invalid_payload s -> Printf.sprintf "Invalid attachment payload: %s" s
  | Missing_field s -> Printf.sprintf "Missing field: %s" s

let meta_json_key = "attachments"

type attachment_meta_read_error =
  | Meta_not_object of { received : string }
  | Attachments_not_list of { received : string }
  | Attachment_decode_error of { index : int; error : error }

let attachment_meta_read_error_to_string = function
  | Meta_not_object { received } ->
      Printf.sprintf "attachment meta must be an object (received %s)" received
  | Attachments_not_list { received } ->
      Printf.sprintf "attachment meta field %S must be a list (received %s)"
        meta_json_key received
  | Attachment_decode_error { index; error } ->
      Printf.sprintf "attachment meta item %d decode failed: %s" index
        (error_to_string error)

(* Kind *)

type kind =
  | Image
  | Video
  | Youtube
  | External_link

let kind_to_string = function
  | Image -> "image"
  | Video -> "video"
  | Youtube -> "youtube"
  | External_link -> "external_link"

let kind_of_string = function
  | "image" -> Ok Image
  | "video" -> Ok Video
  | "youtube" -> Ok Youtube
  | "external_link" -> Ok External_link
  | s -> Error (Invalid_kind s)

(* Id — same character class + length envelope as Board_types.Post_id *)

module Id = struct
  type t = string

  let valid_pattern = Board_types.alphanumeric_id_re

  let of_string s =
    let s = String.trim s in
    let len = String.length s in
    if len >= 1 && len <= 64 && Re.execp valid_pattern s then Ok s
    else Error (Invalid_id (Printf.sprintf "Invalid attachment id: %s" s))

  let to_string t = t

  let generate () = Random_id.prefixed ~prefix:"a-" ~bytes:16

  let equal = String.equal
end

(* Record *)

type t = {
  id : Id.t;
  kind : kind;
  origin_url : string;
  origin_name : string;
  origin_size_bytes : int;
  mime_type : string;
  width : int option;
  height : int option;
  created_at : float;
}

(* JSON encoding — explicit, no ppx_deriving_yojson dependency. *)

let to_yojson (t : t) : Yojson.Safe.t =
  `Assoc [
    "id", `String (Id.to_string t.id);
    "kind", `String (kind_to_string t.kind);
    "origin_url", `String t.origin_url;
    "origin_name", `String t.origin_name;
    "origin_size_bytes", `Int t.origin_size_bytes;
    "mime_type", `String t.mime_type;
    "width", Json_util.int_opt_to_json t.width;
    "height", Json_util.int_opt_to_json t.height;
    "created_at", `Float t.created_at;
  ]

let opt_int_of_yojson = function
  | `Null -> Ok None
  | `Int i -> Ok (Some i)
  | other ->
      Error
        (Invalid_payload
           (Printf.sprintf "expected null or int (received %s)"
              (Json_util.kind_name other)))

let assoc_get key = function
  | `Assoc kvs -> (
      match List.assoc_opt key kvs with
      | Some v -> Ok v
      | None -> Error (Missing_field key))
  | other ->
      Error
        (Invalid_payload
           (Printf.sprintf "expected JSON object (received %s)"
              (Json_util.kind_name other)))

let string_of_yojson key json =
  match assoc_get key json with
  | Ok (`String s) -> Ok s
  | Ok other ->
      Error
        (Invalid_payload
           (Printf.sprintf "%s: expected string (received %s)" key
              (Json_util.kind_name other)))
  | Error e -> Error e

let int_of_yojson key json =
  match assoc_get key json with
  | Ok (`Int i) -> Ok i
  | Ok other ->
      Error
        (Invalid_payload
           (Printf.sprintf "%s: expected int (received %s)" key
              (Json_util.kind_name other)))
  | Error e -> Error e

let float_of_yojson key json =
  match assoc_get key json with
  | Ok (`Float f) -> Ok f
  | Ok (`Int i) -> Ok (float_of_int i)
  | Ok other ->
      Error
        (Invalid_payload
           (Printf.sprintf "%s: expected float (received %s)" key
              (Json_util.kind_name other)))
  | Error e -> Error e

let opt_int_field key json =
  match assoc_get key json with
  | Ok v -> opt_int_of_yojson v
  | Error _ -> Ok None  (* missing optional => None *)

let ( let* ) = Result.bind

let of_yojson (json : Yojson.Safe.t) : (t, error) result =
  let* id_str = string_of_yojson "id" json in
  let* id = Id.of_string id_str in
  let* kind_str = string_of_yojson "kind" json in
  let* kind = kind_of_string kind_str in
  let* origin_url = string_of_yojson "origin_url" json in
  let* origin_name = string_of_yojson "origin_name" json in
  let* origin_size_bytes = int_of_yojson "origin_size_bytes" json in
  let* mime_type = string_of_yojson "mime_type" json in
  let* width = opt_int_field "width" json in
  let* height = opt_int_field "height" json in
  let* created_at = float_of_yojson "created_at" json in
  Ok {
    id; kind; origin_url; origin_name;
    origin_size_bytes; mime_type; width; height; created_at;
  }

(* meta_json embedding *)

let attach_to_post_meta ~existing (attachments : t list) : Yojson.Safe.t =
  let attachments_json = `List (List.map to_yojson attachments) in
  let other_keys =
    match existing with
    | Some (`Assoc kvs) ->
      List.filter (fun (k, _) -> not (String.equal k meta_json_key)) kvs
    | _ -> []
  in
  `Assoc (other_keys @ [meta_json_key, attachments_json])

type attachments_of_post_meta_result = {
  attachments : t list;
  errors : attachment_meta_read_error list;
}

let attachments_of_post_meta_result (meta : Yojson.Safe.t option) :
    attachments_of_post_meta_result =
  match meta with
  | None -> { attachments = []; errors = [] }
  | Some (`Assoc kvs) -> (
      match List.assoc_opt meta_json_key kvs with
      | None -> { attachments = []; errors = [] }
      | Some (`List items) ->
          let rec loop index attachments errors = function
            | [] ->
                {
                  attachments = List.rev attachments;
                  errors = List.rev errors;
                }
            | item :: rest -> (
                match of_yojson item with
                | Ok attachment -> loop (index + 1) (attachment :: attachments) errors rest
                | Error error ->
                    loop (index + 1) attachments
                      (Attachment_decode_error { index; error } :: errors)
                      rest)
          in
          loop 0 [] [] items
      | Some other ->
          {
            attachments = [];
            errors =
              [
                Attachments_not_list
                  { received = Json_util.kind_name other };
              ];
          })
  | Some other ->
      {
        attachments = [];
        errors = [ Meta_not_object { received = Json_util.kind_name other } ];
      }

let attachments_of_post_meta (meta : Yojson.Safe.t option) : t list =
  (attachments_of_post_meta_result meta).attachments
