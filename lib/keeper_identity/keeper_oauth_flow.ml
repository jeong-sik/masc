(** See keeper_oauth_flow.mli. Every provider-specific value here comes from
    the declaration; there is no branch that names a service. *)

module Provider = Keeper_oauth_provider

type tokens = {
  access_token : string;
  refresh_token : string option;
  expires_at : float option;
}

type pending = {
  provider_id : string;
  keeper : string;
  verifier : string;
  state : string;
  redirect_uri : string;
  authorize_url : string;
}

type exchange_error =
  | Transport of string
  | Provider_rejected of { status : int; body : string }
  | Malformed_response of string
  | State_mismatch

let exchange_error_to_string = function
  | Transport detail -> Printf.sprintf "the token request did not complete: %s" detail
  | Provider_rejected { status; body } ->
    Printf.sprintf "the provider refused the exchange (HTTP %d): %s" status body
  | Malformed_response detail ->
    Printf.sprintf "the provider's answer could not be read: %s" detail
  | State_mismatch ->
    "the callback echoed a state this exchange did not send"

type post =
  url:string -> headers:(string * string) list -> body:string ->
  (int * string, string) result

let default_post ~url ~headers ~body =
  Masc_http_client.post_sync ~url ~headers ~body ()

(* RFC 7636 wants 43-128 unreserved characters. Hex from the process crypto
   source is unreserved by construction, so no escaping question arises at
   the point where a mistake would silently weaken the proof. *)
let fresh_verifier () = Random_id.hex ~bytes:32
let fresh_state () = Random_id.hex ~bytes:16

let query pairs =
  pairs
  |> List.map (fun (key, value) ->
       Printf.sprintf "%s=%s" (Uri.pct_encode key) (Uri.pct_encode value))
  |> String.concat "&"

let begin_authorization
      ~(provider : Provider.t)
      ~(discovered : Keeper_oauth_discovery.t)
      ~client_id
      ~scopes
      ~redirect_uri
      ~keeper
  =
  let verifier = fresh_verifier () in
  let state = fresh_state () in
  (* A server that names no scopes gets no scope parameter. "scope=" is not
     an empty list, it is a malformed one, and some servers answer it with
     invalid_scope. *)
  let scope =
    match
      match scopes with
      (* Everything the server said it offers. Narrowing is not this code's
         decision -- but it is the operator's, and an app they brought is
         the authority on what it may be granted, so what they recorded with
         the client wins over what the resource publishes. *)
      | [] -> discovered.Keeper_oauth_discovery.scopes_supported
      | asked -> asked
    with
    | [] -> []
    | scopes -> [ "scope", String.concat " " scopes ]
  in
  let parameters =
    let base =
      [ "response_type", "code"
      ; "client_id", client_id
      ; "redirect_uri", redirect_uri
      ]
      @ scope
      @ [ "state", state
      ; "code_challenge", Auth_oauth.pkce_s256 verifier
      ; "code_challenge_method", "S256"
        (* RFC 8707: name the resource the token is for, so a token minted for
           one MCP server cannot be presented to another. *)
      ; "resource", discovered.Keeper_oauth_discovery.resource
      ; "prompt", "consent"
      ]
    in
    let overrides = provider.Provider.authorize_params in
    let overridden_keys = List.map fst overrides in
    let filtered_base =
      List.filter (fun (k, _) -> not (List.mem k overridden_keys)) base
    in
    filtered_base @ overrides
  in
  { provider_id = provider.Provider.id
  ; keeper
  ; verifier
  ; state
  ; redirect_uri
  ; authorize_url =
      let sep =
        if String.contains discovered.Keeper_oauth_discovery.authorize_url '?'
        then "&"
        else "?"
      in
      Printf.sprintf "%s%s%s"
        discovered.Keeper_oauth_discovery.authorize_url
        sep
        (query parameters)
  }

let form_headers =
  [ "Content-Type", "application/x-www-form-urlencoded"
  ; "Accept", "application/json"
  ]

(* [expires_in] is seconds from now, so the answer is only meaningful next to
   the moment it was read. Storing the instant rather than the duration means
   a later reader does not have to know when the exchange happened. *)
let tokens_of_response ~now body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error detail -> Error (Malformed_response detail)
  | json ->
    let member key =
      match json with
      | `Assoc pairs -> List.assoc_opt key pairs
      | _ -> None
    in
    (match member "access_token" with
     | Some (`String access_token) when String.trim access_token <> "" ->
       let refresh_token =
         match member "refresh_token" with
         | Some (`String value) when String.trim value <> "" -> Some value
         | Some _ | None -> None
       in
       let expires_in =
         match member "expires_in" with
         | Some (`Int seconds) -> Some (float_of_int seconds)
         | Some (`Float seconds) -> Some seconds
         | Some (`String s) -> (try Some (float_of_string s) with _ -> None)
         | Some _ | None -> None
       in
       (* RFC 6749 5.1 makes both optional, and neither absence is a failure
          to read the answer. A token that states no expiry is what Slack
          issues for an app without token rotation; refusing it here read as
          a parsing bug to an operator whose app was simply configured that
          way. What a Keeper can do with what came back is a question for
          whoever stores it, so both absences are carried rather than
          decided here. *)
       Ok
         { access_token
         ; refresh_token
         ; expires_at = Option.map (fun seconds -> now +. seconds) expires_in
         }
     | Some _ | None ->
       Error (Malformed_response "the answer carries no non-empty access_token"))

(* RFC 6749 2.3.1 allows the secret in the form body. Sent only when one
   came back from registration: a server that answered without one refuses a
   redemption that carries an empty client_secret, so an absent secret has to
   be an absent parameter rather than an empty one. *)
let with_client_secret client_secret parameters =
  match client_secret with
  | None -> parameters
  | Some secret -> parameters @ [ "client_secret", secret ]

(* RFC 6749 5.2 puts a refusal in an "error" member and asks for a 4xx to
   carry it. Not every server sends the status: Slack's token endpoint
   answers a rejected code with 200 and {"ok":false,"error":"invalid_code"}.
   Reading the status alone turns that into "the answer cannot be read",
   which sends an operator looking for a parsing bug instead of at the
   reason the server gave them. The member is what says no; the status only
   says so when it does. *)
let refusal body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> None
  | `Assoc pairs ->
    (match List.assoc_opt "error" pairs with
     | Some (`String reason) when String.trim reason <> "" -> Some reason
     | Some _ | None -> None)
  | _ -> None

let exchange ~post ~discovered ~now parameters =
  match
    post ~url:discovered.Keeper_oauth_discovery.token_url ~headers:form_headers
      ~body:(query parameters)
  with
  | Error detail -> Error (Transport detail)
  | Ok (status, body) when status >= 200 && status < 300 ->
    (match refusal body with
     | Some _ -> Error (Provider_rejected { status; body })
     | None -> tokens_of_response ~now body)
  | Ok (status, body) -> Error (Provider_rejected { status; body })

let complete
      ?(post = default_post)
      ?client_secret
      ~(discovered : Keeper_oauth_discovery.t)
      ~client_id
      ~pending
      ~code
      ~state
      ~now
      ()
  =
  (* Checked before anything is sent: a code that arrived under another
     exchange's state is not this Keeper's to redeem. *)
  if not (String.equal state pending.state)
  then Error State_mismatch
  else
    exchange ~post ~discovered ~now
      (with_client_secret client_secret
         [ "grant_type", "authorization_code"
         ; "client_id", client_id
         ; "code", code
         ; "redirect_uri", pending.redirect_uri
         ; "code_verifier", pending.verifier
         ; "resource", discovered.Keeper_oauth_discovery.resource
         ])

let refresh
      ?(post = default_post)
      ?client_secret
      ~(discovered : Keeper_oauth_discovery.t)
      ~client_id
      ~refresh_token
      ~now
      ()
  =
  exchange ~post ~discovered ~now
    (with_client_secret client_secret
       [ "grant_type", "refresh_token"
       ; "client_id", client_id
       ; "refresh_token", refresh_token
       ; "resource", discovered.Keeper_oauth_discovery.resource
       ])

let needs_renewal ~(provider : Provider.t) ~expires_at ~now =
  now +. float_of_int provider.Provider.renew_before_sec >= expires_at
