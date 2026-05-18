type health_state =
  | Healthy
  | Unhealthy of
      { since : float
      ; consecutive_failures : int
      }

type provider =
  { provider_id : string
  ; endpoint : string option
  ; probe_interval_seconds : int
  ; unhealthy_threshold : int
  ; recovery_threshold : int
  ; mu : Eio.Mutex.t
  ; mutable state : health_state
  ; mutable consecutive_failures : int
  ; mutable consecutive_successes : int
  }

type t = { providers : (string, provider) Hashtbl.t }

let active_ref : t option Atomic.t = Atomic.make None
let set_active t = Atomic.set active_ref (Some t)
let active () = Atomic.get active_ref

let clamp_probe_interval seconds =
  if seconds < 60 then 60 else seconds
;;

let make_provider
    ~provider_id
    ?endpoint
    ~probe_interval_seconds
    ~unhealthy_threshold
    ~recovery_threshold
    ()
  =
  { provider_id
  ; endpoint
  ; probe_interval_seconds = clamp_probe_interval probe_interval_seconds
  ; unhealthy_threshold = max 1 unhealthy_threshold
  ; recovery_threshold = max 1 recovery_threshold
  ; mu = Eio.Mutex.create ()
  ; state = Healthy
  ; consecutive_failures = 0
  ; consecutive_successes = 0
  }
;;

let create_from_providers providers =
  let table = Hashtbl.create (List.length providers) in
  List.iter (fun provider -> Hashtbl.replace table provider.provider_id provider) providers;
  { providers = table }
;;

let provider_of_decl
    (decl : Cascade_declarative_types.cascade_provider)
    (healthcheck : Cascade_declarative_types.cascade_provider_healthcheck)
  =
  if not healthcheck.enabled then None
  else
    Some
      (make_provider
         ~provider_id:decl.id
         ?endpoint:healthcheck.endpoint
         ~probe_interval_seconds:healthcheck.probe_interval_seconds
         ~unhealthy_threshold:healthcheck.unhealthy_threshold
         ~recovery_threshold:healthcheck.recovery_threshold
         ())
;;

let config_path_for_coord (config : Coord.config) =
  let inputs = Config_dir_resolver.inputs_from_env () in
  let resolution =
    Config_dir_resolver.resolve_with
      { inputs with env_base_path = Some config.base_path }
  in
  if resolution.Config_dir_resolver.cascade_authoring.exists then
    Some resolution.cascade_authoring.path
  else
    None
;;

let create config =
  match config_path_for_coord config with
  | None -> create_from_providers []
  | Some path ->
    (match Cascade_declarative_parser.parse_file path with
     | Error errs ->
       Log.Cascade.warn
         "[provider-health] cascade.toml parse failed; probes disabled: %s"
         (errs
          |> List.map (fun (err : Cascade_declarative_parser.parse_error) ->
                 Printf.sprintf "%s: %s" err.path err.message)
          |> String.concat "; ");
       create_from_providers []
     | Ok cfg ->
       cfg.providers
       |> List.filter_map (fun provider ->
              Option.bind provider.Cascade_declarative_types.healthcheck
                (provider_of_decl provider))
       |> create_from_providers)
;;

let key_prefix key =
  match String.index_opt key ':' with
  | Some idx -> String.sub key 0 idx
  | None ->
    (match String.index_opt key '@' with
     | Some idx -> String.sub key 0 idx
     | None -> key)
;;

let swapped_key key =
  String.map
    (function
      | '-' -> '_'
      | '_' -> '-'
      | ch -> ch)
    key
;;

let find_provider t provider_id =
  let prefix = key_prefix provider_id in
  [ provider_id; prefix; swapped_key provider_id; swapped_key prefix ]
  |> List.find_map (fun key -> Hashtbl.find_opt t.providers key)
;;

let transition provider ~success =
  Eio.Mutex.use_rw ~protect:true provider.mu (fun () ->
    if success then begin
      provider.consecutive_failures <- 0;
      provider.consecutive_successes <- provider.consecutive_successes + 1;
      match provider.state with
      | Healthy -> ()
      | Unhealthy _
        when provider.consecutive_successes >= provider.recovery_threshold ->
        provider.state <- Healthy
      | Unhealthy _ -> ()
    end else begin
      provider.consecutive_successes <- 0;
      provider.consecutive_failures <- provider.consecutive_failures + 1;
      if provider.consecutive_failures >= provider.unhealthy_threshold then begin
        (* P2 review finding: preserve first-failure timestamp across
           repeated failures so outage age (snapshot.since) measures the
           true Healthy→Unhealthy transition instant, not the most recent
           failure. Without this, dashboards and time-based thresholds
           reset on every failure and never reach their cutoff. *)
        let since =
          match provider.state with
          | Unhealthy { since; _ } -> since
          | Healthy ->
            Unix.gettimeofday ()
            (* NDT-OK: external probe observation time stamps the first
               Healthy→Unhealthy transition; deterministic logic depends
               on counters. *)
        in
        provider.state
        <- Unhealthy
             { since; consecutive_failures = provider.consecutive_failures }
      end
    end)
;;

let is_healthy t ~provider_id =
  match find_provider t provider_id with
  | None -> true
  | Some provider ->
    Eio.Mutex.use_rw ~protect:true provider.mu (fun () ->
      match provider.state with
      | Healthy -> true
      | Unhealthy _ -> false)
;;

let record_attempt_result t ~provider_id ~success ~http_status:_ =
  match find_provider t provider_id with
  | None -> ()
  | Some provider -> transition provider ~success
;;

let snapshot t =
  Hashtbl.fold
    (fun provider_id provider acc ->
       let state =
         Eio.Mutex.use_rw ~protect:true provider.mu (fun () -> provider.state)
       in
       (provider_id, state) :: acc)
    t.providers
    []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
;;

let filter_healthy t ~provider_id candidates =
  let filtered =
    List.filter
      (fun candidate -> is_healthy t ~provider_id:(provider_id candidate))
      candidates
  in
  match filtered with
  | [] -> candidates
  | _ -> filtered
;;

let probe_once ~clock ~net:_ provider =
  match provider.endpoint with
  | None -> ()
  | Some endpoint ->
    (match
       Masc_http_client.get_response_sync
         ~clock
         ~timeout_sec:5.0
         ~url:endpoint
         ~headers:[ "accept", "application/json" ]
         ()
     with
     | Ok response ->
       transition provider ~success:(response.Masc_http_client.status >= 200
                                     && response.status < 300)
     | Error message ->
       Log.Cascade.warn
         "[provider-health] probe failed provider=%s endpoint=%s error=%s"
         provider.provider_id
         endpoint
         message;
       transition provider ~success:false)
;;

let start_probe_fiber ~sw ~env t =
  let running = Atomic.make true in
  Eio.Switch.on_release sw (fun () -> Atomic.set running false);
  let clock = Eio.Stdenv.clock env in
  let net = Eio.Stdenv.net env in
  Hashtbl.iter
    (fun _ provider ->
       match provider.endpoint with
       | None ->
         Log.Cascade.warn
           "[provider-health] provider=%s has enabled healthcheck without endpoint; \
            probe fiber not started"
           provider.provider_id
       | Some _ ->
         Eio.Fiber.fork ~sw (fun () ->
           while Atomic.get running do
             (try probe_once ~clock ~net provider with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn ->
                Log.Cascade.warn
                  "[provider-health] probe raised provider=%s error=%s"
                  provider.provider_id
                  (Printexc.to_string exn);
                transition provider ~success:false);
             Eio.Time.sleep clock (float_of_int provider.probe_interval_seconds)
           done))
    t.providers
;;

module For_testing = struct
  type nonrec provider =
    { provider_id : string
    ; endpoint : string option
    ; probe_interval_seconds : int
    ; unhealthy_threshold : int
    ; recovery_threshold : int
    }

  let create providers =
    let make_for_test provider =
      { provider_id = provider.provider_id
      ; endpoint = provider.endpoint
      ; probe_interval_seconds = max 1 provider.probe_interval_seconds
      ; unhealthy_threshold = max 1 provider.unhealthy_threshold
      ; recovery_threshold = max 1 provider.recovery_threshold
      ; mu = Eio.Mutex.create ()
      ; state = Healthy
      ; consecutive_failures = 0
      ; consecutive_successes = 0
      }
    in
    providers |> List.map make_for_test |> create_from_providers
  ;;

  let clear_active () = Atomic.set active_ref None
end
