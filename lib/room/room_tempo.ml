(** Room Tempo - Cluster pace management.

    Extracted from Room module. Controls tempo mode (normal/slow/fast/paused)
    for coordinating cluster-wide agent pacing. *)

open Types
open Room_utils
open Room_state

(** Path to tempo.json *)
let tempo_path config = Filename.concat (masc_dir config) "tempo.json"

(** Read tempo config from file *)
let read_tempo config : tempo_config =
  let path = tempo_path config in
  if Sys.file_exists path then
    try
      match tempo_config_of_yojson (read_json config path) with
      | Ok t -> t
      | Error _ -> default_tempo_config
    with Sys_error _ | Yojson.Json_error _ -> default_tempo_config
  else
    default_tempo_config

(** Write tempo config to file *)
let write_tempo config (tempo : tempo_config) =
  write_json config (tempo_path config) (tempo_config_to_yojson tempo)

(** Get current tempo - returns JSON for MCP response *)
let get_tempo config =
  ensure_initialized config;
  let tempo = read_tempo config in
  tempo_config_to_yojson tempo

(** Set tempo with mode, reason, and agent tracking *)
let set_tempo config ~mode ~reason ~agent_name =
  ensure_initialized config;
  match tempo_mode_of_string mode with
  | Error e -> Printf.sprintf "❌ Invalid tempo mode: %s" e
  | Ok tempo_mode ->
      (* Set delay based on mode *)
      let delay_ms = match tempo_mode with
        | Normal -> 0
        | Slow -> 2000    (* 2 second delay for careful work *)
        | Fast -> 0       (* No delay *)
        | Paused -> 0     (* No delay, but paused state *)
      in
      let tempo = {
        mode = tempo_mode;
        delay_ms;
        reason;
        set_by = Some agent_name;
        set_at = Some (now_iso ());
      } in
      write_tempo config tempo;

      (* Broadcast tempo change *)
      let emoji = match tempo_mode with
        | Normal -> "🎵"
        | Slow -> "🐢"
        | Fast -> "🚀"
        | Paused -> "⏸️"
      in
      let reason_str = match reason with
        | Some r -> Printf.sprintf " (%s)" r
        | None -> ""
      in
      let _ = broadcast config ~from_agent:agent_name
        ~content:(Printf.sprintf "%s Tempo → %s%s" emoji mode reason_str) in

      Printf.sprintf "✅ Tempo set to %s (delay: %dms)%s" mode delay_ms reason_str
