let trim_trailing_slash s =
  let trimmed = String.trim s in
  let len = String.length trimmed in
  if len > 0 && trimmed.[len - 1] = '/' then
    String.sub trimmed 0 (len - 1)
  else
    trimmed

let normalize_graphql_url ~default_scheme raw =
  let trimmed = String.trim raw in
  if trimmed = "" then
    ""
  else
    let with_scheme =
      if String.starts_with ~prefix:"http://" trimmed || String.starts_with ~prefix:"https://" trimmed then
        trimmed
      else
        default_scheme ^ trimmed
    in
    let without_trailing = trim_trailing_slash with_scheme in
    if String.ends_with ~suffix:"/graphql" without_trailing then
      without_trailing
    else
      without_trailing ^ "/graphql"

let default_railway_url =
  "https://second-brain-graphql-production.up.railway.app/graphql"

let railway_graphql_url () =
  match Sys.getenv_opt "RAILWAY_GRAPHQL_URL" with
  | Some raw ->
      let normalized = normalize_graphql_url ~default_scheme:"https://" raw in
      if normalized = "" then default_railway_url else normalized
  | None -> default_railway_url

(* [normalize_graphql_url] builds the URL by concatenation, so the host has to
   be read by the same lexical rule: everything before the first '/', minus a
   trailing port. [Uri.host] cannot stand in here — it reads
   "127.0.0.1.example.com/graphql" as host "127.0.0.1" with the rest as path,
   which would pick the scheme for one host and emit another. *)
let override_host raw =
  let authority =
    let t = String.trim raw in
    match String.index_opt t '/' with
    | Some slash -> String.sub t 0 slash
    | None -> t
  in
  if String.length authority > 0 && authority.[0] = '['
  then
    match String.index_opt authority ']' with
    | Some close -> String.sub authority 1 (close - 1)
    | None -> authority
  else (
    match String.rindex_opt authority ':' with
    | Some colon when String.index_opt authority ':' = Some colon ->
      String.sub authority 0 colon
    | Some _ | None -> authority)

let default_scheme_for_override raw =
  (* This used to match "127.0.0.1" and friends as string prefixes, so
     "127.0.0.1.example.com" read as local while 127.0.0.53 and [::1] did not
     (#27219). The host is parsed as an address now and answered by the same
     predicates the auth boundary uses; anything that is not an address, or an
     address that is not local, keeps https. *)
  let host = override_host raw in
  if Masc_network_defaults.is_loopback_host host
     || Masc_network_defaults.is_unspecified_host host
  then "http://"
  else "https://"

let graphql_url () =
  match Sys.getenv_opt "GRAPHQL_URL" with
  | Some raw ->
      let normalized =
        normalize_graphql_url ~default_scheme:(default_scheme_for_override raw) raw
      in
      if normalized = "" then railway_graphql_url () else normalized
  | _ -> railway_graphql_url ()
