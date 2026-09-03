(** MCP Protocol Server Core (Eio-only)

    This module provides shared types/config/resources for the Eio server.
*)

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
    (* ["any"] is what the spec spells for a scalable format; ["64x64"] told a
       client to pick a raster box out of an SVG that has no fixed one. *)
    sizes = [ "any" ];
  }

(* Only the server itself carries an icon. Per-resource and per-tool icons used
   to be derived -- one palette entry per mimeType, one per read-only tool --
   so every entry in a 97-resource listing shipped a copy of the same inlined
   SVG while the field it was derived from (mimeType, annotations.readOnlyHint)
   sat next to it in the same object. That was 64% of resources/list and 25% of
   tools/list in bytes, carrying nothing a client could not already read. A
   client that wants per-entry glyphs picks them from those fields. *)
let server_icons = [ themed_icon ~label:"MM" ~bg:"#7C3AED" ~fg:"#F5F3FF" ]

(* Every list surface on the wire is a [CacheableResult] (MCP 2026-07-28):
   [ttlMs] and [cacheScope] are required, not optional hints.  Two hints cover
   everything this server answers, so they live here rather than as literals at
   each handler -- [mcp_server_eio_protocol] and [mcp_server_eio_resource] each
   had their own copy of the field builder and their own 5000/30000 literals. *)
type cache_scope = Public | Private

type cache_hint = {
  ttl_ms : int;
  scope : cache_scope;
}

(* Workspace state a caller reads to act on: agents, tasks, the tool list a
   caller's permissions shape.  Private, because the answer is scoped to the
   presented credential, and short, because the workspace moves. *)
let live_state_cache_hint = { ttl_ms = 5000; scope = Private }

(* Catalogues that change only when this binary changes: prompts, resource
   templates, the server's own identity.  Shared caches may hold them. *)
let static_catalogue_cache_hint = { ttl_ms = 30_000; scope = Public }

let cache_scope_to_string = function
  | Public -> "public"
  | Private -> "private"

let cache_hint_fields { ttl_ms; scope } =
  [ ("ttlMs", `Int ttl_ms); ("cacheScope", `String (cache_scope_to_string scope)) ]

(* Vendor prefix for this server's own [_meta] keys.

   MCP 2026-07-28 defines Tool, Resource and the list results as closed shapes:
   they carry no index signature, so implementation data belongs under [_meta]
   rather than beside [name] and [inputSchema]. Every catalog field this server
   adds used to sit at the top level of each tool object, where a strict client
   is entitled to reject it and where a future spec field could collide with it.

   The spec reserves any prefix whose second label is [modelcontextprotocol] or
   [mcp]; this one is the reverse-DNS form of the repository host already named
   in [serverInfo.websiteUrl], so it cannot collide with a spec key or with
   another vendor. *)
let meta_key_prefix = "com.github.yousleepwhen.masc/"

(* Catalog facts about a tool: visibility, lifecycle, implementation status,
   required permission, and the keeper descriptor that owns the name. *)
let tool_catalog_meta_key = meta_key_prefix ^ "catalog"

(* Call counters, only present when the caller asked for [include_usage]. *)
let tool_usage_meta_key = meta_key_prefix ^ "usage"

(* Paging facts about a list result: total before paging, page size. *)
let list_page_meta_key = meta_key_prefix ^ "page"

(* One tool call's trace: the envelope the TUI renders, plus timing and the
   failure class when the call failed. *)
let tool_call_meta_key = meta_key_prefix ^ "call"

(* Facts about the running server that no spec field carries. *)
let server_meta_key = meta_key_prefix ^ "server"

(* Splice [fields] under [key] inside a result's [_meta], leaving any keys
   already there -- including the server info the transport injects -- alone. *)
let meta_field ~key fields =
  if fields = [] then [] else [ (key, `Assoc fields) ]

(* Name, title, and version come from
   [Mcp_transport_protocol.server_info_meta_value], which every result already
   carries in [_meta]. Restating them here would let the handshake and the
   per-result identity drift apart. *)
let server_info =
  let identity =
    match Mcp_transport_protocol.server_info_meta_value with
    | `Assoc fields -> fields
    | _ -> []
  in
  (* The description prose lives in config/mcp/resources.toml ([server]
     table), decoded once at module init by [Mcp_surface_toml]; it is
     client-facing in every initialize result. *)
  `Assoc
    (identity
    @ [
      ("description", `String Mcp_surface_toml.server_description);
      ("websiteUrl", `String "https://github.com/yousleepwhen/masc");
      ("icons", `List (List.map icon_to_json server_icons));
    ])

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
  annotations : Yojson.Safe.t option;
  size : int option;
}

type mcp_resource_template = {
  uri_template : string;
  name : string;
  title : string option;
  description : string;
  mime_type : string;
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
    annotations;
  }

(* The catalogue prose lives in config/mcp/resources.toml, decoded once at
   module init by [Mcp_surface_toml] (RFC
   prompts-and-tool-definitions-outside-ocaml §3 item 8). The list values
   below keep their previous type and evaluation timing, so
   [handle_list_resources_eio] reads them unchanged. Every entry declares its
   title explicitly in the file. *)
let resource_of_entry (entry : Mcp_surface_toml.resource_entry) =
  make_resource ~uri:entry.uri ~name:entry.name ~title:entry.title
    ~description:entry.description ~mime_type:entry.mime_type ()

let resources : mcp_resource list =
  List.map resource_of_entry Mcp_surface_toml.resources

let resource_template_of_entry (entry : Mcp_surface_toml.template_entry) =
  make_resource_template ~uri_template:entry.uri_template ~name:entry.name
    ~title:entry.title ~description:entry.description
    ~mime_type:entry.mime_type ()

let resource_templates : mcp_resource_template list =
  List.map resource_template_of_entry Mcp_surface_toml.resource_templates

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
    Workspace.default_config_uncached
      ~on_backend_ready:(fun _backend ->
        Log.Backend.info "Board: JSONL default backend";
        Board_metric_hooks_adapter.install ();
        Workspace_metric_hooks.install ();
        Atomic.set Workspace_hooks.get_default_runtime_id_fn Runtime.get_default_runtime_id;
        Atomic.set
          Workspace_hooks.get_verifier_exact_lane_slot_ids_fn
          Runtime.verifier_exact_lane_slot_ids;
        Atomic.set Task.Handlers.push_event_to_sessions_fn Subscriptions.push_event_to_sessions;
        Board_dispatch.init_jsonl ())
      base_path
  in
  let registry = Session.create () in
  Session.start_loop registry ~sw;
  Runtime_observation.start_actor_if_needed ~sw;
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
