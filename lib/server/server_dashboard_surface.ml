(** Shared additive envelope for dashboard read models. *)

type cache_metadata = {
  state : string;
  key : string option;
  ttl_s : float option;
  stale : bool;
  stale_reason : string option;
  latest_age_s : float option;
  health : string option;
}

type t = {
  schema : string;
  schema_version : int;
  surface : string;
  source : string;
  generated_at_iso : string;
  cache : cache_metadata;
}

let schema = "masc.dashboard_surface.v1"

let json_string_opt = function
  | Some value -> `String value
  | None -> `Null
;;

let json_float_opt = function
  | Some value -> `Float value
  | None -> `Null
;;

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let string_field key json =
  match assoc_field key json with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None
;;

let float_field key json =
  match assoc_field key json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | _ -> None
;;

let projection_diagnostics json =
  match assoc_field "projection_diagnostics" json with
  | Some (`Assoc fields) -> `Assoc fields
  | _ -> `Assoc []
;;

let first_some values =
  List.find_map Fun.id values
;;

let generated_at_iso json =
  let diagnostics = projection_diagnostics json in
  first_some
    [ string_field "generated_at_iso" json
    ; string_field "generated_at" json
    ; string_field "generated_at" diagnostics
    ]
  |> Option.value ~default:(Masc_domain.now_iso ())
;;

let stale_reason json =
  let diagnostics = projection_diagnostics json in
  first_some
    [ string_field "stale_reason" json
    ; string_field "stale_reason" diagnostics
    ]
;;

let cache_state_of_json ~default json =
  match string_field "cache_state" (projection_diagnostics json) with
  | Some value -> value
  | None -> default
;;

let make
      ?cache_key
      ?ttl_s
      ?(cache_state = "request_cache")
      ~surface
      ~source
      json
  =
  let stale_reason = stale_reason json in
  {
    schema;
    schema_version = 1;
    surface;
    source;
    generated_at_iso = generated_at_iso json;
    cache =
      {
        state = cache_state_of_json ~default:cache_state json;
        key = cache_key;
        ttl_s;
        stale = Option.is_some stale_reason;
        stale_reason;
        latest_age_s = float_field "latest_age_s" json;
        health = string_field "health" json;
      };
  }
;;

let to_json envelope =
  `Assoc
    [ "schema", `String envelope.schema
    ; "schema_version", `Int envelope.schema_version
    ; "surface", `String envelope.surface
    ; "source", `String envelope.source
    ; "generated_at_iso", `String envelope.generated_at_iso
    ; ( "cache"
      , `Assoc
          [ "state", `String envelope.cache.state
          ; "key", json_string_opt envelope.cache.key
          ; "ttl_s", json_float_opt envelope.cache.ttl_s
          ; "stale", `Bool envelope.cache.stale
          ; "stale_reason", json_string_opt envelope.cache.stale_reason
          ; "latest_age_s", json_float_opt envelope.cache.latest_age_s
          ; "health", json_string_opt envelope.cache.health
          ] )
    ; ( "migration"
      , `Assoc
          [ "body_shape", `String "root_fields_preserved"
          ; ( "rule"
            , `String
                "New dashboard read models add this envelope before versioning or removing existing root fields."
            )
          ] )
    ]
;;

let attach ?cache_key ?ttl_s ?cache_state ~surface ~source json =
  match json with
  | `Assoc fields ->
    let envelope = make ?cache_key ?ttl_s ?cache_state ~surface ~source json in
    `Assoc
      (("dashboard_surface_envelope", to_json envelope)
       :: List.remove_assoc "dashboard_surface_envelope" fields)
  | other -> other
;;
