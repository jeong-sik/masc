open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_alerting
module StringMap = Set_util.StringMap
module StringSet = Set_util.StringSet

let has_json_field name fields =
  List.exists (fun (field, _) -> String.equal field name) fields
;;

let error_json ?(fields = []) (message : string) =
  Yojson.Safe.to_string (`Assoc (("error", `String message) :: fields))
;;

let tool_result_error_json (tr : Tool_result.result) =
  let fields =
    match Tool_result.failure_class tr with
    | None -> []
    | Some cls ->
      [ "failure_class", `String (Tool_result.tool_failure_class_to_string cls) ]
  in
  match Tool_result.data tr with
  | `Assoc payload_fields ->
    let payload_fields =
      List.fold_left
        (fun acc (key, value) ->
           if has_json_field key acc then acc else acc @ [ key, value ])
        payload_fields
        fields
    in
    Yojson.Safe.to_string (`Assoc payload_fields)
  | _ ->
    error_json ~fields (Tool_result.message tr)
;;

let file_not_found_prefix = "File not found:"

let missing_file_error_json
      ~(raw_path : string option)
      ~(cwd : string option)
      ~(target : string)
      ~(error : string)
  =
  error_json
    ~fields:
      [ "ok", `Bool false
      ; "path", `String target
      ; "input_file_path", Json_util.string_opt_to_json raw_path
      ; "cwd", Json_util.string_opt_to_json cwd
      ]
    error
;;

let find_registry_meta ~(keeper_name : string) ~(source_layer : string)
  : Keeper_meta_contract.keeper_meta option
  =
  match Keeper_registry_lookup.find_by_name keeper_name with
  | None ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string PathResolverIdentityMismatch)
      ~labels:[ "source_layer", source_layer; "field", "registry_missing" ]
      ();
    None
  | Some entry ->
    if not (String.equal entry.meta.name keeper_name) then
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string PathResolverIdentityMismatch)
        ~labels:[ "source_layer", source_layer; "field", "name_mismatch" ]
        ();
    Some entry.meta
;;

let with_registry_meta ~(keeper_name : string) ~(source_layer : string) f =
  match find_registry_meta ~keeper_name ~source_layer with
  | None ->
    error_json (Printf.sprintf "keeper not found in registry: %s" keeper_name)
  | Some meta -> f meta
;;

let assoc_override_string (key : string) (value : string) = function
  | `Assoc fields ->
    let kept_fields = List.filter (fun (k, _) -> k <> key) fields in
    `Assoc ((key, `String value) :: kept_fields)
  | other -> other
;;

let keeper_effective_allowed_paths ~(meta : keeper_meta) =
  Keeper_alerting_path.effective_allowed_paths ~meta
;;

let keeper_effective_write_allowed_paths ~(meta : keeper_meta) =
  Keeper_alerting_path.effective_write_allowed_paths ~meta
;;

let keeper_playground_root ~(config : Workspace.config) ~(meta : keeper_meta) =
  ignore (Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta);
  Keeper_sandbox.host_root_abs_of_meta ~config meta
;;

let keeper_default_write_root ~(config : Workspace.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
;;

let keeper_default_read_root ~(config : Workspace.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
;;

(* #23469 (task-1733): observation partitions must interpret keeper-relative
   tool paths against the same root the file tools resolve against — the
   keeper's playground sandbox — never the server base path. Unlike
   [keeper_playground_root] this is a pure path computation: the observation
   write path is fire-and-forget and must not run the
   [ensure_sandbox_bundle] directory side effect. Anchored at the normalised
   project root so a [.masc]-suffixed [config.base_path] cannot double up,
   and stripped of the bundle-root trailing slash so downstream structural
   parsers never see an empty path segment. *)
let keeper_observation_sandbox_root
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
  =
  Filename.concat
    (Keeper_alerting_path.project_root_of_config config)
    (Keeper_alerting_path.strip_trailing_slashes
       (Keeper_sandbox.host_root_rel_of_meta ~meta))
;;

let keeper_observation_host_path_of_visible_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      raw_path
  =
  if Filename.is_relative raw_path
     || meta.sandbox_profile <> Keeper_types_profile_sandbox.Docker
  then raw_path
  else (
    let strip = Keeper_alerting_path.strip_trailing_slashes in
    let normalize path = Keeper_alerting_path.normalize_path_for_check_stripped path in
    let container_root = Keeper_sandbox.container_root meta.name |> normalize in
    let raw_norm = normalize raw_path in
    let host_root = keeper_observation_sandbox_root ~config ~meta |> strip in
    if String.equal raw_norm container_root
    then host_root
    else if String.starts_with ~prefix:(container_root ^ "/") raw_norm
    then (
      let suffix =
        String.sub
          raw_norm
          (String.length container_root + 1)
          (String.length raw_norm - String.length container_root - 1)
      in
      Filename.concat host_root suffix)
    else raw_path)
;;

let safe_file_exists path =
  try Fs_compat.file_exists path with
  | Sys_error _ -> false
;;

let safe_is_dir path =
  try Fs_compat.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false
;;

let user_message_error (rej : Keeper_alerting_path.keeper_path_rejection) =
  Keeper_alerting_path.rejection_to_telemetry rej;
  Error (Keeper_alerting_path.rejection_to_user_message rej)
;;

let project_keeper_logical_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      (raw_path : string)
  =
  let raw_path =
    String.trim raw_path
    |> keeper_observation_host_path_of_visible_path ~config ~meta
  in
  if String.equal raw_path "" || not (Filename.is_relative raw_path)
  then raw_path
  else Filename.concat (Keeper_sandbox.host_root_abs_of_meta ~config meta) raw_path
;;

let resolve_projected_keeper_read_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(raw_for_error : string)
      ~(projected_path : string)
  =
  ignore raw_for_error;
  match
    Keeper_alerting_path.resolve_keeper_read_path
      ~config
      ~allowed_paths:(keeper_effective_allowed_paths ~meta)
      ~raw_path:projected_path
  with
  | Ok path -> Ok path
  | Error rejection -> user_message_error rejection
;;

let resolve_keeper_confined_write_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(endpoint : Keeper_alerting_path.confined_path_endpoint)
      ~(raw_path : string)
  =
  let allowed_paths = keeper_effective_write_allowed_paths ~meta in
  let projected_path = project_keeper_logical_path ~config ~meta raw_path in
  match
    Keeper_alerting_path.resolve_keeper_confined_path
      ~config
      ~allowed_paths
      ~endpoint
      ~raw_path:projected_path
  with
  | Ok confined -> Ok confined
  | Error rejection -> user_message_error rejection
;;

let resolve_keeper_path ~config ~meta ~raw_path =
  resolve_keeper_confined_write_path
    ~config
    ~meta
    ~endpoint:Keeper_alerting_path.Follow_referent
    ~raw_path
  |> Result.map Keeper_alerting_path.confined_host_path
;;

let resolve_keeper_read_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
  =
  let allowed_paths = keeper_effective_allowed_paths ~meta in
  let projected_path = project_keeper_logical_path ~config ~meta raw_path in
  match
    Keeper_alerting_path.resolve_keeper_read_path
      ~config
      ~allowed_paths
      ~raw_path:projected_path
  with
  | Error rejection -> user_message_error rejection
  | Ok path -> Ok path
;;

(* cwd is a caller-declared execution location, not keeper-visible path
   vocabulary: reinterpreting it (container-root rewrite, playground join
   for relative input) via [project_keeper_logical_path] hides exactly
   the ambiguous input the [path_outside_sandbox] Gate exists to reject.
   File-path arguments keep the projection — a bare relative path inside
   the sandbox is keeper vocabulary; a cwd must arrive at the Gate raw. *)
let resolve_keeper_read_cwd
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
  =
  let allowed_paths = keeper_effective_allowed_paths ~meta in
  match
    Keeper_alerting_path.resolve_keeper_read_path
      ~config
      ~allowed_paths
      ~raw_path:(String.trim raw_path)
  with
  | Error rejection -> user_message_error rejection
  | Ok path -> Ok path
;;

let resolve_keeper_execute_cwd
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
  =
  let allowed_paths = keeper_effective_write_allowed_paths ~meta in
  match
    Keeper_alerting_path.resolve_keeper_confined_path
      ~config
      ~allowed_paths
      ~endpoint:Keeper_alerting_path.Follow_referent
      ~raw_path:(String.trim raw_path)
  with
  | Ok confined -> Ok (Keeper_alerting_path.confined_host_path confined)
  | Error rejection -> user_message_error rejection
;;

let keeper_agent_sender ~(meta : keeper_meta) = meta.agent_name

let shell_readonly_limit args =
  max 1 (min 200 (Safe_ops.json_int ~default:40 "limit" args))
;;

let shell_readonly_cat_max_bytes args =
  max 256 (min 100000 (Safe_ops.json_int ~default:4000 "max_bytes" args))
;;

let lines_to_json ?(limit = max_int) ?(max_bytes = 32_000) (text : string) : Yojson.Safe.t
  =
  let all_nonempty =
    String.split_on_char '\n' text
    |> List.filter (fun line -> line <> "")
  in
  let total = List.length all_nonempty in
  let truncated_by_limit, limit_overflow =
    if total > limit
    then take limit all_nonempty, total - limit
    else all_nonempty, 0
  in
  (* Byte-budget: accumulate lines until max_bytes is reached.
     This prevents 200 long lines from producing 500KB+ JSON arrays
     that stall the LLM context window. *)
  let rec collect acc bytes_used = function
    | [] -> List.rev acc, 0
    | line :: rest ->
      let line_len =
        String.length line + 4
        (* JSON overhead: quotes, comma *)
      in
      if bytes_used + line_len > max_bytes && acc <> []
      then List.rev acc, List.length rest + 1
      else collect (`String line :: acc) (bytes_used + line_len) rest
  in
  let kept, byte_overflow = collect [] 0 truncated_by_limit in
  let omitted = limit_overflow + byte_overflow in
  if omitted > 0
  then
    `List
      (kept
       @ [ `String
             (Printf.sprintf
                "...[%d more lines omitted — narrow your search pattern or add \
                 --glob/--type filter]"
                omitted)
         ])
  else `List kept
;;

let keeper_text_fallback_json ~(agent_id : string) ~(message : string) =
  let voice = Voice_bridge.get_voice_for_agent agent_id in
  `Assoc
    [ "status", `String "text_fallback"
    ; "agent_id", `String agent_id
    ; "voice", `String voice
    ; "message_preview", `String (short_preview ~max_len:50 message)
    ]
;;

let tag_dispatch_fn
  : (config:Workspace.config
     -> agent_name:string
     -> tag:Tool_dispatch.module_tag
     -> name:string
     -> args:Yojson.Safe.t
     -> Tool_result.result option)
      ref
  =
  ref (fun ~config:_ ~agent_name:_ ~tag:_ ~name:_ ~args:_ -> None)
;;

let descriptor_active_names active_name_set descriptor =
  Keeper_tool_descriptor.keeper_model_names descriptor
  |> List.filter (fun name -> StringSet.mem name active_name_set)
;;

let descriptor_discovery_json active_name_set descriptor =
  `Assoc
    (Keeper_tool_descriptor.discovery_fields descriptor
     @ [ ( "active_names"
         , Json_util.json_string_list
             (descriptor_active_names active_name_set descriptor) )
       ])
;;

let keeper_tools_list_json ~(meta : keeper_meta) =
  let active_name_set =
    Keeper_tool_policy.keeper_model_tool_schemas ()
    |> List.fold_left
         (fun names (schema : Masc_domain.tool_schema) ->
            StringSet.add schema.name names)
         StringSet.empty
  in
  let active_descriptor_names =
    Keeper_tool_descriptor.model_visible_descriptors ()
    |> List.concat_map (fun descriptor ->
      Keeper_tool_descriptor.keeper_model_names descriptor
      |> List.filter_map (fun name ->
        if StringSet.mem name active_name_set then Some (name, descriptor) else None))
  in
  let map =
    List.fold_left
      (fun acc (name, descriptor) ->
         let cat =
           Keeper_tool_descriptor.keeper_tool_group_to_string
             descriptor.Keeper_tool_descriptor.keeper_tool_group
         in
         let list = StringMap.find_opt cat acc |> Option.value ~default:[] in
         StringMap.add cat (name :: list) acc)
      StringMap.empty
      active_descriptor_names
  in
  let assoc =
    StringMap.fold
      (fun cat list acc -> (cat, `List (List.map (fun s -> `String s) list)) :: acc)
      map
      []
  in
  let descriptor_surface =
    active_descriptor_names
    |> List.map snd
    |> List.sort_uniq
         (fun (left : Keeper_tool_descriptor.t)
              (right : Keeper_tool_descriptor.t) ->
            String.compare left.id right.id)
    |> List.map (descriptor_discovery_json active_name_set)
  in
  Yojson.Safe.to_string
    (`Assoc (assoc @ [ "descriptor_surface", `List descriptor_surface ]))
;;
