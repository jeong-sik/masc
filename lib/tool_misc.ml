module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_misc — Miscellaneous operations (facade).

    Dispatches config introspection and tool inventory helpers to
    [Tool_misc_introspection].

    Retains: dashboard, verify_handoff, gc, cleanup_zombies,
    tool_stats, tool_help.

    @since 2.187.0 — Decomposed from monolithic tool_misc.ml *)

open Tool_args

type tool_result = Tool_result.result

type context = {
  config: Workspace.config;
  agent_name: string;
}


(* ================================================================ *)
(* Handlers (retained in facade)                                    *)
(* ================================================================ *)

(* RFC-0189 PR-1b.10 — facade handlers return typed [Tool_result.result].

   [text_ok] mirrors the corrected helper from [tool_library] /
   [tool_misc_web_fetch] (PR-1b.7 / #18767 fix): JSON-string bodies
   parse through [structured_payload_of_message]; plain text falls through as
   [`String body]. Defined locally — extracting a shared helper
   module is a separate refactor (PR-2 territory).

   Failure-class mapping (caller-input violations only in this cluster):
   - [Workflow_rejection] : invalid dashboard scope; missing
                            tool_name; unknown tool.
   - No [Runtime_failure] / [Transient_error] sites here — the
     [Workspace.gc] / [Workspace.cleanup_zombies] / [Dashboard.generate]
     backends assume-success or raise. When a backend later returns
     a typed Error variant, the construction site here gets the
     appropriate class at that time. *)

let text_ok ~tool_name ~start_time body : Tool_result.result =
  let data =
    match Tool_result.structured_payload_of_message body with
    | Some json -> json
    | None -> `String body
  in
  Tool_result.make_ok ~tool_name ~start_time ~data ()

let workflow_err ~tool_name ~start_time msg : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    msg

let expect_no_args ~tool_name ~start_time args =
  match args with
  | `Assoc [] -> Ok ()
  | `Assoc fields ->
      let names = fields |> List.map fst |> String.concat ", " in
      Error
        (workflow_err
           ~tool_name
           ~start_time
           (Printf.sprintf "%s does not accept arguments: %s" tool_name names))
  | _ ->
      Error
        (workflow_err
           ~tool_name
           ~start_time
           (Printf.sprintf "%s arguments must be an object" tool_name))

let dashboard_handler =
  ref (fun ~tool_name ~start_time:_ _ctx _args ->
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time:0.0
      "Dashboard handler not registered"
  )

let register_dashboard_handler f =
  dashboard_handler := f

let handle_dashboard ~tool_name ~start_time ctx args =
  !dashboard_handler ~tool_name ~start_time ctx args

let handle_gc ~tool_name ~start_time ctx args : Tool_result.result =
  let days_raw = get_int args "days" 7 in
  let days = max 1 days_raw in
  if days_raw < 1 then
    Log.Misc.warn "masc_gc days=%d clamped to 1 (minimum guardrail)" days_raw;
  let gc_result = Workspace.gc ctx.config ~days () in
  let expired = 0 in
  let decision_note =
    if expired > 0 then Printf.sprintf "\nExpired %d pending decision(s) past TTL" expired
    else ""
  in
  text_ok ~tool_name ~start_time (gc_result ^ decision_note)

let handle_cleanup_zombies ~tool_name ~start_time ctx _args : Tool_result.result =
  let result = Workspace.cleanup_zombies ctx.config in
  let msg =
    match result with
    | Workspace.No_agents_dir -> "No agents directory"
    | Workspace.No_zombies -> "No zombie agents found"
    | Workspace.Cleaned { count; names; released_tasks; skipped } ->
        let task_note =
          if released_tasks = 0 then ""
          else Printf.sprintf ", released %d orphan task(s)" released_tasks
        in
        if skipped > 0 then
          Printf.sprintf
            "Cleaned %d/%d zombie(s): %s%s (%d skipped due to errors)"
            count
            (count + skipped)
            (String.concat ", " names)
            task_note
            skipped
        else
          Printf.sprintf "Cleaned up %d zombie agent(s): %s%s"
            count (String.concat ", " names) task_note
  in
  text_ok ~tool_name ~start_time msg

let handle_tool_stats ~tool_name ~start_time _ctx args : Tool_result.result =
  let top_n = max 1 (min 100 (get_int args "top_n" 20)) in
  let all_tool_names =
    List.map (fun (s : Masc_domain.tool_schema) -> s.name)
      Config.all_tool_schemas
  in
  let report = Tool_registry.stats_report ~top_n ~all_tool_names in
  text_ok ~tool_name ~start_time (Yojson.Safe.to_string report)

let handle_keeper_waiting_inventory ~tool_name ~start_time ctx args : Tool_result.result =
  match expect_no_args ~tool_name ~start_time args with
  | Error result -> result
  | Ok () ->
      Tool_result.make_ok
        ~tool_name
        ~start_time
        ~data:(Server_keeper_waiting_inventory.tool_json ctx.config)
        ()

let strip_mcp_prefix name =
  let prefix = "mcp__masc__" in
  let plen = String.length prefix in
  if String.length name > plen && String.equal (Stdlib.String.sub name 0 plen) prefix
  then String.sub name plen (String.length name - plen)
  else name

let handle_tool_help ~tool_name ~start_time _ctx args : Tool_result.result =
  let raw_name = String.trim (get_string args "tool_name" "") in
  if String.equal raw_name "" then
    workflow_err ~tool_name ~start_time "tool_name is required"
  else
    let tool_name = strip_mcp_prefix raw_name in
    match Tool_help_registry.find_entry Config.raw_all_tool_schemas tool_name with
    | None ->
        workflow_err ~tool_name ~start_time
          (Printf.sprintf "unknown tool: %s" raw_name)
    | Some entry ->
        text_ok ~tool_name ~start_time
          (Yojson.Safe.to_string (Tool_help_registry.entry_json entry))

(* PR-1b.8 / PR-1b.9 web_* handlers are already typed at the source.
   With dispatch lifting internally now, these wrappers can pass
   the typed result straight through. *)
let handle_web_search ~tool_name ~start_time _ctx args : Tool_result.result =
  let result = Tool_misc_web_search.handle ~tool_name ~start_time args in
  Tool_misc_web_enrichment.enrich_result_if_requested
    ~tool_name
    ~start_time
    args
    result

let handle_web_fetch ~tool_name ~start_time _ctx args : Tool_result.result =
  Tool_misc_web_fetch.handle ~tool_name ~start_time args

(* ================================================================ *)
(* Public re-exports from sub-modules                               *)
(* ================================================================ *)

let tool_inventory_json ctx ~include_hidden =
  Tool_misc_introspection.tool_inventory_json ctx ~include_hidden

(* ================================================================ *)
(* Dispatch (facade)                                                *)
(* ================================================================ *)

let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Time_compat.now () in
  match name with
  | "masc_config" ->
      Some (Tool_misc_introspection.handle_config ~tool_name:name ~start_time:start args)
  | "masc_dashboard" ->
      Some (handle_dashboard ~tool_name:name ~start_time:start ctx args)
  | "masc_keeper_waiting_inventory" ->
      Some (handle_keeper_waiting_inventory ~tool_name:name ~start_time:start ctx args)
  | "masc_gc" -> Some (handle_gc ~tool_name:name ~start_time:start ctx args)
  | "masc_cleanup_zombies" ->
      Some (handle_cleanup_zombies ~tool_name:name ~start_time:start ctx args)
  | "masc_tool_stats" ->
      Some (handle_tool_stats ~tool_name:name ~start_time:start ctx args)
  | "masc_tool_help" ->
      Some (handle_tool_help ~tool_name:name ~start_time:start ctx args)
  | "masc_web_search" ->
      Some (handle_web_search ~tool_name:name ~start_time:start ctx args)
  | "masc_web_fetch" ->
      Some (handle_web_fetch ~tool_name:name ~start_time:start ctx args)
  | _ -> None

let schemas = Tool_schemas_misc.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let tool_spec_read_only =
  [
    "masc_tool_help";
    "masc_dashboard";
    "masc_keeper_waiting_inventory";
  ]

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_misc
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name tool_spec_read_only)
           ~is_idempotent:(List.mem s.name tool_spec_read_only)
           ()))
    schemas
let looks_like_rss_payload = Tool_misc_web_search.looks_like_rss_payload
let parse_bing_rss_items = Tool_misc_web_search.parse_bing_rss_items
let parse_searxng_json = Tool_misc_web_search.parse_searxng_json
let parse_ddg_html = Tool_misc_web_search.parse_ddg_html
let parse_brave_json = Tool_misc_web_search.parse_brave_json
let parse_tavily_json = Tool_misc_web_search.parse_tavily_json
let parse_exa_json = Tool_misc_web_search.parse_exa_json
let parse_bing_search_json = Tool_misc_web_search.parse_bing_search_json
let redact_transport_error_detail = Tool_misc_web_search.redact_transport_error_detail
let web_search_provider_plan = Tool_misc_web_search.provider_plan
let web_search_simulate_for_test ~query ~limit outcomes =
  Tool_misc_web_search.simulate_for_test ~query ~limit outcomes

let with_web_search_simulation_for_test ~outcomes f =
  Tool_misc_web_search.with_simulated_search_for_test ~outcomes f

let with_web_fetch_http_get_for_test http_get f =
  Tool_misc_web_fetch.with_http_get_for_test http_get f
