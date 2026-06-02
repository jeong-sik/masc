(** OAS dispatch hot-path metric helpers.

    Kept outside [Prometheus] so the core registry/export module does not
    grow whenever a narrow hot-path baseline adds instrumentation. *)

let metric_oas_params_of_schema_sec = "masc_oas_params_of_schema_sec"
let metric_oas_make_tool_bundle_sec = "masc_oas_make_tool_bundle_sec"

let hist_disabled =
  Lazy.from_fun (fun () ->
    match Sys.getenv_opt "MASC_DISABLE_HOTPATH_HIST" with
    | Some ("1" | "true" | "yes" | "on" | "TRUE" | "YES" | "ON") -> true
    | _ -> false)
;;

let observe ~metric ~start =
  if Lazy.force hist_disabled
  then ()
  else
    try
      let elapsed = Mtime.span start (Mtime_clock.now ()) in
      let ns = Mtime.Span.to_uint64_ns elapsed in
      let sec = Int64.to_float ns /. 1.0e9 in
      Prometheus.observe_histogram metric sec
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> ()
;;

let register () =
  Prometheus.register_histogram
    ~name:metric_oas_params_of_schema_sec
    ~help:
      "OAS [params_of_json_schema] elapsed seconds per call.  Fires from \
       [Tool_bridge.oas_tool_of_masc] per OAS conversion; hot path target of \
       wise-nibbling-lerdorf Phase B baseline."
    ();
  Prometheus.register_histogram
    ~name:metric_oas_make_tool_bundle_sec
    ~help:
      "OAS [make_tool_bundle] elapsed seconds per call.  Fires once per keeper \
       turn; hot path target of wise-nibbling-lerdorf Phase B baseline."
    ()
;;

let () = register ()
