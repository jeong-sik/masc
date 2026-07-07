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

let mint ~app_id ~installation_id ~pem ~now () =
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
    (match Masc_http_client.post_sync ~url ~headers ~body:"{}" () with
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

let get ~app_id ~installation_id ~pem ~now () =
  let k = key ~app_id ~installation_id in
  (* The whole lookup-or-mint is inside the mutex. Different installations have
     different keys, so two keepers minting concurrently for different
     installations do not contend on [cache_mutex] except for the brief hash
     lookup — the expensive HTTP call happens here only for the installation
     whose cache entry is stale. *)
  Mutex.protect cache_mutex (fun () ->
    match Hashtbl.find_opt cache k with
    | Some c when now < c.expires_at -> Ok c.token
    | _ ->
      (match mint ~app_id ~installation_id ~pem ~now () with
       | Error _ as e -> e
       | Ok token ->
         let expires_at = now + token_lifetime_seconds - refresh_skew_seconds in
         Hashtbl.replace cache k { token; expires_at };
         Ok token))
;;
