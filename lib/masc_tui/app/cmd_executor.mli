(** Asynchronous side-effect executor for {!Masc_tui_store.Cmd.t}.

    Runs HTTP requests on {!Masc_tui_net.Io_domain}, offloads heavy JSON
    decoding onto {!Masc_tui_net.Worker_pool}, synchronizes declarative SSE
    subscriptions via {!Masc_tui_net.Sse_hub}, routes Voice commands via
    {!Masc_tui_net.Voice_runner}, handles clipboard/external URLs/editor escape
    hatch/local server auto-start, and publishes typed {!Masc_tui_store.Msg.t}
    replies back onto {!Masc_tui_net.Ui_bus}. *)

open Masc_tui_core
open Masc_tui_net
open Masc_tui_store

type bus_key =
  | Key_get of string
  | Key_freshness of Subscriptions.stream_id

val equal_bus_key : bus_key -> bus_key -> bool
val hash_bus_key : bus_key -> int

type bus = (bus_key, Msg.t, Msg.t) Ui_bus.t

val create_bus :
  ?stream_capacity:int -> ?on_wake:(unit -> unit) -> unit -> bus

(** {1 Pure Endpoint, Auth & Mapping Helpers} *)

val admin_token_path : base_path:string -> string
(** [<base_path>/.masc/auth/admin.token] derived via
    {!Common.auth_dir_from_base_path} (zero hardcoded paths). *)

val load_bearer_token :
  ?getenv:(string -> string option) ->
  base_path:string ->
  unit ->
  string option
(** Resolve bearer token from [$MASC_TOKEN] when set to a non-blank value,
    otherwise read {!admin_token_path} if present and readable. Never raises
    on missing or unreadable files. *)

val endpoint_of_cli :
  ?bearer_token:string option -> Cli_args.config -> Http_client.endpoint

val msg_error_of_http : Http_client.http_error -> Msg.http_error

val stream_spec_of_id : Subscriptions.stream_id -> Sse_hub.Stream_spec.t
val stream_id_of_kind : Sse_hub.Stream_spec.kind -> Subscriptions.stream_id

val is_safe_external_url : string -> bool
(** [true] only for [http://] or [https://] URLs free of ASCII control
    characters and whitespace. *)

val is_health_body_ready : string -> bool
(** Pure [/health] readiness predicate: [true] iff [body] decodes via
    {!Masc_tui_protocol.Wire_common.decode_server_health} with [ok = true] and
    [ready <> Some false]. *)

val fetch_planning_with_tasks :
  observed_at:Clock.Mono.t ->
  fetch_planning:
    (unit ->
    (Masc_tui_protocol.Wire_work.planning_snapshot, Msg.http_error) result) ->
  fetch_tasks:
    (unit ->
    (Masc_tui_protocol.Wire_work.task list, Msg.http_error) result) ->
  (Masc_tui_protocol.Wire_work.planning_snapshot, Msg.http_error) result
(** Execute planning snapshot fetch and, when [tasks = []], enrich from
    [/api/v1/dashboard/execution?light=true]. Propagates any secondary fetch
    error (including [Workspace_mismatch], [Decode_error], [Http_error], or
    [Transport]) instead of silently returning an empty task list. *)

val decode_hub_event_msgs :
  epoch:Epoch.t ->
  observed_at:Clock.Mono.t ->
  Sse_hub.hub_event ->
  (bus_key option * Msg.t) list
(** Pure projection from a {!Sse_hub.hub_event} into zero or more bus items
    [(Some snapshot_key, msg)] or [(None, stream_msg)]. Handles batched
    [/api/v1/dashboard/logs/stream] frames ([{"reset": ..., "entries": [...]}])
    in chronological order as well as single-entry fallback. *)

val run_setup_login_stream :
  publish:
    ((Masc_tui_protocol.Wire_runtime.setup_login_receipt, Msg.http_error) result ->
    unit) ->
  stream:(on_chunk:(string -> unit) -> (unit, Msg.http_error) result) ->
  unit
(** Run a setup-login SSE stream, delivering each receipt at most once and
    propagating stream errors whenever no terminal receipt
    ([complete]/[completed]/[failed]/[cancelled]/[interrupted]) has arrived. *)

val is_local_host : string -> bool
(** [true] iff [host] refers to the local loopback interface
    (["127.0.0.1"], ["localhost"], ["::1"], or ["[::1]"], case-insensitive
    after trimming). *)

val editor_file_path : base_path:string -> Cmd.editor_target -> string option
(** Local TOML path for {!Cmd.Edit_runtime_toml} / {!Cmd.Edit_keeper_toml}
    under [<base_path>/.masc/config/], or [None] for remote wiki targets.

    {b Local-only invariant}: Direct local TOML editing via [$EDITOR] is
    strictly gated in {!execute} to local loopback hosts ({!is_local_host}) or
    an owned local server. When attached to a remote [--url] host, local TOML
    [$EDITOR] execution is refused without touching local files and an error
    {!Msg.Reply_action_ack} directs the operator to Settings
    ([HTTP /api/v1/config/patch]). *)

val render_memory_diagram_payload :
  ?run_pele:(Pele.scene -> (string, string) result) ->
  probe:Masc_tui_term.Probe.observation ->
  term_program:string option ->
  palette:Masc_tui_term.Palette.t option ->
  keeper:string ->
  kind:Knowledge_store.memory_diagram_kind ->
  mode:Knowledge_store.memory_diagram_mode ->
  ko:bool ->
  tz_offset_sec:int ->
  now_unix:float ->
  max_width:int ->
  chart:Masc_tui_ui.Memory_lineage.chart ->
  unit ->
  Knowledge_store.memory_diagram_payload
(** Resolve a memory diagram render request according to [kind], [mode],
    observed terminal graphics capabilities, and observed terminal palette.
    Forced [Diagram_mode_mermaid] and [Diagram_mode_tree] render purely in
    memory without calling [run_pele]. [Diagram_mode_auto] attempts Pele SVG
    (for [Diagram_pele_card]) or Pele Graph JSON (for [Diagram_formation_tree])
    when graphics (and palette for SVG) are available, automatically falling
    back to Mermaid or Formation Tree text with a 1-line diagnostic note on
    any capability gap or Pele failure. *)

(** {1 Executor Lifecycle & Command Dispatch} *)

type editor_handoff = {
  pause_terminal : unit -> unit;
  resume_terminal : unit -> unit;
}

val noop_editor_handoff : editor_handoff

type t

val create :
  sw:Eio.Switch.t ->
  io:Io_domain.t ->
  worker:Worker_pool.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  cli:Cli_args.config ->
  bus:bus ->
  ?bearer_token:string option ->
  ?voice_backend:Voice_runner.backend ->
  ?editor_handoff:editor_handoff ->
  on_quit:(Exit_reason.t -> unit) ->
  on_restart:(unit -> unit) ->
  unit ->
  t

val current_endpoint : t -> Http_client.endpoint
val update_workspace_guard :
  t -> instance_id:string option -> workspace_sha256:string option -> unit

val execute : t -> Cmd.t -> unit
(** Dispatch one {!Cmd.t}. Asynchronous work forks onto [sw] without blocking
    the caller; {!Cmd.Open_editor_escape_hatch} coordinates terminal handoff
    through {!editor_handoff}.

    {b Local-only invariant}: {!Cmd.Edit_runtime_toml} and
    {!Cmd.Edit_keeper_toml} only launch [$EDITOR] and write local TOML when
    {!is_local_host} holds for [cli.host] or an owned local server is running.
    Remote [--url] sessions refuse local TOML edits and emit an error
    {!Msg.Reply_action_ack}; {!Cmd.Edit_wiki_page} always uses HTTP GET/PUT
    with CAS and works on both local and remote servers. *)

val execute_all : t -> Cmd.t list -> unit
(** Flatten and dispatch a command list in order. *)

val shutdown : ?preserve_owned_server:bool -> t -> unit
(** Shut down {!Sse_hub}, {!Voice_runner}, and (unless
    [preserve_owned_server = true], e.g. during an in-place restart) stop any
    auto-started local {!Masc_server_lifecycle.owned_server}. *)
