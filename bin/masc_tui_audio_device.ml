(* Which microphone a capture would open.

   No server can answer this: sox opens whatever the operating system calls the
   default input, on the machine the TUI runs on. An operator whose captures
   come back empty is usually looking at a different device than the one that
   is selected — a headset that went to sleep, or a virtual device left over
   from a screen recording. *)

(* system_profiler's JSON report: one [SPAudioDataType] entry holding
   [_items], one per device, each with a [_name] and, on the selected input
   only, ["coreaudio_default_audio_input_device": "spaudio_yes"]. The text
   report marks the same device with a "Default Input Device: Yes" line and
   left the name to be inferred as the nearest heading above it, by
   indentation, which was a guess about a layout Apple does not promise. *)
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

let macos_default_input () =
  let read () =
    let input = Unix.open_process_in "system_profiler -json SPAudioDataType 2>/dev/null" in
    Fun.protect
      ~finally:(fun () -> ignore (Unix.close_process_in input))
      (fun () -> In_channel.input_all input)
  in
  match read () with
  | exception (Unix.Unix_error _ | Sys_error _) -> None
  | text ->
    (* Nothing on stdout is system_profiler missing or refusing; either way
       there is no report to read, which is the same answer as a report with
       no default input in it. *)
    (match Yojson.Safe.from_string text with
     | exception Yojson.Json_error _ -> None
     | json -> default_input_of_json json)
;;

let default_input () =
  match Sys.os_type with
  | "Unix" when Sys.file_exists "/usr/sbin/system_profiler" -> macos_default_input ()
  (* Elsewhere the answer would come from ALSA or PulseAudio and the shapes
     differ enough that a guess would be worse than saying nothing. *)
  | _ -> None
;;
