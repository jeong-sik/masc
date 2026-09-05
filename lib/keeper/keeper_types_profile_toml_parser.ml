include Keeper_config
include Keeper_types_profile_sandbox
include Keeper_types_profile_defaults
include Keeper_types_profile_toml_normalizers
include Keeper_types_profile_agent_core_env

type keeper_toml_field_kind =
  | Field_string
  | Field_bool
  | Field_int
  | Field_string_array

(* One list carries both what a keeper TOML key may be called and what it may
   hold. [detect_unknown_keeper_toml_keys] reads the names and
   [validate_known_keeper_field_types] reads the kinds, so a key cannot be
   accepted as known while having no declared type.

   That combination is what makes the loader's conflation reachable: for a key
   nothing type-checks, [Keeper_toml_loader.toml_string_list] returns [[]] and
   [toml_bool_opt] returns [None] for a wrong-typed value exactly as they do
   for an absent one, and the profile keeps a default the file did not ask for
   (#26622). Declaring the kind here is what keeps that unreachable. *)
let keeper_toml_fields =
  [ "name", Field_string
  ; "instructions", Field_string
  ; "autoboot_enabled", Field_bool
  ; "mention_targets", Field_string_array
  ; "proactive_enabled", Field_bool
  ; "sandbox_profile", Field_string
  ; "sandbox_image", Field_string
  ; "network_mode", Field_string
  ; "remote_endpoint", Field_string
  ; "microvm_backend", Field_string
  ; "max_context_override", Field_int
  ; "telemetry_feedback_enabled", Field_bool
  ; "telemetry_feedback_window_hours", Field_int
  ; "always_allow", Field_bool
  ; "voice_always_allow", Field_bool
    (* RFC-0390. The [keeper.tools] key is declared, so any
       other key in that table is unknown and fails the load rather than
       being a silently ignored sibling. A prefix rule would accept
       [tools.nativ] and leave the runtime on its default posture without a
       word, which is what naming them here prevents. *)
  ; "tools.native", Field_string
    (* RFC-0403. Sits in the same [keeper.tools] table as [tools.native] and
       is declared for the same reason: an unlisted sibling fails the load
       rather than being read as no selection at all. *)
  ; "tools.attached_allow", Field_string_array
  ; "skills.names", Field_string_array
  ]

let keeper_toml_field_names = List.map fst keeper_toml_fields

let canonical_keeper_toml_key_names = keeper_toml_field_names

(** One current-key detector shared by profile loading and config audit. *)
let detect_unknown_keeper_toml_keys (doc : Keeper_toml_loader.toml_doc) =
  let known =
    List.map (fun key -> "keeper." ^ key) canonical_keeper_toml_key_names
  in
  let agent_core_env_prefix_len = String.length agent_core_env_key_prefix in
  let starts_with_agent_core_env key =
    String.length key > agent_core_env_prefix_len
    && String.starts_with key ~prefix:agent_core_env_key_prefix
  in
  doc
  |> List.map fst
  |> List.filter (fun key ->
       not (List.mem key known) && not (starts_with_agent_core_env key))
  |> dedupe_keep_order

let toml_value_kind = function
  | Keeper_toml_loader.Toml_string _ -> "string"
  | Keeper_toml_loader.Toml_int _ -> "integer"
  | Keeper_toml_loader.Toml_float _ -> "float"
  | Keeper_toml_loader.Toml_bool _ -> "boolean"
  | Keeper_toml_loader.Toml_string_array _ -> "string array"
  | Keeper_toml_loader.Toml_array _ -> "array"
  | Keeper_toml_loader.Toml_table _ -> "table"
  | Keeper_toml_loader.Toml_inline_table _ -> "inline table"
  | Keeper_toml_loader.Toml_table_array _ -> "table array"
  | Keeper_toml_loader.Toml_offset_datetime _ -> "offset datetime"
  | Keeper_toml_loader.Toml_local_datetime _ -> "local datetime"
  | Keeper_toml_loader.Toml_local_date _ -> "local date"
  | Keeper_toml_loader.Toml_local_time _ -> "local time"
;;

let keeper_toml_field_kind_expectation = function
  | Field_string ->
    "string", (function Keeper_toml_loader.Toml_string _ -> true | _ -> false)
  | Field_bool ->
    "boolean", (function Keeper_toml_loader.Toml_bool _ -> true | _ -> false)
  | Field_int ->
    "integer", (function Keeper_toml_loader.Toml_int _ -> true | _ -> false)
  | Field_string_array ->
    ( "string array"
    , function Keeper_toml_loader.Toml_string_array _ -> true | _ -> false )
;;

let validate_known_keeper_field_types doc =
  let expected key =
    let bare_key = String.sub key 7 (String.length key - 7) in
    Option.map
      keeper_toml_field_kind_expectation
      (List.assoc_opt bare_key keeper_toml_fields)
  in
  doc
  |> List.find_map (fun (key, value) ->
       if String.starts_with key ~prefix:"keeper."
          && not (String.starts_with key ~prefix:agent_core_env_key_prefix)
       then
         match expected key with
         | Some (expected_kind, accepts) when not (accepts value) ->
           Some
             (Printf.sprintf
                "%s must be a TOML %s, got %s"
                key
                expected_kind
                (toml_value_kind value))
         | Some _ | None -> None
       else if String.starts_with key ~prefix:agent_core_env_key_prefix
               && Option.is_none (string_of_toml_value_for_env value)
       then
         Some
           (Printf.sprintf
              "%s must be a scalar TOML value, got %s"
              key
              (toml_value_kind value))
       else None)
  |> function None -> Ok () | Some error -> Error error
;;

let profile_defaults_of_toml (doc : Keeper_toml_loader.toml_doc)
    : (keeper_profile_defaults, string) result =
  let k key = "keeper." ^ key in
  let str key = Keeper_toml_loader.toml_string_opt doc (k key) in
  let bool_ key = Keeper_toml_loader.toml_bool_opt doc (k key) in
  let int_ key = Keeper_toml_loader.toml_int_opt doc (k key) in
  let strs key = Keeper_toml_loader.toml_string_list doc (k key) in
  let has key = List.mem_assoc (k key) doc in
  let agent_core_env = extract_agent_core_env_from_doc doc in
  let result =
    match detect_unknown_keeper_toml_keys doc with
    | [] -> Ok ()
    | fields ->
        Error
          (Printf.sprintf
             "unknown keeper TOML keys: %s"
             (String.concat ", " fields))
  in
  (* Do not use [strs] alone here: it maps an absent array and an explicit []
     to the same value. The profile contract gives those opposite meanings. *)
  let skill_names =
    if has "skills.names"
    then Some (strs "skills.names" |> dedupe_keep_order)
    else None
  in
  (* Same absent-versus-empty rule as [skills.names]: an absent array is
     every attached tool, an explicit [] is none of them. *)
  let attached_tool_allow =
    if has "tools.attached_allow"
    then Some (strs "tools.attached_allow" |> dedupe_keep_order)
    else None
  in
  let result =
    Result.bind result (fun () ->
        validate_known_keeper_field_types doc)
  in
  let result =
    Result.bind result (fun () ->
        match str "sandbox_profile" with
        | Some raw -> (
            match sandbox_profile_of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid sandbox_profile '%s' (allowed: %s)"
                     raw
                     (String.concat ", " valid_sandbox_profile_strings)))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "network_mode" with
        | Some raw -> (
            match network_mode_of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid network_mode '%s' (allowed: %s)"
                     raw
                     (String.concat ", " valid_network_mode_strings)))
        | None -> Ok ())
  in
  (* The profile/mode compatibility rule, read from the type that owns both
     ({!Keeper_types_profile_sandbox.network_mode_rejection}) rather than
     restated here. It was restated here, and this was the only layer that
     ran it: the keeper_up write path never compared the two, so a create
     could produce a keeper TOML that this very function refused on the next
     load. *)
  let result =
    Result.bind result (fun () ->
        match
          ( Option.bind (str "sandbox_profile") sandbox_profile_of_string
          , Option.bind (str "network_mode") network_mode_of_string )
        with
        | Some profile, Some mode -> (
            match network_mode_rejection profile mode with
            | Some message -> Error message
            | None -> Ok ())
        | Some _, None | None, _ -> Ok ())
  in
  (* Phase 1 SSH lane (Task 1 review follow-up): [remote_endpoint] is only
     meaningful for the remote_ssh profile — it names an
     [exec.ssh.endpoints.<name>] registry entry that only the SSH dispatch
     branch consults. Setting it under any other profile (or none) is a
     typo, not an override, so the load rejects it with a named error
     instead of silently carrying a value nothing will read. No legacy TOML
     exists to break: the key itself was introduced by the SSH lane. *)
  let result =
    Result.bind result (fun () ->
        match
          ( Option.bind (str "sandbox_profile") sandbox_profile_of_string
          , str "remote_endpoint" )
        with
        | Some Remote_ssh, _ -> Ok ()
        | _, Some _ ->
            Error
              "remote_endpoint_requires_remote_ssh: keeper.remote_endpoint is \
               only valid with sandbox_profile = \"remote_ssh\""
        | _, None -> Ok ())
  in
  (* [microvm_backend] names which runtime supplies the guest, so it is only
     meaningful under sandbox_profile = "microvm". Set anywhere else it is a
     typo rather than an override, and carrying it silently would leave the
     operator believing a choice was made that nothing reads. An unknown
     spelling is refused by name rather than falling back to a runtime the
     keeper did not ask for -- the point of the key is that the isolation is
     the declared one. *)
  let result =
    Result.bind result (fun () ->
        match
          ( Option.bind (str "sandbox_profile") sandbox_profile_of_string
          , str "microvm_backend" )
        with
        | _, None -> Ok ()
        | Some Micro_vm, Some raw ->
            (match Keeper_microvm_backend.of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "microvm_backend_unknown: keeper.microvm_backend = %S is not \
                      one of: %s"
                     raw
                     (String.concat ", " Keeper_microvm_backend.valid_strings)))
        | _, Some _ ->
            Error
              "microvm_backend_requires_microvm: keeper.microvm_backend is only \
               valid with sandbox_profile = \"microvm\"")
  in
  let result =
    Result.bind result (fun () ->
        match str "tools.native" with
        | Some raw -> (
            match Runtime_native_tools.of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid keeper.tools.native '%s' (allowed: %s)"
                     raw
                     (String.concat
                        ", "
                        Runtime_native_tools.valid_posture_strings)))
        | None -> Ok ())
  in
  let max_context_override_result =
    match int_ "max_context_override" with
    | None -> Ok None
    | Some value ->
      Keeper_config.validate_max_context_override_value value
      |> Result.map Option.some
  in
  Result.bind result (fun () ->
    Result.map
      (fun max_context_override ->
      {
        id = None;
        manifest_path = None;
        instructions = str "instructions";
        autoboot_enabled = bool_ "autoboot_enabled";
        mention_targets = strs "mention_targets";
        proactive_enabled = bool_ "proactive_enabled";
        sandbox_profile =
          Option.bind (str "sandbox_profile") sandbox_profile_of_string;
        sandbox_image = str "sandbox_image";
        network_mode =
          Option.bind (str "network_mode") network_mode_of_string;
        remote_endpoint = str "remote_endpoint";
        microvm_backend =
          Option.bind (str "microvm_backend") Keeper_microvm_backend.of_string;
        max_context_override;
        telemetry_feedback_enabled = bool_ "telemetry_feedback_enabled";
        telemetry_feedback_window_hours = int_ "telemetry_feedback_window_hours";
        always_allow = bool_ "always_allow";
        voice_always_allow = bool_ "voice_always_allow";
        native_tool_posture =
          Option.bind (str "tools.native") Runtime_native_tools.of_string;
        skill_names;
        attached_tool_allow;
        agent_core_env;
      })
      max_context_override_result)

(** Fields actually read by [profile_defaults_of_toml] from the [[keeper]]
    TOML table.  Keep this a subset of [canonical_keeper_toml_key_names] —
    the assertion below fails if a field is parsed into the record without
    being declared known first. *)
let parsed_field_key_names = keeper_toml_field_names

let () =
  assert (
    List.for_all
      (fun key -> List.mem key canonical_keeper_toml_key_names)
      parsed_field_key_names)

let merge_string_list ~base overlay =
  match overlay with [] -> base | xs -> xs

let merge_keeper_profile_defaults
    ~(base : keeper_profile_defaults)
    ~(overlay : keeper_profile_defaults) : keeper_profile_defaults =
  let prefer overlay_value base_value =
    match overlay_value with Some _ -> overlay_value | None -> base_value
  in
  {
    id = prefer overlay.id base.id;
    manifest_path = prefer overlay.manifest_path base.manifest_path;
    instructions = prefer overlay.instructions base.instructions;
    autoboot_enabled = prefer overlay.autoboot_enabled base.autoboot_enabled;
    mention_targets =
      merge_string_list ~base:base.mention_targets overlay.mention_targets;
    proactive_enabled = prefer overlay.proactive_enabled base.proactive_enabled;
    sandbox_profile = prefer overlay.sandbox_profile base.sandbox_profile;
    sandbox_image = prefer overlay.sandbox_image base.sandbox_image;
    network_mode = prefer overlay.network_mode base.network_mode;
    remote_endpoint = prefer overlay.remote_endpoint base.remote_endpoint;
    microvm_backend = prefer overlay.microvm_backend base.microvm_backend;
    max_context_override =
      prefer overlay.max_context_override base.max_context_override;
    telemetry_feedback_enabled =
      prefer overlay.telemetry_feedback_enabled base.telemetry_feedback_enabled;
    telemetry_feedback_window_hours =
      prefer overlay.telemetry_feedback_window_hours
        base.telemetry_feedback_window_hours;
    always_allow = prefer overlay.always_allow base.always_allow;
    voice_always_allow = prefer overlay.voice_always_allow base.voice_always_allow;
    native_tool_posture =
      prefer overlay.native_tool_posture base.native_tool_posture;
    skill_names = prefer overlay.skill_names base.skill_names;
    attached_tool_allow =
      prefer overlay.attached_tool_allow base.attached_tool_allow;
    agent_core_env =
      (let overlay_keys = List.map fst overlay.agent_core_env in
       let surviving_base =
         List.filter (fun (k, _) -> not (List.mem k overlay_keys)) base.agent_core_env
       in
       surviving_base @ overlay.agent_core_env);
  }
