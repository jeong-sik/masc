open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

(** Runtime adapter for registered backend tools available to keeper turns. *)
let masc_path_blocked
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match find_registry_meta ~keeper_name ~source_layer:"masc_path_resolver" with
  | None ->
    Some (error_json (Printf.sprintf "keeper not found in registry: %s" keeper_name))
  | Some meta ->
    let is_read_only =
      Keeper_tool_descriptor_resolution.capability_has Tool_capability.Read_only name
    in
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
           match Json_util.assoc_member_opt key args with
           | Some (`String p) when String.trim p <> "" -> Some p
           | _ -> None)
        [ "path"; "file_path"; "target_path" ]
    in
    let resolve raw =
      if is_read_only
      then resolve_keeper_read_path ~config ~meta ~raw_path:raw
      else resolve_keeper_path ~config ~meta ~raw_path:raw
    in
    List.find_map
      (fun raw ->
         match resolve raw with
         | Error e -> Some e
         | Ok _ -> None)
      candidates)
;;

let handle_masc_tool
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  with_registry_meta ~keeper_name ~source_layer:"masc_path_resolver" @@ fun meta ->
  match masc_path_blocked ~config ~keeper_name ~name ~args with
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
       (* RFC-0084 §1.1 + §2.2 — keeper turn now routes through
          guarded_dispatch so pre-hook chain + telemetry 4-tuple
          emission cover keeper-originated calls. *)
       (match Tool_dispatch.guarded_dispatch ~token ~args () with
         | Some tr ->
           let ok = Tool_result.is_success tr in
           let msg = Tool_result.message tr in
           if ok then msg else tool_result_error_json tr
         | None ->
           if
             Keeper_tool_descriptor_resolution.capability_has
               Tool_capability.Mcp_context_required
               name
           then
             error_json
               (Printf.sprintf
                  "tool '%s' requires MCP session (use keeper_* equivalent)"
                  name)
           else (
             match Tool_dispatch.lookup_tag name with
             | Some tag ->
               let keeper_agent = keeper_agent_sender ~meta in
               (* RFC-0084 §1.1 + §2.2 (PR-9) — wrap the tag-dispatch
                  fallback with Tool_telemetry.with_span so the 3rd
                 dispatch entry reaches 4-tuple emission parity with
                 keeper turn (PR-7) and MCP server (PR-8). 4-tuple
                 propagation now 3/3 = 100% per RFC-0084 §2.1 North Star. *)
               let tag_dispatch_with_telemetry () =
                 let result, _outcome =
                   Tool_telemetry.with_span ~force_new_trace_id:true ~surface:"keeper" ~tool_name:name (fun _trace_id_thunk ->
                     let r =
                       !Keeper_tool_shared_runtime.tag_dispatch_fn
                         ~config
                         ~agent_name:keeper_agent
                         ~tag
                         ~name
                         ~args
                     in
                     let outcome =
                       match r with
                       | Some _ -> "handled"
                       | None -> "no_handler"
                     in
                     r, outcome)
                 in
                 result
               in
               (match tag_dispatch_with_telemetry ()
                with
                | Some tr when Tool_result.is_success tr ->
                  Tool_result.message tr
                | Some tr ->
                  tool_result_error_json tr
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

let handle_registered_tool
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  : string option =
  let dispatch_registered_handler () =
    match Tool_dispatch.mint_token ~name with
    | Error reason ->
      Log.Keeper.debug ~keeper_name
        "registered backend dispatch token mint rejected for tool=%s: %s"
        name reason;
      None
    | Ok token ->
      (* RFC-0084 §1.1 + §2.2 — keeper turn now routes through
         guarded_dispatch so pre-hook chain + telemetry 4-tuple emission
         cover keeper-originated calls. *)
      (match Tool_dispatch.guarded_dispatch ~token ~args () with
       | None -> None
       | Some tr ->
         let msg = Tool_result.message tr in
         Some (if Tool_result.is_success tr then msg else tool_result_error_json tr))
  in
  match dispatch_registered_handler () with
  | Some _ as result -> result
  | None ->
    begin
      match Tool_dispatch.lookup_tag name with
      | Some _ ->
        Some (handle_masc_tool ~config ~keeper_name ~name ~args)
      | None when Tool_dispatch.is_registered name ->
        Some (handle_masc_tool ~config ~keeper_name ~name ~args)
      | None -> None
    end
;;

(* ── Tool execution dispatch ──────────────────────────────────── *)
