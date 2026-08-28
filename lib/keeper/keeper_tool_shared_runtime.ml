open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_alerting
module StringMap = Set_util.StringMap
module StringSet = Set_util.StringSet

let error_json ?(fields = []) (message : string) =
  Yojson.Safe.to_string (`Assoc (("error", `String message) :: fields))
;;

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
  (* Both path-carrying rejections format their payload straight into the
     message the keeper reads, and the resolver only ever sees the projected
     path. Restate them with [raw_for_error] so the diagnostic names the path
     the model asked for instead of the host-side projection — which is the
     contract this function's .mli already declares. *)
  let in_visible_namespace = function
    | Keeper_alerting_path.Outside_sandbox _ ->
      Keeper_alerting_path.Outside_sandbox { raw = raw_for_error }
    | Keeper_alerting_path.Invalid_normalized_path_projection _ ->
      Keeper_alerting_path.Invalid_normalized_path_projection { path = raw_for_error }
    | ( Keeper_alerting_path.Path_required
      | Keeper_alerting_path.Invalid_lexical_endpoint
      | Keeper_alerting_path.Allowed_paths_normalized_empty _ ) as carries_no_path ->
      carries_no_path
  in
  match
    Keeper_alerting_path.resolve_keeper_read_path
      ~config
      ~allowed_paths:(keeper_effective_allowed_paths ~meta)
      ~raw_path:projected_path
  with
  | Ok path -> Ok path
  | Error rejection -> user_message_error (in_visible_namespace rejection)
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

let resolve_keeper_execute_cwd_typed
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
  | Ok confined -> Ok confined
  | Error rejection -> Error rejection
;;

let verify_keeper_confined_root (confined : Keeper_alerting_path.confined_path) =
  match Fs_compat.get_fs_opt () with
  | None ->
    Error
      "filesystem capability unavailable: Eio filesystem was not installed at runtime startup"
  | Some fs ->
    (try
       let anchor_root = Keeper_alerting_path.confined_anchor_root confined in
       let root_relative_path =
         Keeper_alerting_path.confined_root_relative_path confined
       in
       let verify root_dir =
         Keeper_alerting_path.verify_confined_root_capability confined root_dir
       in
       Eio.Path.with_open_dir Eio.Path.(fs / anchor_root) @@ fun anchor_dir ->
       if String.equal root_relative_path "."
       then verify anchor_dir
       else
         Eio.Path.with_open_dir Eio.Path.(anchor_dir / root_relative_path)
         @@ fun root_dir -> verify root_dir
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Eio.Io _ as exn -> Error (Printexc.to_string exn))
;;

let keeper_agent_sender ~(meta : keeper_meta) = meta.name

let shell_readonly_limit args =
  max 1 (min 200 (Safe_ops.json_int ~default:40 "limit" args))
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
     -> keeper_name:string
     -> agent_name:string
     -> tag:Tool_dispatch.module_tag
     -> name:string
     -> args:Yojson.Safe.t
     -> Tool_result.result option)
      ref
  =
  ref
    (fun
      ~config:_
      ~keeper_name:_
      ~agent_name:_
      ~tag:_
      ~name:_
      ~args:_ ->
      None)
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

let active_descriptor_names ~(meta : keeper_meta) =
  let active_name_set =
    Keeper_tool_policy.keeper_model_tool_schemas_for meta.tool_groups ()
    |> List.fold_left
         (fun names (schema : Masc_domain.tool_schema) ->
            StringSet.add schema.name names)
         StringSet.empty
  in
  let descriptors =
    Keeper_tool_descriptor.model_visible_descriptors ()
    |> List.concat_map (fun descriptor ->
      Keeper_tool_descriptor.keeper_model_names descriptor
      |> List.filter_map (fun name ->
        if StringSet.mem name active_name_set then Some (name, descriptor) else None))
  in
  active_name_set, descriptors
;;

let keeper_tools_list_json ~(meta : keeper_meta) =
  let active_name_set, active_descriptor_names = active_descriptor_names ~meta in
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

let keeper_tools_search_json ~(meta : keeper_meta) ~query =
  let active_name_set, active_descriptors = active_descriptor_names ~meta in
  let documents =
    List.map
      (fun (name, descriptor) ->
         let category =
           Keeper_tool_descriptor.keeper_tool_group_to_string
             descriptor.Keeper_tool_descriptor.keeper_tool_group
         in
         Keeper_capability_search.
           { id = descriptor.id; name; description = descriptor.description; category })
      active_descriptors
  in
  match Keeper_capability_search.search ~query documents with
  | Error _ as error -> error
  | Ok hits ->
       let rec render index rows = function
         | [] ->
           Ok
             (`Assoc
                [ "query", `String query
                ; "match_count", `Int (List.length rows)
                ; "matches", `List (List.rev rows)
                ])
         | (hit : Keeper_capability_search.hit) :: rest ->
           (match
              List.find_map
                (fun (name, descriptor) ->
                   if String.equal name hit.document.name
                      && String.equal descriptor.Keeper_tool_descriptor.id hit.document.id
                   then Some descriptor
                   else None)
                active_descriptors
            with
            | None ->
              Error
                (Keeper_capability_search.Index_unavailable
                   "capability index returned an identity outside its authorized input")
            | Some descriptor ->
              let row =
                `Assoc
                  ([ "rank", `Int index
                   ; "score", `Float hit.rank
                   ; "matched_name", `String hit.document.name
                   ; "category", `String hit.document.category
                   ]
                   @ Keeper_tool_descriptor.discovery_fields descriptor
                   @ [ ( "active_names"
                       , Json_util.json_string_list
                           (descriptor_active_names active_name_set descriptor) ) ])
              in
              render (index + 1) (row :: rows) rest)
       in
       render 1 [] hits
;;
