let trim_trailing_slash s =
  let trimmed = String.trim s in
  let len = String.length trimmed in
  if len > 0 && trimmed.[len - 1] = '/' then String.sub trimmed 0 (len - 1) else trimmed
;;

let normalize_graphql_url ~default_scheme raw =
  let trimmed = String.trim raw in
  if trimmed = ""
  then ""
  else (
    let with_scheme =
      if
        String.starts_with ~prefix:"http://" trimmed
        || String.starts_with ~prefix:"https://" trimmed
      then trimmed
      else default_scheme ^ trimmed
    in
    let without_trailing = trim_trailing_slash with_scheme in
    if String.ends_with ~suffix:"/graphql" without_trailing
    then without_trailing
    else without_trailing ^ "/graphql")
;;

let default_railway_url = "https://second-brain-graphql-production.up.railway.app/graphql"

let railway_graphql_url () =
  match Sys.getenv_opt "RAILWAY_GRAPHQL_URL" with
  | Some raw ->
    let normalized = normalize_graphql_url ~default_scheme:"https://" raw in
    if normalized = "" then default_railway_url else normalized
  | None -> default_railway_url
;;

let default_scheme_for_override raw =
  let trimmed = String.trim raw in
  if
    String.starts_with ~prefix:"localhost" trimmed
    || String.starts_with ~prefix:"127.0.0.1" trimmed
    || String.starts_with ~prefix:"0.0.0.0" trimmed
    || String.starts_with ~prefix:"[::1]" trimmed
  then "http://"
  else "https://"
;;

let graphql_url () =
  match Sys.getenv_opt "GRAPHQL_URL" with
  | Some raw ->
    let normalized =
      normalize_graphql_url ~default_scheme:(default_scheme_for_override raw) raw
    in
    if normalized = "" then railway_graphql_url () else normalized
  | _ -> railway_graphql_url ()
;;
