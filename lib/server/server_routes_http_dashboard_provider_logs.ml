(** Provider log projections for dashboard HTTP routes.

    After runtime purge, provider log configuration was removed from
    Runtime_schema.provider. The endpoint returns an empty provider list
    until provider log config is re-introduced in the runtime model. *)

let provider_log_surface = "/api/v1/dashboard/provider-logs"
let provider_log_tail_surface = "/api/v1/dashboard/provider-logs/tail"

let dashboard_provider_logs_json () =
  `Assoc
    [
      ("generated_at_iso", `String (Masc_domain.now_iso ()));
      ("dashboard_surface", `String provider_log_surface);
      ("source", `String "runtime_provider_log");
      ("ok", `Bool true);
      ("providers", `List []);
    ]

let dashboard_provider_log_tail_json request =
  let provider_id =
    match Server_utils.query_param request "provider" with
    | Some raw -> String.trim raw
    | None -> ""
  in
  let error status message =
    ( status,
      `Assoc
        [
          ("generated_at_iso", `String (Masc_domain.now_iso ()));
          ("dashboard_surface", `String provider_log_tail_surface);
          ("source", `String "runtime_provider_log");
          ("ok", `Bool false);
          ("error", `String message);
        ] )
  in
  if String.equal provider_id ""
  then error `Bad_request "provider query parameter is required"
  else
    error `Not_found
      (Printf.sprintf
         "provider %S has no configured log (provider log config not yet \
          migrated to runtime model)"
         provider_id)
