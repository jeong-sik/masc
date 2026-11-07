(* HIGH-RISK-UNREVIEWED: see the interface. *)

let ( let* ) = Result.bind

module Client = struct
  type t =
    { client_id : string
    ; client_secret : string
    ; redirect_uri : string
    }

  type error =
    | Client_id_empty
    | Client_secret_empty
    | Redirect_uri_not_https

  let make ~client_id ~client_secret ~redirect_uri =
    if String.equal client_id ""
    then Error Client_id_empty
    else if String.equal client_secret ""
    then Error Client_secret_empty
    else if not (Login_transport.is_https_url redirect_uri)
    then Error Redirect_uri_not_https
    else Ok { client_id; client_secret; redirect_uri }
  ;;

  let error_to_string = function
    | Client_id_empty -> "the client ID is empty"
    | Client_secret_empty -> "the client secret is empty"
    | Redirect_uri_not_https -> "the redirect URI is not an https URL with a host and no query or fragment"
  ;;

  let client_id t = t.client_id
  let redirect_uri t = t.redirect_uri
end

type endpoints =
  { authorization_endpoint : string
  ; token_endpoint : string
  ; jwks_uri : string
  }

let http_ok = 200

type kept =
  { value : string
  ; fresh_until_ms : int
  }

type cache =
  { mutex : Mutex.t
  ; mutable discovery : (endpoints * int) option
  ; mutable jwks : kept option
  }

let cache () = { mutex = Mutex.create (); discovery = None; jwks = None }

let header name headers =
  List.find_map
    (fun (key, value) -> if String.equal (String.lowercase_ascii key) name then Some value else None)
    headers
;;

let is_digits text = String.length text > 0 && String.for_all (fun c -> c >= '0' && c <= '9') text

(* RFC 9111 section 5.2: a comma-separated list of [token [ "=" value ]]. *)
let cache_lifetime_ms headers =
  match header "cache-control" headers with
  | None -> None
  | Some value ->
    let directives =
      List.map (fun part -> String.lowercase_ascii (String.trim part)) (String.split_on_char ',' value)
    in
    if List.exists (fun directive -> String.equal directive "no-store" || String.equal directive "no-cache") directives
    then None
    else
      List.find_map
        (fun directive ->
          match String.split_on_char '=' directive with
          | [ "max-age"; seconds ] when is_digits seconds ->
            Option.map (fun seconds -> seconds * 1000) (int_of_string_opt seconds)
          | _ -> None)
        directives
;;

type error =
  | Discovery_unavailable of string
  | Discovery_malformed of string
  | Token_unavailable of string
  | Token_refused of
      { status : int
      ; error : string option
      }
  | Token_answer_malformed
  | Keys_unavailable of string
  | Signature_refused of Oidc_id_token_signature.error
  | Claims_refused of Oidc_google.error

let error_to_string = function
  | Discovery_unavailable detail -> "the Google discovery document could not be read: " ^ detail
  | Discovery_malformed member -> "the Google discovery document has no usable " ^ member
  | Token_unavailable detail -> "the Google token endpoint could not be reached: " ^ detail
  | Token_refused { status; error } ->
    Printf.sprintf
      "Google refused the code (HTTP %d%s)"
      status
      (match error with
       | Some error -> ", " ^ error
       | None -> "")
  | Token_answer_malformed -> "the Google token answer has no ID token"
  | Keys_unavailable detail -> "the Google keys could not be read: " ^ detail
  | Signature_refused error -> "the ID token is refused: " ^ Oidc_id_token_signature.error_to_string error
  | Claims_refused error -> Oidc_google.error_to_string error
;;

(* The answer of a GET, as a body of at most [Login_transport.max_answer_bytes]. *)
let fetch ~(get : Login_transport.get) ~url ~unavailable =
  match get ~url ~headers:[] with
  | Error detail -> Error (unavailable detail)
  | Ok { status; _ } when status <> http_ok -> Error (unavailable (Printf.sprintf "HTTP %d" status))
  | Ok { body; _ } when String.length body > Login_transport.max_answer_bytes -> Error (unavailable "the answer is too long")
  | Ok answer -> Ok answer
;;

let string_member name members =
  match List.assoc_opt name members with
  | Some (`String value) -> Some value
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) | None -> None
;;

let endpoints_of_document body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> Error (Discovery_malformed "JSON object")
  | `Assoc members ->
    let url name =
      match string_member name members with
      | Some url when Login_transport.is_https_url url -> Ok url
      | Some _ | None -> Error (Discovery_malformed name)
    in
    let* () =
      match string_member "issuer" members with
      | Some issuer when Oidc_google.is_issuer issuer -> Ok ()
      | Some _ | None -> Error (Discovery_malformed "issuer")
    in
    let* authorization_endpoint = url "authorization_endpoint" in
    let* token_endpoint = url "token_endpoint" in
    let* jwks_uri = url "jwks_uri" in
    Ok { authorization_endpoint; token_endpoint; jwks_uri }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error (Discovery_malformed "JSON object")
;;

let endpoints ~get cache ~now_ms =
  match
    Mutex.protect cache.mutex (fun () ->
      match cache.discovery with
      | Some (endpoints, fresh_until_ms) when now_ms < fresh_until_ms -> Some endpoints
      | Some _ | None -> None)
  with
  | Some endpoints -> Ok endpoints
  | None ->
    let* answer =
      fetch ~get ~url:Oidc_google.discovery_url ~unavailable:(fun detail -> Discovery_unavailable detail)
    in
    let* endpoints = endpoints_of_document answer.body in
    Option.iter
      (fun lifetime_ms ->
        Mutex.protect cache.mutex (fun () -> cache.discovery <- Some (endpoints, now_ms + lifetime_ms)))
      (cache_lifetime_ms answer.headers);
    Ok endpoints
;;

let authorization_url
  endpoints
  (client : Client.t)
  (started : Oidc_login_transaction.google Oidc_login_transaction.started)
  =
  endpoints.authorization_endpoint
  ^ "?"
  ^ Login_transport.form
      [ "response_type", "code"
      ; "client_id", client.client_id
      ; "redirect_uri", client.redirect_uri
      ; "scope", "openid"
      ; "state", started.state
      ; "nonce", started.held.nonce
      ; "code_challenge", started.code_challenge
      ; "code_challenge_method", "S256"
      ]
;;

let json_members body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> None
  | `Assoc members -> Some members
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let id_token_of_code ~(post : Login_transport.post) endpoints (client : Client.t) ~code ~code_verifier =
  let body =
    Login_transport.form
      [ "grant_type", "authorization_code"
      ; "code", code
      ; "client_id", client.client_id
      ; "client_secret", client.client_secret
      ; "redirect_uri", client.redirect_uri
      ; "code_verifier", code_verifier
      ]
  in
  let headers = [ "content-type", "application/x-www-form-urlencoded"; "accept", "application/json" ] in
  match post ~url:endpoints.token_endpoint ~headers ~body with
  | Error detail -> Error (Token_unavailable detail)
  | Ok { status; body; _ } when status <> http_ok ->
    Error (Token_refused { status; error = Option.bind (json_members body) (string_member "error") })
  | Ok { body; _ } ->
    (match Option.bind (json_members body) (string_member "id_token") with
     | Some token when String.length token <= Login_transport.max_answer_bytes -> Ok token
     | Some _ | None -> Error Token_answer_malformed)
;;

(* Only an unknown key ID can mean that Google rotated its keys after the
   cache was filled; every other failure is the same with any JWKS. *)
let rotated : Oidc_id_token_signature.error -> bool = function
  | Unknown_key_id -> true
  | Malformed_token
  | Algorithm_not_allowed
  | Unsupported_critical_header
  | Missing_key_id
  | Malformed_jwks
  | Key_not_rs256
  | Key_too_short
  | Invalid_signature
  | Invalid_expiry
  | Expired -> false
;;

let verified ~get cache ~now ~now_ms endpoints token =
  let check jwks =
    Result.map_error
      (fun error -> Signature_refused error)
      (Oidc_id_token_signature.verify_signature_and_expiry ~jwks ~now token)
  in
  let read_and_check () =
    let* answer = fetch ~get ~url:endpoints.jwks_uri ~unavailable:(fun detail -> Keys_unavailable detail) in
    Mutex.protect cache.mutex (fun () ->
      cache.jwks
      <- Option.map
           (fun lifetime_ms -> { value = answer.body; fresh_until_ms = now_ms + lifetime_ms })
           (cache_lifetime_ms answer.headers));
    check answer.body
  in
  match
    Mutex.protect cache.mutex (fun () ->
      match cache.jwks with
      | Some { value; fresh_until_ms } when now_ms < fresh_until_ms -> Some value
      | Some _ | None -> None)
  with
  | None -> read_and_check ()
  | Some jwks ->
    (match Oidc_id_token_signature.verify_signature_and_expiry ~jwks ~now token with
     | Ok payload -> Ok payload
     | Error error when rotated error -> read_and_check ()
     | Error error -> Error (Signature_refused error))
;;

let identity
  ~get
  ~post
  cache
  ~now
  ~now_ms
  (client : Client.t)
  ~code
  (taken : Oidc_login_transaction.google Oidc_login_transaction.taken)
  =
  let* endpoints = endpoints ~get cache ~now_ms in
  let* token = id_token_of_code ~post endpoints client ~code ~code_verifier:taken.code_verifier in
  let* payload = verified ~get cache ~now ~now_ms endpoints token in
  Result.map_error
    (fun error -> Claims_refused error)
    (Oidc_google.identity ~client_id:client.client_id ~nonce:taken.held.nonce payload)
;;
