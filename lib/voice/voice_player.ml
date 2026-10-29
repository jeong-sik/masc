(* Voice_player — local playback side effects and audio-file housekeeping.
   Extracted from Voice_bridge (E09 Phase 2b, task-2526): the tone the test
   command plays and the heartbeat's audio-directory cleanup move behind an
   explicit outcome so a cleanup that removes nothing is told, not guessed.

   Design: reports/e09-voice-addon-boundary-design-20261023.md *)

include Voice_bridge_core

open Result.Syntax

let run_voice_status = Voice_bridge_transport.run_voice_status

(** Clean up old audio files (>24 hours) and enforce a size cap.
    Call from heartbeat. Older files are removed first; if the total
    size still exceeds the cap, the oldest files are removed until the
    cap is satisfied. *)
let cleanup_old_audio_files () =
  let dir = Filename.concat (masc_base_dir ()) "audio" in
  if Sys.file_exists dir && Sys.is_directory dir
  then (
    let now = Time_compat.now () in
    let cutoff = now -. Masc_time_constants.day in
    let entries = Sys.readdir dir in
    let with_stats =
      Array.to_list entries
      |> List.filter_map (fun entry ->
           let path = Filename.concat dir entry in
           try
             let stat = Unix.stat path in
             Some (path, stat.st_mtime, stat.st_size)
           with
           | Unix.Unix_error _ | Sys_error _ -> None)
    in
    let by_age = List.sort (fun (_, m1, _) (_, m2, _) -> Float.compare m1 m2) with_stats in
    let removed = ref 0 in
    let remove path =
      try
        Sys.remove path;
        incr removed
      with
      | Unix.Unix_error _ | Sys_error _ -> ()
    in
    (* First pass: remove files older than 24h. *)
    let remaining =
      List.filter
        (fun (path, mtime, _size) ->
           if mtime < cutoff
           then (
             remove path;
             false)
           else true)
        by_age
    in
    (* Second pass: enforce size cap by removing oldest files first. *)
    let max_size_bytes = 500 * 1024 * 1024 in
    let total_size = List.fold_left (fun acc (_, _, size) -> acc + size) 0 remaining in
    if total_size > max_size_bytes
    then
      ignore
        (List.fold_left
           (fun acc (path, _mtime, size) ->
              if acc <= max_size_bytes
              then acc
              else (
                remove path;
                acc - size))
           total_size
           remaining);
    if !removed > 0
    then log_info (Printf.sprintf "Cleaned up %d old audio files" !removed))
;;

let play_tone freq =
  try
    ignore
      (run_voice_status
         ~timeout_sec:Env_config_runtime.Voice.audio_test_tone_timeout_sec
         [ "play"; "-qn"; "synth"; "0.15"; "sine"; Printf.sprintf "%.0f" freq ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Transport.debug "play_tone failed: %s" (Printexc.to_string exn)
;;
