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
  authorize_url : string;
  token_url : string;
  audience : string option;
  scopes : string list;
  access_token_env : string;
  refresh_token_file : string;
  renew_before_sec : int;
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

let optional_string_field pairs key =
  match find pairs key with
  | None -> Ok None
  | Some (S_string value) -> Result.map Option.some (non_empty ~key value)
  | Some (S_int _ | S_array _ | S_other _) ->
    Error (Wrong_type { field = key; expected = "a string" })

let int_field pairs key =
  match find pairs key with
  | None -> Error (Missing_field key)
  | Some (S_int value) -> Ok value
  | Some (S_string _ | S_array _ | S_other _) ->
    Error (Wrong_type { field = key; expected = "an integer" })

let string_list_field pairs key =
  match find pairs key with
  | None -> Error (Missing_field key)
  | Some (S_array items) ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match classify item with
         | S_string value ->
           let* value = non_empty ~key:(key ^ " entry") value in
           collect (value :: acc) rest
         | S_int _ | S_array _ | S_other _ ->
           Error (Wrong_type { field = key; expected = "an array of strings" }))
    in
    let* values = collect [] items in
    if values = [] then Error (Empty_field key) else Ok values
  | Some (S_string _ | S_int _ | S_other _) ->
    Error (Wrong_type { field = key; expected = "an array of strings" })

(* An authorize or token endpoint that is not https would carry the exchange,
   and with it the code and the client secret, in the clear. A declaration
   that names one is a configuration error rather than a provider this flow
   supports. *)
let https_field pairs key =
  let* value = string_field pairs key in
  if String.starts_with ~prefix:"https://" value
  then Ok value
  else Error (Wrong_type { field = key; expected = "an https:// URL" })

let load ~file_name ~contents =
  match Otoml.Parser.from_string_result contents with
  | Error message -> Error (Malformed_toml message)
  | Ok (Otoml.TomlTable pairs) ->
    let* id = string_field pairs "id" in
    let* () =
      if String.equal id file_name
      then Ok ()
      else Error (Name_mismatch { declared = id; file = file_name })
    in
    let* label = string_field pairs "label" in
    let* authorize_url = https_field pairs "authorize_url" in
    let* token_url = https_field pairs "token_url" in
    let* audience = optional_string_field pairs "audience" in
    let* scopes = string_list_field pairs "scopes" in
    let* access_token_env = string_field pairs "access_token_env" in
    let* refresh_token_file = string_field pairs "refresh_token_file" in
    let* renew_before_sec = int_field pairs "renew_before_sec" in
    if renew_before_sec < 0
    then Error (Wrong_type { field = "renew_before_sec"; expected = "a non-negative integer" })
    else
      Ok
        { id
        ; label
        ; authorize_url
        ; token_url
        ; audience
        ; scopes
        ; access_token_env
        ; refresh_token_file
        ; renew_before_sec
        }
  | Ok
      ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
      | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
      | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlInlineTable _
      | Otoml.TomlTableArray _ ) ->
    Error (Wrong_type { field = "top level"; expected = "a table" })

let requires_offline_access provider =
  List.exists (String.equal "offline_access") provider.scopes
