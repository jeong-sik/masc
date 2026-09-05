(** Image downscaling boundary for keeper vision calls.
    RFC-0414 follow-up / Issue #33075. *)

let default_max_dimension = 1568

let max_dimension () = Env_config_keeper.KeeperVision.max_dimension ()

type dimensions =
  { width : int
  ; height : int
  }

type scaler =
  | Sips
  | Magick
  | Convert

let scaler_to_string = function
  | Sips -> "sips"
  | Magick -> "magick"
  | Convert -> "convert"
;;

type failure_reason =
  | Scalers_exhausted
  | Scaler_exception of string

let failure_reason_to_string = function
  | Scalers_exhausted -> "scalers_exhausted"
  | Scaler_exception msg -> "exception:" ^ msg
;;

type downscale_status =
  | Unchanged_within_bounds of dimensions
  | Unchanged_unknown_dimensions
  | Downscaled of
      { original_dims : dimensions
      ; scaled_dims : dimensions option
      ; scaler : scaler
      }
  | Downscale_fallback_error of failure_reason

type metric_result =
  | Metric_ok
  | Metric_unchanged
  | Metric_error

type metric_reason =
  | Reason_within_bounds
  | Reason_unknown_dims
  | Reason_downscaled
  | Reason_downscale_failed

let string_of_metric_result = function
  | Metric_ok -> "ok"
  | Metric_unchanged -> "unchanged"
  | Metric_error -> "error"
;;

let string_of_metric_reason = function
  | Reason_within_bounds -> "within_bounds"
  | Reason_unknown_dims -> "unknown_dims"
  | Reason_downscaled -> "downscaled"
  | Reason_downscale_failed -> "downscale_failed"
;;

let le16 bytes offset =
  Char.code bytes.[offset] lor (Char.code bytes.[offset + 1] lsl 8)
;;

let le24 bytes offset =
  Char.code bytes.[offset]
  lor (Char.code bytes.[offset + 1] lsl 8)
  lor (Char.code bytes.[offset + 2] lsl 16)
;;

let le32 bytes offset =
  Char.code bytes.[offset]
  lor (Char.code bytes.[offset + 1] lsl 8)
  lor (Char.code bytes.[offset + 2] lsl 16)
  lor (Char.code bytes.[offset + 3] lsl 24)
;;

let webp_dimensions bytes =
  let len = String.length bytes in
  if len >= 20
     && String.equal (String.sub bytes 0 4) "RIFF"
     && String.equal (String.sub bytes 8 4) "WEBP"
  then (
    let fourcc = String.sub bytes 12 4 in
    if String.equal fourcc "VP8 " then
      if len >= 30
         && Char.code bytes.[23] = 0x9d
         && Char.code bytes.[24] = 0x01
         && Char.code bytes.[25] = 0x2a
      then
        let w = le16 bytes 26 land 0x3fff in
        let h = le16 bytes 28 land 0x3fff in
        Some { width = w; height = h }
      else None
    else if String.equal fourcc "VP8L" then
      if len >= 25 && Char.code bytes.[20] = 0x2f then
        let b = le32 bytes 21 in
        let w = 1 + (b land 0x3fff) in
        let h = 1 + ((b lsr 14) land 0x3fff) in
        Some { width = w; height = h }
      else None
    else if String.equal fourcc "VP8X" then
      if len >= 30 then
        let w = 1 + le24 bytes 24 in
        let h = 1 + le24 bytes 27 in
        Some { width = w; height = h }
      else None
    else None)
  else None
;;

let detect_dimensions bytes =
  match Keeper_image_dimensions.image_dimensions bytes with
  | Some (w, h) -> Some { width = w; height = h }
  | None -> webp_dimensions bytes
;;

let needs_downscale ?max_dimension:max_dim_opt bytes =
  let max_dim = Option.value max_dim_opt ~default:(max_dimension ()) in
  match detect_dimensions bytes with
  | Some { width; height } -> max width height > max_dim
  | None -> false
;;

let ext_of_media_type = function
  | "image/png" -> ".png"
  | "image/jpeg" -> ".jpg"
  | "image/gif" -> ".gif"
  | "image/webp" -> ".webp"
  | _ -> ".img"
;;

let split_path_env value =
  String.split_on_char ':' value
  |> List.filter (fun entry -> String.trim entry <> "")
;;

let find_executable_in_path ?path_value executable =
  let path_value =
    match path_value with
    | Some value -> value
    | None -> Option.value (Sys.getenv_opt "PATH") ~default:""
  in
  let candidates =
    split_path_env path_value
    |> List.map (fun dir -> Filename.concat dir executable)
  in
  List.find_opt (fun path -> Sys.file_exists path && not (Sys.is_directory path)) candidates
;;

let scaler_candidates ~max_dim ~in_file ~out_file ~media_type =
  let is_webp = String.equal media_type "image/webp" in
  let sips_cmd =
    match find_executable_in_path "sips" with
    | Some prog ->
      if is_webp
      then
        (* macOS sips cannot write WebP, but can convert WebP to PNG *)
        Some
          ( Sips
          , [ prog; "-s"; "format"; "png"; "-Z"; string_of_int max_dim; in_file; "--out"; out_file ]
          , "image/png" )
      else
        Some
          ( Sips
          , [ prog; "-Z"; string_of_int max_dim; in_file; "--out"; out_file ]
          , media_type )
    | None -> None
  in
  let magick_cmd =
    match find_executable_in_path "magick" with
    | Some prog ->
      Some
        ( Magick
        , [ prog; in_file; "-resize"; Printf.sprintf "%dx%d>" max_dim max_dim; out_file ]
        , media_type )
    | None -> None
  in
  let convert_cmd =
    match find_executable_in_path "convert" with
    | Some prog ->
      Some
        ( Convert
        , [ prog; in_file; "-resize"; Printf.sprintf "%dx%d>" max_dim max_dim; out_file ]
        , media_type )
    | None -> None
  in
  List.filter_map Fun.id [ sips_cmd; magick_cmd; convert_cmd ]
;;

let read_file_binary path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)
;;

let execute_downscale ~max_dim ~media_type ~bytes =
  let in_ext = ext_of_media_type media_type in
  let in_file, in_oc =
    Filename.open_temp_file ~mode:[ Open_binary ] "masc_scale_in_" in_ext
  in
  let out_file = Filename.temp_file "masc_scale_out_" ".tmp" in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr in_oc;
      (try Sys.remove in_file with _ -> ());
      (try Sys.remove out_file with _ -> ()))
    (fun () ->
      output_string in_oc bytes;
      close_out_noerr in_oc;
      let candidates = scaler_candidates ~max_dim ~in_file ~out_file ~media_type in
      let rec try_candidates = function
        | [] -> Error Scalers_exhausted
        | (scaler, argv, expected_mt) :: rest ->
          (try Sys.remove out_file with _ -> ());
          let status, _stdout, _stderr =
            Process_eio.run_argv_with_status_split ~timeout_sec:10.0 argv
          in
          (match status with
           | Unix.WEXITED 0 ->
             if Sys.file_exists out_file && (Unix.stat out_file).st_size > 0
             then
               let scaled_bytes = read_file_binary out_file in
               let scaled_dims = detect_dimensions scaled_bytes in
               (match scaled_dims with
                | Some dims when max dims.width dims.height <= max_dim ->
                  Ok (expected_mt, scaled_bytes, Some dims, scaler)
                | _ -> try_candidates rest)
             else try_candidates rest
           | _ -> try_candidates rest)
      in
      try_candidates candidates)
;;

let record_downscale ~result ~reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string VisionDownscale)
    ~labels:
      [ "result", string_of_metric_result result
      ; "reason", string_of_metric_reason reason
      ]
    ()
;;

(* The trailing unit is what lets [?max_dimension] be erased. Without it every
   remaining parameter is labelled, so the compiler cannot tell a partial
   application from a complete one and warning 16 fires -- at the definition
   and again at each call that omits the optional. *)
let downscale_with_status ?max_dimension:max_dim_opt ~media_type ~bytes () =
  try
    let max_dim = Option.value max_dim_opt ~default:(max_dimension ()) in
    match detect_dimensions bytes with
    | None ->
      record_downscale ~result:Metric_unchanged ~reason:Reason_unknown_dims;
      ((media_type, bytes), Unchanged_unknown_dimensions)
    | Some dims when max dims.width dims.height <= max_dim ->
      record_downscale ~result:Metric_unchanged ~reason:Reason_within_bounds;
      ((media_type, bytes), Unchanged_within_bounds dims)
    | Some dims ->
      (match execute_downscale ~max_dim ~media_type ~bytes with
       | Ok (out_mt, out_bytes, scaled_dims, scaler) ->
         record_downscale ~result:Metric_ok ~reason:Reason_downscaled;
         ( (out_mt, out_bytes)
         , Downscaled { original_dims = dims; scaled_dims; scaler } )
       | Error reason ->
         Log.Misc.warn
           "[Keeper_vision_downscale] Downscale failed (%s); using original bytes"
           (failure_reason_to_string reason);
         record_downscale ~result:Metric_error ~reason:Reason_downscale_failed;
         ((media_type, bytes), Downscale_fallback_error reason))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let msg = Printexc.to_string exn in
    Log.Misc.warn
      "[Keeper_vision_downscale] Downscale exception (%s); using original bytes"
      msg;
    record_downscale ~result:Metric_error ~reason:Reason_downscale_failed;
    ((media_type, bytes), Downscale_fallback_error (Scaler_exception msg))
;;

let downscale_if_needed ?max_dimension ~media_type ~bytes () =
  let result, _ = downscale_with_status ?max_dimension ~media_type ~bytes () in
  result
;;
