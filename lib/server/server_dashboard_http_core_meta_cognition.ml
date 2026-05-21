(** Meta-cognition summary cache surface for dashboard HTTP core, extracted
    from [server_dashboard_http_core.ml]. Wraps [Server_dashboard_meta_cognition_cache]
    with the dashboard-cache key derivation and the warm-fork scheduler. *)

open Masc_domain

(* Meta-cognition summary cache extracted to
   [Server_dashboard_meta_cognition_cache] (godfile decomp). *)
module Mc_cache = Server_dashboard_meta_cognition_cache

let dashboard_cache_key = Server_dashboard_http_core_cache.dashboard_cache_key

let meta_cognition_summary_ttl = Mc_cache.summary_ttl
let meta_cognition_summary_stale_for = Mc_cache.summary_stale_for
let meta_cognition_summary_empty_json = Mc_cache.summary_empty_json

let dashboard_shell_cache_prefix (config : Coord.config) =
  Printf.sprintf "shell:coord=%s:" config.base_path
;;

let dashboard_shell_cache_key ?(light = false) (config : Coord.config) =
  Printf.sprintf
    "%sworkspace=%s:mode=%s"
    (dashboard_shell_cache_prefix config)
    config.workspace_path
    (if light then "light" else "full")
;;

let meta_cognition_summary_key (config : Coord.config) =
  dashboard_cache_key config "meta_cognition_summary" "dashboard_shell"
;;

let store_last_good_meta_cognition_summary = Mc_cache.store_last_good
let find_last_good_meta_cognition_summary = Mc_cache.find_last_good
let clear_meta_cognition_warm_flag = Mc_cache.clear_warm_flag

let schedule_meta_cognition_summary_warm (config : Coord.config) =
  let key = meta_cognition_summary_key config in
  let compute () =
    let json = Meta_cognition.summary_json config in
    Mc_cache.store_last_good key json;
    json
  in
  if Mc_cache.try_acquire_warm_slot key
  then (
    match Eio_context.get_switch_opt () with
    | Some sw ->
      Eio.Fiber.fork ~sw (fun () ->
        Eio_guard.protect
          ~finally:(fun () -> Mc_cache.clear_warm_flag key)
          (fun () ->
             try
               Dashboard_cache.invalidate key;
               ignore
                 (Dashboard_cache.get_or_compute
                    key
                    ~ttl:Mc_cache.summary_ttl
                    compute)
               (* Drop cached shell payloads that were rendered while the
                     meta-cognition summary was still warming. *);
               Dashboard_cache.invalidate_prefix (dashboard_shell_cache_prefix config)
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Server.warn
                 "dashboard shell meta_cognition warm failed: %s"
                 (Printexc.to_string exn)))
    | None -> Mc_cache.clear_warm_flag key)
;;

let meta_cognition_summary_cached (config : Coord.config) : Yojson.Safe.t =
  let key = meta_cognition_summary_key config in
  let fallback =
    match find_last_good_meta_cognition_summary key with
    | Some json -> json
    | None -> meta_cognition_summary_empty_json
  in
  let compute () =
    let json = Meta_cognition.summary_json config in
    store_last_good_meta_cognition_summary key json;
    json
  in
  match Dashboard_cache.peek key with
  | Some _ ->
    let result =
      Dashboard_cache.get_or_compute key ~ttl:meta_cognition_summary_ttl compute
    in
    if result = `Null then fallback else result
  | None ->
    (match find_last_good_meta_cognition_summary key with
     | Some stale ->
       Dashboard_cache.seed_stale_if_missing
         key
         ~stale_for:meta_cognition_summary_stale_for
         stale
     | None -> ());
    schedule_meta_cognition_summary_warm config;
    if fallback = meta_cognition_summary_empty_json then `Null else fallback
;;
