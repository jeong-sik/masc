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

(* [t] holds what [raw] parsed to. Its fields are named apart from [raw]'s
   on purpose: while both records described the same two settings under the
   same two names, every field access resolved against whichever type was
   defined last, and read as a type error at some unrelated line -- twice so
   far, at [read_env] and at [resolve]. Distinct names close that off instead
   of asking each new function to annotate its way out. [t] is abstract in
   the interface, so these names stay internal and the accessors below keep
   the public vocabulary. *)
type t =
  { anonymous_mutations_allowed : bool
  ; allowlisted_dev_origins : Server_request_authority.serialized_origin list
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
     | "" -> Ok false
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
  let* anonymous_mutations_allowed =
    parse_boolean
      ~name:allow_anonymous_mutations_env
      raw.allow_anonymous_mutations
  in
  let origin_values =
    match raw.loopback_dev_mutation_origins with
    | Some configured -> split_csv_nonempty configured
    | None -> Masc_network_defaults.vite_dev_default_origins
  in
  let+ allowlisted_dev_origins = parse_origins origin_values in
  { anonymous_mutations_allowed; allowlisted_dev_origins }
;;

let fail_closed =
  { anonymous_mutations_allowed = false; allowlisted_dev_origins = [] }
;;

let allow_anonymous_mutations config = config.anonymous_mutations_allowed
let loopback_dev_mutation_origins config = config.allowlisted_dev_origins

let equal left right =
  Bool.equal left.anonymous_mutations_allowed right.anonymous_mutations_allowed
  && List.equal
       Server_request_authority.serialized_origin_equal
       left.allowlisted_dev_origins
       right.allowlisted_dev_origins
;;

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
