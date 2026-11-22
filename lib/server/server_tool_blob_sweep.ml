let touch_ledger_detail () =
  let counts = Tool_blob_store.touch_counts (Tool_blob_store.observe_touches ()) in
  Printf.sprintf
    "touched_current=%d touched_previous=%d touched_current_evicted=%b touched_previous_evicted=%b"
    counts.current_addresses
    counts.previous_addresses
    counts.current_evicted
    counts.previous_evicted
;;

let warn_report_issues (report : Tool_blob_sweep.report) =
  (match report.unclassified with
   | [] -> ()
   | names ->
     Log.Server.warn "tool blob sweep: %d unclassified entries, nothing deletable: %s"
       (List.length names) (String.concat ", " names));
  if report.touches.current_evicted || report.touches.previous_evicted
  then
    Log.Server.warn
      "tool blob sweep: touch ledger evicted marks (current_evicted=%b previous_evicted=%b); deletion blocked fail-closed"
      report.touches.current_evicted
      report.touches.previous_evicted;
  (match report.malformed_warnings with
   | [] -> ()
   | warnings ->
     let pinned, unpinnable =
       List.fold_left
         (fun (p, u) -> function
           | Tool_blob_maintenance.Pinned_legacy_blob_ref _ -> p + 1, u
           | Tool_blob_maintenance.Unpinnable_malformed_blob_ref _ -> p, u + 1)
         (0, 0)
         warnings
     in
     let sample =
       warnings
       |> List.filteri (fun idx _ -> idx < 5)
       |> List.map Tool_blob_maintenance.malformed_reference_warning_to_string
       |> String.concat "; "
     in
     Log.Server.warn
       "tool blob sweep: %d malformed legacy blob ref(s) (pinned=%d unpinnable=%d%s): %s"
       (List.length warnings)
       pinned
       unpinnable
       (if unpinnable > 0 then ", deletion blocked fail-closed" else "")
       sample);
  if report.delete_failures > 0
  then
    Log.Server.warn
      "tool blob sweep: %d blob deletion failure(s); failed blobs retained in candidates-v2"
      report.delete_failures
;;

(* The scan parses every durable consumer. [Systhread_host] runs it on the
   host domain's thread, so the main domain keeps serving requests; the
   caller's own systhread would hold the main domain's lock while it parses. *)
let scan ~base_path =
  match
    Systhread_host.run ~label:"tool-blob-sweep" (fun () ->
      Tool_blob_sweep.reclaim ~base_path ~scope:Server_tool_blob_scope.scope ())
  with
  | Ok ({ previous = Tool_blob_sweep.Previous_record_invalid _; _ } as report) ->
    Log.Server.warn "tool blob sweep replaced an invalid record: %s"
      (Tool_blob_sweep.report_to_string report);
    warn_report_issues report
  | Ok ({ previous = Tool_blob_sweep.(No_previous_record | Compared_with_previous _); _ } as report)
    ->
    Log.Server.info "tool blob sweep: %s" (Tool_blob_sweep.report_to_string report);
    warn_report_issues report
  | Error error ->
    Log.Server.warn "tool blob sweep recorded nothing: %s %s"
      (Tool_blob_sweep.error_to_string error) (touch_ledger_detail ())
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    (* The loop outlives one scan: a raised scan is logged like a failed one,
       and the next attempt follows the marker as usual. *)
    Log.Server.warn "tool blob sweep raised: %s %s" (Printexc.to_string exn)
      (touch_ledger_detail ())
;;

let start ~sw ~clock ~(config : Workspace.config) =
  let base_path = config.base_path in
  let day = Masc_time_constants.day in
  Server_bootstrap_loops_fiber.fork_logged_fiber ~sw
    ~on_error:(Server_bootstrap_loops_fiber.log_server_fiber_crash "tool_blob_sweep")
    (fun () ->
       (* [scanned] is true right after a scan. A scan that still leaves the
          schedule [Due] wrote no marker, so the next attempt waits a day
          instead of opening another scan at once. *)
       let rec tick ~scanned =
         let now = Time_compat.now () in
         match Tool_blob_sweep.schedule ~base_path ~now with
         | Ok Tool_blob_sweep.Due ->
           if scanned
           then (
             Log.Server.warn "tool blob sweep: no scan marker after a scan; next attempt in a day";
             Eio.Time.sleep clock day;
             tick ~scanned:false)
           else (
             scan ~base_path;
             tick ~scanned:true)
         | Ok (Tool_blob_sweep.Next_at at) ->
           Eio.Time.sleep clock (Float.max 0.0 (at -. now));
           tick ~scanned:false
         | Error error ->
           Log.Server.warn "tool blob sweep schedule unreadable: %s; next attempt in a day"
             (Tool_blob_sweep.error_to_string error);
           Eio.Time.sleep clock day;
           tick ~scanned:false
       in
       tick ~scanned:false)
;;
