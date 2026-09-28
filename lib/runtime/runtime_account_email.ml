type t = string

let max_bytes = 254

let displayable_byte char =
  let code = Char.code char in
  code > 0x20 && code <> 0x7f

let of_string text =
  let length = String.length text in
  if length = 0 || length > max_bytes || not (String.is_valid_utf_8 text) then None
  else if String.for_all displayable_byte text then Some text
  else None

let to_string email = email

type missing =
  | Source_unavailable
  | Source_unrecognized
  | Not_reported
  | Invalid_email

let missing_to_string = function
  | Source_unavailable -> "the client's login file could not be read"
  | Source_unrecognized -> "the client's login file has an unrecognized shape"
  | Not_reported -> "the client's login file names no account email"
  | Invalid_email -> "the client's reported account email is not displayable text"

let missing_to_wire = function
  | Source_unavailable -> "source_unavailable"
  | Source_unrecognized -> "source_unrecognized"
  | Not_reported -> "not_reported"
  | Invalid_email -> "invalid_email"

let ( let* ) = Result.bind

let parse bytes =
  try Ok (Yojson.Safe.from_string bytes) with Yojson.Json_error _ -> Error Source_unrecognized

(* [null] and an absent key both mean the client did not report the value. *)
let member name = function
  | `Assoc fields ->
    (match List.filter (fun (key, _) -> String.equal key name) fields with
     | [] | [ (_, `Null) ] -> Ok None
     | [ (_, value) ] -> Ok (Some value)
     | _ :: _ :: _ -> Error Source_unrecognized)
  | _ -> Error Source_unrecognized

let rec at path json =
  match path with
  | [] -> Ok (Some json)
  | name :: rest ->
    let* child = member name json in
    (match child with
     | None -> Ok None
     | Some child -> at rest child)

let email_at path json =
  let* value = at path json in
  match value with
  | None -> Error Not_reported
  | Some (`String text) ->
    (match of_string text with
     | Some email -> Ok email
     | None -> Error Invalid_email)
  | Some _ -> Error Source_unrecognized

(* Only the claims segment is decoded, to read a display value. This is not
   ID-token verification and grants nothing. *)
let id_token_claims = function
  | `String token ->
    (match String.split_on_char '.' token with
     | [ header; payload; signature ] when header <> "" && signature <> "" ->
       (match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet payload with
        | Ok claims -> parse claims
        | Error _ -> Error Source_unrecognized)
     | _ -> Error Source_unrecognized)
  | _ -> Error Source_unrecognized

let email_in_id_token path json =
  let* token = at path json in
  match token with
  | None -> Error Not_reported
  | Some token ->
    let* claims = id_token_claims token in
    email_at [ "email" ] claims

let of_codex_auth bytes =
  let* json = parse bytes in
  email_in_id_token [ "tokens"; "id_token" ] json

let of_claude_account bytes =
  let* json = parse bytes in
  email_at [ "oauthAccount"; "emailAddress" ] json

let of_muse_auth bytes =
  let* json = parse bytes in
  email_at [ "providers"; "meta"; "user_email" ] json

let of_google_oauth bytes =
  let* json = parse bytes in
  email_in_id_token [ "id_token" ] json

let read_login_file path parse =
  match
    Eio_guard.run_in_systhread ~label:"account-email" (fun () -> Fs_compat.load_file_opt path)
  with
  | Some bytes -> parse bytes
  | None -> Error Source_unavailable
  | exception (Unix.Unix_error _ | Sys_error _) -> Error Source_unavailable

let of_provider (provider : Runtime_schema.provider) =
  let native path parse =
    match path with
    | Some path -> Some (read_login_file path parse)
    | None -> Some (Error Source_unavailable)
  in
  match provider.api_format, provider.credentials with
  | Runtime_schema.Codex_app_server_runtime, _ ->
    native
      (Option.map
         (fun codex_home -> Runtime_verification_codex_home.auth_path ~codex_home)
         (Runtime_codex_app_server.effective_account_home provider.account_home))
      of_codex_auth
  | Claude_code_runtime, _ ->
    native (Runtime_claude_code.account_file provider.account_home) of_claude_account
  | Muse_serve_runtime, _ -> native (Runtime_muse_home.auth_path provider.account_home) of_muse_auth
  | Antigravity_cli_runtime, Some (Runtime_schema.File path) ->
    Some (read_login_file path of_google_oauth)
  | Antigravity_cli_runtime, (Some (Runtime_schema.Env _ | Inline _) | None) -> None
  | (Messages_api | Chat_completions_api | Ollama_api | Gemini_api | Vertex_gemini_api), _ ->
    None

let inventory_json (config : Runtime_schema.config) =
  `List
    (List.filter_map
       (fun (provider : Runtime_schema.provider) ->
          Option.map
            (fun read ->
               let state =
                 match read with
                 | Ok email -> [ "state", `String "read"; "email", `String email ]
                 | Error missing ->
                   [ "state", `String "not_read"; "cause", `String (missing_to_wire missing) ]
               in
               `Assoc (("integration_id", `String provider.id) :: state))
            (of_provider provider))
       config.providers)
