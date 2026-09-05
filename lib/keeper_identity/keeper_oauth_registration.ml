(** See keeper_oauth_registration.mli. *)

type error =
  | Transport of string
  | Refused of { status : int; body : string }
  | Malformed of string

let error_to_string = function
  | Transport detail ->
    Printf.sprintf "the registration request did not complete: %s" detail
  | Refused { status; body } ->
    Printf.sprintf "the server declined to register a client (HTTP %d): %s"
      status body
  | Malformed detail ->
    Printf.sprintf "the registration answer could not be read: %s" detail

type registered = {
  client_id : string;
  client_secret : string option;
  issued_at : float;
}

type post =
  url:string -> headers:(string * string) list -> body:string ->
  (int * string, string) result

let default_post ~url ~headers ~body =
  Masc_http_client.post_sync ~url ~headers ~body ()

let request_body ~client_name ~redirect_uri =
  Yojson.Safe.to_string
    (`Assoc
       [ "client_name", `String client_name
       ; "redirect_uris", `List [ `String redirect_uri ]
       ; "grant_types", `List [ `String "authorization_code"; `String "refresh_token" ]
       ; "response_types", `List [ `String "code" ]
         (* Public client: there is no place on an operator's machine to keep
            a secret that a browser redirect could not also reach, so PKCE is
            the proof instead. *)
       ; "token_endpoint_auth_method", `String "none"
       ])

let register
      ?(post = default_post)
      ~registration_url
      ~client_name
      ~redirect_uri
      ()
  =
  match
    post ~url:registration_url
      ~headers:[ "Content-Type", "application/json"; "Accept", "application/json" ]
      ~body:(request_body ~client_name ~redirect_uri)
  with
  | Error detail -> Error (Transport detail)
  | Ok (status, body) when status < 200 || status >= 300 ->
    Error (Refused { status; body })
  | Ok (_, body) ->
    (match Yojson.Safe.from_string body with
     | exception Yojson.Json_error detail -> Error (Malformed detail)
     | `Assoc pairs ->
       (match List.assoc_opt "client_id" pairs with
        | Some (`String client_id) when String.trim client_id <> "" ->
          let issued_at =
            match List.assoc_opt "client_id_issued_at" pairs with
            | Some (`Int seconds) -> float_of_int seconds
            | Some (`Float seconds) -> seconds
            | Some _ | None -> 0.0
          in
          (* A secret here is the server saying its token endpoint wants
             one. Metadata cannot be trusted for this either way: Vercel and
             Hugging Face both omit "none" from the methods they list and
             both register a public client. *)
          let client_secret =
            match List.assoc_opt "client_secret" pairs with
            | Some (`String value) when String.trim value <> "" -> Some value
            | Some _ | None -> None
          in
          Ok { client_id; client_secret; issued_at }
        | Some _ | None ->
          Error (Malformed "the answer carries no non-empty client_id"))
     | _ -> Error (Malformed "the answer is not an object"))
