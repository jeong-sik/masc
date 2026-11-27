module Owner = Server_dashboard_mission_observation
module Runtime = Server_dashboard_http_core_runtime
module Core_cache = Server_dashboard_http_core_cache

type request = {
  state : Mcp_server.server_state;
  scope : Mcp_server.workspace_scope;
  owner : Owner.owner;
  actor : string option;
}

let request ~state request =
  let scope = Mcp_server.workspace_scope state in
  let owner = Owner.owner_for_scope ~state scope in
  let actor = Server_auth.dashboard_actor_for_request ~base_path:scope.config.base_path request in
  {state; scope; owner; actor}

let cache ~state = Owner.cache (Owner.owner_for_scope ~state (Mcp_server.workspace_scope state))

let compute ~state ~(scope : Mcp_server.workspace_scope) ~sw ~clock ?actor () =
  let net, mono_clock = Runtime.state_dashboard_runtime_caps state in
  let started_at = Unix.gettimeofday () in
  Runtime.run_dashboard_compute ~mode:Server_dashboard_http_runtime_support.Offloaded_readonly
    ?net ?mono_clock ~sw ~clock ~config:scope.Mcp_server.config
    ~kind:Pool_work.Cpu ~name:__FUNCTION__ (fun ~config ~sw ->
      let observation = Dashboard_briefing.observe_current ?actor ~config ~sw ~clock
          ~proc_mgr:state.Mcp_server.proc_mgr () in
      {observation with json = Core_cache.with_projection_diagnostics
          ~surface:"mission" ~started_at ~extra:[] observation.json})

module Completions = Server_workspace_invalidation.Make (struct
  type t = unit
  let compare () () = 0
end)

let start ~state ~sw ~clock ~mono_clock =
  Server_observation_refresh.install_scoped ~state ~sw ~install:(fun ~scope ~sw ~is_current ->
    let owner = Owner.owner_for_scope ~state scope in
    let target = Sse.Scoped_runtime_observers (Sse.observer_scope
        ~runtime_authority:(Sse.runtime_authority_exn ~base_path:scope.config.base_path)
        ~instance_id:(Server_observer_scope.instance_id scope)) in
    let changes = Eio.Stream.create 1 in
    let changes_mu = Stdlib.Mutex.create () in
    let changed () = Stdlib.Mutex.protect changes_mu (fun () ->
      if Eio.Stream.is_empty changes then Eio.Stream.add changes ()) in
    let enqueue = ref (fun () -> ()) in
    let retain_if_superseded publication = match Owner.publication_status owner publication with
      | Owner.Superseded -> !enqueue ()
      | Current | Source_pending | Retired -> () in
    let publish () =
      let publication = Owner.publication owner in
      match Owner.publication_status owner publication with
      | Owner.Current ->
          let encoded = Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
            Sse_wire.encode_json (`Assoc ["type", `String "mission_snapshot";
              "payload", publication.json; "ts_unix", `Float (Time_compat.now ())])) in
          if is_current () && Owner.publication_is_current owner publication then (
            Sse.broadcast_encoded_to_with_receipts target
              ~on_fanout:(fun _ -> ()) ~on_committed:(fun _ -> ()) encoded;
            if Owner.publication_is_current owner publication then
              Server_workspace_health_line.observe ~base_path:scope.config.base_path publication.json)
          else retain_if_superseded publication
      | Superseded -> !enqueue ()
      | Source_pending | Retired -> () in
    let publish_owed = Completions.start ~sw ~mono_clock ~publish:(fun () -> publish ()) in
    enqueue := (fun () -> publish_owed ());
    let unsubscribe = Owner.subscribe_completed owner (fun completion ->
      (match completion with
       | Owner.Installed Default_request | Failed Default_request | Invalidated -> changed ()
       | Installed Source_read | Failed Source_read -> ());
      publish_owed ()) in
    Eio.Switch.on_release sw unsubscribe;
    Server_observation_input.subscribe ~sw ~base_path:scope.config.base_path
      ~observer_instance_id:(Server_observer_scope.instance_id scope) (fun input ->
        if Server_observation_refresh.affects Mission input then Owner.invalidate owner);
    (* A default HTTP fill may already own the cache when the source observer
       is installed; its canonical completion is still owed. *)
    publish_owed ();
    let latest_attempt = ref None in
    let interval_s = 120.0 in
    Proactive_refresh.start_on_change_or_deadline ~sw ~clock ~changes
      ~config:{(Proactive_refresh.default_config ~label:"mission" ~interval_s) with
        timeout_s = 60.0; warm_delay_s = 0.0; change_read_spacing_s = interval_s;
        on_failure = Some (fun failure ->
          if is_current () then Option.iter (fun attempt ->
            ignore (Owner.publish_failure_message attempt (Proactive_refresh.failure_message failure)))
            !latest_attempt)}
      ~compute:(fun () ->
        let attempt = Owner.begin_attempt owner ~origin:Source_read in
        latest_attempt := Some attempt;
        try
          let observation = compute ~state ~scope ~sw ~clock () in
          (* Install before returning: the reusable worker reads next_deadline
             before on_result. Own-success admission wins a closing window. *)
          ignore (Owner.publish_observation attempt observation);
          observation
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> ignore (Owner.publish_failure_message attempt (Printexc.to_string exn)); raise exn)
      ~on_result:(fun observation -> match observation.Dashboard_projection_read.completeness with
        | Complete -> () | Partial detail -> raise (Dashboard_projection_read.Incomplete_read detail))
      ~next_deadline:(fun _ -> Owner.next_deadline_unix owner))

let attest_instance context = function
  | `Assoc fields as json ->
    let instance_id = Server_observer_scope.instance_id context.scope in
    (match List.assoc_opt "observer_instance_id" fields with
     | Some (`String existing) when String.equal existing instance_id -> json
     | Some _ | None ->
       `Assoc (("observer_instance_id", `String instance_id)
         :: List.remove_assoc "observer_instance_id" fields))
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as json -> json

let default_json ~sw ~clock context =
  let owner = context.owner in
  let cached () =
    if Owner.has_terminal_answer owner
    then Some (Owner.snapshot_json_unobserved owner) else None in
  match cached () with
  | Some json -> json
  | None ->
      let key = "briefing:default:" ^ Owner.cache_identity owner in
      let attempted = ref None in
      let fail message = Option.iter (fun attempt ->
        ignore (Owner.publish_failure_message attempt message)) !attempted in
      let work = Pool_work.cpu ~name:__FUNCTION__ (fun () ->
        let attempt = Owner.begin_attempt owner ~origin:Default_request in
        attempted := Some attempt;
        try
          let observation = compute ~state:context.state ~scope:context.scope ~sw ~clock () in
          ignore (Owner.publish_observation attempt observation);
          Dashboard_projection_read.json_with_read_diagnostics observation
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> fail (Printexc.to_string exn); raise exn) in
      let json = Dashboard_cache.get_or_compute_with_timeout key
          ~ttl:Core_cache.deep_surface_cache_ttl_s ~clock
          ~timeout_sec:Core_cache.dashboard_briefing_timeout_s work in
      if Dashboard_cache.is_timeout_envelope json then (
        fail (Dashboard_cache.timeout_envelope_message ~kind:Dashboard_cache.Timeout_owner
          ~key ~timeout_sec:Core_cache.dashboard_briefing_timeout_s);
        attest_instance context json)
      else match cached () with
        | Some current -> current
        | None -> attest_instance context json

let actor_briefing_latest_key_mu = Stdlib.Mutex.create ()
let actor_briefing_latest_key : (string * string, string) Hashtbl.t = Hashtbl.create 16
let actor_briefing_latest_key_max = 128

let replace_actor_briefing_latest_key scope_actor key =
  Stdlib.Mutex.protect actor_briefing_latest_key_mu (fun () ->
    if Hashtbl.length actor_briefing_latest_key >= actor_briefing_latest_key_max
       && not (Hashtbl.mem actor_briefing_latest_key scope_actor)
    then Hashtbl.clear actor_briefing_latest_key;
    Hashtbl.replace actor_briefing_latest_key scope_actor key)

let raw_json ~sw ~clock context =
  match context.actor with
  | None -> default_json ~sw ~clock context
  | Some actor ->
      let scope_actor = Server_observer_scope.instance_id context.scope, actor in
      let key = "briefing:actor:" ^ Yojson.Safe.to_string (`List [
        `String (Owner.cache_identity context.owner); `String actor]) in
      (match
         Stdlib.Mutex.protect actor_briefing_latest_key_mu (fun () ->
           Hashtbl.find_opt actor_briefing_latest_key scope_actor)
       with
       | Some previous when not (String.equal previous key) ->
         Dashboard_cache.seed_stale_from_if_missing key ~from:previous
           ~stale_for:Core_cache.deep_surface_cache_ttl_s
       | Some _ | None -> ());
      let json =
        Dashboard_cache.get_or_compute_with_timeout key
          ~ttl:Core_cache.deep_surface_cache_ttl_s ~clock
          ~timeout_sec:Core_cache.dashboard_briefing_timeout_s
          (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
            let computed =
              compute ~state:context.state ~scope:context.scope ~sw ~clock ~actor ()
              |> Dashboard_projection_read.json_with_read_diagnostics
            in
            replace_actor_briefing_latest_key scope_actor key;
            computed))
      in
      if not (Dashboard_cache.is_timeout_envelope json) then
        Stdlib.Mutex.protect actor_briefing_latest_key_mu (fun () ->
          if not (Hashtbl.mem actor_briefing_latest_key scope_actor) then begin
            if Hashtbl.length actor_briefing_latest_key >= actor_briefing_latest_key_max then
              Hashtbl.clear actor_briefing_latest_key;
            Hashtbl.replace actor_briefing_latest_key scope_actor key
          end);
      json

let json ~sw ~clock context =
  raw_json ~sw ~clock context
  |> Dashboard_projection_cache.with_current_keeper_observations ~config:context.scope.config
  |> attest_instance context

type briefing_http_source =
  | Mission_snapshot of Server_dashboard_http_cache.surface_snapshot
  | Base_json of Yojson.Safe.t

let equal_briefing_http_source a b =
  match a, b with
  | Mission_snapshot left, Mission_snapshot right -> left == right
  | Base_json left, Base_json right -> left == right
  | Mission_snapshot _, Base_json _ | Base_json _, Mission_snapshot _ -> false

let snapshot_is_stale (s : Server_dashboard_http_cache.surface_snapshot) =
  match s.last_success_unix, s.last_error_unix with
  | Some success_ts, Some error_ts -> error_ts > success_ts
  | Some _, None | None, (Some _ | None) -> false

type cached_briefing_http = {
  br_source : briefing_http_source;
  br_observed_json : Yojson.Safe.t;
  br_prepared : Server_cached_read_http.prepared_http;
}

let briefing_http_cache_mu = Stdlib.Mutex.create ()
let briefing_http_cache : (string * string option, cached_briefing_http) Hashtbl.t =
  Hashtbl.create 8
let briefing_http_cache_max = 16

let prepare_briefing_from_source ~key ~context ~cacheable ~source ~render_base =
  let cached =
    if cacheable then
      Stdlib.Mutex.protect briefing_http_cache_mu (fun () ->
        Hashtbl.find_opt briefing_http_cache key)
    else None
  in
  let reused, observed =
    match cached with
    | Some entry when equal_briefing_http_source entry.br_source source ->
      let observed =
        entry.br_observed_json
        |> Dashboard_projection_cache.with_current_keeper_observations
             ~config:context.scope.config
        |> attest_instance context
      in
      if observed == entry.br_observed_json
      then Some entry.br_prepared, observed
      else None, observed
    | Some _ | None ->
      let observed =
        render_base ()
        |> Dashboard_projection_cache.with_current_keeper_observations
             ~config:context.scope.config
        |> attest_instance context
      in
      None, observed
  in
  match reused with
  | Some prepared -> prepared
  | None ->
    let prepared =
      Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
        Server_cached_read_http.prepare_json observed)
    in
    if cacheable && not (Dashboard_cache.is_timeout_envelope observed) then
      Stdlib.Mutex.protect briefing_http_cache_mu (fun () ->
        if Hashtbl.length briefing_http_cache >= briefing_http_cache_max
           && not (Hashtbl.mem briefing_http_cache key)
        then Hashtbl.clear briefing_http_cache;
        Hashtbl.replace briefing_http_cache key
          { br_source = source
          ; br_observed_json = observed
          ; br_prepared = prepared
          });
    prepared

let prepared ~sw ~clock context =
  let key = Server_observer_scope.instance_id context.scope, context.actor in
  match context.actor with
  | None when Owner.has_terminal_answer context.owner ->
    let snapshot = Owner.snapshot_unobserved context.owner in
    let cacheable = not (snapshot_is_stale snapshot) in
    prepare_briefing_from_source
      ~key
      ~context
      ~cacheable
      ~source:(Mission_snapshot snapshot)
      ~render_base:(fun () ->
        Server_dashboard_http_cache.surface_snapshot_json
          ~now:(Unix.gettimeofday ()) snapshot)
  | None | Some _ ->
    Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
      let base_json = raw_json ~sw ~clock context in
      prepare_briefing_from_source
        ~key
        ~context
        ~cacheable:true
        ~source:(Base_json base_json)
        ~render_base:(fun () -> base_json))

let health_line ~sw ~clock context =
  default_json ~sw ~clock context
  |> Dashboard_projection_cache.with_current_keeper_observations ~config:context.scope.config
  |> Server_workspace_health_line.of_briefing
  |> attest_instance context
