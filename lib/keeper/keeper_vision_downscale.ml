(** Image downscaling boundary for keeper vision calls.
    RFC-0414 follow-up / Issue #33075. *)

let default_max_dimension = 1568

let max_dimension () = Env_config_keeper.KeeperVision.max_dimension ()

(* Wall-clock budget for one scaler process.

   The input is bounded by [Env_config_keeper.KeeperVision.max_image_bytes]
   (10 MiB ceiling). Resizing a 4000x4000 RGB PNG (3.2 MB) to 1568 px took
   0.17 s with sips, 0.10 s with magick and 0.09 s with convert on an M3 Max
   on 2026-09-05, so this budget is about sixty times the work and fires only
   on a scaler that hangs. Process_eio reports the kill as [Timed_out] and the
   chain moves to the next scaler, so the longest wait before the original
   bytes go out is this value times the number of scalers in
   [scaler_plans]. It is a module constant, not a keeper runtime setting,
   because no operator has needed to move it; if one does, it belongs in
   [Keeper_runtime_setting_registry] next to [vision.max_dimension]. *)
let scaler_timeout_sec = 10.0

type dimensions =
  { width : int
  ; height : int
  }

(* Exactly the formats [detect_dimensions] can read. A media type outside this
   set is refused before any process is spawned: the scalers would be handed
   bytes whose result this module cannot check against the bound. *)
type media_type =
  | Png
  | Jpeg
  | Gif
  | Webp

let all_media_types = [ Png; Jpeg; Gif; Webp ]

let media_type_to_string = function
  | Png -> "image/png"
  | Jpeg -> "image/jpeg"
  | Gif -> "image/gif"
  | Webp -> "image/webp"
;;

(* The inverse is derived from [media_type_to_string] over [all_media_types]
   so there is one spelling of each name; the string side of the boundary is
   open and anything not in the closed set is [None]. *)
let media_type_of_string name =
  List.find_opt
    (fun media_type -> String.equal (media_type_to_string media_type) name)
    all_media_types
;;

let file_extension_of_media_type = function
  | Png -> ".png"
  | Jpeg -> ".jpg"
  | Gif -> ".gif"
  | Webp -> ".webp"
;;

type scaler =
  | Sips
  | Magick
  | Convert

let scaler_to_string = function
  | Sips -> "sips"
  | Magick -> "magick"
  | Convert -> "convert"
;;

type scaler_plan =
  { scaler : scaler
  ; argv : string list
  ; output_media_type : media_type
  }

type captured_output =
  { stdout : string
  ; stderr : string
  }

type attempt_failure =
  | Spawn_refused of Process_eio.spawn_refusal
  | Exited_nonzero of
      { code : int
      ; output : captured_output
      }
  | Timed_out of captured_output
  | Signaled of
      { signal : int
      ; output : captured_output
      }
  | Stopped of
      { signal : int
      ; output : captured_output
      }
  | No_output_written of captured_output
  | Output_dimensions_unknown of captured_output
  | Output_still_too_large of
      { dims : dimensions
      ; output : captured_output
      }

type attempt =
  { attempted : scaler_plan
  ; failure : attempt_failure
  }

type failure_reason =
  | Unsupported_media_type of string
  | Scalers_exhausted of attempt list
  | Scaler_exception of string

let captured_output_to_string { stdout; stderr } =
  Printf.sprintf "stdout=%S stderr=%S" (String.trim stdout) (String.trim stderr)
;;

let attempt_failure_to_string = function
  | Spawn_refused refusal -> Process_eio.spawn_refusal_to_string refusal
  | Exited_nonzero { code; output } ->
    Printf.sprintf "exited %d (%s)" code (captured_output_to_string output)
  | Timed_out output ->
    Printf.sprintf
      "timed out after %.1fs (%s)"
      scaler_timeout_sec
      (captured_output_to_string output)
  | Signaled { signal; output } ->
    Printf.sprintf "killed by signal %d (%s)" signal (captured_output_to_string output)
  | Stopped { signal; output } ->
    Printf.sprintf "stopped by signal %d (%s)" signal (captured_output_to_string output)
  | No_output_written output ->
    Printf.sprintf "exited 0 but wrote no output file (%s)" (captured_output_to_string output)
  | Output_dimensions_unknown output ->
    Printf.sprintf
      "exited 0 but the output header has no readable dimensions (%s)"
      (captured_output_to_string output)
  | Output_still_too_large { dims; output } ->
    Printf.sprintf
      "exited 0 but the output is %dx%d, still over the bound (%s)"
      dims.width
      dims.height
      (captured_output_to_string output)
;;

let attempt_to_string { attempted; failure } =
  Printf.sprintf
    "%s [%s]: %s"
    (scaler_to_string attempted.scaler)
    (String.concat " " (List.map Filename.quote attempted.argv))
    (attempt_failure_to_string failure)
;;

let failure_reason_to_string = function
  | Unsupported_media_type media_type -> "unsupported_media_type:" ^ media_type
  | Scalers_exhausted [] -> "scalers_exhausted: no scaler was planned"
  | Scalers_exhausted attempts ->
    "scalers_exhausted: " ^ String.concat "; " (List.map attempt_to_string attempts)
  | Scaler_exception msg -> "exception:" ^ msg
;;

type downscale_status =
  | Unchanged_within_bounds of dimensions
  | Unchanged_unknown_dimensions
  | Downscaled of
      { original_dims : dimensions
      ; scaled_dims : dimensions
      ; scaler : scaler
      ; failed_before : attempt list
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
  | Reason_unsupported_media_type

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
  | Reason_unsupported_media_type -> "unsupported_media_type"
;;

let metric_reason_of_failure = function
  | Unsupported_media_type _ -> Reason_unsupported_media_type
  | Scalers_exhausted _ | Scaler_exception _ -> Reason_downscale_failed
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

(* argv[0] is the bare program name: Process_eio's spawner resolves it on
   PATH and reports a program it cannot find, or cannot start, as a
   [Process_eio.spawn_refusal], which [attempt_plan] records as that
   attempt's outcome. *)
let scaler_plans ~max_dim ~in_file ~out_file media_type =
  let bound = string_of_int max_dim in
  let sips =
    match media_type with
    | Webp ->
      (* macOS sips cannot write WebP, but can convert WebP to PNG *)
      { scaler = Sips
      ; argv =
          [ scaler_to_string Sips; "-s"; "format"; "png"; "-Z"; bound; in_file; "--out"; out_file ]
      ; output_media_type = Png
      }
    | Png | Jpeg | Gif ->
      { scaler = Sips
      ; argv = [ scaler_to_string Sips; "-Z"; bound; in_file; "--out"; out_file ]
      ; output_media_type = media_type
      }
  in
  let imagemagick scaler =
    { scaler
    ; argv =
        [ scaler_to_string scaler
        ; in_file
        ; "-resize"
        ; Printf.sprintf "%dx%d>" max_dim max_dim
        ; out_file
        ]
    ; output_media_type = media_type
    }
  in
  [ sips; imagemagick Magick; imagemagick Convert ]
;;

let read_file_binary path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)
;;

(* One scaler run, every way it can fall short named. [out_file] is removed
   first so a file left by an earlier plan cannot pass for this one's. *)
let attempt_plan ~max_dim ~out_file (plan : scaler_plan) =
  (try Sys.remove out_file with Sys_error _ -> ());
  match
    Process_eio.run_argv_with_status_split_or_refusal
      ~timeout_sec:scaler_timeout_sec
      plan.argv
  with
  | Error refusal -> Error (Spawn_refused refusal)
  | Ok (status, stdout, stderr) ->
    let output = { stdout; stderr } in
    (match Process_eio.exit_reason_of_status status with
     | Process_eio.Completed 0 ->
       if Sys.file_exists out_file && (Unix.stat out_file).st_size > 0
       then (
         let scaled_bytes = read_file_binary out_file in
         match detect_dimensions scaled_bytes with
         | None -> Error (Output_dimensions_unknown output)
         | Some dims when max dims.width dims.height <= max_dim ->
           Ok (plan.output_media_type, scaled_bytes, dims, plan.scaler)
         | Some dims -> Error (Output_still_too_large { dims; output }))
       else Error (No_output_written output)
     | Process_eio.Completed code -> Error (Exited_nonzero { code; output })
     | Process_eio.Timed_out -> Error (Timed_out output)
     | Process_eio.Signaled signal -> Error (Signaled { signal; output })
     | Process_eio.Stopped signal -> Error (Stopped { signal; output }))
;;

let execute_downscale ~plans ~max_dim ~media_type ~bytes =
  let in_file, in_oc =
    Filename.open_temp_file
      ~mode:[ Open_binary ]
      "masc_scale_in_"
      (file_extension_of_media_type media_type)
  in
  let out_file = Filename.temp_file "masc_scale_out_" ".tmp" in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr in_oc;
      (* Sys.remove performs no Eio operation, so Eio.Cancel.Cancelled cannot
         originate inside these two catches. The catch stays wide because this
         is Fun.protect's finally: an exception escaping here is re-raised as
         Fun.Finally_raised and masks whatever the protected body raised. *)
      (try Sys.remove in_file with _ -> ()) (* cancel-guard-ok *);
      (try Sys.remove out_file with _ -> ()) (* cancel-guard-ok *))
    (fun () ->
      output_string in_oc bytes;
      close_out_noerr in_oc;
      (* [attempted] is newest-first while the chain runs; both exits put it
         back in the order the scalers ran. *)
      let rec try_plans attempted = function
        | [] -> Error (Scalers_exhausted (List.rev attempted))
        | plan :: rest ->
          (match attempt_plan ~max_dim ~out_file plan with
           | Ok (out_media_type, scaled_bytes, dims, scaler) ->
             Ok (out_media_type, scaled_bytes, dims, scaler, List.rev attempted)
           | Error failure -> try_plans ({ attempted = plan; failure } :: attempted) rest)
      in
      try_plans [] (plans ~max_dim ~in_file ~out_file media_type))
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

(* The boundary log: the whole chain, one attempt after another, in the order
   it ran. An operator whose image went out at full size reads here why each
   scaler refused. *)
let fall_back ~media_type ~bytes reason =
  Log.Misc.warn
    "[Keeper_vision_downscale] Downscale failed (%s); using original bytes"
    (failure_reason_to_string reason);
  record_downscale ~result:Metric_error ~reason:(metric_reason_of_failure reason);
  ((media_type, bytes), Downscale_fallback_error reason)
;;

(* The trailing unit is what lets the optionals be erased. Without it every
   remaining parameter is labelled, so the compiler cannot tell a partial
   application from a complete one and warning 16 fires -- at the definition
   and again at each call that omits them. *)
let downscale_with_status
    ?max_dimension:max_dim_opt
    ?(plans = scaler_plans)
    ~media_type
    ~bytes
    ()
  =
  try
    let max_dim = Option.value max_dim_opt ~default:(max_dimension ()) in
    match media_type_of_string media_type with
    | None -> fall_back ~media_type ~bytes (Unsupported_media_type media_type)
    | Some parsed_media_type ->
      (match detect_dimensions bytes with
       | None ->
         record_downscale ~result:Metric_unchanged ~reason:Reason_unknown_dims;
         ((media_type, bytes), Unchanged_unknown_dimensions)
       | Some dims when max dims.width dims.height <= max_dim ->
         record_downscale ~result:Metric_unchanged ~reason:Reason_within_bounds;
         ((media_type, bytes), Unchanged_within_bounds dims)
       | Some dims ->
         (match
            execute_downscale ~plans ~max_dim ~media_type:parsed_media_type ~bytes
          with
          | Ok (out_media_type, out_bytes, scaled_dims, scaler, failed_before) ->
            (* Scalers that fell short before one succeeded are kept on the
               status and logged at debug: on a host without sips every call
               would otherwise warn about the same absent program. *)
            (match failed_before with
             | [] -> ()
             | _ :: _ ->
               Log.Misc.debug
                 "[Keeper_vision_downscale] Downscaled with %s after: %s"
                 (scaler_to_string scaler)
                 (String.concat "; " (List.map attempt_to_string failed_before)));
            record_downscale ~result:Metric_ok ~reason:Reason_downscaled;
            ( (media_type_to_string out_media_type, out_bytes)
            , Downscaled { original_dims = dims; scaled_dims; scaler; failed_before } )
          | Error reason -> fall_back ~media_type ~bytes reason))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> fall_back ~media_type ~bytes (Scaler_exception (Printexc.to_string exn))
;;

let downscale_if_needed ?max_dimension ~media_type ~bytes () =
  let result, _ = downscale_with_status ?max_dimension ~media_type ~bytes () in
  result
;;
