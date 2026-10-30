(* Which microphone a capture would open.

   No server can answer this: sox opens whatever the operating system calls the
   default input, on the machine the TUI runs on. An operator whose captures
   come back empty is usually looking at a different device than the one that
   is selected — a headset that went to sleep, or a virtual device left over
   from a screen recording. *)

(* What a probe answers. Three of these show as "unknown" in the panel and
   are different facts: a machine with no input selected, a report that could
   not be read, and a platform this has no probe for. *)
type probe =
  | Default_input of string
  | No_default_input
  | Probe_failed of string
  | No_probe_on_this_platform

(* system_profiler's JSON report: one [SPAudioDataType] entry holding
   [_items], one per device, each with a [_name] and, on the selected input
   only, ["coreaudio_default_audio_input_device": "spaudio_yes"]. The text
   report marks the same device with a "Default Input Device: Yes" line and
   leaves the name to be inferred as the nearest heading above it, by
   indentation, which is a guess about a layout Apple does not promise. *)
let default_input_of_json (json : Yojson.Safe.t) =
  let assoc = function
    | `Assoc fields -> Some fields
    | _ -> None
  in
  let list_field name fields =
    match List.assoc_opt name fields with
    | Some (`List items) -> items
    | Some _ | None -> []
  in
  let devices =
    Option.value (assoc json) ~default:[]
    |> list_field "SPAudioDataType"
    |> List.concat_map (fun group ->
         Option.value (assoc group) ~default:[] |> list_field "_items")
  in
  List.find_map
    (fun device ->
      let fields = Option.value (assoc device) ~default:[] in
      match
        ( List.assoc_opt "coreaudio_default_audio_input_device" fields
        , List.assoc_opt "_name" fields )
      with
      | Some (`String "spaudio_yes"), Some (`String name) -> Some name
      | _ -> None)
    devices
;;

let system_profiler_command = "system_profiler -json SPAudioDataType 2>/dev/null"

let unix_failure fn err = Printf.sprintf "%s: %s" fn (Unix.error_message err)

(* What [command] wrote to stdout, or why that could not be read. Closing the
   channel reaps the child, and a failure there is a reason like any other:
   raised out of a [Fun.protect] finally it would arrive as [Finally_raised],
   which no caller matches. A child that exits non-zero has not produced a
   report either, whatever it printed. *)
let report_of_command command =
  match Unix.open_process_in command with
  | exception Unix.Unix_error (err, fn, _) -> Error (unix_failure fn err)
  | input ->
    let read =
      match In_channel.input_all input with
      | text -> Ok text
      | exception Unix.Unix_error (err, fn, _) -> Error (unix_failure fn err)
      | exception Sys_error message -> Error message
    in
    let finished =
      match Unix.close_process_in input with
      | Unix.WEXITED 0 -> Ok ()
      | Unix.WEXITED code -> Error (Printf.sprintf "exited %d" code)
      | Unix.WSIGNALED signal -> Error (Printf.sprintf "killed by signal %d" signal)
      | Unix.WSTOPPED signal -> Error (Printf.sprintf "stopped by signal %d" signal)
      | exception Unix.Unix_error (err, fn, _) -> Error (unix_failure fn err)
    in
    (match read, finished with
     | Ok text, Ok () -> Ok text
     | Error reason, _ | Ok _, Error reason -> Error reason)
;;

let probe_with ~command =
  match report_of_command command with
  | Error reason -> Probe_failed reason
  | Ok text ->
    (match Yojson.Safe.from_string text with
     | exception Yojson.Json_error message ->
       Probe_failed ("the report did not parse as JSON: " ^ message)
     | json ->
       (match default_input_of_json json with
        | Some name -> Default_input name
        | None -> No_default_input))
;;

let default_input () =
  match Sys.os_type with
  | "Unix" when Sys.file_exists "/usr/sbin/system_profiler" ->
    probe_with ~command:system_profiler_command
  (* Elsewhere the answer would come from ALSA or PulseAudio and the shapes
     differ enough that a guess would be worse than saying nothing. *)
  | _ -> No_probe_on_this_platform
;;
