open Printf

let github_api_base = "https://api.github.com"

(* GitHub installation tokens expire 1 hour after mint (RFC-0236 §10.2,
   confirmed against the official docs). We track expiry ourselves rather than
   parsing the ISO-8601 [expires_at] in the response — the 1h lifetime is
   guaranteed, so a date-parsing failure mode would add risk without changing
   the cache window. *)
let token_lifetime_seconds = 3600

(* Refresh 5 minutes before the token would actually expire, so a projection
   that lands near the boundary never hands git an already-expired token. *)
let refresh_skew_seconds = 300

(* Use the existing outbound HTTP pool liveness boundary for this small
   control-plane POST. Keeping this tied to the HTTP transport SSOT avoids a
   second GitHub-specific timeout knob. *)
let mint_timeout_sec = Masc_http_client.Pool.default_config.connect_timeout_seconds

type cached = { token : string; expires_at : int }

let cache : (string, cached) Hashtbl.t = Hashtbl.create 8
let cache_mutex = Mutex.create ()

let key ~app_id ~installation_id = app_id ^ ":" ^ installation_id

(* Extract the [token] string from the GitHub [access_tokens] response. The
   response also carries [expires_at], [permissions], [repository_selection];
   only [token] is needed (see {!token_lifetime_seconds} note). *)
let parse_token body =
  try
    (match Yojson.Safe.from_string body with
     | `Assoc fields ->
       (match List.assoc_opt "token" fields with
        | Some (`String tok) when String.length tok > 0 -> Ok tok
        | _ ->
          Error "keeper_github_app_installation_token: response missing \"token\" string field")
     | _ -> Error "keeper_github_app_installation_token: response is not a JSON object")
  with
  | Yojson.Json_error msg ->
    Error (sprintf "keeper_github_app_installation_token: response is not JSON: %s" msg)
;;

let mint ~clock ~timeout_sec ~app_id ~installation_id ~pem ~now () =
  match Keeper_github_app_jwt.sign ~app_id ~pem ~now () with
  | Error _ as e -> e
  | Ok jwt ->
    let url =
      sprintf "%s/app/installations/%s/access_tokens" github_api_base installation_id
    in
    let headers =
      [ ("Authorization", "Bearer " ^ jwt)
      ; ("Accept", "application/vnd.github+json")
      ; ("X-GitHub-Api-Version", "2022-11-28")
      ]
    in
    (* An empty JSON body requests the installation's configured repository
       selection (no per-request restriction). A Content-Type is not required
       for an empty body but GitHub tolerates the default. *)
    (match
       Masc_http_client.post_sync ~clock ~timeout_sec ~url ~headers ~body:"{}" ()
     with
     | Error e -> Error ("keeper_github_app_installation_token: HTTP error: " ^ e)
     | Ok (201, body) ->
       (match parse_token body with
        | Ok _ as ok -> ok
        | Error _ as e -> e)
     | Ok (status, body) ->
       let snippet = String.sub body 0 (min 160 (String.length body)) in
       Error
         (sprintf
            "keeper_github_app_installation_token: GitHub returned %d: %s"
            status
            snippet))
;;

let cached_token_if_valid ~now k =
  Mutex.protect cache_mutex (fun () ->
    match Hashtbl.find_opt cache k with
    | Some c when now < c.expires_at -> Some c.token
    | _ -> None)
;;

let store_freshest_token ~now k token =
  let expires_at = now + token_lifetime_seconds - refresh_skew_seconds in
  Mutex.protect cache_mutex (fun () ->
    match Hashtbl.find_opt cache k with
    | Some c when now < c.expires_at && c.expires_at >= expires_at -> c.token
    | _ ->
      Hashtbl.replace cache k { token; expires_at };
      token)
;;

let get ~clock ~timeout_sec ~app_id ~installation_id ~pem ~now () =
  let k = key ~app_id ~installation_id in
  match cached_token_if_valid ~now k with
  | Some token -> Ok token
  | None ->
    (* The HTTP mint is deliberately outside [cache_mutex]. The mutex protects
       only the cache map, so one stalled installation token request cannot
       block unrelated keeper projections. Concurrent stale misses for the same
       key may co-mint; the freshest cache entry wins on store. *)
    (match mint ~clock ~timeout_sec ~app_id ~installation_id ~pem ~now () with
     | Error _ as e -> e
     | Ok token -> Ok (store_freshest_token ~now k token))
;;
