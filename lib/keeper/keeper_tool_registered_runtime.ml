open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

(** Runtime adapter for registered backend tools available to keeper turns.
    Path-bearing tools validate typed path fields in their owning decoder; this
    generic dispatcher never infers resources or access mode from JSON keys.

    One turn tool call performs exactly one [mint_token] and at most one
    [guarded_dispatch]. The previous shape ran both twice on the fallthrough
    path — the entry attempted mint+dispatch, discarded the outcome's
    distinctions into [None], and the fallthrough handler re-derived them by
    running the same effects again, doubling the pre-hook chain, the
    dispatch observers, and the telemetry spans for every tool the guarded
    dispatcher declined (RFC-0371 §3, keeper_tool_registered_runtime:115). *)

let unregistered_failure ?reason ~name () =
  let fields =
    [ "error", `String "unregistered_masc_tool"; "tool", `String name ]
  in
  let fields =
    match reason with
    | None -> fields
    | Some reason -> fields @ [ "reason", `String reason ]
  in
  Keeper_tool_execution.failure
    ~class_:Tool_result.Policy_rejection
    (Yojson.Safe.to_string (`Assoc fields))
;;

(* Fallthrough for a name the guarded dispatcher declined: capability gate,
   then tag dispatch. Performs no dispatch re-attempt of its own. *)
let masc_tool_fallthrough
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
    else (
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
                   ~keeper_name:meta.name
                   ~agent_name:keeper_agent
                   ~tag
                   ~name
                   ~args
               in
               result, Dispatch_outcome.(to_string (of_result_option result)))
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
      | None -> unregistered_failure ~name ())
;;

(* A mint rejection surfaces the reason only for names this runtime still
   owns; the registry-meta lookup stays first so a missing keeper reads as
   the keeper problem it is, matching the previous fallthrough order. *)
let masc_tool_mint_rejected ~(keeper_name : string) ~(name : string) ~reason =
  match find_registry_meta ~keeper_name ~source_layer:"registered_tool_runtime" with
  | None ->
    Keeper_tool_execution.failure
      (error_json (Printf.sprintf "keeper not found in registry: %s" keeper_name))
  | Some _meta -> unregistered_failure ~reason ~name ()
;;

let handle_registered_tool_with_outcome
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  : Keeper_tool_execution.t option =
  let owned_by_this_runtime () =
    Option.is_some (Tool_dispatch.lookup_tag name) || Tool_dispatch.is_registered name
  in
  match Tool_dispatch.mint_token ~name with
  | Error reason ->
    if owned_by_this_runtime ()
    then Some (masc_tool_mint_rejected ~keeper_name ~name ~reason)
    else None
  | Ok token ->
    (* RFC-0084 §1.1 + §2.2 — keeper turn routes through guarded_dispatch so
       pre-hook chain + telemetry 4-tuple emission cover keeper-originated
       calls. Exactly once. *)
    (match Tool_dispatch.guarded_dispatch ~token ~args () with
     | Some tr -> Some (Keeper_tool_execution.of_tool_result tr)
     | None ->
       if owned_by_this_runtime ()
       then Some (masc_tool_fallthrough ~config ~keeper_name ~name ~args)
       else None)
;;

(* ── Tool execution dispatch ──────────────────────────────────── *)
