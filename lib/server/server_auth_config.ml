let allow_anonymous_mutations_env = "MASC_ALLOW_ANONYMOUS_MUTATIONS"
let loopback_dev_mutation_origins_env = "MASC_HTTP_DEV_MUTATION_ORIGINS"

type raw =
  { allow_anonymous_mutations : string option
  ; loopback_dev_mutation_origins : string option
  }

type resolve_error =
  | Malformed_boolean of
      { name : string
      ; raw : string
      }
  | Malformed_origin of
      { name : string
      ; raw : string
      }

type t =
  { allow_anonymous_mutations : bool
  ; loopback_dev_mutation_origins : Server_request_authority.serialized_origin list
  }

let read_env () : raw =
  { allow_anonymous_mutations =
      Env_config_core.raw_value_opt allow_anonymous_mutations_env
  ; loopback_dev_mutation_origins =
      Env_config_core.raw_value_opt loopback_dev_mutation_origins_env
  }
;;

let parse_boolean ~name = function
  | None -> Ok false
  | Some raw ->
    (match String.trim raw |> String.lowercase_ascii with
     | "1" | "true" | "yes" | "on" -> Ok true
     | "0" | "false" | "no" | "off" -> Ok false
     | _ -> Error (Malformed_boolean { name; raw }))
;;

let split_csv_nonempty raw =
  raw |> String.split_on_char ',' |> List.filter_map String_util.trim_nonempty
;;

let parse_origins values =
  let rec loop parsed = function
    | [] -> Ok (List.rev parsed)
    | raw :: rest ->
      (match Server_request_authority.parse_serialized_origin raw with
       | Ok origin -> loop (origin :: parsed) rest
       | Error `Malformed ->
         Error (Malformed_origin { name = loopback_dev_mutation_origins_env; raw }))
  in
  loop [] values
;;

let resolve raw =
  let open Result.Syntax in
  let* allow_anonymous_mutations =
    parse_boolean
      ~name:allow_anonymous_mutations_env
      raw.allow_anonymous_mutations
  in
  let origin_values =
    match raw.loopback_dev_mutation_origins with
    | Some configured -> split_csv_nonempty configured
    | None -> Masc_network_defaults.vite_dev_default_origins
  in
  let+ loopback_dev_mutation_origins = parse_origins origin_values in
  { allow_anonymous_mutations; loopback_dev_mutation_origins }
;;

let fail_closed =
  { allow_anonymous_mutations = false; loopback_dev_mutation_origins = [] }
;;

let allow_anonymous_mutations config = config.allow_anonymous_mutations
let loopback_dev_mutation_origins config = config.loopback_dev_mutation_origins

let resolve_error_to_string = function
  | Malformed_boolean { name; raw } ->
    Printf.sprintf
      "malformed env %s=%S (expected true/false boolean)"
      name
      raw
  | Malformed_origin { name; raw } ->
    Printf.sprintf
      "malformed env %s entry %S (expected serialized HTTP(S) origin)"
      name
      raw
;;
