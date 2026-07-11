(** Keeper_turn_lifecycle -- keeper shutdown handlers.

    Extracted from keeper_turn.ml. Provides [handle_keeper_down]. *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_keepalive

type tool_result = Keeper_types_profile.tool_result

let remove_pending_confirms_by_target_callback
    : (Workspace.config ->
       target_type:string ->
       target_id:string option ->
       (int, string) result)
        Atomic.t
  =
  Atomic.make (fun _config ~target_type:_ ~target_id:_ -> Ok 0)

let register_remove_pending_confirms_by_target fn =
  Atomic.set remove_pending_confirms_by_target_callback fn

let handle_keeper_down_config ~(config : Workspace.config) args : tool_result =
  let requested_name = String.trim (get_string args "name" "") in
  if not (validate_name requested_name) then
    tool_result_error
      (Printf.sprintf
         "invalid keeper name %S (must be non-empty and match \
          [A-Za-z0-9._-]+; see Keeper_config.validate_name)"
         requested_name)
  else
    let remove_meta = get_bool args "remove_meta" false in
    let remove_session = get_bool args "remove_session" false in
    match read_meta_resolved config requested_name with
    | Error e -> tool_result_error e
    | Ok None ->
      stop_keepalive ~base_path:config.base_path requested_name;
      tool_result_ok (Printf.sprintf "keeper already absent: %s" requested_name)
    | Ok (Some (name, m)) ->
      (match
         Atomic.get remove_pending_confirms_by_target_callback config
           ~target_type:"keeper" ~target_id:(Some name)
       with
       | Error msg ->
         tool_result_error
           (Printf.sprintf
              "keeper pending-confirm cleanup failed for %s: %s"
              name
              msg)
       | Ok pending_confirms_removed ->
      Log.Misc.info
        "[keeper_down] cleanup keeper=%s pending_confirms_removed=%d \
         remove_meta=%b remove_session=%b"
        name pending_confirms_removed remove_meta remove_session;
      let prepare_shutdown =
        if remove_meta then Ok ()
        else
          let retained =
            {
              m with
              updated_at = now_iso ();
              paused = true;
              (* [keeper_down] is a retained shutdown, not a pause followed by
                 a second lifecycle command.  Persist the next-boot intent
                 before stopping the live registry entry; the stop transition
                 itself owns the transient FSM teardown. *)
              latched_reason =
                Some
                  (Keeper_latched_reason.Operator_paused
                     { operator_actor = Keeper_latched_reason.operator_actor_keeper_down });
            }
          in
          match
            write_meta_with_merge
              ~merge:Keeper_meta_merge.caller_wins config retained
          with
          | Ok () ->
            Keeper_registry.update_meta ~base_path:config.base_path name retained;
            Ok ()
          | Error err ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string WriteMetaFailures)
              ~labels:
                [ "keeper", name
                ; ( "phase"
                  , if Keeper_meta_store.is_version_conflict_error err
                    then "keeper_down_cas_race"
                    else "keeper_down" )
                ]
              ();
            Error (Printf.sprintf "keeper_down failed to persist paused state: %s" err)
      in
      (match prepare_shutdown with
       | Error msg -> tool_result_error msg
       | Ok () ->
      (* No irreversible lifecycle mutation occurs before pending-confirm and
         retained-meta preparation have succeeded. *)
      stop_keepalive ~base_path:config.base_path name;
      (if remove_meta then (
         Safe_ops.remove_file_logged ~context:"keeper_down"
           (keeper_meta_path config name);
         Keeper_registry.unregister ~base_path:config.base_path name;
         (* Tier K4c teardown — when the keeper is fully removed
            (remove_meta=true), drop its tool-emission accumulator
            from the registry so its slot is reclaimable. The
            retain-paused branch deliberately keeps the accumulator alive so
            a future resume can drain items captured before shutdown. *)
         Keeper_tool_emission_hook.drop_keeper_accumulator name));
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
          let dir = Filename.concat (session_base_dir config) (Keeper_id.Trace_id.to_string m.runtime.trace_id) in
          try rm_rf dir with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string SessionCleanupFailures)
              ();
            Log.Keeper.error "session dir cleanup failed: %s"
              (Printexc.to_string exn)));
      let json = `Assoc [
        ("name", `String name);
        ("stopped", `Bool true);
        ("remove_meta", `Bool remove_meta);
        ("remove_session", `Bool remove_session);
        ("pending_confirms_removed", `Int pending_confirms_removed);
      ] in
      tool_result_ok (Yojson.Safe.to_string json)))

let handle_keeper_down (ctx : _ context) args = handle_keeper_down_config ~config:ctx.config args

module For_testing = struct
  let remove_pending_confirms_by_target ~config ~target_type ~target_id =
    Atomic.get remove_pending_confirms_by_target_callback config ~target_type ~target_id

  let reset_remove_pending_confirms_by_target () =
    Atomic.set remove_pending_confirms_by_target_callback
      (fun _config ~target_type:_ ~target_id:_ -> Ok 0)
end
