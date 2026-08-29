let refresh_margin_sec = 300.
let jwt_lifetime_sec = 540.
let jwt_backdate_sec = 60.
let credentials_dir_name = "github-app"
let token_stamp_name = "installation-token-expires-at"

type outcome =
  | No_app_identity
  | Fresh of { expires_at : float }
  | Refreshed of { expires_at : float }

type http_post =
  url:string
  -> headers:(string * string) list
  -> body:Yojson.Safe.t
  -> (int * string, string) result

type credentials =
  { app_id : string
  ; installation_id : string
  ; private_key_pem : string
  }

let ( let* ) = Result.bind

let credentials_dir ~config ~keeper_name =
  Filename.concat
    (Filename.concat (Workspace.keepers_runtime_dir config) keeper_name)
    credentials_dir_name
;;

let read_trimmed path =
  match Fs_compat.load_file path with
  | exception exn ->
    Error (Printf.sprintf "%s: %s" path (Printexc.to_string exn))
  | content ->
    (match String_util.trim_nonempty content with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s is empty" path))
;;

let load_credentials ~config ~keeper_name =
  let dir = credentials_dir ~config ~keeper_name in
  if not (Fs_compat.file_exists dir)
  then Ok None
  else
    let* app_id = read_trimmed (Filename.concat dir "app-id") in
    let* installation_id = read_trimmed (Filename.concat dir "installation-id") in
    let* private_key_pem = read_trimmed (Filename.concat dir "private-key.pem") in
    Ok (Some { app_id; installation_id; private_key_pem })
;;

(* ── JWT ─────────────────────────────────────────────────────────────── *)

let b64url data =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet data
;;

let jwt_rs256 ~now ~app_id ~private_key_pem =
  let header = {|{"alg":"RS256","typ":"JWT"}|} in
  let payload =
    Yojson.Safe.to_string
      (`Assoc
         [ "iat", `Int (int_of_float (now -. jwt_backdate_sec))
         ; "exp", `Int (int_of_float (now +. jwt_lifetime_sec))
         ; "iss", `String app_id
         ])
  in
  let signing_input = b64url header ^ "." ^ b64url payload in
  match X509.Private_key.decode_pem private_key_pem with
  | Error (`Msg msg) -> Error ("github-app private key: " ^ msg)
  | Ok (`RSA key) ->
    let signature =
      Mirage_crypto_pk.Rsa.PKCS1.sign
        ~hash:`SHA256
        ~key
        (`Message signing_input)
    in
    Ok (signing_input ^ "." ^ b64url signature)
  | Ok _ -> Error "github-app private key: not an RSA key"
;;

(* ── Mint ────────────────────────────────────────────────────────────── *)

let parse_mint_response body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error msg -> Error ("mint response: " ^ msg)
  | json ->
    let token =
      match Json_util.assoc_member_opt "token" json with
      | Some (`String value) when value <> "" -> Some value
      | _ -> None
    in
    let expires_at =
      match Json_util.assoc_member_opt "expires_at" json with
      | Some (`String value) ->
        (match Ptime.of_rfc3339 value with
         | Ok (t, _, _) -> Some (Ptime.to_float_s t)
         | Error _ -> None)
      | _ -> None
    in
    (match token, expires_at with
     | Some token, Some expires_at -> Ok (token, expires_at)
     | _ -> Error "mint response is missing token or expires_at")
;;

let mint ~now ~http_post credentials =
  let* jwt =
    jwt_rs256
      ~now
      ~app_id:credentials.app_id
      ~private_key_pem:credentials.private_key_pem
  in
  let url =
    Printf.sprintf
      "https://api.github.com/app/installations/%s/access_tokens"
      credentials.installation_id
  in
  let* status, body =
    http_post
      ~url
      ~headers:
        [ "Authorization", "Bearer " ^ jwt
        ; "Accept", "application/vnd.github+json"
        ; "X-GitHub-Api-Version", "2022-11-28"
        ]
      ~body:(`Assoc [])
  in
  if status = 201
  then parse_mint_response body
  else
    Error
      (Printf.sprintf
         "installation token mint failed: HTTP %d: %s"
         status
         (String.sub body 0 (min 300 (String.length body))))
;;

(* ── hosts.yml projection ────────────────────────────────────────────── *)

(* Same fields the shared-account hosts file carries today. gh reads
   [oauth_token] for API calls and hands it to git over https. *)
let hosts_yml ~login ~token =
  String.concat
    "\n"
    [ "github.com:"
    ; "    user: " ^ login
    ; "    oauth_token: " ^ token
    ; "    git_protocol: https"
    ; ""
    ]
;;

let write_projection ~config ~keeper_name ~token ~expires_at =
  let cli_dir =
    Keeper_github_identity.config_dir ~config ~keeper_name
  in
  Fs_compat.mkdir_p cli_dir;
  (try Unix.chmod cli_dir 0o700 with Unix.Unix_error _ -> ());
  let login = keeper_name ^ "[bot]" in
  let* () =
    Fs_compat.save_file_atomic
      (Filename.concat cli_dir "hosts.yml")
      (hosts_yml ~login ~token)
  in
  let* () =
    Fs_compat.save_file_atomic
      (Filename.concat (credentials_dir ~config ~keeper_name) token_stamp_name)
      (Printf.sprintf "%.0f\n" expires_at)
  in
  (try Unix.chmod (Filename.concat cli_dir "hosts.yml") 0o600
   with Unix.Unix_error _ -> ());
  Ok ()
;;

let stored_expiry ~config ~keeper_name =
  let path =
    Filename.concat (credentials_dir ~config ~keeper_name) token_stamp_name
  in
  if not (Fs_compat.file_exists path)
  then None
  else (
    match Fs_compat.load_file path with
    | exception _ -> None
    | content -> float_of_string_opt (String.trim content))
;;

let ensure_fresh ~now ~http_post ~config ~keeper_name =
  let* credentials = load_credentials ~config ~keeper_name in
  match credentials with
  | None -> Ok No_app_identity
  | Some credentials ->
    (match stored_expiry ~config ~keeper_name with
     | Some expires_at when expires_at -. now > refresh_margin_sec ->
       Ok (Fresh { expires_at })
     | Some _ | None ->
       let* token, expires_at = mint ~now ~http_post credentials in
       let* () = write_projection ~config ~keeper_name ~token ~expires_at in
       Log.Keeper.info
         ~keeper_name
         "github-app installation token refreshed expires_at=%.0f"
         expires_at;
       Ok (Refreshed { expires_at }))
;;

let default_http_post ~url ~headers ~body =
  match
    Tool_local_runtime_http.http_post_json_text_with_status_with_headers
      ~timeout_sec:10
      ~headers
      ~url
      ~body_json:(Yojson.Safe.to_string body)
      ()
  with
  | Error _ as error -> error
  | Ok (Some status, body_text) -> Ok (status, body_text)
  | Ok (None, _) -> Error "installation token mint: no HTTP status from curl"
;;

module For_testing = struct
  let jwt_rs256 = jwt_rs256
  let hosts_yml ~login ~token = hosts_yml ~login ~token
  let parse_mint_response = parse_mint_response
end
