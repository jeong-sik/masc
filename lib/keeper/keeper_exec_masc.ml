open Keeper_types
open Keeper_exec_shared

let handle_keeper_autoresearch_tool
      ~(config : Room.config)
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

let keeper_masc_path_blocked
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let effective_paths = keeper_effective_write_allowed_paths ~meta in
  if effective_paths = [] && meta.execution_scope <> "observe_only"
  then None
  else if meta.execution_scope = "observe_only" && effective_paths = []
  then (
    let has_path_arg =
      List.exists
        (fun key ->
           match Yojson.Safe.Util.member key args with
           | `String p when String.trim p <> "" -> true
           | _ -> false)
        [ "path"; "file_path"; "target_path" ]
    in
    if has_path_arg then Some "observe_only_scope: write paths blocked" else None)
  else (
    let candidates =
      List.filter_map
        (fun key ->
           match Yojson.Safe.Util.member key args with
           | `String p when String.trim p <> "" -> Some p
           | _ -> None)
        [ "path"; "file_path"; "target_path" ]
    in
    List.find_map
      (fun raw ->
         match
           Keeper_alerting_path.resolve_keeper_target_path ~config ~allowed_paths:effective_paths ~raw_path:raw
         with
         | Error e -> Some e
         | Ok _ -> None)
      candidates)
;;

let handle_keeper_masc_tool
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match keeper_masc_path_blocked ~config ~meta ~args with
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
       (match Tool_dispatch.dispatch ~token ~args with
        | Some (true, msg) -> msg
        | Some (false, msg) -> error_json msg
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
                 !Keeper_exec_shared.tag_dispatch_fn ~config ~agent_name:keeper_agent ~tag ~name ~args
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

(* ── Tool execution dispatch ──────────────────────────────────── *)
