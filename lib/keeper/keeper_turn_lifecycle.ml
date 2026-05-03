(** Keeper_turn_lifecycle -- keeper shutdown handlers.

    Extracted from keeper_turn.ml. Provides [handle_keeper_down]. *)

open Tool_args
open Keeper_types
open Keeper_keepalive

type tool_result = Keeper_types.tool_result

let handle_keeper_down ctx args : tool_result =
  let requested_name = String.trim (get_string args "name" "") in
  if not (validate_name requested_name) then
    (false, "invalid keeper name")
  else
    let remove_meta = get_bool args "remove_meta" false in
    let remove_session = get_bool args "remove_session" false in
    stop_keepalive ~base_path:ctx.config.base_path requested_name;
    (match keeper_name_from_agent_name requested_name with
     | Some resolved_name when not (String.equal resolved_name requested_name) ->
         stop_keepalive ~base_path:ctx.config.base_path resolved_name
     | _ -> ());
    match read_meta_resolved ctx.config requested_name with
    | Error e -> (false, "" ^ e)
    | Ok None -> (true, Printf.sprintf "keeper already absent: %s" requested_name)
    | Ok (Some (name, m)) ->
      ignore
        (Operator_pending_confirm.remove_pending_confirms_by_target ctx.config
           ~target_type:"keeper" ~target_id:(Some name));
      (if remove_meta then
         ( Safe_ops.remove_file_logged ~context:"keeper_down"
             (keeper_meta_path ctx.config name);
           Keeper_registry.unregister ~base_path:ctx.config.base_path name;
           (* Tier K4c teardown — when the keeper is fully removed
              (remove_meta=true), drop its tool-emission accumulator
              from the registry so its slot is reclaimable. The
              retain-paused branch (else) deliberately keeps the
              accumulator alive so a future resume can drain any
              pending items captured before pause. *)
           Keeper_tool_emission_hook.drop_keeper_accumulator name )
       else
         let retained =
           {
             m with
             updated_at = now_iso ();
             paused = true;
           }
         in
         ((match write_meta ctx.config retained with
           | Ok () -> ()
           | Error err ->
               Prometheus.inc_counter
                 Prometheus.metric_keeper_write_meta_failures
                 ~labels:[("keeper", name);
                          ("phase",
                           if Keeper_meta_store.is_version_conflict_error err
                           then "keeper_down_cas_race"
                           else "keeper_down")]
                 ();
               if Keeper_meta_store.is_version_conflict_error err then
                 Log.Keeper.warn "keeper_down write_meta lost CAS race: %s" err
               else
                 Log.Keeper.error "keeper_down write_meta failed: %s" err);
          Keeper_registry.update_meta ~base_path:ctx.config.base_path name retained;
          Keeper_registry.dispatch_event_unit ~base_path:ctx.config.base_path name
            Keeper_state_machine.Operator_pause));
      if remove_session then (
        let rec rm_rf path =
          if Fs_compat.file_exists path then begin
            if Sys.is_directory path then begin
              Sys.readdir path |> Array.iter (fun entry ->
                rm_rf (Filename.concat path entry)
              );
              Fs_compat.rmdir path
            end else
              Sys.remove path
          end
        in
        if validate_name (Keeper_id.Trace_id.to_string m.runtime.trace_id) then (
          let dir = Filename.concat (session_base_dir ctx.config) (Keeper_id.Trace_id.to_string m.runtime.trace_id) in
          try rm_rf dir with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            Log.Keeper.error "session dir cleanup failed: %s"
              (Printexc.to_string exn)));
      let json = `Assoc [
        ("name", `String name);
        ("stopped", `Bool true);
        ("remove_meta", `Bool remove_meta);
        ("remove_session", `Bool remove_session);
      ] in
      (true, Yojson.Safe.to_string json)
