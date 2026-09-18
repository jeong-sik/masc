let default_endpoint = "https://api.typesafe.ai/v1/systemone"
let default_model = "jev-latest"

let api_key () =
  match Sys.getenv_opt "TYPESAFEAI_API_KEY" with
  | Some k when String.trim k <> "" -> Some (String.trim k)
  | _ ->
    (match Sys.getenv_opt "TYPESAFE_API_KEY" with
     | Some k when String.trim k <> "" -> Some (String.trim k)
     | _ -> None)
;;

let endpoint () =
  match Sys.getenv_opt "MASC_TYPESAFEAI_ENDPOINT" with
  | Some ep when String.trim ep <> "" -> String.trim ep
  | _ ->
    (match Sys.getenv_opt "MASC_TYPESAFE_ENDPOINT" with
     | Some ep when String.trim ep <> "" -> String.trim ep
     | _ -> default_endpoint)
;;

let model () =
  match Sys.getenv_opt "MASC_TYPESAFEAI_MODEL" with
  | Some m when String.trim m <> "" -> String.trim m
  | _ ->
    (match Sys.getenv_opt "MASC_TYPESAFE_MODEL" with
     | Some m when String.trim m <> "" -> String.trim m
     | _ -> default_model)
;;

let is_enabled () =
  let is_explicitly_disabled v =
    match v with
    | Some ("0" | "false" | "no" | "off") -> true
    | _ -> false
  in
  let is_explicitly_enabled v =
    match v with
    | Some ("1" | "true" | "yes" | "on") -> true
    | _ -> false
  in
  let env_val =
    match Sys.getenv_opt "MASC_TYPESAFEAI_ENABLED" with
    | Some _ as v -> v
    | None -> Sys.getenv_opt "MASC_TYPESAFE_ENABLED"
  in
  if is_explicitly_disabled env_val
  then false
  else if is_explicitly_enabled env_val
  then Option.is_some (api_key ())
  else Option.is_some (api_key ())
;;
