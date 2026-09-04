(** Regression: a noise-reduced capture must not leave its temporaries behind.

    PR #33036 introduced [noise_reduced_copy], whose success path handed the
    reduced [masc_nr_*.wav] to the caller and nobody removed it — every
    noise-reduced capture leaked one file forever. The scope-guard replacement
    ([with_noise_reduced_audio]) removes both temporaries when [f] returns,
    falls back to the original file when sox fails, and still cleans up when
    [f] raises.

    sox itself is not needed: [run_voice_status] resolves [sox] through PATH,
    so a stub script decides success or failure deterministically.

    Every path is derived from this process's own
    [Filename.get_temp_dir_name], proven to exist by a probe file. TMPDIR is
    deliberately not rewritten: inside a dune action the temp dir is a private
    overlay, and pointing TMPDIR elsewhere makes file creation and directory
    reads disagree across the exec boundary. *)

open Alcotest

exception F_raised

(* One concrete result type for the polymorphic guard; assertions read it
   through [Result.is_ok] / [Error F_raised]. *)
type guard_return = Guard_ok

let write_stub_sox ~dir ~behavior =
  let path = Filename.concat dir "sox" in
  let body =
    match behavior with
    | `ok ->
      "#!/bin/sh\n\
      \ # Accepts any argv; writes the profile where noiseprof expects one.\n\
      \ for a in \"$@\"; do case \"$a\" in *.prof) : > \"$a\";; esac; done\n\
      \ exit 0\n"
    | `fail -> "#!/bin/sh\nexit 1\n"
  in
  let oc = open_out_bin path in
  output_string oc body;
  close_out oc;
  Unix.chmod path 0o755;
  path
;;

let count_masc_nr_files dir =
  Array.to_list (Sys.readdir dir)
  |> List.filter (fun name ->
         String.length name >= 7 && String.sub name 0 7 = "masc_nr_")
  |> List.length
;;

(* The temp dir this process actually writes to, proven by a probe file. *)
let proven_temp_dir () =
  let probe = Filename.temp_file "masc_nr_probe_" "" in
  let dir = Filename.dirname probe in
  Sys.remove probe;
  dir
;;

let make_source_wav dir =
  let path = Filename.concat dir "masc_nr_capture.wav" in
  let oc = open_out_bin path in
  output_string oc "RIFFfake-wav-bytes";
  close_out oc;
  path
;;

(* Puts a stub sox first on PATH, runs the guard, restores PATH. Returns the
   proven temp dir, the file [f] saw, and the guard's outcome. [raise_in_f]
   decides whether [f] raises, so the leak assertion covers that path too. *)
let run_guard ~behavior ~raise_in_f ~(observe : string option ref) () =
  let dir = proven_temp_dir () in
  let audio_file = make_source_wav dir in
  let before = count_masc_nr_files dir in
  let bindir = Filename.concat dir "masc_nr_stub_bin" in
  (try Unix.mkdir bindir 0o755 with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  ignore (write_stub_sox ~dir:bindir ~behavior);
  let old_path = Sys.getenv_opt "PATH" |> Option.value ~default:"" in
  Unix.putenv "PATH" (bindir ^ ":" ^ old_path);
  let result =
    try
      Ok
        (Masc.Voice_bridge.with_noise_reduced_audio ~audio_file ~f:(fun p ->
             observe := Some p;
             if raise_in_f then raise F_raised else Guard_ok))
    with
    | exn -> Error exn
  in
  Unix.putenv "PATH" old_path;
  (try Sys.remove (Filename.concat bindir "sox") with
  | Sys_error _ -> ());
  (try Unix.rmdir bindir with
  | Sys_error _ | Unix.Unix_error _ -> ());
  (Sys.remove audio_file;
   (dir, before, result))
;;

let test_success_path_leaves_no_temporaries () =
  let observe = ref None in
  let dir, before, result = run_guard ~behavior:`ok ~raise_in_f:false ~observe () in
  check bool "guard returned normally" true
    (match result with
     | Ok Guard_ok -> true
     | _ -> false);
  check bool "f ran on a .wav" true
    (match !observe with
     | Some p -> Filename.check_suffix p ".wav"
     | None -> false);
  (match !observe with
   | Some p -> check bool "reduced copy removed" false (Sys.file_exists p)
   | None -> ());
  check int "no new masc_nr_* left behind" before (count_masc_nr_files dir)
;;

let test_sox_failure_falls_back_to_original () =
  let observe = ref None in
  let dir, before, result = run_guard ~behavior:`fail ~raise_in_f:false ~observe () in
  check bool "guard returned normally" true
    (match result with
     | Ok Guard_ok -> true
     | _ -> false);
  (match !observe with
   | Some p ->
     check bool "fell back to the original capture" true
       (Filename.check_suffix p "masc_nr_capture.wav")
   | None -> check bool "f was called" true false);
  check int "no new masc_nr_* left behind" before (count_masc_nr_files dir)
;;

let test_f_raising_still_cleans_up () =
  let observe = ref None in
  let dir, before, result = run_guard ~behavior:`ok ~raise_in_f:true ~observe () in
  check bool "f's exception propagated" true
    (match result with
     | Error F_raised -> true
     | _ -> false);
  (match !observe with
   | Some p -> check bool "reduced copy removed even after raise" false (Sys.file_exists p)
   | None -> ());
  check int "no new masc_nr_* left behind after raise" before
    (count_masc_nr_files dir)
;;

let () =
  Alcotest.run
    "voice noise-reduction cleanup"
    [ ( "temporaries are scope-owned"
      , [ test_case "success leaves none" `Quick test_success_path_leaves_no_temporaries
        ; test_case "sox failure falls back to original" `Quick
            test_sox_failure_falls_back_to_original
        ; test_case "f raising still cleans up" `Quick test_f_raising_still_cleans_up
        ] ) ]
;;
