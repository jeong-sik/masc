let sample_rate = 16_000

(* 16-bit signed mono is what the recorder is told to produce. Anything else
   would be decoded as noise rather than refused, so the capture pins the
   encoding on the command line and this pins the same numbers here. sox
   defaults to 32-bit when left alone -- measured 2026-09-04, and it made a
   hand-computed RMS read 0.41 against sox's 0.011. *)
let bytes_per_sample = 2
let full_scale = 32_768.0

(* A WAV header is not a fixed 44 bytes. The recorder wrote 80 in one measured
   case, so the data chunk is found rather than assumed. The search stops well
   short of any audio: no real header runs past a kilobyte, and scanning
   further risks matching the four letters inside the samples themselves. *)
let header_search_limit = 1024
let data_marker = "data"

let find_data_offset buffer length =
  let limit = min length (header_search_limit - String.length data_marker) in
  let rec scan index =
    if index > limit
    then None
    else if String.sub buffer index (String.length data_marker) = data_marker
    then Some (index + String.length data_marker + 4 (* the chunk's size field *))
    else scan (index + 1)
  in
  if length < String.length data_marker then None else scan 0
;;

let tail_rms ?(window_seconds = 0.3) path =
  match open_in_bin path with
  | exception Sys_error message -> Error message
  | channel ->
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
         let file_length = in_channel_length channel in
         let head_length = min file_length header_search_limit in
         let head = really_input_string channel head_length in
         match find_data_offset head head_length with
         (* The recorder creates the file before it writes anything into it,
            and with a trigger it may never write. An empty file is the normal
            state at the start of every capture, not a fault. *)
         | None -> Error "no audio yet"
         | Some data_offset ->
           let available = file_length - data_offset in
           if available < bytes_per_sample
           then Error "no audio yet"
           else (
             let window_bytes =
               int_of_float (window_seconds *. float_of_int sample_rate)
               * bytes_per_sample
             in
             let span = min window_bytes available in
             (* Odd byte counts happen: the reader can catch the recorder
                between the two halves of a sample. *)
             let span = span - (span mod bytes_per_sample) in
             if span < bytes_per_sample
             then Error "no audio yet"
             else (
               seek_in channel (file_length - span);
               let pcm = really_input_string channel span in
               let count = span / bytes_per_sample in
               let sum = ref 0.0 in
               for index = 0 to count - 1 do
                 let low = Char.code pcm.[index * 2] in
                 let high = Char.code pcm.[(index * 2) + 1] in
                 let raw = low lor (high lsl 8) in
                 let signed = if raw >= 32_768 then raw - 65_536 else raw in
                 let sample = float_of_int signed in
                 sum := !sum +. (sample *. sample)
               done;
               Ok (sqrt (!sum /. float_of_int count) /. full_scale))))
;;
