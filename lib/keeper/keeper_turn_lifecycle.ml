(** Keeper_turn_lifecycle -- keeper model-set and shutdown handlers.

    Extracted from keeper_turn.ml.  Provides [handle_keeper_model_set] and
    [handle_keeper_down]. *)

open Tool_args
open Keeper_types
open Keeper_keepalive
open Keeper_turn_session

type tool_result = Keeper_types.tool_result

let handle_keeper_model_set ctx args : tool_result =
  let name = get_string args "name" "" in
  let model = get_string args "model" "" |> String.trim in
  let allowed_models_arg = get_string_list args "allowed_models" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else if model = "" then
    (false, "❌ model is required")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some meta) ->
            let is_local = label_is_local_runtime model in
            let runtime_ok =
              if is_local then (
                let model_id =
                  match String.index_opt model ':' with
                  | Some i -> String.sub model (i + 1) (String.length model - i - 1)
                  | None -> model
                in
                match Tool_local_runtime.fetch_models () with
                | Ok (_, models) -> List.mem model_id models
                | Error _ -> false)
              else true
            in
            if is_local && not runtime_ok then
              (false, Printf.sprintf "❌ model not present in llama inventory: %s" model)
            else
              let allowed_models =
                dedupe_keep_order
                  (allowed_models_arg @ [ model ] @ meta.allowed_models @ meta.models)
              in
              let updated =
                {
                  meta with
                  active_model = model;
                  allowed_models;
                  models = dedupe_keep_order (model :: meta.models);
                  updated_at = now_iso ();
                }
              in
              match write_meta ctx.config updated with
              | Error e -> (false, "❌ " ^ e)
              | Ok () ->
                  stop_keepalive updated.name;
                  start_keepalive ctx updated;
                  ( true,
                    Yojson.Safe.pretty_to_string
                      (`Assoc
                        [
                          ("name", `String updated.name);
                          ("active_model", `String updated.active_model);
                          ("allowed_models",
                            `List
                              (List.map (fun item -> `String item) updated.allowed_models));
                  ("room_scope", `String updated.room_scope);
                  ("trigger_mode", `String updated.trigger_mode);
                    ]) )


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
      (if remove_meta then
         Safe_ops.remove_file_logged ~context:"keeper_down"
           (keeper_meta_path ctx.config name)
       else
         let retained =
           {
             m with
             active_team_session_id = None;
             last_team_session_started_at = "";
             updated_at = now_iso ();
           }
         in
         write_meta_logged ctx.config retained);
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
        if validate_name m.trace_id then (
          let dir = Filename.concat (session_base_dir ctx.config) m.trace_id in
          try rm_rf dir with exn ->
            Log.Keeper.error "session dir cleanup failed: %s"
              (Printexc.to_string exn)));
      let json = `Assoc [
        ("name", `String name);
        ("stopped", `Bool true);
        ("remove_meta", `Bool remove_meta);
        ("remove_session", `Bool remove_session);
      ] in
      (true, Yojson.Safe.pretty_to_string json)
