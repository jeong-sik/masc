open Keeper_meta_contract
open Keeper_types_profile
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

let assoc_override_string (key : string) (value : string) = function
  | `Assoc fields ->
    let kept_fields = List.filter (fun (k, _) -> k <> key) fields in
    `Assoc ((key, `String value) :: kept_fields)
  | other -> other
;;

let keeper_sandbox_roots ~(meta : keeper_meta) =
  Keeper_alerting_path.sandbox_roots ~meta
;;


let keeper_playground_root ~(config : Workspace.config) ~(meta : keeper_meta) =
  ignore (Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta);
  Keeper_sandbox.host_root_abs_of_meta ~config meta
;;

let keeper_default_write_root ~(config : Workspace.config) ~(meta : keeper_meta) =
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

(* Whose filesystem says whether a cwd exists follows where the tree is
   (RFC-0427 A-1). A shared-mount tree is on this host, so the host answers.
   A tree the endpoint owns (a microvm work volume, a remote_ssh account) is
   not: the host directory of the same name is the bookkeeping bundle, and
   the endpoint answers ENOENT itself when the tool runs there. Asking the
   host refused 38 Execute calls on 2026-09-05, and 101 Read calls in the
   week to 2026-09-24, each for a checkout that existed in the guest. *)
type cwd_existence =
  | Endpoint_decides
  | Host_directory
  | Host_missing
  | Host_file

let cwd_existence ~(meta : keeper_meta) cwd =
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
  | Keeper_types_profile_sandbox.Endpoint_owned -> Endpoint_decides
  | Keeper_types_profile_sandbox.Shared_mount ->
    if safe_is_dir cwd
    then Host_directory
    else if safe_file_exists cwd
    then Host_file
    else Host_missing
;;

let user_message_error (rej : Keeper_alerting_path.keeper_path_rejection) =
  Keeper_alerting_path.rejection_to_telemetry rej;
  Error (Keeper_alerting_path.refusal_of_rejection rej)
;;

(* HIGH-RISK-UNREVIEWED: sandbox path boundary, needs human review.
   The one place a path a Keeper names becomes a host path (#29964). Read,
   Grep, Execute, Edit/Write and keeper_code_query all come through here, so
   the same spelling names the same host location whichever tool receives it:
   - a Docker Keeper's container-visible absolute path maps to its host mount;
   - any other absolute path keeps its identity;
   - a relative path joins [host_cwd] when the tool resolved one, and the
     Keeper's playground root otherwise.
   [None] means the caller named nothing; what that means (a required path, or
   a default cwd) is the tool's to say. The result is not yet confined: every
   caller hands it to a [Keeper_alerting_path] resolver, which owns the
   allowed-root check and its typed rejections. *)
let host_path_of_keeper_visible_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ?host_cwd
      (visible_path : string)
  =
  match String.trim visible_path with
  | "" -> None
  | visible_path ->
    let host_path =
      keeper_observation_host_path_of_visible_path ~config ~meta visible_path
    in
    if Filename.is_relative host_path
    then (
      let base =
        match host_cwd with
        | Some host_cwd -> host_cwd
        | None -> Keeper_sandbox.host_root_abs_of_meta ~config meta
      in
      Some (Filename.concat base host_path))
    else Some host_path
;;

let confine_keeper_visible_path ~config ~meta ?host_cwd ~endpoint ~raw_path () =
  match host_path_of_keeper_visible_path ~config ~meta ?host_cwd raw_path with
  | None -> Error Keeper_alerting_path.Path_required
  | Some host_path ->
    Keeper_alerting_path.resolve_keeper_confined_path
      ~config
      ~sandbox_roots:(keeper_sandbox_roots ~meta)
      ~endpoint
      ~raw_path:host_path
;;

let resolve_keeper_confined_write_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(endpoint : Keeper_alerting_path.confined_path_endpoint)
      ~(raw_path : string)
  =
  match confine_keeper_visible_path ~config ~meta ~endpoint ~raw_path () with
  | Ok confined -> Ok confined
  | Error rejection -> user_message_error rejection
;;

let resolve_keeper_read_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
  =
  match
    confine_keeper_visible_path
      ~config
      ~meta
      ~endpoint:Keeper_alerting_path.Follow_referent
      ~raw_path
      ()
  with
  | Error rejection -> user_message_error rejection
  | Ok confined -> Ok (Keeper_alerting_path.confined_host_path confined)
;;

let resolve_keeper_read_path_in_cwd
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(host_cwd : string)
      ~(raw_path : string)
  =
  (* Both path-carrying rejections format their payload straight into the
     message the keeper reads, and the confinement only ever sees the host
     path. Restate them with [raw_path] so the diagnostic names the path the
     model asked for instead of the host-side projection. *)
  let in_visible_namespace = function
    | Keeper_alerting_path.Outside_sandbox _ ->
      Keeper_alerting_path.Outside_sandbox { raw = raw_path }
    | Keeper_alerting_path.Invalid_normalized_path_projection _ ->
      Keeper_alerting_path.Invalid_normalized_path_projection { path = raw_path }
    | ( Keeper_alerting_path.Path_required
      | Keeper_alerting_path.Invalid_lexical_endpoint
      | Keeper_alerting_path.Sandbox_roots_normalized_empty _ ) as carries_no_path ->
      carries_no_path
  in
  match
    confine_keeper_visible_path
      ~config
      ~meta
      ~host_cwd
      ~endpoint:Keeper_alerting_path.Follow_referent
      ~raw_path
      ()
  with
  | Ok confined -> Ok (Keeper_alerting_path.confined_host_path confined)
  | Error rejection -> user_message_error (in_visible_namespace rejection)
;;

(* Execute resolves its cwd through [host_path_of_keeper_visible_path] and, for
   a remote keeper, its endpoint namespace before this boundary, so what
   arrives here is a concrete host coordinate to confine. *)
let resolve_keeper_execute_cwd_typed
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
  =
  let sandbox_roots = keeper_sandbox_roots ~meta in
  match
    Keeper_alerting_path.resolve_keeper_confined_path
      ~config
      ~sandbox_roots
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

let search_result_max_bytes = 32_000

(* Longest one returned line may be before it is cut. The byte budget below
   keeps the first line whatever its size, so a file stored as one line (a
   minified JSON dump) came back whole. From 2026-11-06T09:52Z to
   11-07T09:52Z, 67 Grep calls each carried one 285 KB matched line: 21.3 MB,
   13.0% of the day's tool result bytes, and every result was above the
   65,536-byte inline ceiling of every lane, so the Keeper held a blob marker.
   The other 4,980 matched lines in that window: 4,967 were at most 2,000
   bytes. See docs/evidence/grep-long-lines-2026-11. *)
let default_max_line_bytes = 2_000

let cut_to_bytes ~max_bytes text =
  let length = String.length text in
  if length <= max_bytes
  then text
  else (
    let kept = String_util.utf8_prefix ~max_bytes text in
    Printf.sprintf "%s...[cut: %d of %d bytes kept]" kept (String.length kept) length)
;;

let lines_to_json
      ?(limit = max_int)
      ?(max_bytes = search_result_max_bytes)
      ?(max_line_bytes = default_max_line_bytes)
      (text : string)
  : Yojson.Safe.t
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
  (* A line longer than the whole budget would still pass as the first one,
     so each line is cut to at most the budget before it is counted. *)
  let max_line_bytes = min max_line_bytes max_bytes in
  let truncated_by_limit =
    List.map (cut_to_bytes ~max_bytes:max_line_bytes) truncated_by_limit
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

let active_descriptor_names_for_descriptors descriptors =
  let active_name_set =
    descriptors
    |> List.concat_map Keeper_tool_descriptor.keeper_model_names
    |> List.fold_left (fun names name -> StringSet.add name names) StringSet.empty
  in
  let descriptor_names =
    descriptors
    |> List.concat_map (fun descriptor ->
      Keeper_tool_descriptor.keeper_model_names descriptor
      |> List.map (fun name -> name, descriptor))
  in
  active_name_set, descriptor_names
;;

let active_descriptor_names ~(meta : keeper_meta) =
  let descriptors = Keeper_tool_descriptor.model_visible_descriptors () in
  active_descriptor_names_for_descriptors descriptors
;;

let keeper_tools_list_json ~(meta : keeper_meta) =
  let active_name_set, active_descriptor_names = active_descriptor_names ~meta in
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
    (`Assoc
       [ "descriptor_surface", `List descriptor_surface
       ; "search_scope", `String "active_tools_only"
       ])
;;

(* The full rows of a 203 Tool and 52 Skill surface were 292,804 bytes, above
   every lane's inline ceiling (16,384 to 65,536), so all 53 calls between
   2026-11-06T09:52Z and 11-07T09:52Z reached the model as a blob marker and a
   200 character preview. The inventory lists names and availability, 9,888
   bytes for the same surface. *)
let keeper_tools_list_json_for_surface ~capability_surface =
  Yojson.Safe.to_string (Keeper_capability_surface.inventory_to_yojson capability_surface)
;;

let keeper_capability_search_json_for_surface ~capability_surface ~query =
  let text,syntax = match query with
    | Keeper_capability_search.Literal text -> text,"literal"
    | Keeper_capability_search.Fts5 text -> text,"fts5" in
  let documents =
    Keeper_capability_surface.candidates capability_surface
    |> List.map (fun candidate ->
         Keeper_capability_search.
           { payload = candidate
           ; name = Keeper_capability_surface.candidate_name candidate
           ; description =
               Keeper_capability_surface.candidate_description candidate
           ; invocation_name =
               Keeper_capability_surface.candidate_invocation_name candidate
           })
  in
  match Keeper_capability_search.search ~query documents with
  | Error _ as error -> error
  | Ok hits ->
    let matches =
      hits
      |> List.map (fun hit ->
        `Assoc
          [ "bm25", `Float hit.Keeper_capability_search.bm25
          ; "matched_name", `String hit.document.name
          ; ( "invocation_name"
            , Option.fold
                ~none:`Null
                ~some:(fun name -> `String name)
                hit.document.invocation_name )
          ; ( "candidate"
            , Keeper_capability_surface.candidate_to_yojson
                hit.document.payload )
          ])
    in
    Ok
      (`Assoc
         [ "schema", `String "masc.keeper.capability_search.v1"
         ; "query", `String text
         ; "syntax", `String syntax
         ; "search_scope", `String "frozen_capability_surface"
         ; "surface_digest", `String (Keeper_capability_surface.digest capability_surface)
         ; "match_count", `Int (List.length matches)
         ; "matches", `List matches
         ])
;;
