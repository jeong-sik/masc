type tools_projection = {
  base_path : string;
  workspace_path : string;
  masc_root : string;
  json : Yojson.Safe.t;
  etag : string;
  encoded : Http_response_payload.prepared;
}

type tools_result =
  | Tools_pending of Yojson.Safe.t
  | Tools_ready of Yojson.Safe.t
  | Tools_error of Yojson.Safe.t

let make_tools_projection ~(config : Workspace.config) json =
  let raw = Yojson.Safe.to_string json in
  { base_path = config.base_path; workspace_path = config.workspace_path;
    masc_root = Workspace.masc_dir config; json;
    etag = Http_server_eio.Response.weak_etag_value raw;
    encoded = Http_response_payload.prepare raw }
;;

type t = {
  generated_at : float;
  base_path : string;
  workspace_path : string;
  masc_root : string;
  shell : Yojson.Safe.t;
  shell_light : Yojson.Safe.t;
  tools : tools_projection;
  telemetry_summary : Yojson.Safe.t;
}

type partial = {
  shell : (Yojson.Safe.t * Yojson.Safe.t) option;
  tools : tools_projection option;
  telemetry : Yojson.Safe.t option;
  latest : t option;
}

type publisher = {
  config : Workspace.config;
  masc_root : string;
  is_current : unit -> bool;
  state : partial Atomic.t;
}
type tools_update = { publisher : publisher; projection : tools_projection }
let active : publisher option Atomic.t = Atomic.make None

let activate ~config ~is_current =
  let publisher = { config; masc_root = Workspace.masc_dir config; is_current;
    state = Atomic.make { shell = None; tools = None; telemetry = None; latest = None } } in
  Atomic.set active (Some publisher);
  publisher
;;

let rec retire publisher =
  let observed = Atomic.get active in
  match observed with
  | None -> ()
  | Some current ->
      if current == publisher && not (Atomic.compare_and_set active observed None)
      then retire publisher
;;

let read_publisher publisher select =
  let value = select (Atomic.get publisher.state) in
  if publisher.is_current () then value else None
;;

let current () = Option.bind (Atomic.get active)
    (fun publisher -> read_publisher publisher (fun state -> state.latest))

let publisher_for_config (config : Workspace.config) =
  match Atomic.get active with
  | Some publisher when String.equal publisher.config.base_path config.base_path
      && String.equal publisher.config.workspace_path config.workspace_path
      && String.equal publisher.masc_root (Workspace.masc_dir config) -> Some publisher
  | Some _ | None -> None
;;

let current_for_config config =
  Option.bind (publisher_for_config config) (fun publisher -> read_publisher publisher (fun state -> state.latest))
let shell_for_config config =
  Option.bind (publisher_for_config config) (fun publisher -> read_publisher publisher (fun state -> state.shell))
let tools_for_config config =
  Option.bind (publisher_for_config config) (fun publisher -> read_publisher publisher (fun state -> state.tools))
let telemetry_for_config config =
  Option.bind (publisher_for_config config) (fun publisher -> read_publisher publisher (fun state -> state.telemetry))

let update publisher change =
  let generated_at = Unix.gettimeofday () in
  Lockfree_atomic.update publisher.state (fun previous ->
    let next = change previous in
    match next.shell, next.tools, next.telemetry with
    | Some (shell, shell_light), Some tools, Some telemetry_summary ->
      {next with latest = Some { generated_at; base_path = publisher.config.base_path;
        workspace_path = publisher.config.workspace_path; masc_root = publisher.masc_root;
        shell; shell_light; tools; telemetry_summary }}
    | (None, _, _) | (_, None, _) | (_, _, None) -> next)
;;

let publish_shell publisher ~shell ~shell_light =
  update publisher (fun state -> {state with shell = Some (shell, shell_light)})
;;

let prepare_tools publisher json =
  {publisher; projection = make_tools_projection ~config:publisher.config json}
;;

let publish_tools {publisher; projection = tools} =
  update publisher (fun state -> {state with tools = Some tools})
;;

let publish_telemetry publisher json =
  update publisher (fun state -> {state with telemetry = Some json})
;;

let should_reuse_projection ~now ~ttl ~refreshed_at =
  let age = now -. refreshed_at in age >= 0.0 && age < ttl
;;

type activity_events_entry =
  { refreshed_at : float
  ; value : Yojson.Safe.t
  ; base_path : string
  ; workspace_path : string
  ; public_parents : Board_activity_access.proof
  }

type activity_events_cache = activity_events_entry option Atomic.t

let make_activity_events_cache () : activity_events_cache = Atomic.make None

let refresh_activity_events ~(config : Workspace.config) ~now ~ttl
    ~(cache : activity_events_cache) compute =
  let started_at = now () in
  let still_public entry =
    String.equal entry.base_path config.base_path
    && String.equal entry.workspace_path config.workspace_path
    && Board_activity_access.is_current entry.public_parents
  in
  match Atomic.get cache with
  | Some entry
    when should_reuse_projection
           ~now:started_at
           ~ttl
           ~refreshed_at:entry.refreshed_at
         && still_public entry ->
    entry.value
  | previous ->
    let reader = Board_activity_access.create () in
    (match compute ~keep:(Board_activity_access.keep reader) with
     | value ->
       Atomic.set cache (Some
         { refreshed_at = now (); value; base_path = config.base_path
         ; workspace_path = config.workspace_path
         ; public_parents = Board_activity_access.proof reader });
       value
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn ->
       (match previous with
        | Some entry when still_public entry -> entry.value
        | Some _ -> raise exn
        | None -> raise exn))
;;

let public_activity_cache = make_activity_events_cache ()
let public_activity_mutex = Cross_context_mutex.create ()

let public_activity_events config =
  Cross_context_mutex.with_lock public_activity_mutex (fun () ->
    refresh_activity_events ~config ~now:Unix.gettimeofday ~ttl:10.0
      ~cache:public_activity_cache (fun ~keep ->
        Activity_graph.recent_json_response config ~raw_limit:1000 ~keep ()))
;;

let invalidate_public_activity_events ~base_path =
  Lockfree_atomic.update public_activity_cache (function
    | Some entry -> if String.equal entry.base_path base_path then None else Some entry
    | None -> None)
;;

let make_for_test ~config ~shell ?(shell_light = `Null) ~tools ~telemetry_summary () =
  {generated_at = Unix.gettimeofday (); base_path = config.Workspace.base_path;
   workspace_path = config.workspace_path; masc_root = Workspace.masc_dir config;
   shell; shell_light; tools = make_tools_projection ~config tools; telemetry_summary}
;;

let publish_for_test (snapshot : t) =
  let config = { (Workspace.default_config snapshot.base_path) with
    workspace_path = snapshot.workspace_path } in
  let publisher = activate ~config ~is_current:(fun () -> true) in
  Atomic.set publisher.state {shell = Some (snapshot.shell, snapshot.shell_light);
    tools = Some snapshot.tools; telemetry = Some snapshot.telemetry_summary;
    latest = Some snapshot}
;;

let reset_for_test () = Atomic.set active None

module For_testing = struct
  type activity_cache = activity_events_cache
  let make_activity_cache = make_activity_events_cache
  let refresh_activity_events = refresh_activity_events
end
