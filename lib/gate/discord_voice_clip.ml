type source_format =
  | Mp3
  | Wav
  | Ogg
  | Mp4
  | Webm

(* ffmpeg's demuxer names, as [ffmpeg -demuxers] prints them. *)
let demuxer = function
  | Mp3 -> "mp3"
  | Wav -> "wav"
  | Ogg -> "ogg"
  | Mp4 -> "mov,mp4,m4a,3gp,3g2,mj2"
  | Webm -> "matroska,webm"

(* Voice Messages: clients sample the recording "at most once per 100
   milliseconds". 8 kHz keeps 800 samples per point, plenty for a peak, at a
   sixth of the 48 kHz stream's PCM size. *)
let waveform_sample_rate = 8000
let waveform_point_secs = 0.1
let pcm_sample_bytes = 2
let waveform_byte_max = 255
let pcm_peak_max = 32767

let waveform_of_pcm_s16le ~sample_rate pcm =
  let samples = String.length pcm / pcm_sample_bytes in
  if samples = 0 || sample_rate <= 0 then None
  else
    let duration_secs = float_of_int samples /. float_of_int sample_rate in
    let points =
      Float.ceil (duration_secs /. waveform_point_secs)
      |> int_of_float
      |> min Discord_rest_client.voice_waveform_max_points
      |> max 1
    in
    let magnitude index =
      abs (String.get_int16_le pcm (index * pcm_sample_bytes))
    in
    (* Point [k] covers samples [k * samples / points] up to the next point's
       start. The [max] keeps a slice non-empty when there are fewer samples
       than points. *)
    let point k =
      let first = k * samples / points in
      let past_last = max (first + 1) ((k + 1) * samples / points) in
      let rec peak index acc =
        if index >= past_last then acc else peak (index + 1) (max acc (magnitude index))
      in
      (* -32768 has magnitude 32768; [min] keeps it at the top byte. *)
      min waveform_byte_max (peak first 0 * waveform_byte_max / pcm_peak_max)
    in
    Some (duration_secs, String.init points (fun k -> Char.chr (point k)))

(* A Keeper's spoken reply is seconds long and ffmpeg encodes it in well
   under a second. The bound stops a wedged ffmpeg from holding the post's
   fiber; it is not a budget on slow encodes. *)
let ffmpeg_timeout_sec = 30.0

(* ffmpeg repeats a decode error once per packet, so a WAV read as MP3
   fills kilobytes of stderr. Its first line names the cause and its last
   line the outcome; a failure carries those two. *)
let stderr_summary stderr =
  match List.filter (fun line -> line <> "") (List.map String.trim (String.split_on_char '\n' stderr)) with
  | [] -> "no diagnostics"
  | [ line ] -> line
  | first :: rest -> first ^ " ... " ^ List.nth rest (List.length rest - 1)

let run_ffmpeg args =
  match
    Process_eio.run_argv_with_status_split_or_refusal ~timeout_sec:ffmpeg_timeout_sec
      ("ffmpeg" :: args)
  with
  | Error refusal ->
    Error (Printf.sprintf "ffmpeg: %s" (Process_eio.spawn_refusal_to_string refusal))
  | Ok (status, _stdout, stderr) ->
    (match Process_eio.exit_reason_of_status status with
     | Process_eio.Completed 0 -> Ok ()
     | Process_eio.Completed code ->
       Error (Printf.sprintf "ffmpeg exited %d (%s)" code (stderr_summary stderr))
     | Process_eio.Timed_out -> Error "ffmpeg timed out"
     | Process_eio.Signaled signal -> Error (Printf.sprintf "ffmpeg signaled %d" signal)
     | Process_eio.Stopped signal -> Error (Printf.sprintf "ffmpeg stopped %d" signal))

(* Discord's clients upload "a 1 channel, 48000 Hz, 32kbps Opus stream in an
   OGG container" (Voice Messages, as of 2023-04-14). *)
let opus_output_args out =
  [ "-map"; "0:a:0"; "-vn"; "-ac"; "1"; "-ar"; "48000"; "-c:a"; "libopus"
  ; "-b:a"; "32k"; "-f"; "ogg"; out ]

let pcm_output_args out =
  [ "-map"; "0:a:0"; "-vn"; "-ac"; "1"; "-ar"; string_of_int waveform_sample_rate
  ; "-c:a"; "pcm_s16le"; "-f"; "s16le"; out ]

let transcode ~dir format bytes =
  let open Result.Syntax in
  let input = Filename.concat dir "input" in
  let ogg_path = Filename.concat dir "voice.ogg" in
  let pcm_path = Filename.concat dir "waveform.pcm" in
  let* () =
    try Ok (Fs_compat.save_file input bytes) with
    | Sys_error detail -> Error ("voice clip input write failed: " ^ detail)
  in
  (* [-protocol_whitelist file] and a named demuxer keep ffmpeg to the one
     input file: no playlist or concat demuxer that would open other paths
     or URLs named inside the bytes. *)
  let* () =
    run_ffmpeg
      ([ "-nostdin"; "-hide_banner"; "-loglevel"; "error"; "-y"
       ; "-protocol_whitelist"; "file"; "-f"; demuxer format; "-i"; input ]
       @ opus_output_args ogg_path
       @ pcm_output_args pcm_path)
  in
  try Ok (Fs_compat.load_file ogg_path, Fs_compat.load_file pcm_path) with
  | Sys_error detail -> Error ("voice clip output read failed: " ^ detail)

let remove_scratch dir =
  try Fs_compat.remove_tree dir with
  | Sys_error detail ->
    Log.Discord.warn "voice clip scratch %s was not removed: %s" dir detail
  | Unix.Unix_error (error, call, _) ->
    Log.Discord.warn "voice clip scratch %s was not removed: %s: %s" dir call
      (Unix.error_message error)

let of_audio format bytes =
  let open Result.Syntax in
  let* dir =
    try Ok (Filename.temp_dir "masc-discord-voice-" "") with
    | Sys_error detail -> Error ("voice clip scratch directory failed: " ^ detail)
  in
  let transcoded =
    Fun.protect ~finally:(fun () -> remove_scratch dir) (fun () ->
      transcode ~dir format bytes)
  in
  let* ogg, pcm = transcoded in
  match waveform_of_pcm_s16le ~sample_rate:waveform_sample_rate pcm with
  | None -> Error "the audio decodes to no samples"
  | Some (duration_secs, waveform) ->
    Discord_rest_client.voice_clip ~duration_secs ~waveform ogg
