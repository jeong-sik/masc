(* Dashboard /runtime-defaults endpoint JSON builder.

   Serves the structured, ALREADY-RESOLVED runtime defaults and model routing
   that the runtime actually uses — the singletons populated by
   [Runtime.init_default] at startup (runtime.toml SSOT). This does NOT re-parse
   runtime.toml; the frontend consumes the resolved structure directly instead
   of the raw TOML source_text exposed by [/api/v1/runtime/config/raw].

   No fabricated defaults: when the runtime config is uninitialized the
   singletons hold [None]/[[]] and surface as null/empty arrays. The resolving
   accessors that raise on an unset default (e.g. [get_default_runtime_id])
   are intentionally avoided — the option-returning [get_default_runtime] is the
   only default source used here. *)

(* [Runtime_instance.t] record fields ([provider], [model], [binding]) and the nested
   [Runtime_schema] record labels ([display_name], [api_name], [max_context],
   [is_default]) need to be in scope for field access. *)
open Runtime_schema

type runtime_entry =
  { id : string
  ; provider : string
  ; model : string
  ; max_context : int
  ; is_default : bool
  }

type resolved =
  { default_runtime_id : string option
  ; default_model : string option
  ; default_max_context : int option
  ; runtimes : runtime_entry list
  ; media_failover : string list
  ; config_path : string option
  }

let string_opt_json = function
  | Some s -> `String s
  | None -> `Null
;;

let int_opt_json = function
  | Some i -> `Int i
  | None -> `Null
;;

let runtime_entry_json (e : runtime_entry) : Yojson.Safe.t =
  `Assoc
    [ "id", `String e.id
    ; "provider", `String e.provider
    ; "model", `String e.model
    ; "max_context", `Int e.max_context
    ; "is_default", `Bool e.is_default
    ]
;;

let build ~generated_at_iso (r : resolved) : Yojson.Safe.t =
  `Assoc
    [ "generated_at_iso", `String generated_at_iso
    ; "dashboard_surface", `String "/api/v1/dashboard/runtime-defaults"
    ; "source", `String "runtime_config"
    ; "config_path", string_opt_json r.config_path
    ; "default_runtime_id", string_opt_json r.default_runtime_id
    ; "default_model", string_opt_json r.default_model
    ; "default_max_context", int_opt_json r.default_max_context
    ; "runtimes", `List (List.map runtime_entry_json r.runtimes)
    ; ( "model_routing"
      , `Assoc
          [ "media_failover", `List (List.map (fun s -> `String s) r.media_failover)
          ] )
    ]
;;

let resolved_of_snapshot
    (snapshot : Runtime.dashboard_runtime_defaults_snapshot) : resolved =
  let default = snapshot.default_runtime in
  let entry (rt : Runtime_instance.t) : runtime_entry =
    { id = rt.id
    ; provider = rt.provider.display_name
    ; model = rt.model.api_name
    ; max_context = Runtime_instance.max_context_of_runtime rt
    ; is_default = rt.binding.is_default
    }
  in
  { default_runtime_id = Option.map (fun (rt : Runtime_instance.t) -> rt.id) default
  ; default_model = Option.map (fun (rt : Runtime_instance.t) -> rt.model.api_name) default
  ; default_max_context =
      Option.map Runtime_instance.max_context_of_runtime default
  ; runtimes = List.map entry snapshot.runtimes
  ; media_failover = snapshot.media_failover
  ; config_path = snapshot.config_path
  }
;;

let resolved_of_runtime () : resolved =
  Runtime.dashboard_runtime_defaults_snapshot ()
  |> resolved_of_snapshot
;;

let current ~generated_at_iso () : Yojson.Safe.t =
  build ~generated_at_iso (resolved_of_runtime ())
;;

type cached_prepared =
  { snap_default : Runtime_instance.t option
  ; snap_runtimes : Runtime_instance.t list
  ; snap_media_failover : string list
  ; snap_config_path : string option
  ; prepared : Server_cached_read_http.prepared_http
  }

let prepared_cache_mu = Stdlib.Mutex.create ()
let prepared_cache : cached_prepared option ref = ref None

let snapshot_matches (cached : cached_prepared)
    (snap : Runtime.dashboard_runtime_defaults_snapshot) =
  Option.equal ( == ) cached.snap_default snap.default_runtime
  && cached.snap_runtimes == snap.runtimes
  && cached.snap_media_failover == snap.media_failover
  && Option.equal String.equal cached.snap_config_path snap.config_path
;;

let current_prepared () : Server_cached_read_http.prepared_http =
  let snap = Runtime.dashboard_runtime_defaults_snapshot () in
  let hit =
    Stdlib.Mutex.protect prepared_cache_mu (fun () ->
      match !prepared_cache with
      | Some cached when snapshot_matches cached snap -> Some cached.prepared
      | Some _ | None -> None)
  in
  match hit with
  | Some prepared -> prepared
  | None ->
    let json =
      build ~generated_at_iso:(Masc_domain.now_iso ()) (resolved_of_snapshot snap)
    in
    let prepared = Server_cached_read_http.prepare_json json in
    Stdlib.Mutex.protect prepared_cache_mu (fun () ->
      prepared_cache :=
        Some
          { snap_default = snap.default_runtime
          ; snap_runtimes = snap.runtimes
          ; snap_media_failover = snap.media_failover
          ; snap_config_path = snap.config_path
          ; prepared
          });
    prepared
;;
