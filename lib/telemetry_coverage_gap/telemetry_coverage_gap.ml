(** Durable telemetry coverage gaps.

    This store records write-path failures that leave one telemetry lane behind
    another.  Unified telemetry can then surface the gap even when the primary
    lane itself has no fresh rows to read. *)

(* [masc_root] is [<base>/.masc]. *)
let location masc_root =
  Dated_jsonl.Store.(at (root_of_masc_dir masc_root) Root.Telemetry_coverage_gaps)

let store_dir masc_root = Dated_jsonl.Store.dir (location masc_root)

let string_opt_json = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null

(* RFC-0154: derive (raw_error, error_class) from the optional [exn] /
   [error] inputs.  When both are present, [error] wins for the wire
   value (caller's explicit string is authoritative) while [exn] is
   still used for the typed errno match.  When only [error] is given,
   [classify_string] runs over it for the typed tag. *)
let derive_error_and_class ~error ~exn =
  match exn, error with
  | Some e, Some explicit ->
      let cls = System_error_class.classify_exn e in
      (Some explicit, Some cls)
  | Some e, None ->
      let cls = System_error_class.classify_exn e in
      (Some (Printexc.to_string e), Some cls)
  | None, Some s ->
      let cls = System_error_class.classify_string s in
      (Some s, Some cls)
  | None, None -> (None, None)

let class_json = function
  | None -> `Null
  | Some cls -> `String (System_error_class.to_short_tag cls)

type change = {
  canonical_masc_root : string;
  source : string;
  keeper_name : string option;
}

type listener = { callback : change -> unit }
let listeners : listener list Atomic.t = Atomic.make []
let notification_failures = Atomic.make 0
let failed_notifications () = Atomic.get notification_failures

let rec update_listeners change =
  let before = Atomic.get listeners in
  if not (Atomic.compare_and_set listeners before (change before)) then
    update_listeners change
;;

let subscribe_changed callback =
  let listener = {callback} in
  update_listeners (fun before -> listener :: before);
  fun () -> update_listeners (List.filter (fun existing -> existing != listener))
;;

let notify_changed change =
  List.iter (fun listener ->
    match listener.callback change with
    | () -> ()
    | exception _ ->
        (* cancel-guard-ok: commit observations must not replace the writer's outcome,
           including cancellation delivered by a listener. No I/O here. *)
        ignore (Atomic.fetch_and_add notification_failures 1))
    (Atomic.get listeners)
;;

let record ~masc_root ~source ~producer ~durable_store ~dashboard_surface
    ~stale_reason ?keeper_name ?trace_id ?error ?exn () =
  let canonical_masc_root = Fs_compat.realpath_lenient masc_root in
  let raw_error, error_class = derive_error_and_class ~error ~exn in
  (* The OTel counter was severed in #20189 (retired scrape-backend
     purge) without an Otel_metric_store replacement; every coverage-gap
     record must also bump the counter so dashboards see gaps without
     reading the JSONL store. *)
  Otel_metric_store_core.inc_counter
    Otel_builtin_metric_names.metric_telemetry_coverage_gap
    ~labels:
      [
        ("source", source);
        ("producer", producer);
        ("dashboard_surface", dashboard_surface);
        ("stale_reason", stale_reason);
      ]
    ();
  let store = Dated_jsonl.open_store (location masc_root) in
  let now = Time_compat.now () in
  let json =
    `Assoc
      [
        ("schema", `String "masc.telemetry_coverage_gap.v1");
        ("ts", `Float now);
        ("ts_iso", `String (Masc_domain.iso8601_of_unix_seconds now));
        ("source", `String source);
        ("producer", `String producer);
        ("durable_store", `String durable_store);
        ("dashboard_surface", `String dashboard_surface);
        ("stale_reason", `String stale_reason);
        ("keeper_name", string_opt_json keeper_name);
        ("trace_id", string_opt_json trace_id);
        ("error", string_opt_json raw_error);
        ("error_class", class_json error_class);
      ]
  in
  match Dated_jsonl.append_notifying_commit store json ~on_committed:(fun () ->
    notify_changed {canonical_masc_root; source; keeper_name}) with
  | () -> ()
  | exception Dated_jsonl.Append_guard_skipped -> ()

let read_recent ~masc_root ~n =
  if n <= 0 then []
  else
    let dir = store_dir masc_root in
    if not (Sys.file_exists dir) then []
    else Dated_jsonl.read_recent (Dated_jsonl.open_store (location masc_root)) n
