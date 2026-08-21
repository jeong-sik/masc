(* HIGH-RISK-UNREVIEWED: OAuth authorization and token lifecycle code.
   Human security review is required before this marker may be removed. *)

open Masc_domain

let ( let* ) = Result.bind

type scope =
  | Mcp_tools
  | Mcp_admin
[@@deriving show { with_path = false }, eq]

let scope_to_string = function
  | Mcp_tools -> "mcp:tools"
  | Mcp_admin -> "mcp:admin"
;;

let scopes_supported = [ Mcp_tools; Mcp_admin ]
let scopes_to_string scopes = String.concat " " (List.map scope_to_string scopes)

type error =
  | OAuth_disabled
  | Invalid_request of string
  | Invalid_client
  | Invalid_grant
  | Invalid_scope
  | Access_denied
  | Temporarily_unavailable
  | Store_error of string
[@@deriving show { with_path = false }]

let protocol_error_code = function
  | OAuth_disabled | Temporarily_unavailable -> "temporarily_unavailable"
  | Invalid_request _ -> "invalid_request"
  | Invalid_client -> "invalid_client"
  | Invalid_grant -> "invalid_grant"
  | Invalid_scope -> "invalid_scope"
  | Access_denied -> "access_denied"
  | Store_error _ -> "server_error"
;;

module Policy = struct
  let max_redirect_uris = 8
  let max_uri_bytes = 2048
  let max_client_name_bytes = 200
  let max_state_bytes = 1024
end

let enabled = Env_config_runtime_services.OAuth.enabled
let code_ttl_sec = Env_config_runtime_services.OAuth.code_ttl_sec
let access_token_ttl_sec = Env_config_runtime_services.OAuth.access_token_ttl_sec
let refresh_token_ttl_sec = Env_config_runtime_services.OAuth.refresh_token_ttl_sec
let max_pending_codes = Env_config_runtime_services.OAuth.max_pending_codes
let max_clients = Env_config_runtime_services.OAuth.max_clients

let pkce_s256 verifier =
  Digestif.SHA256.digest_string verifier
  |> Digestif.SHA256.to_raw_string
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
;;

let constant_time_string_equal = Auth_credential_base.constant_time_string_equal

let expected_resource_key : string Eio.Fiber.key = Eio.Fiber.create_key ()

let with_expected_resource resource f =
  Eio.Fiber.with_binding expected_resource_key resource f
;;

let expected_resource () =
  match Eio.Fiber.get expected_resource_key with
  | value -> value
  | exception Effect.Unhandled _ -> None
;;

let is_pkce_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
  | _ -> false
;;

let valid_pkce_value value =
  let length = String.length value in
  length >= 43 && length <= 128 && String.for_all is_pkce_char value
;;

let add_scope_once acc scope =
  if List.exists (equal_scope scope) acc then acc else acc @ [ scope ]
;;

let add_scope_with_implications acc = function
  | Mcp_tools -> add_scope_once acc Mcp_tools
  | Mcp_admin ->
    let acc = add_scope_once acc Mcp_tools in
    add_scope_once acc Mcp_admin
;;

let parse_scopes raw =
  let values =
    match raw with
    | None -> [ scope_to_string Mcp_tools ]
    | Some value ->
      value
      |> String.split_on_char ' '
      |> List.filter_map (fun item ->
        let item = String.trim item in
        if String.equal item "" then None else Some item)
  in
  let rec parse acc = function
    | [] -> Ok acc
    | "mcp:tools" :: rest -> parse (add_scope_with_implications acc Mcp_tools) rest
    | "mcp:admin" :: rest -> parse (add_scope_with_implications acc Mcp_admin) rest
    | _ :: _ -> Error Invalid_scope
  in
  match values with
  | [] -> Error Invalid_scope
  | _ -> parse [] values
;;

let effective_role ~bootstrap_role scopes =
  if List.exists (equal_scope Mcp_admin) scopes
  then
    match bootstrap_role with
    | Admin -> Ok Admin
    | Worker -> Error Invalid_scope
  else Ok Worker
;;

let validate_loopback_redirect_uri value =
  if String.length value = 0 || String.length value > Policy.max_uri_bytes
  then Error (Invalid_request "redirect_uri length is invalid")
  else
    let uri = Uri.of_string value in
    let scheme_ok =
      match Uri.scheme uri with
      | Some scheme -> String.equal (String.lowercase_ascii scheme) "http"
      | None -> false
    in
    let host_ok =
      match Uri.host uri with
      | Some host when String.equal (String.lowercase_ascii host) "localhost" -> true
      | Some host ->
        (match Ipaddr.of_string host with
         | Ok (Ipaddr.V4 address) ->
           let octets = Ipaddr.V4.to_octets address in
           String.length octets = 4 && Char.code octets.[0] = 127
         | Ok (Ipaddr.V6 address) ->
           Ipaddr.V6.compare address Ipaddr.V6.localhost = 0
         | Error _ -> false)
      | None -> false
    in
    if
      scheme_ok
      && host_ok
      && Option.is_none (Uri.userinfo uri)
      && Option.is_none (Uri.fragment uri)
    then Ok ()
    else Error (Invalid_request "redirect_uri must be an absolute loopback HTTP URI")
;;

type client =
  { client_id : string
  ; client_name : string option
  ; redirect_uris : string list
  ; created_at_unix : float
  }

type authorization_request =
  { client_id : string
  ; client_name : string option
  ; redirect_uri : string
  ; resource : string
  ; scopes : scope list
  ; state : string option
  ; code_challenge : string
  }

type pending_grant =
  { base_path : string
  ; request : authorization_request
  ; agent_name : string
  ; bootstrap_token_hash : string
  ; role : agent_role
  ; expires_at_unix : float
  }

type access_record =
  { token_hash : string
  ; family_id : string
  ; issued_at_unix : float
  ; expires_at_unix : float
  }

type family_record =
  { family_id : string
  ; client_id : string
  ; agent_name : string
  ; bootstrap_token_hash : string
  ; role : agent_role
  ; scopes : scope list
  ; resource : string
  ; current_access_hash : string
  ; current_refresh_hash : string
  ; refresh_expires_at_unix : float
  ; revoked_at_unix : float option
  }

type token_pair =
  { access_token : string
  ; refresh_token : string
  ; token_type : string
  ; expires_in : int
  ; scope : string
  }

(* Protects only non-yielding in-process Hashtbl operations. Durable store work
   is serialized separately through [with_store_io]. *)
let pending_mutex = Stdlib.Mutex.create ()
let pending_codes : (string, pending_grant) Hashtbl.t = Hashtbl.create 31
let store_mutex = Stdlib.Mutex.create ()

let now () = Time_compat.now ()
let token_hash = Auth_credential_base.sha256_hash
let oauth_dir base_path = Filename.concat (Auth_credential_base.auth_dir base_path) "oauth"
let clients_dir base_path = Filename.concat (oauth_dir base_path) "clients"
let access_tokens_dir base_path = Filename.concat (oauth_dir base_path) "access_tokens"
let families_dir base_path = Filename.concat (oauth_dir base_path) "families"

let client_path base_path client_id =
  Filename.concat (clients_dir base_path) (token_hash client_id ^ ".json")
;;

let access_path base_path hash =
  Filename.concat (access_tokens_dir base_path) (hash ^ ".json")
;;

let family_path base_path family_id =
  Filename.concat (families_dir base_path) (token_hash family_id ^ ".json")
;;

let ensure_oauth_dirs base_path =
  Auth_credential_base.ensure_auth_dirs base_path;
  List.iter
    Fs_compat.mkdir_p
    [ oauth_dir base_path
    ; clients_dir base_path
    ; access_tokens_dir base_path
    ; families_dir base_path
    ]
;;

let save_json_private path json =
  let payload = Yojson.Safe.pretty_to_string json in
  (* [save_file_atomic] creates its sibling temp inode with mode 0600 via
     [Filename.temp_file]. Truncating that existing inode does not widen its
     mode, and rename preserves it. Keep publication, fsync, cleanup, and
     cancellation semantics in the shared writer; the OAuth test below locks
     the resulting record mode. *)
  match Fs_compat.save_file_atomic path payload with
  | Error msg -> Error (Store_error msg)
  | Ok () -> Ok ()
;;

let load_json_opt path =
  if not (Sys.file_exists path)
  then Ok None
  else
    try Ok (Some (Yojson.Safe.from_string (Fs_compat.load_file path))) with
    | Sys_error msg | Yojson.Json_error msg -> Error (Store_error msg)
;;

let rec lock_store fd =
  match Unix.lockf fd Unix.F_LOCK 0 with
  | () -> Ok ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> lock_store fd
;;

let with_store_io ~base_path f =
  try
    Auth_credential_base.run_blocking_io (fun () ->
      Stdlib.Mutex.protect store_mutex (fun () ->
        ensure_oauth_dirs base_path;
        let lock_path = Filename.concat (oauth_dir base_path) ".store.lock" in
        let fd =
          Unix.openfile
            lock_path
            [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ]
            0o600
        in
        Fun.protect
          ~finally:(fun () ->
            (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
            Unix.close fd)
          (fun () ->
            let* () = lock_store fd in
            f ())))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Store_error (Printexc.to_string exn))
;;

let json_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | _ -> Error (Store_error (Printf.sprintf "invalid OAuth store field %s" name))
;;

let json_optional_string fields name =
  match List.assoc_opt name fields with
  | Some `Null | None -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (Store_error (Printf.sprintf "invalid OAuth store field %s" name))
;;

let json_float fields name =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (float_of_int value)
  | _ -> Error (Store_error (Printf.sprintf "invalid OAuth store field %s" name))
;;

let json_string_list fields name =
  match List.assoc_opt name fields with
  | Some (`List values) ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> collect (value :: acc) rest
      | _ :: _ -> Error (Store_error (Printf.sprintf "invalid OAuth store field %s" name))
    in
    collect [] values
  | _ -> Error (Store_error (Printf.sprintf "invalid OAuth store field %s" name))
;;

let role_of_string = function
  | "worker" -> Ok Worker
  | "admin" -> Ok Admin
  | _ -> Error (Store_error "invalid OAuth role")
;;

let scopes_of_strings values =
  let rec parse acc = function
    | [] -> Ok acc
    | "mcp:tools" :: rest -> parse (add_scope_once acc Mcp_tools) rest
    | "mcp:admin" :: rest -> parse (add_scope_once acc Mcp_admin) rest
    | _ :: _ -> Error (Store_error "invalid OAuth scope")
  in
  let* scopes = parse [] values in
  if
    List.exists (equal_scope Mcp_admin) scopes
    && not (List.exists (equal_scope Mcp_tools) scopes)
  then Error (Store_error "invalid OAuth scope closure: mcp:admin requires mcp:tools")
  else Ok scopes
;;

let client_to_yojson (client : client) =
  `Assoc
    [ "client_id", `String client.client_id
    ; "client_name", (match client.client_name with None -> `Null | Some v -> `String v)
    ; "redirect_uris", `List (List.map (fun v -> `String v) client.redirect_uris)
    ; "created_at_unix", `Float client.created_at_unix
    ]
;;

let client_of_yojson = function
  | `Assoc fields ->
    let* client_id = json_string fields "client_id" in
    let* client_name = json_optional_string fields "client_name" in
    let* redirect_uris = json_string_list fields "redirect_uris" in
    let* created_at_unix = json_float fields "created_at_unix" in
    Ok { client_id; client_name; redirect_uris; created_at_unix }
  | _ -> Error (Store_error "invalid OAuth client record")
;;

let token_record_to_yojson
    ~token_hash:hash
    ~family_id
    ~issued_at_unix
    ~expires_at_unix
  =
  `Assoc
    [ "token_hash", `String hash
    ; "family_id", `String family_id
    ; "issued_at_unix", `Float issued_at_unix
    ; "expires_at_unix", `Float expires_at_unix
    ]
;;

let token_record_fields = function
  | `Assoc fields ->
    let* token_hash = json_string fields "token_hash" in
    let* family_id = json_string fields "family_id" in
    let* issued_at_unix = json_float fields "issued_at_unix" in
    let* expires_at_unix = json_float fields "expires_at_unix" in
    Ok (token_hash, family_id, issued_at_unix, expires_at_unix)
  | _ -> Error (Store_error "invalid OAuth token record")
;;

let access_record_of_yojson json =
  let*
    (token_hash, family_id, issued_at_unix, expires_at_unix)
    = token_record_fields json
  in
  Ok
    { token_hash
    ; family_id
    ; issued_at_unix
    ; expires_at_unix
    }
;;

let family_to_yojson (family : family_record) =
  `Assoc
    [ "family_id", `String family.family_id
    ; "client_id", `String family.client_id
    ; "agent_name", `String family.agent_name
    ; "bootstrap_token_hash", `String family.bootstrap_token_hash
    ; "role", `String (agent_role_to_string family.role)
    ; "scopes", `List (List.map (fun scope -> `String (scope_to_string scope)) family.scopes)
    ; "resource", `String family.resource
    ; "current_access_hash", `String family.current_access_hash
    ; "current_refresh_hash", `String family.current_refresh_hash
    ; "refresh_expires_at_unix", `Float family.refresh_expires_at_unix
    ; ( "revoked_at_unix"
      , match family.revoked_at_unix with
        | None -> `Null
        | Some value -> `Float value )
    ]
;;

let family_of_yojson = function
  | `Assoc fields ->
    let* family_id = json_string fields "family_id" in
    let* client_id = json_string fields "client_id" in
    let* agent_name = json_string fields "agent_name" in
    let* bootstrap_token_hash = json_string fields "bootstrap_token_hash" in
    let* role_name = json_string fields "role" in
    let* role = role_of_string role_name in
    let* scope_names = json_string_list fields "scopes" in
    let* scopes = scopes_of_strings scope_names in
    let* resource = json_string fields "resource" in
    let* current_access_hash = json_string fields "current_access_hash" in
    let* current_refresh_hash = json_string fields "current_refresh_hash" in
    let* refresh_expires_at_unix = json_float fields "refresh_expires_at_unix" in
    let* revoked_at_unix =
      match List.assoc_opt "revoked_at_unix" fields with
      | None | Some `Null -> Ok None
      | Some (`Float value) -> Ok (Some value)
      | Some (`Int value) -> Ok (Some (float_of_int value))
      | Some _ -> Error (Store_error "invalid OAuth store field revoked_at_unix")
    in
    Ok
      { family_id
      ; client_id
      ; agent_name
      ; bootstrap_token_hash
      ; role
      ; scopes
      ; resource
      ; current_access_hash
      ; current_refresh_hash
      ; refresh_expires_at_unix
      ; revoked_at_unix
      }
  | _ -> Error (Store_error "invalid OAuth token family record")
;;

let cleanup_expired_codes_locked current =
  Hashtbl.filter_map_inplace
    (fun _ (grant : pending_grant) ->
      if grant.expires_at_unix <= current then None else Some grant)
    pending_codes
;;

let register_client ~base_path ~client_name ~redirect_uris =
  if not (enabled ())
  then Error OAuth_disabled
  else if redirect_uris = [] || List.length redirect_uris > Policy.max_redirect_uris
  then Error (Invalid_request "redirect_uris count is invalid")
  else if
    match client_name with
    | Some value -> String.length value > Policy.max_client_name_bytes
    | None -> false
  then Error (Invalid_request "client_name is too long")
  else
    let rec validate seen = function
      | [] -> Ok ()
      | uri :: rest ->
        if List.mem uri seen
        then Error (Invalid_request "redirect_uris contains a duplicate")
        else
          let* () = validate_loopback_redirect_uri uri in
          validate (uri :: seen) rest
    in
    let* () = validate [] redirect_uris in
    let created_at_unix = now () in
    let client =
      { client_id = "masc_" ^ Auth_credential_base.generate_token ()
      ; client_name
      ; redirect_uris
      ; created_at_unix
      }
    in
    with_store_io ~base_path (fun () ->
      let entries =
        Sys.readdir (clients_dir base_path)
        |> Array.to_list
        |> List.filter (fun path -> Filename.check_suffix path ".json")
      in
      let rec load_clients acc = function
        | [] -> Ok (List.rev acc)
        | entry :: rest ->
          let path = Filename.concat (clients_dir base_path) entry in
          let* json = load_json_opt path in
          (match json with
           | None -> load_clients acc rest
           | Some json ->
             let* stored = client_of_yojson json in
             load_clients ((path, stored) :: acc) rest)
      in
      let* stored_clients = load_clients [] entries in
      match
        List.find_opt
          (fun (_, (stored : client)) ->
            Option.equal String.equal stored.client_name client_name
            && List.equal
                 String.equal
                 (List.sort String.compare stored.redirect_uris)
                 (List.sort String.compare redirect_uris))
          stored_clients
      with
      | Some (_, stored) -> Ok stored
      | None ->
        let client_limit = max_clients () in
        let* () =
          if List.length stored_clients < client_limit
          then Ok ()
          else Error Temporarily_unavailable
        in
        let* () =
          save_json_private
            (client_path base_path client.client_id)
            (client_to_yojson client)
        in
        Ok client)
;;

let find_client ~base_path ~client_id =
  with_store_io ~base_path (fun () ->
    let* json = load_json_opt (client_path base_path client_id) in
    match json with
    | None -> Ok None
    | Some json ->
      let* client = client_of_yojson json in
      if constant_time_string_equal client.client_id client_id
      then Ok (Some client)
      else Error (Store_error "OAuth client file integrity mismatch"))
;;

let activate_client_locked ~base_path ~client_id =
  let path = client_path base_path client_id in
  let* json = load_json_opt path in
  match json with
  | None -> Error Invalid_client
  | Some json ->
    let* client = client_of_yojson json in
    if not (constant_time_string_equal client.client_id client_id)
    then Error (Store_error "OAuth client file integrity mismatch")
    else Ok ()
;;

let require_nonempty name = function
  | Some value when not (String.equal (String.trim value) "") -> Ok value
  | _ -> Error (Invalid_request (name ^ " is required"))
;;

let validate_authorization_request
    ~base_path
    ~expected_resource
    ~response_type
    ~client_id
    ~redirect_uri
    ~resource
    ~scope
    ~state
    ~code_challenge
    ~code_challenge_method
  =
  if not (enabled ())
  then Error OAuth_disabled
  else
    let* response_type = require_nonempty "response_type" response_type in
    let* client_id = require_nonempty "client_id" client_id in
    let* redirect_uri = require_nonempty "redirect_uri" redirect_uri in
    let* resource = require_nonempty "resource" resource in
    let* code_challenge = require_nonempty "code_challenge" code_challenge in
    let* code_challenge_method =
      require_nonempty "code_challenge_method" code_challenge_method
    in
    if not (String.equal response_type "code")
    then Error (Invalid_request "response_type must be code")
    else if not (String.equal code_challenge_method "S256")
    then Error (Invalid_request "code_challenge_method must be S256")
    else if not (valid_pkce_value code_challenge)
    then Error (Invalid_request "code_challenge is invalid")
    else if not (String.equal resource expected_resource)
    then Error (Invalid_request "resource does not match the MCP endpoint")
    else if
      match state with
      | Some value -> String.length value > Policy.max_state_bytes
      | None -> false
    then Error (Invalid_request "state is too long")
    else
      let* scopes = parse_scopes scope in
      let* client = find_client ~base_path ~client_id in
      match client with
      | None -> Error Invalid_client
      | Some client when not (List.mem redirect_uri client.redirect_uris) ->
        Error (Invalid_request "redirect_uri is not registered")
      | Some client ->
        Ok
          { client_id
          ; client_name = client.client_name
          ; redirect_uri
          ; resource
          ; scopes
          ; state
          ; code_challenge
          }
;;

let issue_authorization_code
    ~base_path
    ~(request : authorization_request)
    ~(bootstrap_credential : agent_credential)
  =
  let* role = effective_role ~bootstrap_role:bootstrap_credential.role request.scopes in
  let raw_code = "mac_" ^ Auth_credential_base.generate_token () in
  let hash = token_hash raw_code in
  let issued_at_unix = now () in
  let grant =
    { base_path
    ; request
    ; agent_name = bootstrap_credential.agent_name
    ; bootstrap_token_hash = token_hash bootstrap_credential.token
    ; role
    ; expires_at_unix = issued_at_unix +. float_of_int (code_ttl_sec ())
    }
  in
  let* () =
    with_store_io ~base_path (fun () ->
      activate_client_locked ~base_path ~client_id:request.client_id)
  in
  Stdlib.Mutex.protect pending_mutex (fun () ->
      cleanup_expired_codes_locked issued_at_unix;
      if Hashtbl.length pending_codes >= max_pending_codes ()
      then Error Temporarily_unavailable
      else (
        Hashtbl.replace pending_codes hash grant;
        Ok raw_code))
;;

let load_family base_path family_id =
  let* json = load_json_opt (family_path base_path family_id) in
  match json with
  | None -> Ok None
  | Some json ->
    let* family = family_of_yojson json in
    if String.equal family.family_id family_id
    then Ok (Some family)
    else Error (Store_error "OAuth family file integrity mismatch")
;;

let live_role_allows ~granted_role live_role =
  match granted_role, live_role with
  | Worker, (Worker | Admin) | Admin, Admin -> true
  | Admin, Worker -> false
;;

let live_bootstrap_allows
    ~base_path
    ~agent_name
    ~bootstrap_token_hash
    ~granted_role
  =
  match Auth_credential_base.load_credential base_path agent_name with
  | None -> false
  | Some credential ->
    let not_expired =
      match credential.expires_at with
      | None -> true
      | Some expires_at ->
        String.compare (iso8601_of_unix_seconds (now ())) expires_at <= 0
    in
    not_expired
    && constant_time_string_equal (token_hash credential.token) bootstrap_token_hash
    && live_role_allows ~granted_role credential.role
;;

let revoke_family_locked ~base_path ~current family =
  match family.revoked_at_unix with
  | Some _ -> Ok ()
  | None ->
    let revoked_family = { family with revoked_at_unix = Some current } in
    save_json_private
      (family_path base_path family.family_id)
      (family_to_yojson revoked_family)
;;

let remove_file_if_exists path =
  match Sys.remove path with
  | () -> ()
  | exception Sys_error _ when not (Sys.file_exists path) -> ()
;;

let json_entries dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun path -> Filename.check_suffix path ".json")
;;

let cleanup_token_store_locked ~base_path ~current =
  let cleanup_access entry =
    let path = Filename.concat (access_tokens_dir base_path) entry in
    let* json = load_json_opt path in
    match json with
    | None -> Ok ()
    | Some json ->
      let* record = access_record_of_yojson json in
      let* family = load_family base_path record.family_id in
      let removable =
        record.expires_at_unix <= current
        || match family with
           | None -> true
           | Some family ->
             Option.is_some family.revoked_at_unix
             || not
                  (constant_time_string_equal
                     family.current_access_hash
                     record.token_hash)
      in
      if removable then remove_file_if_exists path;
      Ok ()
  in
  let rec iter f = function
    | [] -> Ok ()
    | entry :: rest ->
      let* () = f entry in
      iter f rest
  in
  let* () = iter cleanup_access (json_entries (access_tokens_dir base_path)) in
  let cleanup_family entry =
    let path = Filename.concat (families_dir base_path) entry in
    let* json = load_json_opt path in
    match json with
    | None -> Ok ()
    | Some json ->
      let* family = family_of_yojson json in
      if
        Option.is_some family.revoked_at_unix
        || (family.refresh_expires_at_unix <= current
            && not (Sys.file_exists (access_path base_path family.current_access_hash)))
      then remove_file_if_exists path;
      Ok ()
  in
  iter cleanup_family (json_entries (families_dir base_path))
;;

let refresh_token_for_family family_id =
  "mrt_" ^ family_id ^ "." ^ Auth_credential_base.generate_token ()
;;

let refresh_token_family_id token =
  let prefix = "mrt_" in
  if not (String.starts_with ~prefix token)
  then None
  else
    match String.split_on_char '.' (String.sub token (String.length prefix) (String.length token - String.length prefix)) with
    | [ family_id; secret ] when not (String.equal family_id "" || String.equal secret "") ->
      Some family_id
    | _ -> None
;;

let mint_pair_locked
    ~base_path
    ~family_id
    ~client_id
    ~agent_name
    ~bootstrap_token_hash
    ~role
    ~scopes
    ~resource
  =
  ensure_oauth_dirs base_path;
  let* () = cleanup_token_store_locked ~base_path ~current:(now ()) in
  let issued_at_unix = now () in
  let access_token = "mat_" ^ Auth_credential_base.generate_token () in
  let refresh_token = refresh_token_for_family family_id in
  let access_hash = token_hash access_token in
  let refresh_hash = token_hash refresh_token in
  let access =
    { token_hash = access_hash
    ; family_id
    ; issued_at_unix
    ; expires_at_unix = issued_at_unix +. float_of_int (access_token_ttl_sec ())
    }
  in
  let family =
    { family_id
    ; client_id
    ; agent_name
    ; bootstrap_token_hash
    ; role
    ; scopes
    ; resource
    ; current_access_hash = access_hash
    ; current_refresh_hash = refresh_hash
    ; refresh_expires_at_unix =
        issued_at_unix +. float_of_int (refresh_token_ttl_sec ())
    ; revoked_at_unix = None
    }
  in
  let access_json =
    token_record_to_yojson
      ~token_hash:access.token_hash
      ~family_id:access.family_id
      ~issued_at_unix:access.issued_at_unix
      ~expires_at_unix:access.expires_at_unix
  in
  let* () = save_json_private (access_path base_path access_hash) access_json in
  let* () = save_json_private (family_path base_path family_id) (family_to_yojson family) in
  Ok
    { access_token
    ; refresh_token
    ; token_type = "Bearer"
    ; expires_in = access_token_ttl_sec ()
    ; scope = scopes_to_string scopes
    }
;;

let exchange_authorization_code
    ~base_path
    ~expected_resource
    ~code
    ~client_id
    ~redirect_uri
    ~resource
    ~code_verifier
  =
  if not (enabled ())
  then Error OAuth_disabled
  else if not (valid_pkce_value code_verifier)
  then Error Invalid_grant
  else
    let hash = token_hash code in
    let claimed_grant =
      Stdlib.Mutex.protect pending_mutex (fun () ->
          let current = now () in
          cleanup_expired_codes_locked current;
          match Hashtbl.find_opt pending_codes hash with
          | None -> Error Invalid_grant
          | Some grant ->
            let resource =
              match resource with
              | Some resource -> resource
              | None -> grant.request.resource
            in
            if
              not (String.equal grant.base_path base_path)
              || not (String.equal grant.request.client_id client_id)
              || not (String.equal grant.request.redirect_uri redirect_uri)
              || not (String.equal grant.request.resource resource)
              || not (String.equal expected_resource resource)
              || not
                   (constant_time_string_equal
                      grant.request.code_challenge
                      (pkce_s256 code_verifier))
            then Error Invalid_grant
            else (
              Hashtbl.remove pending_codes hash;
              Ok grant))
    in
    let* grant = claimed_grant in
    let family_id = "mof_" ^ Auth_credential_base.generate_token () in
    with_store_io ~base_path (fun () ->
      if
        live_bootstrap_allows
          ~base_path
          ~agent_name:grant.agent_name
          ~bootstrap_token_hash:grant.bootstrap_token_hash
          ~granted_role:grant.role
      then
        mint_pair_locked
          ~base_path
          ~family_id
          ~client_id:grant.request.client_id
          ~agent_name:grant.agent_name
          ~bootstrap_token_hash:grant.bootstrap_token_hash
          ~role:grant.role
          ~scopes:grant.request.scopes
          ~resource:grant.request.resource
      else Error Invalid_grant)
;;

let rotate_refresh_token
    ~base_path
    ~expected_resource
    ~refresh_token
    ~client_id
    ~scope
    ~resource
  =
  if not (enabled ())
  then Error OAuth_disabled
  else
    let refresh_hash = token_hash refresh_token in
    let* family_id =
      match refresh_token_family_id refresh_token with
      | Some family_id -> Ok family_id
      | None -> Error Invalid_grant
    in
    with_store_io ~base_path (fun () ->
      let* family = load_family base_path family_id in
      let current = now () in
      match family with
      | None -> Error Invalid_grant
      | Some family
        when Option.is_some family.revoked_at_unix ->
        Error Invalid_grant
      | Some family
        when not
               (constant_time_string_equal
                  family.current_refresh_hash
                  refresh_hash) ->
        let* () = revoke_family_locked ~base_path ~current family in
        Log.Auth.warn "oauth: refresh token replay revoked token family";
        Error Invalid_grant
      | Some family
        when not
               (live_bootstrap_allows
                  ~base_path
                  ~agent_name:family.agent_name
                  ~bootstrap_token_hash:family.bootstrap_token_hash
                  ~granted_role:family.role) ->
        let* () = revoke_family_locked ~base_path ~current family in
        Log.Auth.warn "oauth: live bootstrap credential revoked token family";
        Error Invalid_grant
      | Some family
        when family.refresh_expires_at_unix <= current
             || not (String.equal family.client_id client_id)
             || not (String.equal family.resource expected_resource)
             || not
                  (match resource with
                   | None -> true
                   | Some requested -> String.equal family.resource requested) ->
        Error Invalid_grant
      | Some family ->
        let* scopes =
          match scope with
          | None -> Ok family.scopes
          | Some raw when String.equal (String.trim raw) "" -> Error Invalid_scope
          | Some raw ->
            let* requested = parse_scopes (Some raw) in
            let granted requested_scope =
              List.exists (equal_scope requested_scope) family.scopes
            in
            if List.for_all granted requested then Ok requested else Error Invalid_scope
        in
        let* role = effective_role ~bootstrap_role:family.role scopes in
        let old_access_path = access_path base_path family.current_access_hash in
        let* pair =
          mint_pair_locked
            ~base_path
            ~family_id:family.family_id
            ~client_id:family.client_id
            ~agent_name:family.agent_name
            ~bootstrap_token_hash:family.bootstrap_token_hash
            ~role
            ~scopes
            ~resource:family.resource
        in
        (match remove_file_if_exists old_access_path with
         | () -> ()
         | exception exn ->
           Log.Auth.warn
             "oauth: superseded access record cleanup failed error=%s"
             (Printexc.to_string exn));
        Ok pair)
;;

let find_access_credential ~base_path ~token =
  if not (enabled ())
  then Ok None
  else
    let hash = token_hash token in
    let path = access_path base_path hash in
    if not (Sys.file_exists path)
    then Ok None
    else
      let request_resource = expected_resource () in
      let result =
        with_store_io ~base_path (fun () ->
          let* json = load_json_opt path in
          match json with
          | None -> Ok None
          | Some json ->
            let* record = access_record_of_yojson json in
            let* family = load_family base_path record.family_id in
            (match family with
             | None -> Error (Store_error "OAuth access token family is missing")
             | Some family ->
               let live_bootstrap =
                 live_bootstrap_allows
                   ~base_path
                   ~agent_name:family.agent_name
                   ~bootstrap_token_hash:family.bootstrap_token_hash
                   ~granted_role:family.role
               in
               if not live_bootstrap
               then
                 let* () =
                   revoke_family_locked ~base_path ~current:(now ()) family
                 in
                 Error Invalid_grant
               else if
                 record.expires_at_unix <= now ()
                 || Option.is_some family.revoked_at_unix
                 || not
                      (match request_resource with
                       | Some expected -> String.equal family.resource expected
                       | None -> false)
                 || not (constant_time_string_equal record.token_hash hash)
                 || not
                      (constant_time_string_equal family.current_access_hash hash)
               then Error Invalid_grant
               else
                 Ok
                   (Some
                      { id = None
                      ; agent_id = None
                      ; agent_name = family.agent_name
                      ; token = record.token_hash
                      ; role = family.role
                      ; created_at =
                          iso8601_of_unix_seconds record.issued_at_unix
                      ; expires_at =
                          Some (iso8601_of_unix_seconds record.expires_at_unix)
                      })))
      in
      match result with
      | Ok value -> Ok value
      | Error (Store_error detail) ->
        Error (System (System_error.IoError ("OAuth credential store: " ^ detail)))
      | Error Temporarily_unavailable ->
        Error (System (System_error.IoError "OAuth credential store unavailable"))
      | Error error ->
        Error
          (Auth
             (Auth_error.InvalidToken
                ("OAuth access token rejected: " ^ protocol_error_code error)))
;;
