(** Durable telemetry coverage gaps.

    This store records write-path failures that leave one telemetry lane behind
    another.  Unified telemetry can then surface the gap even when the primary
    lane itself has no fresh rows to read. *)

let store_dir masc_root =
  Filename.concat masc_root "telemetry-coverage-gaps"

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

let record_result ~masc_root ~source ~producer ~durable_store ~dashboard_surface
    ~stale_reason ?keeper_name ?trace_id ?error ?exn () =
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
  let store = Dated_jsonl.create ~base_dir:(store_dir masc_root) () in
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
  Dated_jsonl.append_result store json

let record ~masc_root ~source ~producer ~durable_store ~dashboard_surface
    ~stale_reason ?keeper_name ?trace_id ?error ?exn () =
  match
    record_result ~masc_root ~source ~producer ~durable_store
      ~dashboard_surface ~stale_reason ?keeper_name ?trace_id ?error ?exn ()
  with
  | Ok () -> ()
  | Error error -> raise (Sys_error error)

let read_error_to_json ~masc_root ~recent_index ~kind ~message =
  `Assoc
    [
      ("source", `String "telemetry_coverage_gap_jsonl");
      ("path", `String (store_dir masc_root));
      ("recent_index", `Int recent_index);
      ("kind", `String kind);
      ("message", `String message);
    ]

let read_recent_with_read_errors ~masc_root ~n =
  if n <= 0 then []
  else
    let dir = store_dir masc_root in
    if not (Sys.file_exists dir) then []
    else
      let lines =
        Dated_jsonl.read_recent_lines (Dated_jsonl.create ~base_dir:dir ()) n
      in
      let rows_rev, errors_rev =
        lines
        |> List.mapi (fun recent_index line -> recent_index, line)
        |> List.fold_left
             (fun (rows, errors) (recent_index, line) ->
               match Yojson.Safe.from_string line with
               | `Assoc _ as json -> json :: rows, errors
               | other ->
                 let error =
                   read_error_to_json
                     ~masc_root
                     ~recent_index
                     ~kind:"row_not_object"
                     ~message:
                       (Printf.sprintf
                          "telemetry coverage gap JSONL row must be object, got %s"
                          (Json_util.kind_name other))
                 in
                 rows, error :: errors
               | exception Yojson.Json_error message ->
                 let error =
                   read_error_to_json
                     ~masc_root
                     ~recent_index
                     ~kind:"json_error"
                     ~message
                 in
                 rows, error :: errors)
             ([], [])
      in
      List.rev rows_rev, List.rev errors_rev

let read_recent ~masc_root ~n =
  fst (read_recent_with_read_errors ~masc_root ~n)
