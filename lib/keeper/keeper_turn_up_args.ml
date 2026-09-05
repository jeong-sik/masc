(** Keeper_turn_up_args -- parse and bundle tool arguments for keeper_up.

    Extracts all argument parsing from handle_keeper_up into a single
    record so that create/update branches receive structured data
    instead of 60+ local bindings. *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type parsed_args = {
  name : string;
  runtime_id_opt : string option;
  autoboot_enabled_opt : bool option;
  mention_targets_opt : string list option;
  max_context_override_opt : int option;
  max_context_override_present : bool;
  proactive_enabled_opt : bool option;
  sandbox_profile_opt : string option;
  remote_endpoint_opt : string option;
  remote_endpoint_present : bool;
  network_mode_opt : string option;
  egress_allow_opt : string list option;
  skill_names_opt : string list option;
  skill_names_present : bool;
  native_tool_posture_opt : Runtime_native_tools.posture option;
  native_tool_posture_present : bool;
  instructions_arg : string option;
  profile_defaults : keeper_profile_defaults;
  declarative_manifest_snapshot : declarative_manifest_snapshot;
  instructions_opt : string option;
}

let parse_tools_patch args =
  match Json_util.assoc_member_opt "tools" args with
  | None -> Ok (false, None)
  | Some (`Assoc fields) ->
      let duplicates =
        fields
        |> List.map fst
        |> List.sort String.compare
        |> List.fold_left
             (fun (previous, duplicates) key ->
                match previous with
                | Some prior when String.equal prior key -> Some key, key :: duplicates
                | _ -> Some key, duplicates)
             (None, [])
        |> snd
        |> List.sort_uniq String.compare
      in
      if duplicates <> []
      then Error ("duplicate tools field(s): " ^ String.concat ", " duplicates)
      else
        let unknown =
          List.filter_map
            (fun (key, _) ->
               if String.equal key "native"
               then None
               else Some key)
            fields
        in
        if unknown <> []
        then Error ("unsupported tools field(s): " ^ String.concat ", " unknown)
        else
          let native =
            match List.assoc_opt "native" fields with
            | None -> Ok (false, None)
            | Some `Null -> Ok (true, None)
            | Some (`String raw) ->
              (match Runtime_native_tools.of_string (String.trim raw) with
               | Some posture -> Ok (true, Some posture)
               | None ->
                 Error
                   (Printf.sprintf
                      "tools.native must be one of %s"
                      (String.concat ", " Runtime_native_tools.valid_posture_strings)))
            | Some other ->
              Error
                (Printf.sprintf
                   "tools.native must be a string or null (received %s)"
                   (Json_util.kind_name other))
          in
          native
  | Some other ->
    Error
      (Printf.sprintf
         "tools must be an object (received %s)"
         (Json_util.kind_name other))
;;

let parse_skills_patch args =
  match Json_util.assoc_member_opt "skills" args with
  | None -> Ok (false, None)
  | Some (`Assoc []) -> Ok (true, None)
  | Some (`Assoc [ ("names", `List values) ]) ->
    let rec collect acc index = function
      | [] -> Ok (true, Some (Json_util.dedupe_keep_order (List.rev acc)))
      | `String value :: rest -> collect (value :: acc) (index + 1) rest
      | bad :: _ ->
        Error
          (Printf.sprintf
             "skills.names[%d] must be a string (received %s)"
             index
             (Json_util.kind_name bad))
    in
    collect [] 0 values
  | Some (`Assoc fields) ->
    Error
      ("unsupported skills field(s): "
       ^ String.concat ", " (List.map fst fields))
  | Some other ->
    Error
      (Printf.sprintf
         "skills must be an object (received %s)"
         (Json_util.kind_name other))
;;

let parse_present_string_list_opt args key =
  match Json_util.assoc_member_opt key args with
  | None -> Ok None
  | Some (`List items) ->
      let rec collect acc index = function
        | [] -> Ok (Some (normalize_name_list (List.rev acc)))
        | `String value :: rest -> collect (value :: acc) (index + 1) rest
        | bad :: _ ->
            Error
              (Printf.sprintf "%s[%d] must be a string (received %s)" key
                 index (Json_util.kind_name bad))
      in
      collect [] 0 items
  | Some `Null -> Error (Printf.sprintf "%s must not be null" key)
  | Some other ->
      Error
        (Printf.sprintf "%s must be an array of strings (received %s)" key
           (Json_util.kind_name other))

let parse_runtime_id_opt args =
  match Json_util.assoc_member_opt "runtime_id" args with
  | None | Some `Null -> Ok None
  | Some (`String raw) ->
      let runtime_id = String.trim raw in
      if runtime_id = ""
      then Error "runtime_id must not be empty"
      else Ok (Some runtime_id)
  | Some other ->
      Error
        (Printf.sprintf
           "runtime_id must be a string (received %s)"
           (Json_util.kind_name other))

let parse_remote_endpoint args =
  match Json_util.assoc_member_opt "remote_endpoint" args with
  | None -> Ok (false, None)
  | Some `Null -> Ok (true, None)
  | Some (`String raw) ->
      let endpoint = String.trim raw in
      if endpoint = ""
      then Error "remote_endpoint must not be blank"
      else Ok (true, Some endpoint)
  | Some other ->
      Error
        (Printf.sprintf
           "remote_endpoint must be a string or null (received %s)"
           (Json_util.kind_name other))

let normalize_max_context_override_value v =
  if v = 0 then Ok None
  else Keeper_config.validate_max_context_override_value v |> Result.map Option.some

let parse_max_context_override args =
  match Json_util.assoc_member_opt "max_context_override" args with
  | None -> Ok (false, None)
  | Some `Null -> Ok (true, None)
  | Some (`Int v) ->
      Result.map (fun value -> (true, value))
        (normalize_max_context_override_value v)
  | Some (`Intlit raw) -> (
      match int_of_string_opt raw with
      | Some v ->
          Result.map (fun value -> (true, value))
            (normalize_max_context_override_value v)
      | None ->
          Error
            (Printf.sprintf
               "max_context_override must be an integer or null (received %s)"
               raw))
  | Some other ->
      Error
        (Printf.sprintf
           "max_context_override must be an integer or null (received %s)"
           (Json_util.kind_name other))

(* The unknown-key contract, derived from the [parse] body below: every
   top-level key the parser consumes, and nothing else. A consumed-but-
   unlisted key would make the gate reject valid traffic; a listed-but-dead
   key would certify exactly the silent drop this gate exists to kill
   (R09: [turn_up_arg_unknown]). Keep exactly in sync with [parse]. *)
(* Carries a value for each field rather than an empty one: a form whose own
   defaults are refused teaches its requirements through a rejection.

   [network_mode] is the exception, and carries the empty string. "none"
   blocks the guest's network and "inherit" opens it; a form that suggests
   either makes that choice for an operator who is not reading it, which is
   how a keeper built to search the web was created unable to. The empty
   string is refused by name, so the form teaches the two spellings through
   the rejection rather than deciding for the reader. *)
let creation_stem =
  {json|{
  "name": "new-keeper",
  "sandbox_profile": "docker",
  "network_mode": "",
  "instructions": "Replace this with what this keeper is for."
}
|json}
;;

let known_turn_up_args =
  [ "name"
  ; "runtime_id"
  ; "autoboot_enabled"
  ; "mention_targets"
  ; "max_context_override"
  ; "proactive_enabled"
  ; "sandbox_profile"
  ; "remote_endpoint"
  ; "network_mode"
  ; "egress_allow"
  ; "tools"
  ; "skills"
  ; "instructions"
  ]

(* Typed rejection naming every unrecognised key, so a caller that sends
   [merge_existing] / [keep_warm] / [stash_untracked] hears about it instead
   of watching the field vanish. *)
let turn_up_arg_unknown keys =
  tool_result_error
    ~class_:Tool_result.Policy_rejection
    (Printf.sprintf
       "[turn_up_arg_unknown] unknown keeper_up argument(s): %s (known arguments: %s)"
       (String.concat ", " (List.sort String.compare keys))
       (String.concat ", " (List.sort String.compare known_turn_up_args)))

(* Top-level envelope gate. Non-object envelopes pass here: the required-name
   check rejects them with the field it cannot find. *)
let validate_no_unknown_keys args =
  match args with
  | `Assoc fields ->
    let unknown =
      List.filter_map
        (fun (key, _) ->
           if List.exists (fun known -> String.equal known key) known_turn_up_args
           then None
           else Some key)
        fields
    in
    if unknown = [] then Ok () else Error (turn_up_arg_unknown unknown)
  | _ -> Ok ()

(* The Docker dispatchability probe [parse] runs for a Docker profile. The
   real one shells out to [docker info] and inspects the image; the test
   suite has no daemon and passes its own. *)
let docker_preflight_default ~timeout_sec =
  Keeper_sandbox_runtime.docker_preflight ~timeout_sec ()
;;

let parse
    ?(docker_preflight = docker_preflight_default)
    (ctx : _ context)
    (args : Yojson.Safe.t) :
    (parsed_args, tool_result) result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    Error (tool_result_error ~class_:Tool_result.Policy_rejection (invalid_name_error name))
  else
    match validate_no_unknown_keys args with
    | Error result -> Error result
    | Ok () ->
    let mention_targets_opt_res = parse_present_string_list_opt args "mention_targets" in
    let runtime_id_opt_res = parse_runtime_id_opt args in
    let tools_patch_res = parse_tools_patch args in
    let skills_patch_res = parse_skills_patch args in
    match
      mention_targets_opt_res,
      runtime_id_opt_res, tools_patch_res, skills_patch_res
    with
    | Error e, _, _, _
    | _, Error e, _, _
    | _, _, Error e, _
    | _, _, _, Error e -> Error (tool_result_error ~class_:Tool_result.Policy_rejection e)
    | Ok mention_targets_opt,
      Ok runtime_id_opt,
      Ok (native_tool_posture_present, native_tool_posture_opt),
      Ok (skill_names_present, skill_names_opt) ->
    let autoboot_enabled_opt = get_bool_opt args "autoboot_enabled" in
    let max_context_override_res = parse_max_context_override args in
    let proactive_enabled_opt = get_bool_opt args "proactive_enabled" in
    let sandbox_profile_opt = Safe_ops.json_string_opt "sandbox_profile" args in
    let remote_endpoint_res = parse_remote_endpoint args in
    let network_mode_opt = Safe_ops.json_string_opt "network_mode" args in
    let egress_allow_opt_res = parse_present_string_list_opt args "egress_allow" in
    let instructions_arg = get_string_opt args "instructions" in
    match
      load_declarative_materialization_defaults
        ~base_path:ctx.config.base_path
        name
    with
    | Error error ->
      Error (tool_result_error ~class_:Tool_result.Policy_rejection (keeper_toml_load_error_to_string error))
    | Ok { profile_defaults; manifest_snapshot = declarative_manifest_snapshot } ->
    (* An explicit profile must be valid, and one of the call, the keeper TOML,
       or the manifest has to state it. There is no fallback: the arm that used
       to take [None, None, None] resolved to [Local], and the only thing
       between that and host execution was a feature flag defaulting to off. *)
    let sandbox_profile_error =
      match sandbox_profile_opt, profile_defaults.sandbox_profile,
        profile_defaults.manifest_path
      with
      | Some raw, _, _ when Option.is_none (sandbox_profile_of_string raw) ->
        Some
          (Printf.sprintf
             "invalid sandbox_profile: %S (expected: %s)"
             raw
             (String.concat ", " Keeper_types_profile.valid_sandbox_profile_strings))
      | Some _, _, _ | None, Some _, _ -> None
      | None, None, None | None, None, Some _ ->
        Some
          (missing_required_sandbox_profile_error
             ~keeper_name:name
             profile_defaults)
    in
    let instructions_opt =
      match instructions_arg with
      | Some _ -> instructions_arg
      | None -> profile_defaults.instructions
    in
    (* Whether the stated profile can dispatch at all. Config shape first
       (an endpoint on a non-SSH profile, a missing one on SSH), then the
       profile's own preflight where one exists. *)
    let sandbox_dispatch_error =
      match sandbox_profile_error, remote_endpoint_res with
      | Some _, _ -> None
      | None, Error error -> Some error
      | None, Ok (remote_endpoint_present, remote_endpoint_opt) ->
        (* [sandbox_profile_error] is [None] only when a profile was stated,
           so this is a [Some] every time control reaches here. Naming the
           other arm rather than defaulting keeps it that way: a later edit
           that admits an unstated profile has to answer this match. *)
        let sandbox_profile =
          match
            Option.bind sandbox_profile_opt sandbox_profile_of_string,
            profile_defaults.sandbox_profile
          with
          | Some profile, _ | None, Some profile -> Some profile
          | None, None -> None
        in
        let endpoint_name =
          if remote_endpoint_present
          then remote_endpoint_opt
          else profile_defaults.remote_endpoint
        in
        (match sandbox_profile, endpoint_name with
         | None, _ -> None
         | Some Remote_ssh, None ->
           Some
             "remote_ssh_endpoint_missing: sandbox_profile=remote_ssh requires remote_endpoint"
         | Some Remote_ssh, Some endpoint_name ->
           (match
              Keeper_sandbox_ssh.resolve_endpoint_name
                ~base_path:ctx.config.base_path ~name:endpoint_name
            with
            | Error error -> Some error
            | Ok endpoint ->
              if not (Env_config_sandbox.Preflight.enabled ())
              then None
              else
                (match
                   Keeper_sandbox_ssh.create ~base_path:ctx.config.base_path
                     ~keeper_name:name ~endpoint ()
                 with
                 | Error error -> Some error
                 | Ok ssh ->
                   (match Keeper_sandbox_remote.check_preflight ~force:true ssh with
                    | Ok () -> None
                    | Error error -> Some error)))
         | Some (Docker | Micro_vm), Some _ ->
           Some
             "remote_endpoint_requires_remote_ssh: clear remote_endpoint or select sandbox_profile=remote_ssh"
         | Some Docker, None ->
           (* Same fail-closed as the [Remote_ssh] arm: a Docker keeper whose
              daemon, image or hardening the preflight cannot see is
              undispatchable, and admitting it only moves the refusal to its
              first Execute. new-keeper, 2026-09-02: admitted from the TUI in
              33 ms with no daemon on the host, two Execute failures on
              docker_container_probe_failed, purged eleven minutes later.
              [None] from the preflight is the master switch being off, which
              keeps the operator's opt-out. *)
           (match
              docker_preflight
                ~timeout_sec:
                  (Env_config_sandbox.Shell_timeout.timeout_sec
                     ~bucket:Env_config_sandbox.Shell_timeout.Io
                     ())
            with
            | None -> None
            | Some preflight ->
              Keeper_sandbox_runtime.docker_preflight_rejection preflight)
         (* No microvm preflight exists yet; the guest is created on the first
            sandboxed call (RFC-0406). *)
         | Some Micro_vm, None -> None)
    in
    match
      sandbox_profile_error, sandbox_dispatch_error, max_context_override_res
    with
    | Some msg, _, _
    | None, Some msg, _ ->
      Error (tool_result_error ~class_:Tool_result.Policy_rejection msg)
    | None, None, Error msg ->
      Error (tool_result_error ~class_:Tool_result.Policy_rejection msg)
    | None, None, Ok (max_context_override_present, max_context_override_opt) ->
    let remote_endpoint_present, remote_endpoint_opt =
      match remote_endpoint_res with
      | Ok value -> value
      | Error _ -> false, None
    in
    match egress_allow_opt_res with
    | Error e -> Error (tool_result_error ~class_:Tool_result.Policy_rejection e)
    | Ok egress_allow_opt ->
    (* An allowlist on a keeper that is not in the policy lane does nothing.
       Storing it anyway is how an operator comes to believe a keeper is
       restricted when it reaches the whole internet, so the pair is refused
       rather than half-applied. The effective mode is checked, not just the
       argument: a keeper already in the lane may add hosts without repeating
       the mode. *)
    let effective_network_mode =
      match network_mode_opt with
      | Some mode -> Some (String.trim mode)
      | None ->
        Option.map
          Keeper_types_profile_sandbox.network_mode_to_string
          profile_defaults.network_mode
    in
    (match egress_allow_opt, effective_network_mode with
     | Some _, Some "policy" | None, _ -> Ok ()
     | Some _, mode ->
       Error
         (tool_result_error
            ~class_:Tool_result.Policy_rejection
            (Printf.sprintf
               "egress_allow needs network_mode = \"policy\"; this keeper's mode \
                is %s. An allowlist outside the policy lane is never consulted, \
                so it is refused rather than stored."
               (match mode with None -> "unset" | Some mode -> "\"" ^ mode ^ "\"")))
     )
    |> Result.map (fun () ->
    {
      name;
      runtime_id_opt;
      autoboot_enabled_opt;
      mention_targets_opt;
      max_context_override_opt;
      max_context_override_present;
      proactive_enabled_opt;
      sandbox_profile_opt;
      remote_endpoint_opt;
      remote_endpoint_present;
      network_mode_opt;
      egress_allow_opt;
      skill_names_opt;
      skill_names_present;
      native_tool_posture_opt;
      native_tool_posture_present;
      instructions_arg;
      profile_defaults;
      declarative_manifest_snapshot;
      instructions_opt;
    })

(** Resolve mention targets with dedup and filtering. *)
let resolve_mention_targets ~mention_targets_opt ~fallback_targets ~name =
  let raw =
    match mention_targets_opt with
    | Some targets -> targets
    | None -> if fallback_targets <> [] then fallback_targets else [ name ]
  in
  raw |> List.filter_map String_util.trim_nonempty |> dedupe_keep_order

(* An explicit request wins over the TOML default. Neither source stating one
   returns [None] rather than [Local]: omission is not a choice of isolation
   boundary. Substituting [Local] here sent every omission through the
   playground gate, which answered "local is disabled" about a profile the
   caller never named. Callers report the missing field instead. *)
let resolve_sandbox_profile ?requested ~fallback () =
  match Option.bind requested sandbox_profile_of_string with
  | Some stated -> Some stated
  | None -> fallback

let resolve_network_mode ~sandbox_profile ~fallback =
  fallback
  |> Option.value ~default:(default_network_mode_for_profile sandbox_profile)


(* Which network mode a keeper lands on, from the caller's raw argument, the
   keeper TOML declaration, and the profile's own default. One function
   because create and update disagreed: update read the caller's value, create
   computed one from [profile_defaults] and dropped the caller's, so the same
   declaration produced a different keeper depending on whether the name
   already existed -- and the create side said nothing about the drop. A
   keeper created for web search landed on "none" and failed inside the guest.

   An unparseable value is an error naming every accepted spelling, rendered
   from [valid_network_mode_strings] rather than a hand-typed pair, so a third
   mode reaches the message without an edit here.

   A parseable value the profile cannot hold is an error too. Honouring the
   caller's mode without that check wrote [remote_ssh] with [network_mode =
   "none"] into a keeper TOML, which booted from the in-memory meta and
   reported success -- and was then refused by
   [Keeper_types_profile_toml_parser] on the next load of that file, leaving a
   hand edit as the only way out. The rule itself belongs to the type that
   owns both fields; this reads it. *)
let resolve_requested_network_mode ~requested ~sandbox_profile ~fallback =
  let accepted mode =
    match Keeper_types_profile.network_mode_rejection sandbox_profile mode with
    | Some message -> Error message
    | None -> Ok mode
  in
  match requested with
  | None -> accepted (resolve_network_mode ~sandbox_profile ~fallback)
  | Some raw ->
    (match network_mode_of_string raw with
     | Some mode -> accepted mode
     | None ->
       Error
         (Printf.sprintf
            "invalid network_mode: %S (expected: %s)"
            raw
            (String.concat ", " Keeper_types_profile.valid_network_mode_strings)))
