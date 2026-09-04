(* Which microphone a capture would open.

   No server can answer this: sox opens whatever the operating system calls the
   default input, on the machine the TUI runs on. An operator whose captures
   come back empty is usually looking at a different device than the one that
   is selected — a headset that went to sleep, or a virtual device left over
   from a screen recording. *)

let macos_default_input () =
  (* system_profiler prints one indented block per device and marks the
     selected one with "Default Input Device: Yes" on a line of its own. The
     name is the nearest heading above that line, so this walks the output
     keeping the last heading it saw. A heading is a line whose indentation is
     shallower than the fields under it and which ends in a colon. *)
  let read () =
    let input = Unix.open_process_in "system_profiler SPAudioDataType 2>/dev/null" in
    Fun.protect
      ~finally:(fun () -> ignore (Unix.close_process_in input))
      (fun () ->
         let rec walk heading =
           match input_line input with
           | exception End_of_file -> None
           | line ->
             let trimmed = String.trim line in
             let indent = String.length line - String.length (String.trim line) in
             if
               String.length trimmed > 1
               && String.ends_with ~suffix:":" trimmed
               && indent <= 8
             then walk (Some (String.sub trimmed 0 (String.length trimmed - 1)))
             else if
               String.length trimmed > 0
               && String.starts_with ~prefix:"Default Input Device:" trimmed
               && String.ends_with ~suffix:"Yes" trimmed
             then heading
             else walk heading
         in
         walk None)
  in
  try read () with
  | Unix.Unix_error _ | Sys_error _ -> None
;;

let default_input () =
  match Sys.os_type with
  | "Unix" when Sys.file_exists "/usr/sbin/system_profiler" -> macos_default_input ()
  (* Elsewhere the answer would come from ALSA or PulseAudio and the shapes
     differ enough that a guess would be worse than saying nothing. *)
  | _ -> None
;;
