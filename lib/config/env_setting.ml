(** Env_setting — the declared environment knobs, as closed vocabularies.

    A knob is a constructor. Its wire name, default, operator-facing category
    and description come from one exhaustive [spec] match, and the row list the
    snapshot reports is that spec mapped over [all], so a knob cannot be
    readable by the process and absent from [masc_config].

    The list is static rather than filled by declaration-time side effects.
    A registry populated at module initialization is complete only in a binary
    that links the declaring modules: [Env_config_snapshot] links before them
    (masc_config.cmxa order 683 vs 752), and a test executable that never
    mentions them does not link them at all, so the catalogue would report
    nothing. *)

type row =
  { env_name : string
  ; default_display : string
  ; category : string
  ; description : string
  }

module Bool_knob = struct
  type t = Oauth_enabled [@@deriving enumerate]

  let spec = function
    | Oauth_enabled ->
      ( "MASC_OAUTH_ENABLED"
      , false
      , "auth"
      , "Enable the OAuth authorization server" )
  ;;

  let env_name t = let n, _, _, _ = spec t in n
  let default t = let _, d, _, _ = spec t in d

  let row t =
    let env_name, default, category, description = spec t in
    { env_name; default_display = string_of_bool default; category; description }
  ;;

  let get t = Env_config_core.get_bool ~default:(default t) (env_name t)
end

module Int_knob = struct
  type t =
    | Oauth_code_ttl_sec
    | Oauth_access_token_ttl_sec
    | Oauth_refresh_token_ttl_sec
    | Oauth_max_pending_codes
    | Oauth_max_clients
  [@@deriving enumerate]

  let spec = function
    | Oauth_code_ttl_sec ->
      "MASC_OAUTH_CODE_TTL_SEC", 300, "auth", "Authorization-code lifetime in seconds"
    | Oauth_access_token_ttl_sec ->
      "MASC_OAUTH_ACCESS_TOKEN_TTL_SEC", 3600, "auth", "Access-token lifetime in seconds"
    | Oauth_refresh_token_ttl_sec ->
      ( "MASC_OAUTH_REFRESH_TOKEN_TTL_SEC"
      , 2_592_000
      , "auth"
      , "Refresh-token lifetime in seconds" )
    | Oauth_max_pending_codes ->
      ( "MASC_OAUTH_MAX_PENDING_CODES"
      , 128
      , "auth"
      , "Maximum process-local pending authorization codes" )
    | Oauth_max_clients ->
      ( "MASC_OAUTH_MAX_CLIENTS"
      , 128
      , "auth"
      , "Maximum durable dynamic-client registrations" )
  ;;

  let env_name t = let n, _, _, _ = spec t in n
  let default t = let _, d, _, _ = spec t in d

  let row t =
    let env_name, default, category, description = spec t in
    { env_name; default_display = string_of_int default; category; description }
  ;;

  let get t = Env_config_core.get_int ~default:(default t) (env_name t)
end

let all_rows = List.map Bool_knob.row Bool_knob.all @ List.map Int_knob.row Int_knob.all
let rows_in ~category = List.filter (fun r -> String.equal r.category category) all_rows
