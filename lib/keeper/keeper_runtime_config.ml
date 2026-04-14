(** Keeper_runtime_config — load runtime tuning from
    [<base_path>/.masc/config/keeper_runtime.toml].  See [.mli] for design. *)

(* TOML key → env var name. Each entry maps a structured TOML path to the
   single env var that [Env_config_keeper] / [Keeper_keepalive] already
   read at module init. Adding a new tunable means adding a row here AND
   documenting it in the TOML schema in the .mli.

   Keep this list tight: only knobs the user genuinely needs to change
   per workspace. CI/test-only overrides should remain pure env vars. *)
let key_to_env =
  [
    "autonomous.max_turns_per_call",
      "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS";
    "autonomous.semaphore_wait_timeout_sec",
      "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC";
    "reactive.max_turns_per_call",
      "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL";
  ]

let toml_path ~base_path =
  Filename.concat base_path ".masc/config/keeper_runtime.toml"

let read_file path =
  try Ok (In_channel.with_open_text path In_channel.input_all)
  with Sys_error msg -> Error msg

(** Format a TOML scalar back to a string suitable for putenv.
    Booleans → "true"/"false"; floats keep their TOML representation;
    strings pass through as-is. String arrays are not supported — they
    have no env var equivalent in the keeper config. *)
let value_to_string = function
  | Keeper_toml_loader.Toml_string s -> Some s
  | Keeper_toml_loader.Toml_int i -> Some (string_of_int i)
  | Keeper_toml_loader.Toml_float f ->
    (* Match TOML representation (no trailing zeros). *)
    Some (Printf.sprintf "%g" f)
  | Keeper_toml_loader.Toml_bool b -> Some (if b then "true" else "false")
  | Keeper_toml_loader.Toml_string_array _ -> None

(** Apply one TOML key to the corresponding env var, unless the env var
    is already set (caller override wins).  Returns [true] iff a putenv
    actually happened.

    [~env_lookup] and [~env_set] are injectable for testing: production
    uses [Sys.getenv_opt] / [Unix.putenv]; tests supply a fake env to
    avoid global process env pollution. *)
let apply_one
    ?(env_lookup = Sys.getenv_opt)
    ?(env_set = Unix.putenv)
    (doc : Keeper_toml_loader.toml_doc) (toml_key, env_name) =
  match env_lookup env_name with
  | Some _ ->
    (* Caller env override — leave alone. *)
    false
  | None ->
    match List.assoc_opt toml_key doc with
    | None -> false
    | Some v ->
      match value_to_string v with
      | None -> false
      | Some s ->
        env_set env_name s;
        true

(** Pure version of the load+apply pipeline. Parses TOML and returns
    the number of overrides that would be applied, plus a list of
    (env_name, value) pairs. Exposed for testing without env side effects. *)
let resolve_overrides
    ?(env_lookup = Sys.getenv_opt)
    (doc : Keeper_toml_loader.toml_doc) =
  let applied = ref [] in
  let count =
    List.fold_left
      (fun acc (toml_key, env_name) ->
        match env_lookup env_name with
        | Some _ -> acc
        | None ->
          match List.assoc_opt toml_key doc with
          | None -> acc
          | Some v ->
            match value_to_string v with
            | None -> acc
            | Some s ->
              applied := (env_name, s) :: !applied;
              acc + 1)
      0
      key_to_env
  in
  (count, List.rev !applied)

let load_and_apply ~base_path =
  let path = toml_path ~base_path in
  if not (Sys.file_exists path) then
    Ok 0
  else
    match read_file path with
    | Error msg -> Error (Printf.sprintf "read %s: %s" path msg)
    | Ok content ->
      match Keeper_toml_loader.parse_toml content with
      | Error msg -> Error (Printf.sprintf "parse %s: %s" path msg)
      | Ok doc ->
        let count =
          List.fold_left
            (fun acc kv -> if apply_one doc kv then acc + 1 else acc)
            0
            key_to_env
        in
        Ok count
