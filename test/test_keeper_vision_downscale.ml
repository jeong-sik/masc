open Alcotest

module Vd = Masc.Keeper_vision_downscale

let be_byte offset value = Char.chr ((value lsr offset) land 0xff)
let be4 value = String.init 4 (fun i -> be_byte ((3 - i) * 8) value)
let be2 value = String.init 2 (fun i -> be_byte ((1 - i) * 8) value)
let le2 value = String.init 2 (fun i -> be_byte (i * 8) value)

let le4 value =
  String.init 4 (fun i -> Char.chr ((value lsr (i * 8)) land 0xff))
;;

let png_header width height =
  String.concat ""
    [ "\x89PNG\r\n\x1a\n"
    ; "\x00\x00\x00\x0d"
    ; "IHDR"
    ; be4 width
    ; be4 height
    ; "\x08\x06\x00\x00\x00"
    ]
;;

let jpeg_header width height =
  String.concat ""
    [ "\xff\xd8"
    ; "\xff\xe0"
    ; "\x00\x04"
    ; "AB"
    ; "\xff\xc0"
    ; "\x00\x08"
    ; "\x08"
    ; be2 height
    ; be2 width
    ]
;;

let gif_header width height = "GIF89a" ^ le2 width ^ le2 height

let webp_vp8_header width height =
  let tag = "\x00\x00\x00" in
  let code = "\x9d\x01\x2a" in
  let dims = le2 (width land 0x3fff) ^ le2 (height land 0x3fff) in
  let payload = tag ^ code ^ dims in
  "RIFF" ^ le4 (String.length payload + 12) ^ "WEBPVP8 " ^ le4 (String.length payload) ^ payload
;;

let webp_vp8l_header width height =
  let packed =
    ((width - 1) land 0x3fff) lor (((height - 1) land 0x3fff) lsl 14)
  in
  let payload = "\x2f" ^ le4 packed in
  "RIFF" ^ le4 (String.length payload + 12) ^ "WEBPVP8L" ^ le4 (String.length payload) ^ payload
;;

let webp_vp8x_header width height =
  let w_bytes = String.sub (le4 (width - 1)) 0 3 in
  let h_bytes = String.sub (le4 (height - 1)) 0 3 in
  let payload = "\x00\x00\x00\x00" ^ w_bytes ^ h_bytes in
  "RIFF" ^ le4 (String.length payload + 12) ^ "WEBPVP8X" ^ le4 10 ^ payload
;;

let dims_pair (d : Vd.dimensions) = (d.width, d.height)

let test_detect_dimensions_png () =
  let res = Vd.detect_dimensions (png_header 3456 2168) in
  check (option (pair int int)) "png dimensions" (Some (3456, 2168))
    (Option.map dims_pair res);
  check (option (pair int int)) "truncated png" None
    (Option.map dims_pair (Vd.detect_dimensions "\x89PNG"))
;;

let test_detect_dimensions_jpeg () =
  let res = Vd.detect_dimensions (jpeg_header 12345 6789) in
  check (option (pair int int)) "jpeg dimensions" (Some (12345, 6789))
    (Option.map dims_pair res);
  check (option (pair int int)) "broken jpeg" None
    (Option.map dims_pair (Vd.detect_dimensions "\xff\xd8\x00\x00"))
;;

let test_detect_dimensions_gif () =
  let res = Vd.detect_dimensions (gif_header 800 600) in
  check (option (pair int int)) "gif dimensions" (Some (800, 600))
    (Option.map dims_pair res)
;;

let test_detect_dimensions_webp () =
  let res_vp8 = Vd.detect_dimensions (webp_vp8_header 2500 1200) in
  check (option (pair int int)) "webp vp8 dimensions" (Some (2500, 1200))
    (Option.map dims_pair res_vp8);

  let res_vp8l = Vd.detect_dimensions (webp_vp8l_header 3100 1800) in
  check (option (pair int int)) "webp vp8l dimensions" (Some (3100, 1800))
    (Option.map dims_pair res_vp8l);

  let res_vp8x = Vd.detect_dimensions (webp_vp8x_header 2048 1536) in
  check (option (pair int int)) "webp vp8x dimensions" (Some (2048, 1536))
    (Option.map dims_pair res_vp8x);

  check (option (pair int int)) "truncated webp" None
    (Option.map dims_pair (Vd.detect_dimensions "RIFF\x00\x00\x00\x00WEBPVP8 "))
;;

let test_needs_downscale () =
  check bool "within bounds (1000, 800) with max 1568" false
    (Vd.needs_downscale ~max_dimension:1568 (png_header 1000 800));
  check bool "exact bounds (1568, 1568) with max 1568" false
    (Vd.needs_downscale ~max_dimension:1568 (png_header 1568 1568));
  check bool "exceeding width (2000, 1000) with max 1568" true
    (Vd.needs_downscale ~max_dimension:1568 (png_header 2000 1000));
  check bool "exceeding height (1000, 2000) with max 1568" true
    (Vd.needs_downscale ~max_dimension:1568 (png_header 1000 2000));
  check bool "unknown format returns false" false
    (Vd.needs_downscale ~max_dimension:1568 "not-an-image")
;;

(* {1 Media types} *)

let test_media_type_round_trip () =
  List.iter
    (fun media_type ->
      let name = Vd.media_type_to_string media_type in
      match Vd.media_type_of_string name with
      | Some parsed -> check bool ("round trip " ^ name) true (parsed = media_type)
      | None -> failf "%s did not parse back" name)
    Vd.all_media_types;
  check int "four formats and no more" 4 (List.length Vd.all_media_types);
  check bool "bmp is outside the closed set" true
    (Option.is_none (Vd.media_type_of_string "image/bmp"));
  check bool "an empty string is outside the closed set" true
    (Option.is_none (Vd.media_type_of_string ""))
;;

(* {1 Scaler plans} *)

let test_scaler_plans_shape () =
  let plans media_type =
    Vd.scaler_plans ~max_dim:1568 ~in_file:"/in.img" ~out_file:"/out.tmp" media_type
  in
  let scalers media_type = List.map (fun (p : Vd.scaler_plan) -> p.scaler) (plans media_type) in
  check (list string) "sips, then magick, then convert" [ "sips"; "magick"; "convert" ]
    (List.map Vd.scaler_to_string (scalers Vd.Png));
  List.iter
    (fun (plan : Vd.scaler_plan) ->
      match plan.argv with
      | program :: _ ->
        check string "argv[0] is the bare program name for the spawner to resolve"
          (Vd.scaler_to_string plan.scaler) program
      | [] -> fail "a plan with an empty argv")
    (plans Vd.Png);
  (match plans Vd.Webp with
   | (sips : Vd.scaler_plan) :: _ ->
     check bool "sips turns webp into png" true (sips.output_media_type = Vd.Png);
     check bool "the sips argv asks for png output" true
       (List.mem "format" sips.argv && List.mem "png" sips.argv)
   | [] -> fail "no plans for webp");
  (match plans Vd.Jpeg with
   | (sips : Vd.scaler_plan) :: _ ->
     check bool "sips keeps jpeg as jpeg" true (sips.output_media_type = Vd.Jpeg)
   | [] -> fail "no plans for jpeg")
;;

(* {1 Downscale without a process} *)

let test_downscale_with_status_within_bounds () =
  let bytes = gif_header 800 600 in
  let (out_mt, out_bytes), status =
    Vd.downscale_with_status ~max_dimension:1568 ~media_type:"image/gif" ~bytes ()
  in
  check string "same media type" "image/gif" out_mt;
  check string "identical bytes" bytes out_bytes;
  match status with
  | Vd.Unchanged_within_bounds { width = 800; height = 600 } -> ()
  | Vd.Unchanged_within_bounds _
  | Vd.Unchanged_unknown_dimensions
  | Vd.Downscaled _
  | Vd.Downscale_fallback_error _ -> fail "expected Unchanged_within_bounds 800x600"
;;

let test_downscale_with_status_unknown () =
  let bytes = "random_unparseable_bytes" in
  let (out_mt, out_bytes), status =
    Vd.downscale_with_status ~max_dimension:1568 ~media_type:"image/png" ~bytes ()
  in
  check string "same media type" "image/png" out_mt;
  check string "identical bytes" bytes out_bytes;
  match status with
  | Vd.Unchanged_unknown_dimensions -> ()
  | Vd.Unchanged_within_bounds _
  | Vd.Downscaled _
  | Vd.Downscale_fallback_error _ -> fail "expected Unchanged_unknown_dimensions"
;;

(* A media type outside the closed set is refused before the plan is even
   built, so no scaler can be spawned for it. *)
let test_unsupported_media_type_is_refused_without_spawning () =
  let planned = ref false in
  let plans ~max_dim:_ ~in_file:_ ~out_file:_ _media_type =
    planned := true;
    []
  in
  let bytes = png_header 2000 1000 in
  let (out_mt, out_bytes), status =
    Vd.downscale_with_status ~max_dimension:1568 ~plans ~media_type:"image/bmp" ~bytes ()
  in
  check string "the caller's media type comes back" "image/bmp" out_mt;
  check string "the bytes come back untouched" bytes out_bytes;
  check bool "no plan was built" false !planned;
  match status with
  | Vd.Downscale_fallback_error (Vd.Unsupported_media_type "image/bmp") -> ()
  | Vd.Downscale_fallback_error reason ->
    failf "expected Unsupported_media_type, got %s" (Vd.failure_reason_to_string reason)
  | Vd.Unchanged_within_bounds _ | Vd.Unchanged_unknown_dimensions | Vd.Downscaled _ ->
    fail "expected Downscale_fallback_error"
;;

(* {1 Downscale through controlled scalers}

   Every plan below runs a real process. The chain is driven through the
   [plans] parameter, so which program plays each scaler is the test's
   choice; the module still spawns, waits, reads the output file and checks
   its header. *)

let with_runtime f =
  Eio_main.run @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.fs env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing f
;;

let write_fixture bytes =
  let path = Filename.temp_file "masc_vd_fixture_" ".png" in
  Out_channel.with_open_bin path (fun oc -> output_string oc bytes);
  path
;;

let remove_fixture path = try Sys.remove path with Sys_error _ -> ()

let refused_stderr = "scaler-refused-fixture"

(* Exits 2 after writing to stderr; writes no output. *)
let refusing scaler : Vd.scaler_plan =
  { scaler
  ; argv = [ "/bin/sh"; "-c"; Printf.sprintf "echo %s >&2; exit 2" refused_stderr ]
  ; output_media_type = Vd.Png
  }
;;

(* Copies [fixture] to the output file, as a scaler that produced [fixture]. *)
let copying scaler ~fixture ~out_file : Vd.scaler_plan =
  { scaler; argv = [ "/bin/cp"; fixture; out_file ]; output_media_type = Vd.Png }
;;

(* Exits 0 and writes nothing. *)
let silent scaler : Vd.scaler_plan =
  { scaler; argv = [ "/bin/sh"; "-c"; "exit 0" ]; output_media_type = Vd.Png }
;;

(* A program that is on no PATH. *)
let missing_program = Printf.sprintf "masc-no-such-scaler-%d" (Unix.getpid ())

let missing scaler ~in_file ~out_file : Vd.scaler_plan =
  { scaler; argv = [ missing_program; in_file; out_file ]; output_media_type = Vd.Png }
;;

let oversized_input = png_header 2000 1000

let attempt_scaler (a : Vd.attempt) = Vd.scaler_to_string a.attempted.scaler

let check_exited_nonzero_with_refusal label (a : Vd.attempt) =
  match a.failure with
  | Vd.Exited_nonzero { code; output } ->
    check int (label ^ ": exit code") 2 code;
    check bool (label ^ ": stderr kept") true
      (String.equal (String.trim output.stderr) refused_stderr);
    check string (label ^ ": stdout kept and empty") "" output.stdout
  | Vd.Spawn_refused _
  | Vd.Timed_out _
  | Vd.Signaled _
  | Vd.Stopped _
  | Vd.No_output_written _
  | Vd.Output_dimensions_unknown _
  | Vd.Output_still_too_large _ ->
    failf "%s: expected Exited_nonzero, got %s" label (Vd.attempt_to_string a)
;;

let test_first_scaler_fails_second_succeeds () =
  with_runtime @@ fun () ->
  let fixture = write_fixture (png_header 800 600) in
  Fun.protect ~finally:(fun () -> remove_fixture fixture) @@ fun () ->
  let plans ~max_dim:_ ~in_file:_ ~out_file _media_type =
    [ refusing Vd.Sips; copying Vd.Magick ~fixture ~out_file ]
  in
  let (out_mt, out_bytes), status =
    Vd.downscale_with_status ~max_dimension:1568 ~plans ~media_type:"image/png"
      ~bytes:oversized_input ()
  in
  match status with
  | Vd.Downscaled { original_dims; scaled_dims; scaler; failed_before } ->
    check string "output media type" "image/png" out_mt;
    check string "the output file's bytes come back" (png_header 800 600) out_bytes;
    check (pair int int) "original dims" (2000, 1000) (dims_pair original_dims);
    check (pair int int) "scaled dims read from the output" (800, 600) (dims_pair scaled_dims);
    check string "the second scaler did it" "magick" (Vd.scaler_to_string scaler);
    (match failed_before with
     | [ first ] ->
       check string "the first attempt is kept" "sips" (attempt_scaler first);
       check_exited_nonzero_with_refusal "first attempt" first
     | [] -> fail "the failed first attempt was dropped"
     | _ :: _ :: _ -> fail "more attempts than scalers that ran")
  | Vd.Downscale_fallback_error reason ->
    failf "expected Downscaled, got %s" (Vd.failure_reason_to_string reason)
  | Vd.Unchanged_within_bounds _ | Vd.Unchanged_unknown_dimensions ->
    fail "expected Downscaled"
;;

let index_of needle haystack =
  let ln = String.length needle and lh = String.length haystack in
  let rec go i =
    if i + ln > lh then None
    else if String.equal (String.sub haystack i ln) needle then Some i
    else go (i + 1)
  in
  go 0
;;

let test_every_scaler_fails_lists_every_attempt_in_order () =
  with_runtime @@ fun () ->
  let too_large = write_fixture (png_header 3000 3000) in
  Fun.protect ~finally:(fun () -> remove_fixture too_large) @@ fun () ->
  let plans ~max_dim:_ ~in_file:_ ~out_file _media_type =
    [ refusing Vd.Sips; silent Vd.Magick; copying Vd.Convert ~fixture:too_large ~out_file ]
  in
  let (out_mt, out_bytes), status =
    Vd.downscale_with_status ~max_dimension:1568 ~plans ~media_type:"image/png"
      ~bytes:oversized_input ()
  in
  check string "the caller's media type comes back" "image/png" out_mt;
  check string "the original bytes come back" oversized_input out_bytes;
  match status with
  | Vd.Downscale_fallback_error (Vd.Scalers_exhausted attempts as reason) ->
    check (list string) "every scaler, in the order tried"
      [ "sips"; "magick"; "convert" ]
      (List.map attempt_scaler attempts);
    (match attempts with
     | [ first; second; third ] ->
       check_exited_nonzero_with_refusal "sips" first;
       (match second.failure with
        | Vd.No_output_written _ -> ()
        | Vd.Spawn_refused _
        | Vd.Exited_nonzero _
        | Vd.Timed_out _
        | Vd.Signaled _
        | Vd.Stopped _
        | Vd.Output_dimensions_unknown _
        | Vd.Output_still_too_large _ ->
          failf "magick: expected No_output_written, got %s" (Vd.attempt_to_string second));
       (match third.failure with
        | Vd.Output_still_too_large { dims; output = _ } ->
          check (pair int int) "convert: the oversized output's dims" (3000, 3000) (dims_pair dims)
        | Vd.Spawn_refused _
        | Vd.Exited_nonzero _
        | Vd.Timed_out _
        | Vd.Signaled _
        | Vd.Stopped _
        | Vd.No_output_written _
        | Vd.Output_dimensions_unknown _ ->
          failf "convert: expected Output_still_too_large, got %s" (Vd.attempt_to_string third))
     | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ :: _ -> fail "expected exactly three attempts");
    let line = Vd.failure_reason_to_string reason in
    check bool "the rendered reason carries the first scaler's stderr" true
      (Option.is_some (index_of refused_stderr line));
    (match index_of "sips" line, index_of "magick" line, index_of "convert" line with
     | Some s, Some m, Some c ->
       check bool "the rendered reason lists the scalers in the order tried" true (s < m && m < c)
     | None, _, _ | _, None, _ | _, _, None ->
       failf "a scaler is missing from the rendered reason: %s" line)
  | Vd.Downscale_fallback_error reason ->
    failf "expected Scalers_exhausted, got %s" (Vd.failure_reason_to_string reason)
  | Vd.Unchanged_within_bounds _ | Vd.Unchanged_unknown_dimensions | Vd.Downscaled _ ->
    fail "expected Downscale_fallback_error"
;;

let check_executable_not_found label (a : Vd.attempt) =
  match a.failure with
  | Vd.Spawn_refused (Process_eio.Executable_not_found program) ->
    check string (label ^ ": the refusal names the absent program") missing_program program
  | Vd.Spawn_refused
      (( Process_eio.Empty_argv | Process_eio.Spawn_failed _ | Process_eio.Child_setup_failed _
       | Process_eio.Cwd_unavailable _ ) as refusal) ->
    failf "%s: expected Executable_not_found, got %s" label
      (Process_eio.spawn_refusal_to_string refusal)
  | Vd.Exited_nonzero _
  | Vd.Timed_out _
  | Vd.Signaled _
  | Vd.Stopped _
  | Vd.No_output_written _
  | Vd.Output_dimensions_unknown _
  | Vd.Output_still_too_large _ ->
    failf "%s: expected Executable_not_found, got %s" label (Vd.attempt_to_string a)
;;

(* A program that does not exist is one attempt with a typed outcome. It is
   neither an exception nor a 127 exit dressed as one. *)
let test_missing_executable_is_one_typed_attempt () =
  with_runtime @@ fun () ->
  let fixture = write_fixture (png_header 800 600) in
  Fun.protect ~finally:(fun () -> remove_fixture fixture) @@ fun () ->
  (* Alone in the chain: the chain is exhausted by that one attempt. *)
  let only_missing ~max_dim:_ ~in_file ~out_file _media_type =
    [ missing Vd.Sips ~in_file ~out_file ]
  in
  let _, status =
    Vd.downscale_with_status ~max_dimension:1568 ~plans:only_missing
      ~media_type:"image/png" ~bytes:oversized_input ()
  in
  (match status with
   | Vd.Downscale_fallback_error (Vd.Scalers_exhausted [ only ]) ->
     check_executable_not_found "only attempt" only
   | Vd.Downscale_fallback_error reason ->
     failf "expected one exhausted attempt, got %s" (Vd.failure_reason_to_string reason)
   | Vd.Unchanged_within_bounds _ | Vd.Unchanged_unknown_dimensions | Vd.Downscaled _ ->
     fail "expected Downscale_fallback_error");
  (* First in the chain: the next scaler runs and the absence is recorded. *)
  let missing_then_copy ~max_dim:_ ~in_file ~out_file _media_type =
    [ missing Vd.Sips ~in_file ~out_file; copying Vd.Convert ~fixture ~out_file ]
  in
  let _, status =
    Vd.downscale_with_status ~max_dimension:1568 ~plans:missing_then_copy
      ~media_type:"image/png" ~bytes:oversized_input ()
  in
  match status with
  | Vd.Downscaled { scaler; failed_before = [ first ]; original_dims = _; scaled_dims = _ } ->
    check string "convert did it" "convert" (Vd.scaler_to_string scaler);
    check_executable_not_found "first attempt" first
  | Vd.Downscaled { failed_before; _ } ->
    failf "expected exactly one earlier attempt, got %d" (List.length failed_before)
  | Vd.Downscale_fallback_error reason ->
    failf "expected Downscaled, got %s" (Vd.failure_reason_to_string reason)
  | Vd.Unchanged_within_bounds _ | Vd.Unchanged_unknown_dimensions ->
    fail "expected Downscaled"
;;

(* Valid 1-bit 2000x1000 PNG base64 fixture *)
let valid_2000x1000_png_b64 =
  "iVBORw0KGgoAAAANSUhEUgAAB9AAAAPoAQAAAACuJVgHAAAD5klEQVR42u3PAQEAAAgCIOv/5xoi"
  ^ "PGAurTbq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6hUehaYIz0sqNDUAAAAASUVORK5CYII="
;;

(* The real chain on whatever this host has installed. A host with a scaler
   downscales; a host with none reports every scaler absent. A scaler that is
   present and still fails on a valid PNG is a finding, and the message says
   which one and why. *)
let test_downscale_oversized_png_live () =
  with_runtime @@ fun () ->
  let bytes =
    match Base64.decode valid_2000x1000_png_b64 with
    | Ok b -> b
    | Error (`Msg msg) -> failwith ("fixture b64 decode failed: " ^ msg)
  in
  let (out_mt, out_bytes), status =
    Vd.downscale_with_status ~max_dimension:1568 ~media_type:"image/png" ~bytes ()
  in
  match status with
  | Vd.Downscaled { original_dims; scaled_dims; scaler = _; failed_before = _ } ->
    check string "downscaled media type" "image/png" out_mt;
    check (pair int int) "original dims" (2000, 1000) (dims_pair original_dims);
    check bool "scaled width <= 1568" true (scaled_dims.width <= 1568);
    check bool "scaled height <= 1568" true (scaled_dims.height <= 1568)
  | Vd.Downscale_fallback_error (Vd.Scalers_exhausted attempts as reason) ->
    check string "fallback media type" "image/png" out_mt;
    check string "fallback original bytes" bytes out_bytes;
    check int "one attempt per planned scaler" 3 (List.length attempts);
    List.iter
      (fun (a : Vd.attempt) ->
        match a.failure with
        | Vd.Spawn_refused (Process_eio.Executable_not_found _) -> ()
        | Vd.Spawn_refused
            ( Process_eio.Empty_argv | Process_eio.Spawn_failed _ | Process_eio.Child_setup_failed _
            | Process_eio.Cwd_unavailable _ )
        | Vd.Exited_nonzero _
        | Vd.Timed_out _
        | Vd.Signaled _
        | Vd.Stopped _
        | Vd.No_output_written _
        | Vd.Output_dimensions_unknown _
        | Vd.Output_still_too_large _ ->
          failf "an installed scaler failed on a valid png: %s"
            (Vd.failure_reason_to_string reason))
      attempts
  | Vd.Downscale_fallback_error reason ->
    failf "unexpected fallback: %s" (Vd.failure_reason_to_string reason)
  | Vd.Unchanged_within_bounds _ | Vd.Unchanged_unknown_dimensions ->
    fail "expected Downscaled or Scalers_exhausted"
;;

let test_closed_sum_printers () =
  check string "sips to string" "sips" (Vd.scaler_to_string Vd.Sips);
  check string "magick to string" "magick" (Vd.scaler_to_string Vd.Magick);
  check string "convert to string" "convert" (Vd.scaler_to_string Vd.Convert);
  check string "unsupported media type names the type" "unsupported_media_type:image/bmp"
    (Vd.failure_reason_to_string (Vd.Unsupported_media_type "image/bmp"));
  check string "an empty chain says so" "scalers_exhausted: no scaler was planned"
    (Vd.failure_reason_to_string (Vd.Scalers_exhausted []));
  check string "exception to string" "exception:test"
    (Vd.failure_reason_to_string (Vd.Scaler_exception "test"));
  let attempt : Vd.attempt =
    { attempted = { scaler = Vd.Magick; argv = [ "magick"; "a"; "b" ]; output_media_type = Vd.Png }
    ; failure = Vd.Exited_nonzero { code = 1; output = { stdout = ""; stderr = "boom\n" } }
    }
  in
  let rendered = Vd.attempt_to_string attempt in
  check bool "an attempt names its scaler" true (Option.is_some (index_of "magick" rendered));
  check bool "an attempt shows the exit code" true (Option.is_some (index_of "exited 1" rendered));
  check bool "an attempt shows the trimmed stderr" true
    (Option.is_some (index_of "stderr=\"boom\"" rendered))
;;

let () =
  run "Keeper_vision_downscale"
    [ ( "dimensions"
      , [ test_case "png header" `Quick test_detect_dimensions_png
        ; test_case "jpeg header" `Quick test_detect_dimensions_jpeg
        ; test_case "gif header" `Quick test_detect_dimensions_gif
        ; test_case "webp headers (vp8, vp8l, vp8x)" `Quick
            test_detect_dimensions_webp
        ] )
    ; ( "decision"
      , [ test_case "needs_downscale bounds logic" `Quick test_needs_downscale
        ; test_case "media type closed set round trip" `Quick test_media_type_round_trip
        ; test_case "scaler plans shape" `Quick test_scaler_plans_shape
        ] )
    ; ( "downscale"
      , [ test_case "within bounds is unchanged" `Quick
            test_downscale_with_status_within_bounds
        ; test_case "unknown format is unchanged" `Quick
            test_downscale_with_status_unknown
        ; test_case "unsupported media type is refused without spawning" `Quick
            test_unsupported_media_type_is_refused_without_spawning
        ; test_case "first scaler fails, second succeeds, first is kept" `Quick
            test_first_scaler_fails_second_succeeds
        ; test_case "every scaler fails, every attempt listed in order" `Quick
            test_every_scaler_fails_lists_every_attempt_in_order
        ; test_case "missing executable is one typed attempt" `Quick
            test_missing_executable_is_one_typed_attempt
        ; test_case "oversized png live downscale" `Quick
            test_downscale_oversized_png_live
        ; test_case "closed sum printers" `Quick
            test_closed_sum_printers
        ] )
    ]
;;
