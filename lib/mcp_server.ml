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
      ("name", `String "masc-mcp");
      ("title", `String "MASC MCP Server");
      ("version", `String Version.version);
      ( "description",
        `String
          "Multi-agent MCP server exposing MASC room coordination, tools, prompts, and resources." );
      ("websiteUrl", `String "https://github.com/yousleepwhen/masc-mcp");
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
    ~title:"Coord Status"
    ~description:"Current room status snapshot (same as masc_status)"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://status.json" ~name:"MASC Status (JSON)"
    ~title:"Coord Status (JSON)"
    ~description:"Current room status snapshot as JSON (for data collection)"
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
    ~description:"In-memory agent/session status (same as masc_who)"
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
    ~description:"Recent event log snapshot (task/agent/worktree transitions)"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://events.json?limit=50"
    ~name:"Recent Events (JSON)"
    ~title:"Event Log (JSON)"
    ~description:"Recent event log snapshot as JSON"
    ~mime_type:"application/json" ();
  make_resource ~uri:"masc://worktrees" ~name:"Worktrees"
    ~title:"Git Worktrees"
    ~description:"Git worktree snapshot for the current repo"
    ~mime_type:"text/markdown" ();
  make_resource ~uri:"masc://worktrees.json" ~name:"Worktrees (JSON)"
    ~title:"Git Worktrees (JSON)"
    ~description:"Git worktree snapshot as JSON"
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
  let events_dir = Filename.concat (Coord.masc_dir config) "events" in
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

(** Issue #8474: FSM transition matrix.  Each entry mirrors a match-arm
    in [Coord_task.transition_task_r] (lib/coord/coord_task.ml ~line
    831).  Verifier-FSM rows ([submit_for_verification],
    [approve_verification], [reject_verification]) are gated at runtime
    by [MASC_VERIFICATION_FSM_ENABLED] but listed unconditionally so
    the published schema matches the action enum
    ([Types.valid_task_action_strings] via #8354).  The regression test
    [test_types.ml :: fsm_transition_matrix] asserts every action
    listed by [Coord_task.valid_next_actions_for_status] for any
    reachable status appears here, so adding a 4th verifier action
    fails the test before it ships with a stale schema. *)
let task_fsm_transitions : (string * string list * string * string option) list =
  [
    ("claim",                   ["todo"],                                  "claimed",                None);
    ("start",                   ["claimed"],                               "in_progress",            None);
    ("done",                    ["claimed"; "in_progress"],                "done",                   None);
    ("cancel",                  ["todo"; "claimed"; "in_progress"],        "cancelled",              None);
    ("release",                 ["claimed"; "in_progress"],                "todo",                   None);
    (* Action names match [Types.task_action_to_string] (SSOT):
       Approve_verification -> "approve", Reject_verification -> "reject". *)
    ("submit_for_verification", ["claimed"; "in_progress"],                "awaiting_verification",  Some "MASC_VERIFICATION_FSM_ENABLED + verifier-FSM only");
    ("approve",                 ["awaiting_verification"],                 "done",                   Some "MASC_VERIFICATION_FSM_ENABLED + verifier != assignee");
    ("reject",                  ["awaiting_verification"],                 "in_progress",            Some "MASC_VERIFICATION_FSM_ENABLED + verifier != assignee");
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
    ("task_statuses", `List (List.map (fun s -> `String s) Types.valid_task_status_strings));
    ("actions", `List (List.map (fun s -> `String s) Types.valid_task_action_strings));
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
    "- done: claimed/in_progress(by you) -> done";
    "- cancel: todo/claimed/in_progress(by you) -> cancelled";
    "- release: claimed/in_progress(by you) -> todo";
    "- submit_for_verification: claimed/in_progress(by you) -> awaiting_verification (MASC_VERIFICATION_FSM_ENABLED)";
    "- approve: awaiting_verification -> done (verifier != assignee, MASC_VERIFICATION_FSM_ENABLED)";
    "- reject: awaiting_verification -> in_progress (verifier != assignee, MASC_VERIFICATION_FSM_ENABLED)";
    "";
    "CAS guard: expected_version == backlog.version";
  ]

(** MCP Server state *)
type server_state = {
  mutable room_config: Coord.config;
  session_registry: Session.registry;
  on_sse_broadcast: (Yojson.Safe.t -> unit) option Atomic.t;  (* SSE push callback, Atomic for cross-fiber visibility *)
  sw: Eio.Switch.t option; (* Request/runtime fibers for HTTP/MCP handlers *)
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option; (* For agent spawning *)
  fs: Eio.Fs.dir_ty Eio.Path.t option; (* For filesystem access *)
  clock: float Eio.Time.clock_ty Eio.Resource.t option; (* For timestamps/sleep *)
  mono_clock: Eio.Time.Mono.ty Eio.Resource.t option;
  net: Eio_context.eio_net option; (* For network calls - P3a: replaces global ref *)
}

let create_state ~base_path =
  let config = Coord.default_config base_path in
  let registry = Session.create () in
  (* Wire notification harness: subscription events → session queues *)
  Subscriptions.set_session_push_fn (fun event ->
    Session.push_notification_to_active_agents registry ~event
  );
  let state = {
    room_config = config;
    session_registry = registry;
    on_sse_broadcast = Atomic.make None;
    sw = None;
    proc_mgr = None;
    fs = None;
    clock = None;
    mono_clock = None;
    net = None;
  } in
  Tool_board.set_agent_lookup (fun name ->
    try Coord.is_agent_joined state.room_config ~agent_name:name
    with Sys_error _ | Not_found | Invalid_argument _ -> false);
  state

(** Create state with Eio context. *)
let create_state_eio ~sw ~proc_mgr ~fs ~clock ~mono_clock ~net ~base_path =
  let config =
    Coord.default_config_eio ~sw
      ~on_backend_ready:(fun _backend ->
        Log.Backend.info "Board: JSONL default backend";
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
     [Oas_worker_cascade] as an Eio actor (mailbox + Promise.await) but
     never wired its [start_actor_if_needed] into a bootstrap path.
     [cascade_metrics_json ()] (called from [tool_unified.ml:summary_report],
     which the dashboard tool inspector hits) does
     [Stream.add Get_metrics_json u; Promise.await p]. Without an actor
     fiber draining [stream], the await blocks forever. *)
  Oas_worker_cascade.start_actor_if_needed ~sw;
  (* Wire notification harness: subscription events → session queues *)
  Subscriptions.set_session_push_fn (fun event ->
    Session.push_notification_to_active_agents registry ~event
  );
  let state = {
    room_config = config;
    session_registry = registry;
    on_sse_broadcast = Atomic.make None;
    sw = Some sw;
    proc_mgr = Some proc_mgr;
    fs = Some fs;
    clock = Some clock;
    mono_clock = Some mono_clock;
    net = Some net;
  } in
  (* Board post kind auto-classification: reads state.room_config so
     room changes via set_room are reflected automatically. *)
  Tool_board.set_agent_lookup (fun name ->
    try Coord.is_agent_joined state.room_config ~agent_name:name
    with Sys_error _ | Not_found | Invalid_argument _ -> false);
  state

(** Register SSE broadcast callback *)
let set_sse_callback state callback =
  Atomic.set state.on_sse_broadcast (Some callback)

(** Broadcast to all SSE clients *)
let sse_broadcast state notification =
  match Atomic.get state.on_sse_broadcast with
  | Some push -> push notification
  | None -> ()
