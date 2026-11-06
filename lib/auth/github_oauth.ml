(* HIGH-RISK-UNREVIEWED: see the interface. *)

let ( let* ) = Result.bind

(* docs.github.com, "Authorizing OAuth apps" and "Get the authenticated
   user", read 2026-11-06. *)
let authorize_url = "https://github.com/login/oauth/authorize"
let token_url = "https://github.com/login/oauth/access_token"
let user_url = "https://api.github.com/user"
let api_version = "2026-03-10"

(* GitHub rejects a REST request without a User-Agent ("Getting started with
   the REST API"). The shared HTTP client would add its own, but the rule is
   GitHub's, so these requests name one whatever transport carries them. *)
let user_agent = "masc"
let http_ok = 200

let authorization_url client (started : unit Oidc_login_transaction.started) =
  authorize_url
  ^ "?"
  ^ Login_transport.form
      [ "client_id", Login_client.client_id client
      ; "redirect_uri", Login_client.redirect_uri client
      ; "state", started.state
      ; "code_challenge", started.code_challenge
      ; "code_challenge_method", "S256"
      ]
;;

type error =
  | Token_unavailable of string
  | Token_refused of
      { status : int
      ; error : string option
      }
  | User_unavailable of string
  | User_answer_malformed
  | Identity_refused of Authz_external_identity.error

let error_to_string = function
  | Token_unavailable detail -> "the GitHub token request did not complete: " ^ detail
  | Token_refused { status; error = None } ->
    Printf.sprintf "GitHub gave no access token for the code (HTTP %d)" status
  | Token_refused { status; error = Some error } ->
    Printf.sprintf "GitHub refused the code (HTTP %d): %s" status error
  | User_unavailable detail -> "the GitHub user could not be read: " ^ detail
  | User_answer_malformed -> "the GitHub user has no integer id"
  | Identity_refused error -> Authz_external_identity.error_to_string error
;;

let too_long = "the answer is too long"

let json_members body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> None
  | `Assoc members -> Some members
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let string_member name members =
  match List.assoc_opt name members with
  | Some (`String value) -> Some value
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) | None -> None
;;

let access_token ~(post : Login_transport.post) client ~code (taken : unit Oidc_login_transaction.taken) =
  let body =
    Login_transport.form
      (([ "code", code ] @ Login_client.token_request_fields client)
       @ [ "code_verifier", taken.code_verifier ])
  in
  let headers =
    [ "Content-Type", "application/x-www-form-urlencoded"
    ; "Accept", "application/json"
    ; "User-Agent", user_agent
    ]
  in
  match post ~url:token_url ~headers ~body with
  | Error detail -> Error (Token_unavailable detail)
  | Ok { body; _ } when String.length body > Login_transport.max_answer_bytes -> Error (Token_unavailable too_long)
  | Ok { status; body; _ } ->
    let members = json_members body in
    (match Option.bind members (string_member "access_token") with
     | Some token when status = http_ok && not (String.equal token "") -> Ok token
     | Some _ | None -> Error (Token_refused { status; error = Option.bind members (string_member "error") }))
;;

let user_identity ~(get : Login_transport.get) token =
  let headers =
    [ "Authorization", "Bearer " ^ token
    ; "Accept", "application/vnd.github+json"
    ; "X-GitHub-Api-Version", api_version
    ; "User-Agent", user_agent
    ]
  in
  match get ~url:user_url ~headers with
  | Error detail -> Error (User_unavailable detail)
  | Ok { status; _ } when status <> http_ok -> Error (User_unavailable (Printf.sprintf "HTTP %d" status))
  | Ok { body; _ } when String.length body > Login_transport.max_answer_bytes -> Error (User_unavailable too_long)
  | Ok { body; _ } ->
    (match Option.bind (json_members body) (List.assoc_opt "id") with
     | Some (`Int user_id) ->
       Authz_external_identity.github ~user_id |> Result.map_error (fun error -> Identity_refused error)
     | Some (`Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) | None ->
       Error User_answer_malformed)
;;

let identity ~get ~post client ~code taken =
  let* token = access_token ~post client ~code taken in
  user_identity ~get token
;;
