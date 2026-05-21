(** Per-provider timeout normalization helpers for keeper profile.

    Validates declared [per_provider_timeout] values from TOML / JSON
    sources, surfacing non-finite / non-positive / wrong-type cases as
    [Per_provider_timeout_invalid] (typed failure, not silent default).

    Pure helpers (modulo [Log.Keeper.warn] on validation failure).
    Extracted verbatim from [Keeper_types_profile]. The
    [per_provider_timeout_state] variant + constructors come from
    [Keeper_types_profile_defaults] via [include] — same pattern the
    parent uses at line 145. *)

include Keeper_types_profile_defaults

let normalize_per_provider_timeout_opt ~(source : string)
    (value : float option) : float option =
  match value with
  | Some f when Float.is_finite f && f > 0.0 -> Some f
  | Some f when not (Float.is_finite f) ->
      Log.Keeper.warn
        "%s per_provider_timeout=%s is non-finite; ignoring"
        source (string_of_float f);
      None
  | Some f ->
      Log.Keeper.warn
        "%s per_provider_timeout=%s is non-positive; ignoring"
        source (string_of_float f);
      None
  | None -> None
;;

let per_provider_timeout_of_declared_float_opt ~(source : string)
    ~(declared : bool)
    (value : float option)
    : per_provider_timeout_state * float option =
  if not declared then
    Per_provider_timeout_unset, None
  else
    match value with
    | None ->
        Log.Keeper.warn
          "%s per_provider_timeout has invalid type; ignoring"
          source;
        Per_provider_timeout_invalid, None
    | Some _ ->
        (match normalize_per_provider_timeout_opt ~source value with
         | Some f -> Per_provider_timeout_set, Some f
         | None -> Per_provider_timeout_invalid, None)
;;

let per_provider_timeout_of_toml ~(source : string)
    (doc : Keeper_toml_loader.toml_doc)
    (key : string)
    : per_provider_timeout_state * float option =
  per_provider_timeout_of_declared_float_opt
    ~source
    ~declared:(List.mem_assoc key doc)
    (Keeper_toml_loader.toml_float_opt doc key)
;;

let per_provider_timeout_of_json_field ~(source : string)
    ~(field : string)
    (json : Yojson.Safe.t)
    : per_provider_timeout_state * float option =
  per_provider_timeout_of_declared_float_opt
    ~source
    ~declared:(Option.is_some (Safe_ops.json_member_opt field json))
    (Safe_ops.json_float_opt field json)
;;

let normalize_per_provider_timeout_json_field ~(source : string)
    ~(field : string)
    (json : Yojson.Safe.t)
    : float option =
  per_provider_timeout_of_json_field ~source ~field json |> snd
;;
