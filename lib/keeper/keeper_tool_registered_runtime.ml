open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

(** Runtime adapter for registered backend tools available to keeper turns.
    Path-bearing tools validate typed path fields in their owning decoder; this
    generic dispatcher never infers resources or access mode from JSON keys. *)
let handle_masc_tool_with_outcome
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match find_registry_meta ~keeper_name ~source_layer:"registered_tool_runtime" with
  | None ->
    Keeper_tool_execution.failure
      (error_json (Printf.sprintf "keeper not found in registry: %s" keeper_name))
  | Some meta ->
    match Tool_dispatch.mint_token ~name with
    | Error reason ->
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (Yojson.Safe.to_string
           (`Assoc
               [ "error", `String "unregistered_masc_tool"
               ; "tool", `String name
               ; "reason", `String reason
               ]))
    | Ok token ->
      (* RFC-0084 §1.1 + §2.2 — keeper turn now routes through
         guarded_dispatch so pre-hook chain + telemetry 4-tuple
         emission cover keeper-originated calls. *)
      match Tool_dispatch.guarded_dispatch ~token ~args () with
      | Some tr -> Keeper_tool_execution.of_tool_result tr
      | None ->
        if
          Keeper_tool_descriptor_resolution.capability_has
            Tool_capability.Mcp_context_required
            name
        then
          Keeper_tool_execution.failure
            ~class_:Tool_result.Policy_rejection
            (error_json
               (Printf.sprintf
                  "tool '%s' requires MCP session (use keeper_* equivalent)"
                  name))
        else
          match Tool_dispatch.lookup_tag name with
          | Some tag ->
            let keeper_agent = keeper_agent_sender ~meta in
            let result, _outcome =
              Tool_telemetry.with_span
                ~force_new_trace_id:true
                ~surface:"keeper"
                ~tool_name:name
                (fun _trace_id_thunk ->
                   let result =
                     !Keeper_tool_shared_runtime.tag_dispatch_fn
                       ~config
                       ~agent_name:keeper_agent
                       ~tag
                       ~name
                       ~args
                   in
                   let outcome =
                     match result with
                     | Some _ -> "handled"
                     | None -> "no_handler"
                   in
                   result, outcome)
            in
            (match result with
             | Some tr -> Keeper_tool_execution.of_tool_result tr
             | None ->
               Keeper_tool_execution.failure
                 (Yojson.Safe.to_string
                    (`Assoc
                        [ "error", `String "tool_not_supported_in_keeper"
                        ; "tool", `String name
                        ; ( "hint"
                          , `String
                              "tag dispatch returned None; tool may be unsupported, \
                               blocked, or misconfigured" )
                        ])))
          | None ->
            Keeper_tool_execution.failure
              ~class_:Tool_result.Policy_rejection
              (Yojson.Safe.to_string
                 (`Assoc
                     [ "error", `String "unregistered_masc_tool"
                     ; "tool", `String name
                     ]))
;;

let handle_registered_tool_with_outcome
      ~(config : Workspace.config)
      ~(keeper_name : string)
  ~(name : string)
      ~(args : Yojson.Safe.t)
  : Keeper_tool_execution.t option =
  let dispatch_registered_handler () =
    match Tool_dispatch.mint_token ~name with
    | Error _ -> None
    | Ok token ->
      (* RFC-0084 §1.1 + §2.2 — keeper turn now routes through
         guarded_dispatch so pre-hook chain + telemetry 4-tuple emission
         cover keeper-originated calls. *)
      (match Tool_dispatch.guarded_dispatch ~token ~args () with
       | None -> None
       | Some tr -> Some (Keeper_tool_execution.of_tool_result tr))
  in
  match dispatch_registered_handler () with
  | Some _ as result -> result
  | None ->
    begin
      match Tool_dispatch.lookup_tag name with
      | Some _ ->
        Some (handle_masc_tool_with_outcome ~config ~keeper_name ~name ~args)
      | None when Tool_dispatch.is_registered name ->
        Some (handle_masc_tool_with_outcome ~config ~keeper_name ~name ~args)
      | None -> None
    end
;;

(* ── Tool execution dispatch ──────────────────────────────────── *)
