open Keeper_types
open Keeper_exec_shared

(** Issue #10349 Phase 2: registry-canonical meta lookup for masc path
    resolvers.  Same contract as [Keeper_exec_fs.with_registry_meta]. *)
let with_registry_meta ~(keeper_name : string) f =
  match Keeper_registry.find_by_name keeper_name with
  | None ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_path_resolver_identity_mismatch
      ~labels:[ "source_layer", "masc_path_resolver"; "field", "registry_missing" ]
      ();
    error_json
      (Printf.sprintf "keeper not found in registry: %s" keeper_name)
  | Some entry ->
    if not (String.equal entry.meta.name keeper_name) then
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_path_resolver_identity_mismatch
        ~labels:[ "source_layer", "masc_path_resolver"; "field", "name_mismatch" ]
        ();
    f entry.meta
;;

let handle_keeper_autoresearch_tool
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  let ctx : Tool_autoresearch.context =
    { base_path = Keeper_alerting_path.project_root_of_config config
    ; agent_name = Some meta.name
    ; start_operation = None
    ; config = Some config
    ; sw = None
    ; clock = None
    }
  in
  match Tool_autoresearch.dispatch ctx ~name ~args with
  | Some (true, msg) -> msg
  | Some (false, msg) -> error_json msg
  | None -> error_json ~fields:[ "tool", `String name ] "unknown_autoresearch_tool"
;;

(* Read-only masc_code_* tools (search, read, symbols) are path-bearing but
   should NOT go through the strict write resolver. The write resolver
   anchors raw relative paths at project-root and rejects on first miss;
   the read resolver adds [maybe_resolve_missing_relative_read_path] which
   walks the keeper's allowed roots looking for a matching suffix. That
   recovery is what turns a keeper call like
     masc_code_search path=repos/masc-mcp/lib
   into a successful lookup against
     <base>/.masc/playground/<name>/repos/masc-mcp/lib
   — exactly the path the keeper's prompt refers to. Field evidence on
   2026-04-17/18 showed ~240 masc_code_* failures with [path_not_in_
   allowed_paths] that would have resolved under the read walker.
   See memory/handoff-2026-04-18-masc-tool-failure-investigation.md R1. *)
let keeper_masc_path_blocked
      ~(config : Coord.config)
      ~(keeper_name : string)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match Keeper_registry.find_by_name keeper_name with
  | None ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_path_resolver_identity_mismatch
      ~labels:[ "source_layer", "masc_path_resolver"; "field", "registry_missing" ]
      ();
    Some (error_json (Printf.sprintf "keeper not found in registry: %s" keeper_name))
  | Some entry ->
    if not (String.equal entry.meta.name keeper_name) then
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_path_resolver_identity_mismatch
        ~labels:[ "source_layer", "masc_path_resolver"; "field", "name_mismatch" ]
        ();
    let meta = entry.meta in
    let is_read_only = Tool_dispatch.is_read_only name in
    let effective_paths =
      if is_read_only
      then keeper_effective_allowed_paths ~meta
      else keeper_effective_write_allowed_paths ~meta
    in
  if effective_paths = []
  then None
  else (
    let candidates =
      List.filter_map
        (fun key ->
           match Yojson.Safe.Util.member key args with
           | `String p when String.trim p <> "" -> Some p
           | _ -> None)
        [ "path"; "file_path"; "target_path" ]
    in
    let resolve raw =
      if is_read_only
      then resolve_keeper_read_path ~config ~meta ~raw_path:raw
      else
        Keeper_alerting_path.resolve_keeper_target_path
          ~config
          ~allowed_paths:effective_paths
          ~raw_path:raw
    in
    List.find_map
      (fun raw ->
         match resolve raw with
         | Error e -> Some e
         | Ok _ -> None)
      candidates)
;;

let handle_keeper_masc_code_read
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let path = Safe_ops.json_string ~default:"" "path" args in
  let offset = Safe_ops.json_int ~default:0 "offset" args in
  let limit = Safe_ops.json_int ~default:100 "limit" args in
  if path = ""
  then error_json "Path required: 'path' parameter"
  else (
    match resolve_keeper_read_path ~config ~meta ~raw_path:path with
    | Error e -> error_json e
    | Ok target ->
      if not (Sys.file_exists target)
      then error_json (Printf.sprintf "File not found: %s" path)
      else if Tool_code.is_binary_file target
      then error_json "Binary file detected"
      else (
        let file_size = (Unix.stat target).Unix.st_size in
        if file_size > Tool_code.max_file_size
        then
          error_json
            (Printf.sprintf
               "File too large: %d bytes (max: %d)"
               file_size
               Tool_code.max_file_size)
        else (
          try
            let content = In_channel.with_open_text target In_channel.input_all in
            let lines = String.split_on_char '\n' content in
            let total_lines = List.length lines in
            let safe_offset = max 0 (min offset total_lines) in
            let safe_limit = min limit (total_lines - safe_offset) in
            let selected_lines = ref [] in
            for i = safe_offset to safe_offset + safe_limit - 1 do
              match List.nth_opt lines i with
              | Some line -> selected_lines := line :: !selected_lines
              | None -> ()
            done;
            let result_lines = List.rev !selected_lines in
            Yojson.Safe.to_string
              (`Assoc
                  [ "path", `String path
                  ; "offset", `Int safe_offset
                  ; "limit", `Int safe_limit
                  ; "total_lines", `Int total_lines
                  ; "lines", `List (List.map (fun line -> `String line) result_lines)
                  ])
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            error_json
              (Printf.sprintf "Failed to read file: %s" (Printexc.to_string exn)))))
;;

let handle_keeper_masc_tool
      ~(config : Coord.config)
      ~(keeper_name : string)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  with_registry_meta ~keeper_name @@ fun meta ->
  match keeper_masc_path_blocked ~config ~keeper_name ~name ~args with
  | Some err -> error_json err
  | None ->
    (match Tool_dispatch.mint_token ~name with
     | Error reason ->
       Yojson.Safe.to_string
         (`Assoc
             [ "error", `String "unregistered_masc_tool"
             ; "tool", `String name
             ; "reason", `String reason
             ])
     | Ok token ->
       if name = "masc_code_read"
       then handle_keeper_masc_code_read ~config ~meta ~args
       else (
         match Tool_dispatch.dispatch ~token ~args with
         | Some tr ->
           let ok = tr.success in
           let msg = Tool_result.message tr in
           if ok then msg else error_json msg
         | None ->
           if Tool_dispatch.is_mcp_context_required name
           then
             error_json
               (Printf.sprintf
                  "tool '%s' requires MCP session (use keeper_* equivalent)"
                  name)
           else (
             match Tool_dispatch.lookup_tag name with
             | Some tag ->
               let keeper_agent = keeper_agent_sender ~meta in
               (match
                  !Keeper_exec_shared.tag_dispatch_fn
                    ~config
                    ~agent_name:keeper_agent
                    ~tag
                    ~name
                    ~args
                with
                | Some (true, msg) -> msg
                | Some (false, msg) -> error_json msg
                | None ->
                  Yojson.Safe.to_string
                    (`Assoc
                        [ "error", `String "tool_not_supported_in_keeper"
                        ; "tool", `String name
                        ; ( "hint"
                          , `String
                              "tag dispatch returned None; tool may be unsupported, \
                               blocked, or misconfigured" )
                        ]))
             | None ->
               Yojson.Safe.to_string
                 (`Assoc
                     [ "error", `String "unregistered_masc_tool"; "tool", `String name ]))))
;;

let handle_registered_keeper_tool
      ~(config : Coord.config)
      ~(keeper_name : string)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  with_registry_meta ~keeper_name @@ fun meta ->
  match Tool_dispatch.lookup_tag name with
  | Some Tool_dispatch.Mod_autoresearch ->
    Some (handle_keeper_autoresearch_tool ~config ~meta ~name ~args)
  | Some _ ->
    Some (handle_keeper_masc_tool ~config ~keeper_name ~name ~args)
  | None when Tool_dispatch.is_registered name ->
    Some (handle_keeper_masc_tool ~config ~keeper_name ~name ~args)
  | None -> None
;;

(* ── Tool execution dispatch ──────────────────────────────────── *)
