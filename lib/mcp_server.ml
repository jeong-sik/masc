(** MCP Protocol Server Core (Eio-only)

    This module provides shared types/config/resources for the Eio server.
    Legacy handlers have been removed.
*)

(* JSON-RPC core — canonical definitions live in Mcp_transport_protocol.
   Aliases here preserve backward compatibility for callers using Mcp_server.*.
   These are zero-cost: OCaml native compilation inlines module aliases. *)

type jsonrpc_request = Mcp_transport_protocol.jsonrpc_request = {
  jsonrpc : string;
  id : Yojson.Safe.t option;
  method_ : string;
  params : Yojson.Safe.t option;
}

let jsonrpc_request_of_yojson = Mcp_transport_protocol.jsonrpc_request_of_yojson
let jsonrpc_request_to_yojson = Mcp_transport_protocol.jsonrpc_request_to_yojson
let has_field = Mcp_transport_protocol.has_field
let get_field = Mcp_transport_protocol.get_field
let is_jsonrpc_v2 = Mcp_transport_protocol.is_jsonrpc_v2
let is_jsonrpc_response = Mcp_transport_protocol.is_jsonrpc_response
let is_notification = Mcp_transport_protocol.is_notification
let get_id = Mcp_transport_protocol.get_id
let is_valid_request_id = Mcp_transport_protocol.is_valid_request_id
let validate_initialize_params = Mcp_transport_protocol.validate_initialize_params
let make_response = Mcp_transport_protocol.make_response
let make_error = Mcp_transport_protocol.make_error
let jsonrpc_notification = Mcp_transport_protocol.jsonrpc_notification

(* Protocol version — canonical in Mcp_transport_protocol *)
let supported_protocol_versions = Mcp_transport_protocol.supported_protocol_versions
let default_protocol_version = Mcp_transport_protocol.default_protocol_version
let is_supported_protocol_version = Mcp_transport_protocol.is_supported_protocol_version
let normalize_protocol_version = Mcp_transport_protocol.normalize_protocol_version
let protocol_version_from_params = Mcp_transport_protocol.protocol_version_from_params

let validate_protocol_version = Mcp_transport_protocol.validate_protocol_version

(** Server info *)
type mcp_icon = {
  src : string;
  mime_type : string option;
  sizes : string list;
}

let svg_icon_data_uri ~bg ~fg ~label =
  let text =
    if String.length label <= 2 then label else String.sub label 0 2
  in
  let svg =
    Printf.sprintf
      "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64' viewBox='0 0 64 64'><rect width='64' height='64' rx='14' fill='%s'/><text x='32' y='38' font-family='Arial, sans-serif' font-size='22' font-weight='700' text-anchor='middle' fill='%s'>%s</text></svg>"
      bg fg text
  in
  "data:image/svg+xml;utf8," ^ Uri.pct_encode svg

let icon_to_json (icon : mcp_icon) =
  let base =
    [ ("src", `String icon.src) ]
    @
    match icon.mime_type with
    | Some mime_type -> [ ("mimeType", `String mime_type) ]
    | None -> []
  in
  let base =
    if icon.sizes = [] then base
    else base @ [ ("sizes", `List (List.map (fun size -> `String size) icon.sizes)) ]
  in
  `Assoc base

let themed_icon ~label ~bg ~fg =
  {
    src = svg_icon_data_uri ~bg ~fg ~label;
    mime_type = Some "image/svg+xml";
    sizes = [ "64x64" ];
  }

let text_icon = themed_icon ~label:"TXT" ~bg:"#0F766E" ~fg:"#F0FDFA"
let json_icon = themed_icon ~label:"JS" ~bg:"#1D4ED8" ~fg:"#EFF6FF"
let doc_icon = themed_icon ~label:"MC" ~bg:"#111827" ~fg:"#F9FAFB"

let icons_for_mime mime_type =
  match String.lowercase_ascii mime_type with
  | "application/json" -> [ json_icon ]
  | "text/markdown"
  | "text/plain; charset=utf-8"
  | "text/plain" -> [ text_icon ]
  | _ -> [ doc_icon ]

let server_icons = [ themed_icon ~label:"MM" ~bg:"#7C3AED" ~fg:"#F5F3FF" ]

let server_info =
  `Assoc
    [
      ("name", `String "masc");
      ("title", `String "MASC MCP Server");
      ("version", `String Version.version);
      ( "description",
        `String
          "Multi-agent MCP server exposing MASC workspace state, tools, prompts, and resources." );
      ("websiteUrl", `String "https://github.com/yousleepwhen/masc");
      ("icons", `List (List.map icon_to_json server_icons));
    ]

let capabilities =
  `Assoc
    [
      ("tools", `Assoc [ ("listChanged", `Bool true) ]);
      ("resources", `Assoc [ ("subscribe", `Bool true); ("listChanged", `Bool false) ]);
      ("prompts", `Assoc [ ("listChanged", `Bool false) ]);
    ]

(** MCP Resources (read-only context) *)
type mcp_resource = {
  uri : string;
  name : string;
  title : string option;
  description : string;
  mime_type : string;
  icons : mcp_icon list;
  annotations : Yojson.Safe.t option;
  size : int option;
}

type mcp_resource_template = {
  uri_template : string;
  name : string;
  title : string option;
  description : string;
  mime_type : string;
  icons : mcp_icon list;
  annotations : Yojson.Safe.t option;
}

let resource_to_json (r : mcp_resource) =
  let base =
    [
      ("uri", `String r.uri);
      ("name", `String r.name);
      ("description", `String r.description);
      ("mimeType", `String r.mime_type);
    ]
    @
    match r.title with
    | Some title -> [ ("title", `String title) ]
    | None -> []
  in
  let base =
    if r.icons = [] then base
    else base @ [ ("icons", `List (List.map icon_to_json r.icons)) ]
  in
  let base =
    match r.annotations with
    | Some annotations -> base @ [ ("annotations", annotations) ]
    | None -> base
  in
  let base =
    match r.size with
    | Some size -> base @ [ ("size", `Int size) ]
    | None -> base
  in
  `Assoc base

let resource_template_to_json (t : mcp_resource_template) =
  let base =
    [
      ("uriTemplate", `String t.uri_template);
      ("name", `String t.name);
      ("description", `String t.description);
      ("mimeType", `String t.mime_type);
    ]
    @
    match t.title with
    | Some title -> [ ("title", `String title) ]
    | None -> []
  in
  let base =
    if t.icons = [] then base
    else base @ [ ("icons", `List (List.map icon_to_json t.icons)) ]
  in
  let base =
    match t.annotations with
    | Some annotations -> base @ [ ("annotations", annotations) ]
    | None -> base
  in
  `Assoc base

let make_resource ?title ?annotations ?size ~uri ~name ~description ~mime_type () =
  {
    uri;
    name;
    title = (match title with Some _ as value -> value | None -> Some name);
    description;
    mime_type;
    icons = icons_for_mime mime_type;
    annotations;
    size;
  }

let make_resource_template ?title ?annotations ~uri_template ~name ~description
    ~mime_type () =
  {
    uri_template;
    name;
    title = (match title with Some _ as value -> value | None -> Some name);
    description;
    mime_type;
    icons = icons_for_mime mime_type;
    annotations;
  }

let resources : mcp_resource list = [
  make_resource ~uri:"masc://status" ~name:"MASC Status"
    ~title:"Project Status"
    ~description:"Current project status snapshot (same as masc_status)"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://status.json" ~name:"MASC Status (JSON)"
    ~title:"Project Status (JSON)"
    ~description:"Current project status snapshot as JSON (for data collection)"
    ~mime_type:"application/json" ();
  make_resource ~uri:"masc://tasks" ~name:"Quest Board"
    ~title:"Task Board"
    ~description:"Task board snapshot (defaults to active tasks; same as masc_tasks)"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://tasks.json" ~name:"Quest Board (JSON)"
    ~title:"Task Board (JSON)"
    ~description:"Task board snapshot as JSON (backlog.json; all statuses)"
    ~mime_type:"application/json" ();
  make_resource ~uri:"masc://who" ~name:"Active Agents"
    ~title:"Online Agents"
    ~description:"In-memory agent/session status"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://who.json" ~name:"Active Agents (JSON)"
    ~title:"Online Agents (JSON)"
    ~description:"In-memory agent/session status as JSON"
    ~mime_type:"application/json" ();
  make_resource ~uri:"masc://agents" ~name:"Agents (Metadata)"
    ~title:"Agent Registry"
    ~description:"Agent registry snapshot (capabilities, tasks, last_seen)"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://agents.json" ~name:"Agents (Metadata, JSON)"
    ~title:"Agent Registry (JSON)"
    ~description:"Agent registry snapshot as JSON"
    ~mime_type:"application/json" ();
  make_resource ~uri:"masc://messages?since_seq=0&limit=10"
    ~name:"Recent Messages"
    ~title:"Recent Messages"
    ~description:"Recent messages snapshot (same as masc_messages)"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://messages.json?since_seq=0&limit=10"
    ~name:"Recent Messages (JSON)"
    ~title:"Recent Messages (JSON)"
    ~description:"Recent messages snapshot as JSON (for data collection)"
    ~mime_type:"application/json" ();
  make_resource ~uri:"masc://events?limit=50" ~name:"Recent Events"
    ~title:"Event Log"
    ~description:"Recent event log snapshot (task/agent transitions)"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://events.json?limit=50"
    ~name:"Recent Events (JSON)"
    ~title:"Event Log (JSON)"
    ~description:"Recent event log snapshot as JSON"
    ~mime_type:"application/json" ();
  make_resource ~uri:"masc://schema" ~name:"Task FSM Schema"
    ~title:"Task State Machine"
    ~description:"Task state machine rules (markdown)"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://schema.json" ~name:"Task FSM Schema (JSON)"
    ~title:"Task State Machine (JSON)"
    ~description:"Task state machine rules as JSON"
    ~mime_type:"application/json" ();
  (* Agent Being Protocol - Institution Memory *)
  make_resource ~uri:"masc://institution" ~name:"Institution Memory"
    ~title:"Institution Memory"
    ~description:"Institutional knowledge: mission, values, procedural memory, succession policy"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://institution.json"
    ~name:"Institution Memory (JSON)"
    ~title:"Institution Memory (JSON)"
    ~description:"Institutional knowledge as JSON for agent onboarding"
    ~mime_type:"application/json" ();
  (* Library - curated knowledge from direct research *)
  make_resource ~uri:"masc://library" ~name:"Library Index"
    ~title:"Research Library"
    ~description:"List of curated library documents (direct research only)"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://library.json" ~name:"Library Index (JSON)"
    ~title:"Research Library (JSON)"
    ~description:"List of curated library documents as JSON with full metadata"
    ~mime_type:"application/json" ();
  make_resource ~uri:"masc://tool-help-index" ~name:"Tool Help Index"
    ~title:"Tool Help Index"
    ~description:"Canonical help index for MCP-exposed MASC tools"
    ~mime_type:"text/markdown" ();
]

let resource_templates : mcp_resource_template list = [
  make_resource_template ~uri_template:"masc://messages{?since_seq,limit}"
    ~name:"Messages (range)"
    ~title:"Messages by Range"
    ~description:"Read messages with optional since_seq and limit"
    ~mime_type:"text/markdown" ();
  make_resource_template ~uri_template:"masc://messages.json{?since_seq,limit}"
    ~name:"Messages (range, JSON)"
    ~title:"Messages by Range (JSON)"
    ~description:"Read messages as JSON with optional since_seq and limit"
    ~mime_type:"application/json" ();
  make_resource_template ~uri_template:"masc://events{?limit}"
    ~name:"Events (range)"
    ~title:"Events by Range"
    ~description:"Read recent event log entries with optional limit"
    ~mime_type:"text/markdown" ();
  make_resource_template ~uri_template:"masc://events.json{?limit}"
    ~name:"Events (range, JSON)"
    ~title:"Events by Range (JSON)"
    ~description:"Read recent event log entries as JSON with optional limit"
    ~mime_type:"application/json" ();
  make_resource_template ~uri_template:"masc://library/{topic}"
    ~name:"Library Document"
    ~title:"Library Document"
    ~description:"Read a specific library document by topic name"
    ~mime_type:"text/markdown" ();
  make_resource_template ~uri_template:"masc://library/{topic}.json"
    ~name:"Library Document (JSON)"
    ~title:"Library Document (JSON)"
    ~description:"Read a specific library document as JSON with metadata"
    ~mime_type:"application/json" ();
  make_resource_template ~uri_template:"masc://tool-help/{tool_name}"
    ~name:"Tool Help"
    ~title:"Tool Help"
    ~description:"Read canonical help for a specific MCP tool"
    ~mime_type:"text/markdown" ();
]

(** Parse a masc:// resource URI into (resource_id, Uri.t) *)
let parse_masc_resource_uri uri_str =
  let uri = Uri.of_string uri_str in
  match Uri.scheme uri with
  | Some "masc" ->
      let host_segments =
        match Uri.host uri with
        | Some h when h <> "" -> [h]
        | _ -> []
      in
      let path_segments =
        Uri.path uri
        |> String.split_on_char '/'
        |> List.filter (fun s -> s <> "")
      in
      let segments = host_segments @ path_segments in
      let id = String.concat "/" segments in
      (id, uri)
  | _ -> (uri_str, uri)

let int_query_param uri key ~default =
  match Uri.get_query_param uri key with
  | None -> default
  | Some s -> Safe_ops.int_of_string_with_default ~default s

(** Read recent event log lines from .masc/events *)
let read_event_lines config ~limit =
  let events_dir = Filename.concat (Workspace.masc_dir config) "events" in
  if not (Sys.file_exists events_dir) then []
  else
    let month_dirs =
      Sys.readdir events_dir |> Array.to_list |> List.sort compare |> List.rev
    in
    let collected = ref [] in
    let remaining = ref limit in
    let read_lines path =
      let content = Fs_compat.load_file path in
      String.split_on_char '\n' content
      |> List.filter (fun s -> s <> "")
    in
    let add_lines path =
      if !remaining <= 0 then ()
      else
        let lines = read_lines path in
        let rec take rev_lines =
          match rev_lines with
          | [] -> ()
          | line :: rest ->
              if !remaining > 0 then begin
                collected := line :: !collected;
                decr remaining;
                take rest
              end
        in
        take (List.rev lines)
    in
    List.iter (fun month ->
      if !remaining > 0 then
        let month_path = Filename.concat events_dir month in
        if Sys.file_exists month_path && Sys.is_directory month_path then
          let files =
            Sys.readdir month_path |> Array.to_list |> List.sort compare |> List.rev
          in
          List.iter (fun file ->
            if !remaining > 0 then
              let path = Filename.concat month_path file in
              if Sys.file_exists path then add_lines path
          ) files
    ) month_dirs;
    List.rev !collected

(** Issue #8474: FSM transition matrix. Each entry mirrors a match-arm
    in the task transition lifecycle. Verification actions are always
    available when their objective source-state preconditions hold, so
    the published schema matches the action enum
    ([Masc_domain.valid_task_action_strings] via #8354).  The regression test
    [test_types.ml :: fsm_transition_matrix] asserts every action
    listed by [Workspace_task.valid_next_actions_for_status] for any
    reachable status appears here, so adding a 4th verifier action
    fails the test before it ships with a stale schema. *)
let task_fsm_transitions : (string * string list * string * string option) list =
  [
    ("claim",                   ["todo"],                                  "claimed",                None);
    ("start",                   ["claimed"],                               "in_progress",            None);
    ("done",                    ["in_progress"],                           "done",                   Some "configured LLM completion verdict must pass");
    ("cancel",                  ["todo"; "claimed"; "in_progress"],        "cancelled",              None);
    ("release",                 ["claimed"; "in_progress"],                "todo",                   None);
    (* Action names match [Masc_domain.task_action_to_string] (SSOT):
       Approve_verification -> "approve", Reject_verification -> "reject". *)
    ("submit_for_verification", ["claimed"; "in_progress"],                "awaiting_verification",  Some "asynchronous configured LLM review state");
    ("approve",                 ["awaiting_verification"],                 "done",                   Some "configured LLM completion verdict must pass");
    ("reject",                  ["awaiting_verification"],                 "in_progress",            Some "configured LLM completion verdict must reject");
  ]

let task_fsm_transition_to_json (action, froms, to_, gate) =
  let base =
    [ ("action", `String action)
    ; ("from", `List (List.map (fun s -> `String s) froms))
    ; ("to", `String to_)
    ]
  in
  let fields = match gate with
    | None -> base
    | Some g -> base @ [("gated_by", `String g)]
  in
  `Assoc fields

let schema_json =
  (* Issue #8354: enums derived from Variant SSOT in [Types]. Hand-rolled
     lists used to drop [awaiting_verification] and the verification
     actions ([submit_for_verification] / [approve] / [reject]).
     Issue #8474: transitions matrix derived from [task_fsm_transitions]
     (single source of truth) — used to drop the 3 verifier-FSM rows. *)
  `Assoc [
    ("task_statuses", `List (List.map (fun s -> `String s) Masc_domain.valid_task_status_strings));
    ("actions", `List (List.map (fun s -> `String s) Masc_domain.valid_task_action_strings));
    ("transitions", `List (List.map task_fsm_transition_to_json task_fsm_transitions));
    ("cas", `Assoc [
      ("field", `String "backlog.version");
      ("parameter", `String "expected_version");
    ]);
  ]

let schema_markdown =
  String.concat "\n" [
    "# Task FSM";
    "";
    "- claim: todo -> claimed";
    "- start: claimed(by you) -> in_progress";
    "- done: in_progress(by you) -> done (configured LLM verdict=pass)";
    "- cancel: todo/claimed/in_progress(by you) -> cancelled";
    "- release: claimed/in_progress(by you) -> todo";
    "- submit_for_verification: claimed/in_progress(by you) -> awaiting_verification";
    "- approve: awaiting_verification -> done (configured LLM verdict=pass)";
    "- reject: awaiting_verification -> in_progress (configured LLM verdict=reject)";
    "";
    "CAS guard: expected_version == backlog.version";
  ]

type owner_identity_projection =
  | Owner_identity_projection_pending
  | Owner_identity_projection_complete of int
  | Owner_identity_projection_failed of Eio.Exn.with_bt

exception Owner_identity_projection_settled_more_than_once

type publication_recovery_available =
  { registry : Fs_compat.Publication_recovery.registry
  ; owner_identity_projection : owner_identity_projection Atomic.t
  }

type publication_recovery_runtime_state =
  | Publication_recovery_initializing
  | Publication_recovery_available of publication_recovery_available
  | Publication_recovery_unavailable of
      Fs_compat.Publication_recovery.registry_error
  | Publication_recovery_initialization_crashed of Eio.Exn.with_bt
  | Publication_recovery_non_runtime

type publication_recovery_runtime =
  { state : publication_recovery_runtime_state Atomic.t
  ; initialized : unit Eio.Promise.t option
  }

type publication_recovery_runtime_snapshot =
  | Publication_recovery_initializing_snapshot
  | Publication_recovery_available_snapshot of
      { health : Fs_compat.Publication_recovery.health_snapshot
      ; owner_identity_projection : owner_identity_projection
      }
  | Publication_recovery_unavailable_snapshot of
      Fs_compat.Publication_recovery.registry_error
  | Publication_recovery_initialization_crashed_snapshot
  | Publication_recovery_non_runtime_snapshot

(** The active workspace and its publication-recovery registry are one atomic
    fact. The registry snapshot is the sole activation-health source. *)
type workspace_scope =
  { config : Workspace.config
  ; publication_recovery : publication_recovery_runtime
  }

type workspace_runtime =
  { process_masc_root : string
  ; scope : workspace_scope Atomic.t
  }

(** MCP Server state *)
type server_state = {
  workspace_runtime: workspace_runtime;
  session_registry: Session.registry;
  on_sse_broadcast: (Yojson.Safe.t -> unit) option Atomic.t;  (* SSE push callback, Atomic for cross-fiber visibility *)
  sw: Eio.Switch.t option; (* Request/runtime fibers for HTTP/MCP handlers *)
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option; (* For agent spawning *)
  fs: Eio.Fs.dir_ty Eio.Path.t option; (* For filesystem access *)
  clock: float Eio.Time.clock_ty Eio.Resource.t option; (* For timestamps/sleep *)
  mono_clock: Eio.Time.Mono.ty Eio.Resource.t option;
  net: Eio_context.eio_net option; (* For network calls - P3a: replaces global ref *)
}

type workspace_switch_error =
  | Workspace_masc_root_mismatch of
      { runtime_root : string
      ; requested_root : string
      }

let workspace_switch_error_to_string = function
  | Workspace_masc_root_mismatch { runtime_root; requested_root } ->
    Printf.sprintf
      "workspace MASC root mismatch: runtime=%s requested=%s"
      runtime_root
      requested_root
;;

let workspace_scope state = Atomic.get state.workspace_runtime.scope
let workspace_config state = (workspace_scope state).config

let workspace_scope_publication_recovery_registry scope =
  match Atomic.get scope.publication_recovery.state with
  | Publication_recovery_available available -> Some available.registry
  | Publication_recovery_initializing
  | Publication_recovery_unavailable _
  | Publication_recovery_initialization_crashed _
  | Publication_recovery_non_runtime -> None
;;

let publication_recovery_availability_provider state () =
  match Atomic.get (workspace_scope state).publication_recovery.state with
  | Publication_recovery_initializing ->
    Keeper_publication_recovery_availability.Initializing
  | Publication_recovery_available available ->
    Keeper_publication_recovery_availability.Available available.registry
  | Publication_recovery_unavailable error ->
    Keeper_publication_recovery_availability.Registry_unavailable error
  | Publication_recovery_initialization_crashed failure ->
    Keeper_publication_recovery_availability.Initialization_crashed failure
  | Publication_recovery_non_runtime ->
    Keeper_publication_recovery_availability.Non_runtime
;;

let workspace_scope_publication_recovery_snapshot scope =
  match Atomic.get scope.publication_recovery.state with
  | Publication_recovery_initializing ->
    Publication_recovery_initializing_snapshot
  | Publication_recovery_available available ->
    Publication_recovery_available_snapshot
      { health =
          Fs_compat.Publication_recovery.health_snapshot available.registry
      ; owner_identity_projection =
          Atomic.get available.owner_identity_projection
      }
  | Publication_recovery_unavailable error ->
    Publication_recovery_unavailable_snapshot error
  | Publication_recovery_initialization_crashed _ ->
    Publication_recovery_initialization_crashed_snapshot
  | Publication_recovery_non_runtime ->
    Publication_recovery_non_runtime_snapshot
;;

type publication_recovery_health_count =
  | Owner_identity_rejected_health_count
  | In_progress_health_count
  | Demanded_owner_health_count
  | Attention_health_count

type publication_recovery_health_count_violation =
  | Negative_health_count of publication_recovery_health_count * int
  | Health_count_overflow of publication_recovery_health_count

exception Publication_recovery_health_count_violation of
  publication_recovery_health_count_violation

let checked_health_count_add ~count left right =
  if left < 0
  then
    raise
      (Publication_recovery_health_count_violation
         (Negative_health_count (count, left)))
  else if right < 0
  then
    raise
      (Publication_recovery_health_count_violation
         (Negative_health_count (count, right)))
  else if left > Int.max_int - right
  then
    raise
      (Publication_recovery_health_count_violation
         (Health_count_overflow count))
  else left + right
;;

let checked_health_count_sum ~count values =
  List.fold_left (checked_health_count_add ~count) 0 values
;;

let checked_health_count_increment ~count value =
  checked_health_count_add ~count value 1
;;

let publication_recovery_available_snapshot_to_health_yojson
    ~owner_identity_projection
    ({ discovery_phase
     ; discovery_row_count
     ; discovered_owner_count
     ; invalid_owner_name_count
     ; retryable_lane_failure_count
     ; owners
     } : Fs_compat.Publication_recovery.health_snapshot)
  =
  let discovery_phase_name, discovery_warming, discovery_failed =
    match discovery_phase with
    | Fs_compat.Publication_recovery.Health_discovery_required ->
      "required", true, false
    | Fs_compat.Publication_recovery.Health_discovery_running ->
      "running", true, false
    | Fs_compat.Publication_recovery.Health_discovery_failed ->
      "failed", false, true
    | Fs_compat.Publication_recovery.Health_discovery_complete ->
      "complete", false, false
  in
  let identity_projection_pending =
    match discovery_phase, owner_identity_projection with
    | Fs_compat.Publication_recovery.Health_discovery_complete,
      Owner_identity_projection_pending -> true
    | ( Fs_compat.Publication_recovery.Health_discovery_required
      | Fs_compat.Publication_recovery.Health_discovery_running
      | Fs_compat.Publication_recovery.Health_discovery_failed )
      , _
    | Fs_compat.Publication_recovery.Health_discovery_complete,
      ( Owner_identity_projection_complete _
      | Owner_identity_projection_failed _ ) -> false
  in
  let identity_projection_failed =
    match owner_identity_projection with
    | Owner_identity_projection_failed _ -> true
    | Owner_identity_projection_pending
    | Owner_identity_projection_complete _ -> false
  in
  let owner_identity_rejected_count =
    match owner_identity_projection with
    | Owner_identity_projection_pending -> 0
    | Owner_identity_projection_complete count -> count
    | Owner_identity_projection_failed _ -> 0
  in
  let in_progress_count =
    checked_health_count_sum
      ~count:In_progress_health_count
      [ owners.inspection_pending
      ; owners.inspection_running
      ; owners.reconciliation_pending
      ; owners.reconciliation_running
      ]
  in
  let demanded_owner_count =
    checked_health_count_sum
      ~count:Demanded_owner_health_count
      [ in_progress_count
      ; owners.ready_without_obligation
      ; owners.ready
      ; owners.blocked
      ]
  in
  let attention_count =
    checked_health_count_sum
      ~count:Attention_health_count
      [ (if discovery_failed then 1 else 0)
      ; (if identity_projection_failed then 1 else 0)
      ; invalid_owner_name_count
      ; owner_identity_rejected_count
      ; owners.blocked
      ; retryable_lane_failure_count
      ]
  in
  let status =
    if attention_count > 0
    then Health_status.Degraded
    else if discovery_warming || identity_projection_pending || in_progress_count > 0
    then Health_status.Warming
    else Health_status.Ok
  in
  let status_reason_fields =
    [ (if discovery_failed then 1 else 0), "discovery_failed"
    ; (if identity_projection_failed then 1 else 0), "owner_identity_projection_failed"
    ; invalid_owner_name_count, "invalid_owner_name"
    ; owner_identity_rejected_count, "owner_identity_rejected"
    ; owners.blocked, "owner_blocked"
    ; retryable_lane_failure_count, "owner_lane_store_failure"
    ]
  in
  let status_reasons =
    List.filter_map
      (fun (count, reason) -> if count > 0 then Some (`String reason) else None)
      status_reason_fields
  in
  let status_reasons =
    if identity_projection_pending
    then `String "owner_identity_projection_pending" :: status_reasons
    else status_reasons
  in
  `Assoc
    [ "schema", `String "masc.publication_recovery_activation.v4"
    ; "status", `String (Health_status.to_string status)
    ; "global_blocking", `Bool false
    ; "operator_action_required", `Bool (attention_count > 0)
    ; "discovery_phase", `String discovery_phase_name
    ; "discovery_row_count", `Int discovery_row_count
    ; "demanded_owner_count", `Int demanded_owner_count
    ; "in_progress_count", `Int in_progress_count
    ; "attention_count", `Int attention_count
    ; "status_reasons", `List status_reasons
    ; ( "row_counts"
      , `Assoc
          [ "discovered_owner", `Int discovered_owner_count
          ; "invalid_owner_name", `Int invalid_owner_name_count
          ; "owner_identity_rejected", `Int owner_identity_rejected_count
          ; "owner_inspection_pending", `Int owners.inspection_pending
          ; "owner_inspection_running", `Int owners.inspection_running
          ; ( "owner_reconciliation_pending"
            , `Int owners.reconciliation_pending )
          ; ( "owner_reconciliation_running"
            , `Int owners.reconciliation_running )
          ; "owner_ready", `Int owners.ready
          ; ( "owner_ready_without_obligation"
            , `Int owners.ready_without_obligation )
          ; "owner_blocked", `Int owners.blocked
          ; "owner_lane_store_failure"
          , `Int retryable_lane_failure_count
          ] )
    ]
;;

let publication_recovery_snapshot_to_health_yojson = function
  | Publication_recovery_initializing_snapshot ->
    `Assoc
      [ "schema", `String "masc.publication_recovery_activation.v4"
      ; "status", `String (Health_status.to_string Health_status.Warming)
      ; "global_blocking", `Bool false
      ; "operator_action_required", `Bool false
      ; "discovery_phase", `String "initializing"
      ; "discovery_row_count", `Int 0
      ; "demanded_owner_count", `Int 0
      ; "in_progress_count", `Int 0
      ; "attention_count", `Int 0
      ; "status_reasons", `List [ `String "registry_initializing" ]
      ]
  | Publication_recovery_available_snapshot
      { health; owner_identity_projection } ->
    publication_recovery_available_snapshot_to_health_yojson
      ~owner_identity_projection
      health
  | Publication_recovery_unavailable_snapshot _ ->
    `Assoc
      [ "schema", `String "masc.publication_recovery_activation.v4"
      ; "status", `String (Health_status.to_string Health_status.Degraded)
      ; "global_blocking", `Bool false
      ; "operator_action_required", `Bool true
      ; "discovery_phase", `String "unavailable"
      ; "discovery_row_count", `Int 0
      ; "demanded_owner_count", `Int 0
      ; "in_progress_count", `Int 0
      ; "attention_count", `Int 1
      ; "status_reasons", `List [ `String "registry_unavailable" ]
      ]
  | Publication_recovery_initialization_crashed_snapshot ->
    `Assoc
      [ "schema", `String "masc.publication_recovery_activation.v4"
      ; "status", `String (Health_status.to_string Health_status.Degraded)
      ; "global_blocking", `Bool false
      ; "operator_action_required", `Bool true
      ; "discovery_phase", `String "initialization_crashed"
      ; "discovery_row_count", `Int 0
      ; "demanded_owner_count", `Int 0
      ; "in_progress_count", `Int 0
      ; "attention_count", `Int 1
      ; "status_reasons", `List [ `String "registry_initialization_crashed" ]
      ]
  | Publication_recovery_non_runtime_snapshot ->
    `Assoc
      [ "schema", `String "masc.publication_recovery_activation.v4"
      ; "status", `String "unavailable"
      ; "global_blocking", `Bool false
      ; "operator_action_required", `Bool false
      ; "reason", `String "non_runtime_state"
      ]
;;

let publication_recovery_owner_identity_rejected_count rows =
  List.fold_left
    (fun identity_rejected -> function
      | Fs_compat.Publication_recovery.Invalid_owner_name _ ->
        identity_rejected
      | Fs_compat.Publication_recovery.Discovered_owner owner ->
        (match
           Keeper_id.Keeper_name.of_string
             (Fs_compat.Publication_recovery.owner_to_string owner)
         with
         | Ok _ -> identity_rejected
         | Error _ ->
           checked_health_count_increment
             ~count:Owner_identity_rejected_health_count
             identity_rejected))
    0
    rows
;;

let settle_owner_identity_projection_with
    ~project
    owner_identity_projection
    rows
  =
  let observation =
    match project rows with
    | count -> `Complete count
    | exception (Eio.Cancel.Cancelled _ as cancellation) ->
      let backtrace = Printexc.get_raw_backtrace () in
      `Cancelled (cancellation, backtrace)
    | exception exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      `Failed (exception_, backtrace)
  in
  let terminal =
    match observation with
    | `Complete count -> Owner_identity_projection_complete count
    | `Cancelled failure
    | `Failed failure -> Owner_identity_projection_failed failure
  in
  Eio.Cancel.protect (fun () ->
    let current = Atomic.get owner_identity_projection in
    match current with
    | Owner_identity_projection_pending ->
      if not
           (Atomic.compare_and_set
              owner_identity_projection
              current
              terminal)
      then raise Owner_identity_projection_settled_more_than_once
    | Owner_identity_projection_complete _
    | Owner_identity_projection_failed _ ->
      raise Owner_identity_projection_settled_more_than_once);
  (match observation with
   | `Cancelled ((_, backtrace) as cancellation) ->
     (match Eio.Fiber.check () with
      | () -> terminal
      | exception Eio.Cancel.Cancelled _ ->
        Printexc.raise_with_backtrace (fst cancellation) backtrace)
   | `Complete _
   | `Failed _ ->
     Eio.Fiber.check ();
     terminal)
;;

let run_publication_recovery_discovery ~registry_root available =
  match
    Fs_compat.Publication_recovery.discover_owners available.registry
  with
  | Ok rows ->
    let owner_identity_projection =
      settle_owner_identity_projection_with
        ~project:publication_recovery_owner_identity_rejected_count
        available.owner_identity_projection
        rows
    in
    let health =
      Fs_compat.Publication_recovery.health_snapshot available.registry
    in
    (match owner_identity_projection with
     | Owner_identity_projection_complete owner_identity_rejected_count ->
       Log.Server.emit
         (if
            health.invalid_owner_name_count = 0
            && owner_identity_rejected_count = 0
          then Log.Info
          else Log.Warn)
         ~category:Log.Boundary
         ~details:
           (`Assoc
              [ "registry_root", `String registry_root
              ; "discovered_owner_count", `Int health.discovered_owner_count
              ; "invalid_owner_name_count", `Int health.invalid_owner_name_count
              ; ( "owner_identity_rejected_count"
                , `Int owner_identity_rejected_count )
              ])
         "publication recovery owner discovery settled"
     | Owner_identity_projection_failed (exception_, backtrace) ->
       Log.Server.emit
         Log.Error
         ~category:Log.Boundary
         ~details:
           (`Assoc
              [ "registry_root", `String registry_root
              ; "exception", `String (Printexc.to_string exception_)
              ; ( "backtrace"
                , `String (Printexc.raw_backtrace_to_string backtrace) )
              ])
         "publication recovery owner identity projection failed"
     | Owner_identity_projection_pending ->
       raise Owner_identity_projection_settled_more_than_once)
  | Error Fs_compat.Publication_recovery.Registry_discovery_in_progress ->
    Log.Server.emit
      Log.Debug
      ~category:Log.Boundary
      ~details:(`Assoc [ "registry_root", `String registry_root ])
      "publication recovery owner discovery already running"
  | Error
      (Fs_compat.Publication_recovery.Registry_discovery_terminal failure) ->
    Log.Server.emit
      Log.Warn
      ~category:Log.Boundary
      ~details:
        (`Assoc
           [ "registry_root", `String registry_root
           ; ( "failure"
             , `String
                 (Fs_compat.Publication_recovery.discovery_failure_to_string
                    failure) )
           ])
      "publication recovery owner discovery degraded"
;;

let run_isolated_publication_recovery_discovery ~registry_root available =
  match run_publication_recovery_discovery ~registry_root available with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as cancellation) ->
    let backtrace = Printexc.get_raw_backtrace () in
    (match Eio.Fiber.check () with
     | exception Eio.Cancel.Cancelled _ ->
       Printexc.raise_with_backtrace cancellation backtrace
     | () ->
       Log.Server.emit
         Log.Error
         ~category:Log.Boundary
         ~details:
           (`Assoc
              [ "registry_root", `String registry_root
              ; "exception", `String (Printexc.to_string cancellation)
              ; ( "backtrace"
                , `String (Printexc.raw_backtrace_to_string backtrace) )
              ])
         "publication recovery discovery raised non-current cancellation")
  | exception exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Log.Server.emit
      Log.Error
      ~category:Log.Boundary
      ~details:
        (`Assoc
           [ "registry_root", `String registry_root
           ; "exception", `String (Printexc.to_string exception_)
           ; ( "backtrace"
             , `String (Printexc.raw_backtrace_to_string backtrace) )
           ])
      "publication recovery discovery fiber crashed after isolation"
;;

let validate_workspace_config state config =
  let requested_root = Workspace.masc_root_dir config in
  let runtime_root = state.workspace_runtime.process_masc_root in
  if String.equal requested_root runtime_root
  then Ok ()
  else
    Error (Workspace_masc_root_mismatch { runtime_root; requested_root })
;;

let set_workspace_config state config =
  match validate_workspace_config state config with
  | Error _ as error -> error
  | Ok () ->
    let rec replace_config () =
      let current_scope = workspace_scope state in
      let replacement =
        { config
        ; publication_recovery = current_scope.publication_recovery
        }
      in
      if not
           (Atomic.compare_and_set
              state.workspace_runtime.scope
              current_scope
              replacement)
      then replace_config ()
    in
    replace_config ();
    Ok ()
;;

exception Publication_recovery_initialization_settled_twice
exception Publication_recovery_initialized_more_than_once

let set_publication_recovery_initialized runtime state =
  let current = Atomic.get runtime.state in
  match current with
  | Publication_recovery_initializing ->
    if not (Atomic.compare_and_set runtime.state current state)
    then raise Publication_recovery_initialized_more_than_once
  | Publication_recovery_available _
  | Publication_recovery_unavailable _
  | Publication_recovery_initialization_crashed _
  | Publication_recovery_non_runtime ->
    raise Publication_recovery_initialized_more_than_once
;;

let settle_publication_recovery_initialization resolver =
  if not (Eio.Promise.try_resolve resolver ())
  then raise Publication_recovery_initialization_settled_twice
;;

let agent_session_bound_or_observe_failure state ~agent_name =
  match
    Workspace.is_agent_session_bound
      (workspace_config state)
      ~agent_name
  with
  | is_bound -> is_bound
  | exception ((Sys_error _ | Not_found | Invalid_argument _) as exception_) ->
    let backtrace = Printexc.get_raw_backtrace () in
    Log.Server.emit
      Log.Warn
      ~category:Log.Boundary
      ~details:
        (`Assoc
           [ "agent_name", `String agent_name
           ; "exception", `String (Printexc.to_string exception_)
           ; ( "backtrace"
             , `String (Printexc.raw_backtrace_to_string backtrace) )
           ])
      "board agent-session lookup failed";
    false
;;

module For_testing = struct
  type health_count_sum_observation =
    | Health_count_sum of int
    | Health_count_negative
    | Health_count_overflow

  let publication_recovery_health_count_sum values =
    match checked_health_count_sum ~count:Attention_health_count values with
    | value -> Health_count_sum value
    | exception
        Publication_recovery_health_count_violation
          (Negative_health_count _) -> Health_count_negative
    | exception
        Publication_recovery_health_count_violation
          (Health_count_overflow _) -> Health_count_overflow
  ;;

  let publication_recovery_identity_projection_failure_health exception_ =
    let owner_identity_projection =
      Atomic.make Owner_identity_projection_pending
    in
    let owner_identity_projection =
      settle_owner_identity_projection_with
        ~project:(fun _ -> raise exception_)
        owner_identity_projection
        []
    in
    publication_recovery_available_snapshot_to_health_yojson
      ~owner_identity_projection
      { Fs_compat.Publication_recovery.discovery_phase =
          Fs_compat.Publication_recovery.Health_discovery_complete
      ; discovery_row_count = 0
      ; discovered_owner_count = 0
      ; invalid_owner_name_count = 0
      ; retryable_lane_failure_count = 0
      ; owners =
          { Fs_compat.Publication_recovery.inspection_pending = 0
          ; inspection_running = 0
          ; reconciliation_pending = 0
          ; reconciliation_running = 0
          ; ready_without_obligation = 0
          ; ready = 0
          ; blocked = 0
          }
      }
  ;;

  let publication_recovery_registry state =
    workspace_scope_publication_recovery_registry (workspace_scope state)
  ;;

  let create_state ~base_path =
    let config = Workspace.default_config base_path in
    let registry = Session.create () in
    (* Wire notification harness: subscription events → session queues *)
    Subscriptions.set_session_push_fn (fun event ->
      Session.push_notification_to_active_agents registry ~event
    );
    let state =
      { workspace_runtime =
          { process_masc_root = Workspace.masc_root_dir config
          ; scope =
              Atomic.make
                { config
                ; publication_recovery =
                    { state = Atomic.make Publication_recovery_non_runtime
                    ; initialized = None
                    }
                }
          }
      ; session_registry = registry
      ; on_sse_broadcast = Atomic.make None
      ; sw = None
      ; proc_mgr = None
      ; fs = None
      ; clock = None
      ; mono_clock = None
      ; net = None
      }
    in
    Board_tool.set_agent_lookup (fun name ->
      agent_session_bound_or_observe_failure state ~agent_name:name);
    state
  ;;

  type publication_recovery_runtime_observation =
    | Runtime_initializing
    | Runtime_available
    | Runtime_unavailable
    | Runtime_initialization_crashed
    | Runtime_non_runtime

  let publication_recovery_runtime_observation state =
    match Atomic.get (workspace_scope state).publication_recovery.state with
    | Publication_recovery_initializing -> Runtime_initializing
    | Publication_recovery_available _ -> Runtime_available
    | Publication_recovery_unavailable _ -> Runtime_unavailable
    | Publication_recovery_initialization_crashed _ ->
      Runtime_initialization_crashed
    | Publication_recovery_non_runtime -> Runtime_non_runtime
  ;;

  let await_publication_recovery_initialization state =
    Option.iter
      Eio.Promise.await
      (workspace_scope state).publication_recovery.initialized
  ;;
end

(** Create state with Eio context. *)
let create_state_eio ~sw ~proc_mgr ~fs ~clock ~mono_clock ~net ~base_path =
  let config =
    Workspace.default_config_eio ~sw
      ~on_backend_ready:(fun _backend ->
        Log.Backend.info "Board: JSONL default backend";
        Board_agent_effect_hooks.install ();
        Board_metric_hooks_adapter.install ();
        Workspace_metric_hooks.install ();
        Atomic.set Workspace_hooks.get_default_runtime_id_fn Runtime.get_default_runtime_id;
        Atomic.set
          Workspace_hooks.get_cross_verifier_runtime_id_fn
          Runtime.cross_verifier_runtime_id;
        Atomic.set Task.Handlers.record_verdict_fn (fun ~task_id ~req ~result () ->
          Eval_calibration.record_verdict ~task_id ~req ~result ());
        Atomic.set Task.Handlers.sse_broadcast_fn Sse.broadcast;
        Atomic.set Task.Handlers.push_event_to_sessions_fn Subscriptions.push_event_to_sessions;
        Atomic.set Task.Handlers.get_few_shot_block_fn (fun () ->
          Eval_calibration.format_few_shot_block
            (Eval_calibration.select_examples ~max_examples:3));
        Board_dispatch.init_jsonl ())
      base_path
  in
  let registry = Session.create () in
  (* Start the registry's actor consumer fiber. Without this, every
     [Session.*] helper that awaits a reply (register, restore_from_disk,
     check_rate_limit, push_message, push_notification, get_session,
     get_sessions) hangs forever — the mailbox has no consumer.
     Missed when #10664 introduced the actor model. *)
  Session.start_loop registry ~sw;
  (* Same sweep miss as Session.start_loop above: PR #10730 introduced
     [Runtime_observation] as an Eio actor (mailbox + Promise.await) but
     never wired its [start_actor_if_needed] into a bootstrap path.
     [runtime_metrics_json ()] (called from [tool_unified.ml:summary_report],
     which the dashboard tool inspector hits) does
     [Stream.add Get_metrics_json u; Promise.await p]. Without an actor
     fiber draining [stream], the await blocks forever. *)
  Runtime_observation.start_actor_if_needed ~sw;
  (* Wire notification harness: subscription events → session queues *)
  Subscriptions.set_session_push_fn (fun event ->
    Session.push_notification_to_active_agents registry ~event
  );
  Keeper_supervisor.set_global_switch sw;
  let process_masc_root = Workspace.masc_root_dir config in
  let publication_recovery_initialized,
      resolve_publication_recovery_initialized =
    Eio.Promise.create ()
  in
  let publication_recovery =
    { state = Atomic.make Publication_recovery_initializing
    ; initialized = Some publication_recovery_initialized
    }
  in
  let state = {
    workspace_runtime =
      { process_masc_root
      ; scope =
          Atomic.make
            { config; publication_recovery }
      };
    session_registry = registry;
    on_sse_broadcast = Atomic.make None;
    sw = Some sw;
    proc_mgr = Some proc_mgr;
    fs = Some fs;
    clock = Some clock;
    mono_clock = Some mono_clock;
    net = Some net;
  } in
  (* [Fiber.fork] starts its child immediately. Yield before opening the
     registry so callers receive the typed [Initializing] state before any
     publication-recovery filesystem work. The child performs one registry
     open and one name discovery; exact owner work remains lane-demanded. *)
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Fiber.yield ();
    let registry_root = Eio.Path.(fs / process_masc_root) in
    let initialization =
      try
        `Returned
          (Fs_compat.Publication_recovery.open_registry
             ~sw
             ~fs
             ~registry_root)
      with
      | Eio.Cancel.Cancelled _ as cancellation ->
        let backtrace = Printexc.get_raw_backtrace () in
        (match Eio.Fiber.check () with
         | exception Eio.Cancel.Cancelled _ ->
           Printexc.raise_with_backtrace cancellation backtrace
         | () -> `Crashed (cancellation, backtrace))
      | exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        `Crashed (exception_, backtrace)
    in
    match initialization with
    | `Returned (Ok registry) ->
      let available =
        { registry
        ; owner_identity_projection =
            Atomic.make Owner_identity_projection_pending
        }
      in
      Eio.Cancel.protect (fun () ->
        set_publication_recovery_initialized
          publication_recovery
          (Publication_recovery_available available);
        settle_publication_recovery_initialization
          resolve_publication_recovery_initialized);
      Eio.Fiber.check ();
      run_isolated_publication_recovery_discovery
        ~registry_root:process_masc_root
        available
    | `Returned (Error error) ->
      Eio.Cancel.protect (fun () ->
        set_publication_recovery_initialized
          publication_recovery
          (Publication_recovery_unavailable error);
        settle_publication_recovery_initialization
          resolve_publication_recovery_initialized);
      Eio.Fiber.check ();
      Log.Server.emit
        Log.Warn
        ~category:Log.Boundary
        ~details:
          (`Assoc
             [ "registry_root", `String process_masc_root
             ; ( "error"
               , `String
                   (Fs_compat.Publication_recovery.registry_error_to_string
                      error) )
             ])
        "publication recovery registry is unavailable; publication filesystem tools fail closed"
    | `Crashed (exception_, backtrace) ->
      Eio.Cancel.protect (fun () ->
        set_publication_recovery_initialized
          publication_recovery
          (Publication_recovery_initialization_crashed
             (exception_, backtrace));
        settle_publication_recovery_initialization
          resolve_publication_recovery_initialized);
      Eio.Fiber.check ();
      Log.Server.emit
        Log.Error
        ~category:Log.Boundary
        ~details:
          (`Assoc
             [ "registry_root", `String process_masc_root
             ; "exception", `String (Printexc.to_string exception_)
             ; ( "backtrace"
               , `String (Printexc.raw_backtrace_to_string backtrace) )
             ])
        "publication recovery registry initialization crashed; publication filesystem tools fail closed");
  (* Agent-to-agent board feedback lookup follows the active workspace. *)
  Board_tool.set_agent_lookup (fun name ->
    agent_session_bound_or_observe_failure state ~agent_name:name);
  state

(** Register SSE broadcast callback *)
let set_sse_callback state callback =
  Atomic.set state.on_sse_broadcast (Some callback)

(** Broadcast to all SSE clients *)
let sse_broadcast state notification =
  match Atomic.get state.on_sse_broadcast with
  | Some push -> push notification
  | None -> ()
