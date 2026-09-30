(** Strict Runtime probe observations; no I/O or UI state. *)

open Tui_decode_fields
let ( let* ) = Result.bind

type runtime_probe_refresh_state =
  | Runtime_probe_fresh
  | Runtime_probe_recent
  | Runtime_probe_served_stale
  | Runtime_probe_warming_up

type runtime_probe_status =
  | Runtime_probe_reachable
  | Runtime_probe_no_http_runtimes
  | Runtime_probe_degraded
  | Runtime_probe_unreachable
  | Runtime_probe_warming

type runtime_provider_status =
  | Runtime_provider_reachable
  | Runtime_provider_missing_auth
  | Runtime_provider_auth_failed
  | Runtime_provider_network_error
  | Runtime_provider_server_error
  | Runtime_provider_endpoint_not_found
  | Runtime_provider_http_error
  | Runtime_provider_unknown_http_status
  | Runtime_provider_skipped_cli
  | Runtime_provider_skipped_native_auth
  | Runtime_provider_invalid_endpoint
  | Runtime_provider_invalid_execution_transport

type runtime_probe_transport =
  | Runtime_probe_http
  | Runtime_probe_cli

type runtime_provider_probe = {
  rpp_runtime_id : string;
  rpp_transport : runtime_probe_transport;
  rpp_status : runtime_provider_status;
  rpp_reachable : bool option;
  rpp_http_status : int option;
  rpp_latency_ms : float option;
  rpp_error : string option;
  rpp_checked_at : string;
}

type runtime_probe_summary = {
  rpsu_runtimes : int;
  rpsu_probed : int;
  rpsu_reachable : int;
  rpsu_failed : int;
  rpsu_skipped : int;
  rpsu_default_runtime_id : string option;
}

type runtime_probe_snapshot = {
  rps_generated_at : string;
  rps_refreshed_at_unix : float option;
  rps_cache_ttl_sec : float;
  rps_cache_age_sec : float option;
  rps_cache_hit : bool;
  rps_refresh_state : runtime_probe_refresh_state;
  rps_status : runtime_probe_status;
  rps_probe_ok : bool;
  rps_checked_at : string;
  rps_summary : runtime_probe_summary;
  rps_providers : runtime_provider_probe list;
  rps_errors : string list;
  rps_observations : string list;
  rps_limitations : string list;
}

let runtime_probe_refresh_state_to_string = function
  | Runtime_probe_fresh -> "fresh"
  | Runtime_probe_recent -> "recent"
  | Runtime_probe_served_stale -> "served_stale"
  | Runtime_probe_warming_up -> "warming_up"

(* The word the wire uses, so the badge shows what the server said. This
   spelled two of them "reachable" and "no_http_runtimes" while the producer
   wrote "ok" and "idle", and the only caller is the status badge -- so the
   screen would have named a reading the system never used. One vocabulary,
   read and written. *)
let runtime_probe_status_to_string = function
  | Runtime_probe_reachable -> "ok"
  | Runtime_probe_no_http_runtimes -> "idle"
  | Runtime_probe_degraded -> "degraded"
  (* The producer writes both "unavailable" and "unreachable" for this
     reading; one of them has to be the one written back. *)
  | Runtime_probe_unreachable -> "unreachable"
  | Runtime_probe_warming -> "warming_up"

let runtime_provider_status_to_string = function
  | Runtime_provider_reachable -> "reachable"
  | Runtime_provider_missing_auth -> "missing_auth"
  | Runtime_provider_auth_failed -> "auth_failed"
  | Runtime_provider_network_error -> "network_error"
  | Runtime_provider_server_error -> "server_error"
  | Runtime_provider_endpoint_not_found -> "endpoint_not_found"
  | Runtime_provider_http_error -> "http_error"
  | Runtime_provider_unknown_http_status -> "unknown_http_status"
  | Runtime_provider_skipped_cli -> "skipped_cli"
  | Runtime_provider_skipped_native_auth -> "skipped_native_auth"
  | Runtime_provider_invalid_endpoint -> "invalid_endpoint"
  | Runtime_provider_invalid_execution_transport ->
      "invalid_execution_transport"

let runtime_probe_refresh_state_of_string = function
  | "fresh" -> Ok Runtime_probe_fresh
  | "recent" -> Ok Runtime_probe_recent
  | "served_stale" -> Ok Runtime_probe_served_stale
  | "warming_up" -> Ok Runtime_probe_warming_up
  | value -> Error (Printf.sprintf "unknown runtime probe refresh_state %S" value)

(* The words the producer writes, not a list that grew beside it.

   [Server_dashboard_http_runtime_info] fills this field from three places:
   the live summary picks between [Health_status.Ok], [Idle], [Degraded] and
   [Unavailable]; the failure envelope writes ["unreachable"]; the cold-start
   envelope writes ["warming_up"]. Those six are the whole vocabulary.

   This list had ["reachable"] and ["no_http_runtimes"] instead of ["ok"] and
   ["idle"], and nothing has written those two -- searched for the literals
   across lib/ and bin/. So every response failed the decode and the surface
   drew "probe unavailable / read failed" with all twenty-nine candidates
   reading "unobserved". A dead column that looks like an observation nobody
   made is worse than an empty one: it answers the question wrongly instead
   of declining to.

   The variant names stay: they say what the reading means, and the meaning
   did not drift -- only the spelling the wire uses. *)
let runtime_probe_status_of_string = function
  | "ok" -> Ok Runtime_probe_reachable
  | "idle" -> Ok Runtime_probe_no_http_runtimes
  | "degraded" -> Ok Runtime_probe_degraded
  (* Two spellings for one reading, both live: the summary path writes
     ["unavailable"] and the failure envelope writes ["unreachable"]. *)
  | "unavailable" | "unreachable" -> Ok Runtime_probe_unreachable
  | "warming_up" -> Ok Runtime_probe_warming
  | value -> Error (Printf.sprintf "unknown runtime probe status %S" value)

let runtime_provider_status_of_string = function
  | "reachable" -> Ok Runtime_provider_reachable
  | "missing_auth" -> Ok Runtime_provider_missing_auth
  | "auth_failed" -> Ok Runtime_provider_auth_failed
  | "network_error" -> Ok Runtime_provider_network_error
  | "server_error" -> Ok Runtime_provider_server_error
  | "endpoint_not_found" -> Ok Runtime_provider_endpoint_not_found
  | "http_error" -> Ok Runtime_provider_http_error
  | "unknown_http_status" -> Ok Runtime_provider_unknown_http_status
  | "skipped_cli" -> Ok Runtime_provider_skipped_cli
  | "skipped_native_auth" -> Ok Runtime_provider_skipped_native_auth
  | "invalid_endpoint" -> Ok Runtime_provider_invalid_endpoint
  | "invalid_execution_transport" ->
      Ok Runtime_provider_invalid_execution_transport
  | value -> Error (Printf.sprintf "unknown runtime provider status %S" value)

let runtime_probe_transport_of_string = function
  | "http" -> Ok Runtime_probe_http
  | "cli" -> Ok Runtime_probe_cli
  | value -> Error (Printf.sprintf "unknown runtime probe transport %S" value)

let decode_runtime_provider_probe json =
  let* rpp_runtime_id = required_string_field json "runtime_id" in
  let* transport = required_string_field json "transport" in
  let* rpp_transport = runtime_probe_transport_of_string transport in
  let* status = required_string_field json "status" in
  let* rpp_status = runtime_provider_status_of_string status in
  let* rpp_reachable = required_nullable_bool_field json "reachable" in
  let* rpp_http_status = required_nullable_int_field json "http_status" in
  let* rpp_latency_ms = required_nullable_float_field json "latency_ms" in
  let* rpp_error = required_nullable_string_field json "error" in
  let* rpp_checked_at = required_string_field json "checked_at" in
  let expected_reachable =
    match rpp_status with
    | Runtime_provider_reachable -> Some true
    | Runtime_provider_skipped_cli | Runtime_provider_skipped_native_auth -> None
    | Runtime_provider_missing_auth
    | Runtime_provider_auth_failed
    | Runtime_provider_network_error
    | Runtime_provider_server_error
    | Runtime_provider_endpoint_not_found
    | Runtime_provider_http_error
    | Runtime_provider_unknown_http_status
    | Runtime_provider_invalid_endpoint
    | Runtime_provider_invalid_execution_transport -> Some false
  in
  let* () =
    if rpp_reachable = expected_reachable then Ok ()
    else
      Error
        (Printf.sprintf "runtime %S status %S disagrees with reachable"
           rpp_runtime_id status)
  in
  let* () =
    match rpp_transport, rpp_status with
    | Runtime_probe_cli, Runtime_provider_skipped_cli
    | Runtime_probe_http,
      ( Runtime_provider_reachable
      | Runtime_provider_skipped_native_auth
      | Runtime_provider_missing_auth
      | Runtime_provider_auth_failed
      | Runtime_provider_network_error
      | Runtime_provider_server_error
      | Runtime_provider_endpoint_not_found
      | Runtime_provider_http_error
      | Runtime_provider_unknown_http_status
      | Runtime_provider_invalid_endpoint
      | Runtime_provider_invalid_execution_transport ) -> Ok ()
    | Runtime_probe_cli, _ ->
        Error (Printf.sprintf "CLI runtime %S was not skipped" rpp_runtime_id)
    | Runtime_probe_http, Runtime_provider_skipped_cli ->
        Error (Printf.sprintf "HTTP runtime %S was marked skipped_cli" rpp_runtime_id)
  in
  let nonnegative name = function
    | Some value when value < 0 ->
        Error (Printf.sprintf "runtime %S has negative %s" rpp_runtime_id name)
    | Some _ | None -> Ok ()
  in
  let* () = nonnegative "http_status" rpp_http_status in
  let* () =
    match rpp_latency_ms with
    | Some value when value < 0.0 ->
        Error (Printf.sprintf "runtime %S has negative latency_ms" rpp_runtime_id)
    | Some _ | None -> Ok ()
  in
  Ok
    { rpp_runtime_id
    ; rpp_transport
    ; rpp_status
    ; rpp_reachable
    ; rpp_http_status
    ; rpp_latency_ms
    ; rpp_error
    ; rpp_checked_at
    }

let decode_runtime_probe_summary json =
  let* rpsu_runtimes = required_int_field json "runtimes" in
  let* rpsu_probed = required_int_field json "probed" in
  let* rpsu_reachable = required_int_field json "reachable" in
  let* rpsu_failed = required_int_field json "failed" in
  let* rpsu_skipped = required_int_field json "skipped" in
  let* rpsu_default_runtime_id =
    required_nullable_string_field json "default_runtime_id"
  in
  let counts =
    [ "runtimes", rpsu_runtimes
    ; "probed", rpsu_probed
    ; "reachable", rpsu_reachable
    ; "failed", rpsu_failed
    ; "skipped", rpsu_skipped
    ]
  in
  match List.find_opt (fun (_, value) -> value < 0) counts with
  | Some (name, _) -> Error (Printf.sprintf "runtime probe summary %s is negative" name)
  | None ->
      Ok
        { rpsu_runtimes
        ; rpsu_probed
        ; rpsu_reachable
        ; rpsu_failed
        ; rpsu_skipped
        ; rpsu_default_runtime_id
        }

let decode_runtime_probe_snapshot json =
  let* rps_generated_at = required_string_field json "generated_at" in
  let* rps_refreshed_at_unix =
    required_nullable_float_field json "refreshed_at_unix"
  in
  let* rps_cache_ttl_sec = Json_util.require_float json "cache_ttl_sec" in
  let* rps_cache_age_sec = required_nullable_float_field json "cache_age_sec" in
  let* rps_cache_hit = required_bool_field json "cache_hit" in
  let* refresh_state = required_string_field json "refresh_state" in
  let* rps_refresh_state = runtime_probe_refresh_state_of_string refresh_state in
  let* probe = required_object_field json "probe" in
  let* source = required_string_field probe "source" in
  let* () =
    if String.equal source Config_dir_resolver.runtime_toml_filename then Ok ()
    else
      Error
        (Printf.sprintf "runtime probe source is %S, expected %s" source
           Config_dir_resolver.runtime_toml_filename)
  in
  let* status = required_string_field probe "status" in
  let* rps_status = runtime_probe_status_of_string status in
  let* rps_probe_ok = required_bool_field probe "probe_ok" in
  let* rps_checked_at = required_string_field probe "checked_at" in
  let* summary = required_object_field probe "summary" in
  let* rps_summary = decode_runtime_probe_summary summary in
  let* providers = required_list_field probe "providers" in
  let* rps_providers =
    decode_list "providers" decode_runtime_provider_probe providers
  in
  let* rps_errors = require_string_list probe "errors" in
  let* rps_observations = require_string_list probe "observations" in
  let* rps_limitations = require_string_list probe "limitations" in
  let* () =
    if rps_cache_ttl_sec <= 0.0 then Error "runtime probe cache_ttl_sec must be positive"
    else
      match rps_cache_age_sec with
      | Some age when age < 0.0 -> Error "runtime probe cache_age_sec is negative"
      | Some _ | None -> Ok ()
  in
  let* () =
    match rps_refreshed_at_unix, rps_cache_age_sec with
    | Some _, Some _ | None, None -> Ok ()
    | Some _, None | None, Some _ ->
        Error "runtime probe refreshed_at_unix and cache_age_sec disagree"
  in
  let* () =
    match rps_refresh_state, rps_cache_hit with
    | (Runtime_probe_fresh | Runtime_probe_recent), true
    | (Runtime_probe_served_stale | Runtime_probe_warming_up), false -> Ok ()
    | _ ->
        Error
          (Printf.sprintf "runtime probe refresh_state %S disagrees with cache_hit"
             refresh_state)
  in
  let observed_reachable, observed_failed, observed_skipped =
    List.fold_left
      (fun (reachable, failed, skipped) provider ->
         match provider.rpp_reachable with
         | Some true -> reachable + 1, failed, skipped
         | Some false -> reachable, failed + 1, skipped
         | None -> reachable, failed, skipped + 1)
      (0, 0, 0) rps_providers
  in
  let row_count = List.length rps_providers in
  let* () =
    if rps_summary.rpsu_runtimes <> row_count then
      Error
        (Printf.sprintf "runtime probe summary has %d runtimes but providers has %d rows"
           rps_summary.rpsu_runtimes row_count)
    else if rps_summary.rpsu_reachable <> observed_reachable then
      Error "runtime probe reachable count disagrees with providers"
    else if rps_summary.rpsu_failed <> observed_failed then
      Error "runtime probe failed count disagrees with providers"
    else if rps_summary.rpsu_skipped <> observed_skipped then
      Error "runtime probe skipped count disagrees with providers"
    else if rps_summary.rpsu_probed <> observed_reachable + observed_failed then
      Error "runtime probe probed count disagrees with providers"
    else Ok ()
  in
  let* () =
    let seen = Hashtbl.create (max 1 row_count) in
    let rec loop = function
      | [] -> Ok ()
      | row :: rest ->
          if Hashtbl.mem seen row.rpp_runtime_id then
            Error
              (Printf.sprintf "duplicate runtime probe id %S" row.rpp_runtime_id)
          else begin
            Hashtbl.add seen row.rpp_runtime_id ();
            loop rest
          end
    in
    loop rps_providers
  in
  let* () =
    match rps_summary.rpsu_default_runtime_id with
    | None -> Ok ()
    | Some default_id ->
        if List.exists (fun row -> String.equal row.rpp_runtime_id default_id) rps_providers
        then Ok ()
        else Error (Printf.sprintf "default runtime %S is absent from providers" default_id)
  in
  let status_counts_valid =
    match rps_status with
    | Runtime_probe_reachable -> observed_failed = 0 && observed_reachable > 0
    | Runtime_probe_no_http_runtimes ->
        observed_failed = 0 && observed_reachable = 0
    | Runtime_probe_degraded -> observed_failed > 0 && observed_reachable > 0
    | Runtime_probe_unreachable ->
        observed_reachable = 0 && (observed_failed > 0 || row_count = 0)
    | Runtime_probe_warming -> row_count = 0
  in
  let* () =
    if status_counts_valid then Ok ()
    else
      Error
        (Printf.sprintf "runtime probe status %S disagrees with provider counts" status)
  in
  let expected_probe_ok =
    match rps_status with
    | Runtime_probe_reachable | Runtime_probe_no_http_runtimes -> true
    | Runtime_probe_degraded | Runtime_probe_unreachable | Runtime_probe_warming -> false
  in
  let* () =
    if rps_probe_ok = expected_probe_ok then Ok ()
    else Error (Printf.sprintf "runtime probe status %S disagrees with probe_ok" status)
  in
  let* () =
    match rps_refresh_state, rps_status, rps_refreshed_at_unix with
    | Runtime_probe_warming_up, Runtime_probe_warming, None -> Ok ()
    | Runtime_probe_warming_up, _, _ ->
        Error "runtime probe warming_up refresh must carry a warming probe without a cache time"
    | (Runtime_probe_fresh | Runtime_probe_recent | Runtime_probe_served_stale), _, Some _ ->
        Ok ()
    | (Runtime_probe_fresh | Runtime_probe_recent | Runtime_probe_served_stale), _, None ->
        Error "runtime probe cached refresh is missing refreshed_at_unix"
  in
  Ok
    { rps_generated_at
    ; rps_refreshed_at_unix
    ; rps_cache_ttl_sec
    ; rps_cache_age_sec
    ; rps_cache_hit
    ; rps_refresh_state
    ; rps_status
    ; rps_probe_ok
    ; rps_checked_at
    ; rps_summary
    ; rps_providers
    ; rps_errors
    ; rps_observations
    ; rps_limitations
    }

let runtime_probe_for_id snapshot ~runtime_id =
  Option.bind snapshot (fun probe ->
    List.find_opt (fun row -> String.equal row.rpp_runtime_id runtime_id)
      probe.rps_providers)
