(** Transport-neutral OAuth request parsing and protocol operations. *)

type authorization_post_outcome =
  | Authorization_redirect of string
  | Authorization_form_error of
      { status : [ `Bad_request | `Unauthorized ]
      ; message : string
      ; request : Auth_oauth.authorization_request
      }

val max_request_body_bytes : int

val parse_form : string -> ((string * string) list, Auth_oauth.error) result
val html_escape : string -> string

val render_authorization_form :
  ?error:string -> Auth_oauth.authorization_request -> string

val authorization_form_headers : (string * string) list

val ensure_optional_string_subset :
  (string * Yojson.Safe.t) list ->
  string ->
  string list ->
  (unit, Auth_oauth.error) result

val oauth_error_description : Auth_oauth.error -> string

val oauth_error_status :
  Auth_oauth.error ->
  [ `Bad_request | `Internal_server_error | `Service_unavailable | `Unauthorized ]

val oauth_error_json : Auth_oauth.error -> Yojson.Safe.t

val authorize_get :
  base_path:string ->
  authority:Server_request_authority.authority ->
  target:string ->
  (Auth_oauth.authorization_request, Auth_oauth.error) result

val authorize_post :
  base_path:string ->
  authority:Server_request_authority.authority ->
  body:string ->
  (authorization_post_outcome, Auth_oauth.error) result

val register_client :
  base_path:string -> string -> (Auth_oauth.client, Auth_oauth.error) result

val registered_client_json : Auth_oauth.client -> Yojson.Safe.t

val token :
  base_path:string ->
  authority:Server_request_authority.authority ->
  body:string ->
  (Auth_oauth.token_pair, Auth_oauth.error) result

val token_pair_json : Auth_oauth.token_pair -> Yojson.Safe.t
