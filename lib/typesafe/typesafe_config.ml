let default_endpoint = "https://api.typesafe.ai/v1/systemone"
let default_model = "jev-latest"

let api_key () =
  match Sys.getenv_opt "TYPESAFE_API_KEY" with
  | Some k when String.trim k <> "" -> Some (String.trim k)
  | _ -> None
;;

let endpoint () =
  match Sys.getenv_opt "MASC_TYPESAFE_ENDPOINT" with
  | Some ep when String.trim ep <> "" -> String.trim ep
  | _ -> default_endpoint
;;

let model () =
  match Sys.getenv_opt "MASC_TYPESAFE_MODEL" with
  | Some m when String.trim m <> "" -> String.trim m
  | _ -> default_model
;;

let is_enabled () =
  let explicitly_disabled =
    match Sys.getenv_opt "MASC_TYPESAFE_ENABLED" with
    | Some ("0" | "false" | "no" | "off") -> true
    | _ -> false
  in
  if explicitly_disabled
  then false
  else
    match Sys.getenv_opt "MASC_TYPESAFE_ENABLED" with
    | Some ("1" | "true" | "yes" | "on") -> Option.is_some (api_key ())
    | _ ->
      (* If MASC_TYPESAFE_ENABLED is not set, opt-in is active when TYPESAFE_API_KEY is present *)
      Option.is_some (api_key ())
;;
