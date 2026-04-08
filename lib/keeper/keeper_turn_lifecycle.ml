(** Keeper_turn_lifecycle -- keeper shutdown handlers.

    Extracted from keeper_turn.ml. Provides [handle_keeper_down]. *)

open Tool_args
open Keeper_types
open Keeper_keepalive
open Keeper_turn_session

type tool_result = Keeper_types.tool_result

let handle_keeper_down ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    let remove_meta = get_bool args "remove_meta" false in
    let remove_session = get_bool args "remove_session" false in
    stop_keepalive name;
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (true, Printf.sprintf "keeper already absent: %s" name)
    | Ok (Some m) ->
      let stop_linked_session session_id =
        match
          Team_session_engine_eio.stop_session ~config:ctx.config ~session_id
            ~reason:"keeper_down" ~generate_report:false
        with
        | Ok _ -> ()
        | Error err ->
            Log.Keeper.error "linked team session stop failed: %s"
              err
      in
      Option.iter stop_linked_session m.active_team_session_id;
      ignore
        (Operator_pending_confirm.remove_pending_confirms_by_target ctx.config
           ~target_type:"keeper" ~target_id:(Some name));
      (if remove_meta then
         ( Safe_ops.remove_file_logged ~context:"keeper_down"
             (keeper_meta_path ctx.config name);
           Keeper_registry.unregister ~base_path:ctx.config.base_path name )
       else
         let retained =
           {
             m with
             active_team_session_id = None;
             last_team_session_started_at = "";
             updated_at = now_iso ();
             paused = true;
           }
         in
         (write_meta_logged ctx.config retained;
          Keeper_registry.update_meta ~base_path:ctx.config.base_path name retained;
          ignore (Keeper_registry.dispatch_event ~base_path:ctx.config.base_path name
            Keeper_state_machine.Operator_pause)));
      if remove_session then (
        let rec rm_rf path =
          if Sys.file_exists path then begin
            if Sys.is_directory path then begin
              Sys.readdir path |> Array.iter (fun entry ->
                rm_rf (Filename.concat path entry)
              );
              Unix.rmdir path
            end else
              Sys.remove path
          end
        in
        if validate_name m.runtime.trace_id then (
          let dir = Filename.concat (session_base_dir ctx.config) m.runtime.trace_id in
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
