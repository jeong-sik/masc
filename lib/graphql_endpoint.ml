let trim_trailing_slash s =
  let trimmed = String.trim s in
  let len = String.length trimmed in
  if len > 0 && trimmed.[len - 1] = '/' then
    String.sub trimmed 0 (len - 1)
  else
    trimmed

let starts_with s prefix =
  let s_len = String.length s in
  let prefix_len = String.length prefix in
  s_len >= prefix_len && String.sub s 0 prefix_len = prefix

let ends_with s suffix =
  let s_len = String.length s in
  let suffix_len = String.length suffix in
  s_len >= suffix_len
  && String.sub s (s_len - suffix_len) suffix_len = suffix

let normalize_graphql_url ~default_scheme raw =
  let trimmed = String.trim raw in
  if trimmed = "" then
    ""
  else
    let with_scheme =
      if starts_with trimmed "http://" || starts_with trimmed "https://" then
        trimmed
      else
        default_scheme ^ trimmed
    in
    let without_trailing = trim_trailing_slash with_scheme in
    if ends_with without_trailing "/graphql" then
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

let default_scheme_for_override raw =
  let trimmed = String.trim raw in
  if starts_with trimmed "localhost"
     || starts_with trimmed "127.0.0.1"
     || starts_with trimmed "0.0.0.0"
     || starts_with trimmed "[::1]"
  then
    "http://"
  else
    "https://"

let graphql_url () =
  match Sys.getenv_opt "GRAPHQL_URL" with
  | Some raw ->
      let normalized =
        normalize_graphql_url ~default_scheme:(default_scheme_for_override raw) raw
      in
      if normalized = "" then railway_graphql_url () else normalized
  | _ -> railway_graphql_url ()
