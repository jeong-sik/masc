(** Meta-cognition summary cache surface for dashboard HTTP core, extracted
    from [server_dashboard_http_core.ml]. Wraps [Server_dashboard_meta_cognition_cache]
    with the dashboard-cache key derivation and the warm-fork scheduler. *)

open Masc_domain

(* Meta-cognition summary cache extracted to
   [Server_dashboard_meta_cognition_cache] (godfile decomp). *)
module Mc_cache = Server_dashboard_meta_cognition_cache

let dashboard_cache_key = Server_dashboard_http_core_cache.dashboard_cache_key

let meta_cognition_summary_ttl = Mc_cache.summary_ttl

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

let clear_meta_cognition_warm_flag = Mc_cache.clear_warm_flag

let schedule_meta_cognition_summary_warm (config : Coord.config) =
  let key = meta_cognition_summary_key config in
  let compute () = Meta_cognition.summary_json config in
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
  let compute () = Meta_cognition.summary_json config in
  match Dashboard_cache.peek key with
  | Some _ ->
    Dashboard_cache.get_or_compute key ~ttl:meta_cognition_summary_ttl compute
  | None ->
    schedule_meta_cognition_summary_warm config;
    `Null
;;
