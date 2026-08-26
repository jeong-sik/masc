(** See keeper_oauth_provider.mli for what this is and what it deliberately
    does not cover. *)

type error =
  | Missing_field of string
  | Empty_field of string
  | Wrong_type of { field : string; expected : string }
  | Name_mismatch of { declared : string; file : string }
  | Malformed_toml of string

let error_to_string = function
  | Missing_field field -> Printf.sprintf "%s is required" field
  | Empty_field field -> Printf.sprintf "%s must not be empty" field
  | Wrong_type { field; expected } ->
    Printf.sprintf "%s must be %s" field expected
  | Name_mismatch { declared; file } ->
    Printf.sprintf
      "id is %S but the file is named %S; a renamed file must not become a \
       different provider"
      declared
      file
  | Malformed_toml detail -> Printf.sprintf "TOML parse error: %s" detail

type t = {
  id : string;
  label : string;
  mcp_url : string;
  access_token_env : string;
  expires_at_env : string;
  refresh_token_file : string;
  renew_before_sec : int;
  authorize_params : (string * string) list;
}

let ( let* ) = Result.bind

(* Every TOML constructor is named once, here. The library's warning 4 asks
   for that at each match; classifying in one place means a new constructor
   is one decision rather than four, and the field readers below match on a
   closed type of our own. *)
type shape =
  | S_string of string
  | S_int of int
  | S_array of Otoml.t list
  | S_other of string

let classify = function
  | Otoml.TomlString value -> S_string value
  | Otoml.TomlInteger value -> S_int value
  | Otoml.TomlArray items -> S_array items
  | Otoml.TomlFloat _ -> S_other "a float"
  | Otoml.TomlBoolean _ -> S_other "a boolean"
  | Otoml.TomlOffsetDateTime _ -> S_other "an offset datetime"
  | Otoml.TomlLocalDateTime _ -> S_other "a local datetime"
  | Otoml.TomlLocalDate _ -> S_other "a local date"
  | Otoml.TomlLocalTime _ -> S_other "a local time"
  | Otoml.TomlTable _ -> S_other "a table"
  | Otoml.TomlInlineTable _ -> S_other "an inline table"
  | Otoml.TomlTableArray _ -> S_other "an array of tables"

let find pairs key = Option.map classify (List.assoc_opt key pairs)

let non_empty ~key value =
  if String.equal (String.trim value) "" then Error (Empty_field key) else Ok value

let string_field pairs key =
  match find pairs key with
  | None -> Error (Missing_field key)
  | Some (S_string value) -> non_empty ~key value
  | Some (S_int _ | S_array _ | S_other _) ->
    Error (Wrong_type { field = key; expected = "a string" })

let int_field pairs key =
  match find pairs key with
  | None -> Error (Missing_field key)
  | Some (S_int value) -> Ok value
  | Some (S_string _ | S_array _ | S_other _) ->
    Error (Wrong_type { field = key; expected = "an integer" })

(* An optional table of plain strings, kept in declaration order so the
   authorize URL a reader sees matches the file they are looking at. *)
let string_table_field pairs key =
  match List.assoc_opt key pairs with
  | None -> Ok []
  | Some (Otoml.TomlTable entries) | Some (Otoml.TomlInlineTable entries) ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | (name, value) :: rest ->
        (match classify value with
         | S_string text ->
           let* text = non_empty ~key:(key ^ "." ^ name) text in
           collect ((name, text) :: acc) rest
         | S_int _ | S_array _ | S_other _ ->
           Error
             (Wrong_type { field = key ^ "." ^ name; expected = "a string" }))
    in
    collect [] entries
  | Some
      ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
      | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
      | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ) ->
    Error (Wrong_type { field = key; expected = "a table of strings" })

(* A plaintext MCP server would carry the bearer token in the clear, and its
   discovery answer could be replaced on the way. A declaration that names
   one is a configuration error rather than a provider this supports. *)
let https_field pairs key =
  let* value = string_field pairs key in
  if String.starts_with ~prefix:"https://" value
  then Ok value
  else Error (Wrong_type { field = key; expected = "an https:// URL" })

(* The id names a file and, through {!t} being private, whatever a caller
   builds from a declaration -- a directory holding the client this provider
   registered, for one. One path component, so that stays true. *)
let single_path_component value =
  not
    (String.equal value ""
     || String.equal value "."
     || String.equal value ".."
     || String.exists (fun c -> Char.equal c '/') value)
;;

let load ~file_name ~contents =
  match Otoml.Parser.from_string_result contents with
  | Error message -> Error (Malformed_toml message)
  | Ok (Otoml.TomlTable pairs) ->
    let* id = string_field pairs "id" in
    let* () =
      if not (single_path_component id)
      then Error (Wrong_type { field = "id"; expected = "one path component" })
      else if String.equal id file_name
      then Ok ()
      else Error (Name_mismatch { declared = id; file = file_name })
    in
    let* label = string_field pairs "label" in
    let* mcp_url = https_field pairs "mcp_url" in
    let* authorize_params = string_table_field pairs "authorize_params" in
    let* access_token_env = string_field pairs "access_token_env" in
    let* expires_at_env = string_field pairs "expires_at_env" in
    let* refresh_token_file = string_field pairs "refresh_token_file" in
    let* renew_before_sec = int_field pairs "renew_before_sec" in
    if renew_before_sec < 0
    then Error (Wrong_type { field = "renew_before_sec"; expected = "a non-negative integer" })
    else
      Ok
        { id
        ; label
        ; mcp_url
        ; access_token_env
        ; expires_at_env
        ; refresh_token_file
        ; renew_before_sec
        ; authorize_params
        }
  | Ok
      ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
      | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
      | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlInlineTable _
      | Otoml.TomlTableArray _ ) ->
    Error (Wrong_type { field = "top level"; expected = "a table" })
