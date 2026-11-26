module Http = Http_server_eio
module Env = Server_dashboard_http_v2_envelope
module Sandbox_profile = Keeper_types_profile_sandbox

type probe_state =
  | Probe_fresh
  | Probe_warming
  | Probe_stale
  | Probe_error of string

let probe_state_to_string = function
  | Probe_fresh -> "fresh"
  | Probe_warming -> "warming"
  | Probe_stale -> "stale"
  | Probe_error _ -> "error"
;;

type shim_parity =
  | Shim_matched of { build_identity : string }
  | Shim_mismatch of { shim : string; server : string option }
  | Shim_undeclared
  | Shim_unavailable of string

let check_shim_parity ~base_path =
  let dir = Config_dir_resolver.microvm_shim_dir ~base_path in
  match Keeper_sandbox_microvm.inspect_shim ~dir with
  | Error msg -> Shim_unavailable msg
  | Ok inspection ->
    (match inspection.source, Source_identity.current with
     | Source_identity.Declared shim_id, Some srv_id ->
       if Source_identity.equal shim_id srv_id
       then Shim_matched { build_identity = Source_identity.to_string shim_id }
       else
         Shim_mismatch
           { shim = Source_identity.to_string shim_id
           ; server = Some (Source_identity.to_string srv_id)
           }
     | Source_identity.Declared shim_id, None ->
       Shim_mismatch { shim = Source_identity.to_string shim_id; server = None }
     | Source_identity.Undeclared, _ -> Shim_undeclared
     | Source_identity.Several ids, srv_opt ->
       let shim_desc =
         ids |> List.map Source_identity.to_string |> String.concat ","
       in
       Shim_mismatch
         { shim = shim_desc
         ; server = Option.map Source_identity.to_string srv_opt
         })
;;

let shim_parity_to_json = function
  | Shim_matched { build_identity } ->
    `Assoc [ "status", `String "matched"; "build_identity", `String build_identity ]
  | Shim_mismatch { shim; server } ->
    `Assoc
      [ "status", `String "mismatch"
      ; "shim_identity", `String shim
      ; "server_identity", Json_util.string_opt_to_json server
      ]
  | Shim_undeclared -> `Assoc [ "status", `String "undeclared" ]
  | Shim_unavailable detail ->
    `Assoc [ "status", `String "unavailable"; "detail", `String detail ]
;;

type guest_presence =
  | Guest_probe_pending
  | Guest_present
  | Guest_absent
  | Guest_unavailable

let guest_presence_to_string = function
  | Guest_probe_pending -> "probe_pending"
  | Guest_present -> "present"
  | Guest_absent -> "absent"
  | Guest_unavailable -> "unavailable"
;;

type ssh_reachability =
  | Ssh_probe_pending
  | Ssh_reachable of { rtt_ms : float; measured_at : float }
  | Ssh_unreachable of { detail : string; measured_at : float }

let ssh_reachability_to_json = function
  | Ssh_probe_pending -> `Assoc [ "status", `String "probe_pending" ]
  | Ssh_reachable { rtt_ms; measured_at } ->
    `Assoc
      [ "status", `String "reachable"
      ; "rtt_ms", `Float rtt_ms
      ; "measured_at_unix", `Float measured_at
      ]
  | Ssh_unreachable { detail; measured_at } ->
    `Assoc
      [ "status", `String "unreachable"
      ; "detail", `String detail
      ; "measured_at_unix", `Float measured_at
      ]
;;

let failure_classes_to_json (fc : Tool_metrics_series.failure_class_counts) =
  `Assoc
    [ "dependency_unavailable", `Int fc.dependency_unavailable
    ; "runtime_failure", `Int fc.runtime_failure
    ; "policy_rejection", `Int fc.policy_rejection
    ; "workflow_rejection", `Int fc.workflow_rejection
    ; "operator_cancelled", `Int fc.operator_cancelled
    ]
;;

let stat_to_json (st : Tool_metrics_series.stat) =
  `Assoc
    [ "calls", `Int st.call_count
    ; "failures", `Int st.failure_count
    ; "failure_unclassified", `Int st.failure_unclassified_count
    ; "p50_ms", Json_util.float_opt_to_json st.p50_ms
    ; "p95_ms", Json_util.float_opt_to_json st.p95_ms
    ; "max_ms", Json_util.float_opt_to_json st.max_ms
    ; "failure_classes", failure_classes_to_json st.failure_classes
    ]
;;

let empty_failure_classes : Tool_metrics_series.failure_class_counts =
  { dependency_unavailable = 0
  ; policy_rejection = 0
  ; runtime_failure = 0
  ; workflow_rejection = 0
  ; operator_cancelled = 0
  }
;;

let empty_stat_json =
  `Assoc
    [ "calls", `Int 0
    ; "failures", `Int 0
    ; "failure_unclassified", `Int 0
    ; "p50_ms", `Null
    ; "p95_ms", `Null
    ; "max_ms", `Null
    ; "failure_classes", failure_classes_to_json empty_failure_classes
    ]
;;

let combine_caller_stats (stats : Tool_metrics_series.stat list) =
  let calls = ref 0 in
  let failures = ref 0 in
  let unclassified = ref 0 in
  let dep_unavail = ref 0 in
  let runtime_fail = ref 0 in
  let policy_rej = ref 0 in
  let workflow_rej = ref 0 in
  let op_cancel = ref 0 in
  let max_p95 = ref None in
  List.iter
    (fun (st : Tool_metrics_series.stat) ->
       calls := !calls + st.call_count;
       failures := !failures + st.failure_count;
       unclassified := !unclassified + st.failure_unclassified_count;
       dep_unavail := !dep_unavail + st.failure_classes.dependency_unavailable;
       runtime_fail := !runtime_fail + st.failure_classes.runtime_failure;
       policy_rej := !policy_rej + st.failure_classes.policy_rejection;
       workflow_rej := !workflow_rej + st.failure_classes.workflow_rejection;
       op_cancel := !op_cancel + st.failure_classes.operator_cancelled;
       match st.p95_ms, !max_p95 with
       | Some p, None -> max_p95 := Some p
       | Some p, Some prev when Float.compare p prev > 0 -> max_p95 := Some p
       | _ -> ())
    stats;
  `Assoc
    [ "calls", `Int !calls
    ; "failures", `Int !failures
    ; "failure_unclassified", `Int !unclassified
    ; "p95_ms", Json_util.float_opt_to_json !max_p95
    ; ( "failure_classes"
      , `Assoc
          [ "dependency_unavailable", `Int !dep_unavail
          ; "runtime_failure", `Int !runtime_fail
          ; "policy_rejection", `Int !policy_rej
          ; "workflow_rejection", `Int !workflow_rej
          ; "operator_cancelled", `Int !op_cancel
          ] )
    ]
;;

let socket_status_json ~host_socket =
  match Fs_compat.exact_path_kind ~follow:false host_socket with
  | Fs_compat.Exact_kind Unix.S_SOCK ->
    `Assoc
      [ "status", `String "socket_present"
      ; "exists", `Bool true
      ; "path_basename", `String (Filename.basename host_socket)
      ]
  | Fs_compat.Exact_missing ->
    `Assoc
      [ "status", `String "socket_absent"
      ; "exists", `Bool false
      ; "path_basename", `String (Filename.basename host_socket)
      ]
  | Fs_compat.Exact_kind
      ((Unix.S_REG | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO) as kind) ->
    `Assoc
      [ "status", `String "non_socket"
      ; "exists", `Bool true
      ; "file_kind", `String (Fs_compat.file_kind_to_string kind)
      ]
  | Fs_compat.Exact_unknown ->
    `Assoc [ "status", `String "unreadable"; "exists", `Bool false ]
;;

let probe_report_to_json (report : Keeper_sandbox_remote.probe_report) =
  match report with
  | Keeper_sandbox_remote.Probe_not_asked ->
    `Assoc [ "status", `String "not_asked" ]
  | Keeper_sandbox_remote.Probe_answered
      { major; capabilities; release; observed_at; boot } ->
    let boot_change_str =
      match boot.change with
      | Keeper_sandbox_remote.Boot_unreported -> "unreported"
      | Keeper_sandbox_remote.Boot_first -> "first"
      | Keeper_sandbox_remote.Boot_unchanged -> "unchanged"
      | Keeper_sandbox_remote.Boot_changed -> "changed"
    in
    `Assoc
      [ "status", `String "answered"
      ; "protocol_major", `Int (Exec_ssh_protocol.int_of_major major)
      ; "release", Json_util.string_opt_to_json release
      ; "capabilities", `List (List.map (fun s -> `String s) capabilities)
      ; "observed_at_unix", `Float observed_at
      ; "boot_change", `String boot_change_str
      ]
  | Keeper_sandbox_remote.Probe_failed { at; detail } ->
    `Assoc
      [ "status", `String "failed"
      ; "at_unix", `Float at
      ; "detail", `String detail
      ]
;;

let dispatch_record_to_json = function
  | None -> `Null
  | Some (Keeper_sandbox_remote.Payload_finished { at; status }) ->
    let status_str, code =
      match status with
      | Unix.WEXITED n -> "exited", Some n
      | Unix.WSIGNALED n -> "signaled", Some n
      | Unix.WSTOPPED n -> "stopped", Some n
    in
    `Assoc
      [ "kind", `String "payload_finished"
      ; "at_unix", `Float at
      ; "process_status", `String status_str
      ; "code", Json_util.int_opt_to_json code
      ]
  | Some (Keeper_sandbox_remote.Dispatch_failed { at; failure; detail }) ->
    let failure_str =
      match failure with
      | Keeper_sandbox_remote.Local_timeout -> "local_timeout"
      | Keeper_sandbox_remote.Remote_timeout -> "remote_timeout"
      | Keeper_sandbox_remote.Transport_failed -> "transport_failed"
      | Keeper_sandbox_remote.Shim_refused -> "shim_refused"
      | Keeper_sandbox_remote.Trailer_disagreement -> "trailer_disagreement"
    in
    `Assoc
      [ "kind", `String "dispatch_failed"
      ; "at_unix", `Float at
      ; "failure", `String failure_str
      ; "detail", `String detail
      ]
;;

let build_snapshot_json
      ?(now = Time_compat.now ())
      ?(probe_state = Probe_warming)
      ?(apple_inventory = None)
      ?(ssh_reachability = [])
      ?(tool_series = None)
      ~base_path
      ()
  =
  let masc_root = Config_dir_resolver.masc_root ~base_path in
  let snapshot = Keeper_types_profile.read_keeper_profile_snapshot ~base_path in
  let keeper_names = Keeper_types_profile.snapshot_configured_keeper_names snapshot in
  let shim_parity = check_shim_parity ~base_path in
  let shim_parity_json = shim_parity_to_json shim_parity in
  let shim_mismatch_flag =
    match shim_parity with
    | Shim_mismatch _ -> true
    | Shim_matched _ | Shim_undeclared | Shim_unavailable _ -> false
  in
  let unobserved = ref [] in
  let add_unobserved scope reason =
    unobserved := `Assoc [ "scope", `String scope; "reason", `String reason ] :: !unobserved
  in
  (* Index 24h tool metrics by caller *)
  let caller_metrics_tbl = Hashtbl.create 32 in
  let fleet_tool_metrics_json =
    match tool_series with
    | None -> empty_stat_json
    | Some (Error msg) ->
      add_unobserved "tool_metrics" msg;
      empty_stat_json
    | Some (Ok (series : Tool_metrics_series.t)) ->
      List.iter
        (fun (cu : Tool_metrics_series.caller_usage) ->
           Hashtbl.replace caller_metrics_tbl cu.caller cu.usage)
        series.Tool_metrics_series.by_caller;
      stat_to_json series.Tool_metrics_series.total
  in
  let metrics_for_keeper name =
    match Hashtbl.find_opt caller_metrics_tbl name with
    | Some st -> stat_to_json st
    | None -> empty_stat_json
  in
  (* Apple inventory lookup *)
  let apple_presence_for ~guest_name =
    match apple_inventory with
    | None -> Guest_probe_pending
    | Some (Error _) -> Guest_unavailable
    | Some (Ok inv) ->
      (match Keeper_microvm_guest_inventory.presence ~guest_name inv with
       | Ok Keeper_microvm_guest_inventory.Present -> Guest_present
       | Ok Keeper_microvm_guest_inventory.Absent -> Guest_absent
       | Error _ -> Guest_unavailable)
  in
  (match apple_inventory with
   | Some (Error detail) -> add_unobserved "apple_container" detail
   | Some (Ok _) | None -> ());
  let microvm_guests = ref [] in
  let docker_keepers = ref [] in
  let ssh_keepers_by_endpoint : (string, string list) Hashtbl.t = Hashtbl.create 8 in
  let ssh_keepers_unbound = ref [] in
  let microvm_running = ref 0 in
  let microvm_socket_present = ref 0 in
  List.iter
    (fun keeper_name ->
       match Keeper_types_profile.snapshot_profile_defaults snapshot keeper_name with
       | Error err ->
         add_unobserved
           ("keeper:" ^ keeper_name)
           (Keeper_types_profile.keeper_toml_load_error_to_string err)
       | Ok defaults ->
         let profile =
           match defaults.sandbox_profile with
           | Some p -> p
           | None -> Sandbox_profile.Docker
         in
         let net_mode =
           match defaults.network_mode with
           | Some m -> m
           | None -> Sandbox_profile.default_network_mode_for_profile profile
         in
         (match profile with
          | Sandbox_profile.Micro_vm ->
            let backend =
              match defaults.microvm_backend with
              | Some b -> Some b
              | None -> Keeper_microvm_backend.default_for_host ()
            in
            let backend_str =
              match backend with
              | Some b -> Keeper_microvm_backend.to_string b
              | None -> "unresolved"
            in
            let guest_name =
              Keeper_sandbox_container_name.make
                (Keeper_sandbox_container_name.Micro_vm_persistent
                   { keeper_name; network_mode = net_mode; base_path })
              |> Keeper_sandbox_container_name.to_string
            in
            let host_socket =
              Keeper_microvm_agent_socket.host_path ~base_path ~guest_name
            in
            let sock_kind = Fs_compat.exact_path_kind ~follow:false host_socket in
            if sock_kind = Fs_compat.Exact_kind Unix.S_SOCK
            then incr microvm_socket_present;
            let presence = apple_presence_for ~guest_name in
            (match presence with
             | Guest_present -> incr microvm_running
             | Guest_probe_pending | Guest_absent | Guest_unavailable -> ());
            let work_vol_json =
              match Keeper_sandbox_microvm.work_volume_name ~keeper_name with
              | Ok vname -> `Assoc [ "name", `String vname; "status", `String "declared" ]
              | Error msg -> `Assoc [ "name", `Null; "status", `String "invalid"; "detail", `String msg ]
            in
            let cpus_json =
              match defaults.microvm_cpus with
              | Some c -> `Int (Keeper_microvm_guest_size.cpus_count c)
              | None -> `Null
            in
            let mem_json =
              match defaults.microvm_memory with
              | Some m -> `Int (Keeper_microvm_guest_size.memory_mib m)
              | None -> `Null
            in
            let row =
              `Assoc
                [ "keeper", `String keeper_name
                ; "backend", `String backend_str
                ; "guest_name", `String guest_name
                ; "presence", `String (guest_presence_to_string presence)
                ; "agent_socket", socket_status_json ~host_socket
                ; "shim_parity", shim_parity_json
                ; "network_mode", `String (Sandbox_profile.network_mode_to_string net_mode)
                ; "guest_size", `Assoc [ "cpus", cpus_json; "memory_mib", mem_json ]
                ; "volume", work_vol_json
                ; "tool_metrics_24h", metrics_for_keeper keeper_name
                ]
            in
            microvm_guests := row :: !microvm_guests
          | Sandbox_profile.Remote_ssh ->
            (match defaults.remote_endpoint with
             | Some ep ->
               let prev =
                 match Hashtbl.find_opt ssh_keepers_by_endpoint ep with
                 | Some lst -> lst
                 | None -> []
               in
               Hashtbl.replace ssh_keepers_by_endpoint ep (keeper_name :: prev)
             | None -> ssh_keepers_unbound := keeper_name :: !ssh_keepers_unbound)
          | Sandbox_profile.Docker ->
            docker_keepers
            := `Assoc
                 [ "keeper", `String keeper_name
                 ; "backend", `String "docker"
                 ; "network_mode", `String (Sandbox_profile.network_mode_to_string net_mode)
                 ; "tool_metrics_24h", metrics_for_keeper keeper_name
                 ]
               :: !docker_keepers))
    keeper_names;
  (* Build SSH pools from configured endpoints *)
  let ssh_pools_json, ssh_total_max, ssh_total_keepers =
    match Keeper_sandbox_ssh.configured_endpoints ~base_path with
    | Error detail ->
      add_unobserved "remote_ssh_endpoints" detail;
      [], 0, 0
    | Ok endpoints ->
      let total_max = ref 0 in
      let total_keepers = ref 0 in
      let pools =
        List.map
          (fun (ep : Exec_ssh_endpoint.t) ->
             total_max := !total_max + ep.max_concurrent_sessions;
             let assigned_keepers =
               match Hashtbl.find_opt ssh_keepers_by_endpoint ep.name with
               | Some lst -> List.sort String.compare lst
               | None -> []
             in
             total_keepers := !total_keepers + List.length assigned_keepers;
             let openssh =
               Keeper_sandbox_ssh.openssh_configuration ~base_path ~endpoint:ep ()
             in
             let ep_report =
               Keeper_sandbox_remote.report_openssh
                 ~scope:Keeper_sandbox_remote.Endpoint_dispatch
                 ~base_path
                 openssh
             in
             let reach =
               match List.assoc_opt ep.name ssh_reachability with
               | Some r -> r
               | None -> Ssh_probe_pending
             in
             let keeper_sessions =
               List.map
                 (fun k ->
                    let k_report =
                      Keeper_sandbox_remote.report_openssh
                        ~scope:(Keeper_sandbox_remote.Keeper_dispatch k)
                        ~base_path
                        openssh
                    in
                    `Assoc
                      [ "keeper", `String k
                      ; "last_dispatch", dispatch_record_to_json k_report.last_dispatch
                      ; "tool_metrics_24h", metrics_for_keeper k
                      ])
                 assigned_keepers
             in
             let pool_stats =
               assigned_keepers
               |> List.filter_map (Hashtbl.find_opt caller_metrics_tbl)
               |> combine_caller_stats
             in
             `Assoc
               [ "pool_name", `String ep.name
               ; "host", `String ep.host
               ; "port", `Int ep.port
               ; "unix_user", `String ep.user
               ; "remote_root", `String ep.remote_root
               ; "private_home", `Bool ep.private_home
               ; "max_sessions", `Int ep.max_concurrent_sessions
               ; "active_sessions", `Null
               ; "reachability", ssh_reachability_to_json reach
               ; "shim_probe", probe_report_to_json ep_report.probe
               ; "last_dispatch", dispatch_record_to_json ep_report.last_dispatch
               ; ( "accounts"
                 , `List
                     [ `Assoc
                         [ "unix_user", `String ep.user
                         ; "active_sessions", `Null
                         ; "max_sessions", `Int ep.max_concurrent_sessions
                         ; "keepers", `List (List.map (fun k -> `String k) assigned_keepers)
                         ]
                     ] )
               ; "keeper_sessions", `List keeper_sessions
               ; "tool_metrics_24h", pool_stats
               ])
          endpoints
      in
      pools, !total_max, !total_keepers
  in
  let ssh_unbound_list =
    !ssh_keepers_unbound
    |> List.sort String.compare
    |> List.map (fun k ->
         `Assoc
           [ "keeper", `String k
           ; "backend", `String "remote_ssh"
           ; "binding_state", `String "unbound"
           ; "remote_endpoint", `Null
           ; "tool_metrics_24h", metrics_for_keeper k
           ])
  in
  if ssh_pools_json <> [] || ssh_unbound_list <> []
  then add_unobserved "remote_ssh_sessions" "ssh_active_sessions_unreported";
  let microvm_list = List.rev !microvm_guests in
  let docker_list = List.rev !docker_keepers in
  let volume_gc_json = Server_sandbox_volume_gc_report.envelope_json ~base_path () in
  let disk_json = Keeper_disk_pressure.snapshot_json ~masc_root () in
  let probe_state_json =
    let base =
      [ "kind", `String (probe_state_to_string probe_state)
      ; "measured_at_unix", `Float now
      ]
    in
    match probe_state with
    | Probe_error detail -> `Assoc (base @ [ "error", `String detail ])
    | Probe_fresh | Probe_warming | Probe_stale -> `Assoc base
  in
  let data =
    `Assoc
      [ "probe_state", probe_state_json
      ; ( "summary"
        , `Assoc
            [ "microvm_declared", `Int (List.length microvm_list)
            ; "microvm_running", `Int !microvm_running
            ; "microvm_sockets_present", `Int !microvm_socket_present
            ; ( "microvm_shim_mismatch"
              , `Int (if shim_mismatch_flag then List.length microvm_list else 0) )
            ; "ssh_pools", `Int (List.length ssh_pools_json)
            ; "ssh_keepers", `Int ssh_total_keepers
            ; "ssh_unbound_keepers", `Int (List.length ssh_unbound_list)
            ; "ssh_active_sessions", `Null
            ; "ssh_max_sessions", `Int ssh_total_max
            ; "docker_keepers", `Int (List.length docker_list)
            ] )
      ; "shim_parity", shim_parity_json
      ; "microvm_guests", `List microvm_list
      ; "ssh_pools", `List ssh_pools_json
      ; "ssh_unbound_keepers", `List ssh_unbound_list
      ; "docker_keepers", `List docker_list
      ; "volume_gc_report", volume_gc_json
      ; "host_storage", disk_json
      ; "tool_metrics_24h", fleet_tool_metrics_json
      ; "unobserved_reasons", `List (List.rev !unobserved)
      ]
  in
  Env.ok ~now data
;;

(* Process-local non-blocking cache per base_path *)
type cache_entry =
  { mutable snapshot : Yojson.Safe.t
  ; mutable measured_at : float
  ; mutable refreshing : bool
  }

let cache_ttl_sec = 15.0
let cache_mu = Stdlib.Mutex.create ()
let cache_tbl : (string, cache_entry) Hashtbl.t = Hashtbl.create 4

let clear_cache_for_testing () =
  Stdlib.Mutex.protect cache_mu (fun () -> Hashtbl.clear cache_tbl)
;;

let probe_tcp_rtt ~host ~port ~timeout_sec =
  let started = Unix.gettimeofday () in
  let check () =
    match Unix.getaddrinfo host (string_of_int port) [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ] with
    | [] -> Ssh_unreachable { detail = "host resolution returned no addresses"; measured_at = Unix.gettimeofday () }
    | ai :: _ ->
      let fd = Unix.socket ai.ai_family ai.ai_socktype ai.ai_protocol in
      Fun.protect
        ~finally:(fun () ->
          try Unix.close fd with Unix.Unix_error _ -> ())
        (fun () ->
          Unix.set_nonblock fd;
          let connect_started =
            try
              Unix.connect fd ai.ai_addr;
              `Connected
            with
            | Unix.Unix_error ((Unix.EINPROGRESS | Unix.EWOULDBLOCK | Unix.EAGAIN), _, _) ->
              `Pending
            | Unix.Unix_error (err, _, _) ->
              `Failed (Unix.error_message err)
          in
          match connect_started with
          | `Connected ->
            let rtt_ms = (Unix.gettimeofday () -. started) *. 1000.0 in
            Ssh_reachable { rtt_ms; measured_at = Unix.gettimeofday () }
          | `Failed msg ->
            Ssh_unreachable { detail = msg; measured_at = Unix.gettimeofday () }
          | `Pending ->
            let _, writable, _ = Unix.select [] [ fd ] [] timeout_sec in
            if writable = []
            then
              Ssh_unreachable
                { detail = Printf.sprintf "TCP connect timed out after %.1fs" timeout_sec
                ; measured_at = Unix.gettimeofday ()
                }
            else (
              match Unix.getsockopt_error fd with
              | None ->
                let rtt_ms = (Unix.gettimeofday () -. started) *. 1000.0 in
                Ssh_reachable { rtt_ms; measured_at = Unix.gettimeofday () }
              | Some err ->
                Ssh_unreachable
                  { detail = Unix.error_message err
                  ; measured_at = Unix.gettimeofday ()
                  }))
  in
  try check () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Unix.Unix_error (err, op, _) ->
    Ssh_unreachable
      { detail = Printf.sprintf "%s: %s" op (Unix.error_message err)
      ; measured_at = Unix.gettimeofday ()
      }
  | exn ->
    Ssh_unreachable
      { detail = Printexc.to_string exn; measured_at = Unix.gettimeofday () }
;;

let read_24h_tool_series ~now ~base_path =
  let masc_root = Config_dir_resolver.masc_root ~base_path in
  match
    Tool_metrics_series.sliding_window
      ~span_s:Masc_time_constants.day
      ~until:now
      ~width:Tool_metrics_series.Hour
      ~utc_offset_min:0
  with
  | Error msg -> Error msg
  | Ok window -> Tool_metrics_store.read_series ~masc_root ~window ()
;;

let run_background_probe ~base_path =
  let now = Time_compat.now () in
  let apple_inv =
    match Keeper_microvm_guest_inventory.read_apple ~timeout_sec:2.0 with
    | Ok inv -> Some (Ok inv)
    | Error err -> Some (Error (Keeper_microvm_guest_inventory.error_message err))
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Some (Error (Printexc.to_string exn))
  in
  let ssh_reach =
    match Keeper_sandbox_ssh.configured_endpoints ~base_path with
    | Error _ -> []
    | Ok endpoints ->
      List.map
        (fun (ep : Exec_ssh_endpoint.t) ->
           let r = probe_tcp_rtt ~host:ep.host ~port:ep.port ~timeout_sec:1.5 in
           ep.name, r)
        endpoints
  in
  let tool_ser =
    match read_24h_tool_series ~now ~base_path with
    | res -> Some res
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Some (Error (Printexc.to_string exn))
  in
  let finished_at = Time_compat.now () in
  let snap =
    build_snapshot_json
      ~now:finished_at
      ~probe_state:Probe_fresh
      ~apple_inventory:apple_inv
      ~ssh_reachability:ssh_reach
      ~tool_series:tool_ser
      ~base_path
      ()
  in
  Stdlib.Mutex.protect cache_mu (fun () ->
    match Hashtbl.find_opt cache_tbl base_path with
    | Some entry ->
      entry.snapshot <- snap;
      entry.measured_at <- finished_at;
      entry.refreshing <- false
    | None ->
      Hashtbl.replace
        cache_tbl
        base_path
        { snapshot = snap
        ; measured_at = finished_at
        ; refreshing = false
        });
  Env.announce_v2_dataset ~base_path ~dataset:"infra_sandboxes" ()
;;

let trigger_probe ~sw ~clock:_ ~base_path () =
  (* Check switch liveness BEFORE claiming the single-flight slot so a
     cancelled/closed switch can never leave [refreshing = true] behind. *)
  Eio.Switch.check sw;
  (* Never perform filesystem I/O while holding [cache_mu]. *)
  let has_entry =
    Stdlib.Mutex.protect cache_mu (fun () -> Hashtbl.mem cache_tbl base_path)
  in
  let initial_opt =
    if has_entry
    then None
    else
      Some
        (build_snapshot_json
           ~now:(Time_compat.now ())
           ~probe_state:Probe_warming
           ~base_path
           ())
  in
  let clear_refreshing () =
    Stdlib.Mutex.protect cache_mu (fun () ->
      match Hashtbl.find_opt cache_tbl base_path with
      | Some entry -> entry.refreshing <- false
      | None -> ())
  in
  let should_fork =
    Stdlib.Mutex.protect cache_mu (fun () ->
      match Hashtbl.find_opt cache_tbl base_path with
      | Some entry when entry.refreshing -> false
      | Some entry ->
        entry.refreshing <- true;
        true
      | None ->
        let initial =
          match initial_opt with
          | Some snap -> snap
          | None -> Env.ok ~now:(Time_compat.now ()) (`Assoc [])
        in
        Hashtbl.replace
          cache_tbl
          base_path
          { snapshot = initial
          ; measured_at = 0.0
          ; refreshing = true
          };
        true)
  in
  if should_fork
  then (
    try
      Eio.Fiber.fork ~sw (fun () ->
        (* Put [Eio.Fiber.yield ()] inside [Fun.protect] so cancellation before
           work starts still releases the single-flight reservation. *)
        Fun.protect ~finally:clear_refreshing (fun () ->
          Eio.Fiber.yield ();
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
            run_background_probe ~base_path)))
    with
    | exn ->
      clear_refreshing ();
      raise exn);
  should_fork
;;

let get_fleet_json ?sw ?clock ?(now = Time_compat.now ()) ~base_path () =
  let cached, needs_refresh =
    Stdlib.Mutex.protect cache_mu (fun () ->
      match Hashtbl.find_opt cache_tbl base_path with
      | Some entry ->
        let age = now -. entry.measured_at in
        let stale = Float.compare age cache_ttl_sec > 0 in
        Some (entry.snapshot, stale), stale && not entry.refreshing
      | None -> None, true)
  in
  let response =
    match cached with
    | Some (snap, false) -> snap
    | Some (snap, true) ->
      (* Return cached snapshot immediately without blocking *)
      snap
    | None ->
      let fast =
        build_snapshot_json ~now ~probe_state:Probe_warming ~base_path ()
      in
      Stdlib.Mutex.protect cache_mu (fun () ->
        if not (Hashtbl.mem cache_tbl base_path)
        then
          Hashtbl.replace
            cache_tbl
            base_path
            { snapshot = fast
            ; measured_at = 0.0
            ; refreshing = false
            });
      fast
  in
  (if needs_refresh
   then
     match sw, clock with
     | Some sw, Some clock -> ignore (trigger_probe ~sw ~clock ~base_path () : bool)
     | _ -> ());
  response
;;

let get_keeper_json ?sw ?clock ?(now = Time_compat.now ()) ~base_path ~keeper () =
  let keeper = String.trim keeper in
  if not (Keeper_config.validate_name keeper)
  then
    Error
      ( Env.error_status Env.Invalid_param
      , Env.error_json ~field:"keeper" ~code:Env.Invalid_param "invalid keeper name" )
  else (
    let fleet = get_fleet_json ?sw ?clock ~now ~base_path () in
    let data =
      match Json_util.assoc_member_opt "data" fleet with
      | Some d -> d
      | None -> `Assoc []
    in
    let find_in_list field_name =
      match Json_util.assoc_member_opt field_name data with
      | Some (`List rows) ->
        List.find_opt
          (fun row ->
             Option.equal String.equal (Json_util.assoc_string_opt "keeper" row) (Some keeper))
          rows
      | _ -> None
    in
    let find_in_ssh () =
      match Json_util.assoc_member_opt "ssh_pools" data with
      | Some (`List pools) ->
        List.find_map
          (fun pool ->
             match Json_util.assoc_member_opt "keeper_sessions" pool with
             | Some (`List sessions) ->
               List.find_map
                 (fun sess ->
                    if Option.equal String.equal (Json_util.assoc_string_opt "keeper" sess) (Some keeper)
                    then
                      Some
                        (`Assoc
                          [ "keeper", `String keeper
                          ; "backend", `String "remote_ssh"
                          ; "pool", pool
                          ; "session", sess
                          ])
                    else None)
                 sessions
             | _ -> None)
          pools
      | _ -> None
    in
    let found =
      match find_in_list "microvm_guests" with
      | Some row -> Some row
      | None ->
        (match find_in_ssh () with
         | Some row -> Some row
         | None ->
           (match find_in_list "ssh_unbound_keepers" with
            | Some row -> Some row
            | None -> find_in_list "docker_keepers"))
    in
    match found with
    | None ->
      Error
        ( Env.error_status Env.Sandbox_telemetry_missing
        , Env.error_json
            ~code:Env.Sandbox_telemetry_missing
            (Printf.sprintf "sandbox telemetry for keeper %S not found" keeper) )
    | Some row ->
      Ok
        (Env.ok
           ~now
           (`Assoc
             [ "keeper", `String keeper
             ; "sandbox", row
             ; "probe_state", Option.value ~default:`Null (Json_util.assoc_member_opt "probe_state" data)
             ])))
;;

let sandbox_keeper_prefix = "/api/v1/infra/sandboxes/"

let add_routes ~sw ~clock router =
  router
  |> Server_route.get
       (Server_route.Permission Masc_domain.CanReadState)
       "/api/v1/infra/sandboxes"
       (fun state req reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          let json = get_fleet_json ~sw ~clock ~base_path () in
          Http.Response.json_value ~compress:true ~request:req json reqd)
  |> Server_route.post
       (Server_route.Token_permission Masc_domain.CanAdmin)
       "/api/v1/infra/sandboxes/probe"
       (fun state _actor req reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          let started = trigger_probe ~sw ~clock ~base_path () in
          Http.Response.json_value
            ~status:`Accepted
            ~request:req
            (Env.ok
               (`Assoc
                 [ "accepted", `Bool true
                 ; "refresh_started", `Bool started
                 ; "scope", `String "all"
                 ]))
            reqd)
  |> Server_route.prefix_get
       (Server_route.Permission Masc_domain.CanReadState)
       sandbox_keeper_prefix
       (fun state req reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          match
            Server_utils.extract_path_param
              ~prefix:sandbox_keeper_prefix
              (Http.Request.path req)
          with
          | None ->
            Http.Response.json_value
              ~status:`Bad_request
              ~request:req
              (Env.error_json
                 ~field:"keeper"
                 ~code:Env.Invalid_param
                 "keeper name is required")
              reqd
          | Some raw ->
            let keeper = Uri.pct_decode raw |> String.trim in
            (match get_keeper_json ~sw ~clock ~base_path ~keeper () with
             | Ok json ->
               Http.Response.json_value ~compress:true ~request:req json reqd
             | Error (status, json) ->
               Http.Response.json_value ~status ~compress:true ~request:req json reqd))
;;
