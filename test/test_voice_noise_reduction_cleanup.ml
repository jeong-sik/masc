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
    reads disagree across the exec boundary.

    The leak check is a set difference, not a count. The first version of this
    file compared seven characters of each name against the eight-character
    prefix ["masc_nr_"], so it never matched anything: the count was always
    zero and three "no leak" assertions were checking that 0 = 0. A count
    would also have been thrown off by the source capture this test creates
    and removes; names that exist after and did not exist before are the
    leak, whatever else the directory holds. *)

open Alcotest

exception F_raised

(* One concrete result type for the polymorphic guard; assertions read it
   through [Result.is_ok] / [Error F_raised]. *)
type guard_return = Guard_ok

let temporary_prefix = "masc_nr_"

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

(* Every name in [dir] the guard could have created, sorted so two listings
   compare as sets. *)
let masc_nr_names dir =
  Array.to_list (Sys.readdir dir)
  |> List.filter (String.starts_with ~prefix:temporary_prefix)
  |> List.sort String.compare
;;

let names_added ~before ~after = List.filter (fun name -> not (List.mem name before)) after

(* The temp dir this process actually writes to, proven by a probe file. *)
let proven_temp_dir () =
  let probe = Filename.temp_file (temporary_prefix ^ "probe_") "" in
  let dir = Filename.dirname probe in
  Sys.remove probe;
  dir
;;

let make_source_wav dir =
  let path = Filename.concat dir (temporary_prefix ^ "capture.wav") in
  let oc = open_out_bin path in
  output_string oc "RIFFfake-wav-bytes";
  close_out oc;
  path
;;

(* Puts a stub sox first on PATH, runs the guard, restores PATH. Returns the
   names the guard left behind in the proven temp dir, the file [f] saw, and
   the guard's outcome. [raise_in_f] decides whether [f] raises, so the leak
   assertion covers that path too. The source capture is created after the
   [before] listing and removed before the [after] one, so it is in neither. *)
let run_guard ~behavior ~raise_in_f ~(observe : string option ref) () =
  let dir = proven_temp_dir () in
  let before = masc_nr_names dir in
  let audio_file = make_source_wav dir in
  let bindir = Filename.concat dir (temporary_prefix ^ "stub_bin") in
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
  Sys.remove audio_file;
  let left_behind = names_added ~before ~after:(masc_nr_names dir) in
  (left_behind, result)
;;

let check_nothing_left_behind label left_behind =
  check (list string) label [] left_behind
;;

let test_success_path_leaves_no_temporaries () =
  let observe = ref None in
  let left_behind, result = run_guard ~behavior:`ok ~raise_in_f:false ~observe () in
  check bool "guard returned normally" true
    (match result with
     | Ok Guard_ok -> true
     | _ -> false);
  (match !observe with
   | Some p ->
     check bool "f ran on a .wav" true (Filename.check_suffix p ".wav");
     check bool "f ran on the reduced copy, not the source" false
       (Filename.check_suffix p "capture.wav");
     check bool "reduced copy removed" false (Sys.file_exists p)
   | None -> check bool "f was called" true false);
  check_nothing_left_behind "no profile or reduced copy left behind" left_behind
;;

let test_sox_failure_falls_back_to_original () =
  let observe = ref None in
  let left_behind, result = run_guard ~behavior:`fail ~raise_in_f:false ~observe () in
  check bool "guard returned normally" true
    (match result with
     | Ok Guard_ok -> true
     | _ -> false);
  (match !observe with
   | Some p ->
     check bool "fell back to the original capture" true
       (Filename.check_suffix p (temporary_prefix ^ "capture.wav"))
   | None -> check bool "f was called" true false);
  (* Both temporaries were created before sox ran and failed; the failure
     path has to remove them just the same. *)
  check_nothing_left_behind "no profile or reduced copy left behind after sox failed"
    left_behind
;;

let test_f_raising_still_cleans_up () =
  let observe = ref None in
  let left_behind, result = run_guard ~behavior:`ok ~raise_in_f:true ~observe () in
  check bool "f's exception propagated" true
    (match result with
     | Error F_raised -> true
     | _ -> false);
  (match !observe with
   | Some p -> check bool "reduced copy removed even after raise" false (Sys.file_exists p)
   | None -> check bool "f was called" true false);
  check_nothing_left_behind "no profile or reduced copy left behind after raise"
    left_behind
;;

(* The predicate this file's leak check runs on. Pinned because the defect was
   in exactly this place: a prefix compare that could never be true. *)
let test_the_leak_predicate_matches_the_names_the_guard_creates () =
  check bool "a profile name is counted" true
    (String.starts_with ~prefix:temporary_prefix "masc_nr_ab12cd.prof");
  check bool "a reduced copy name is counted" true
    (String.starts_with ~prefix:temporary_prefix "masc_nr_ab12cd.wav");
  check bool "an unrelated capture is not" false
    (String.starts_with ~prefix:temporary_prefix "masc_stt_agent_ab12cd.wav");
  check (list string) "and a fresh listing of names added is empty" []
    (names_added ~before:[ "masc_nr_x.prof" ] ~after:[ "masc_nr_x.prof" ])
;;

let () =
  Alcotest.run
    "voice noise-reduction cleanup"
    [ ( "temporaries are scope-owned"
      , [ test_case "success leaves none" `Quick test_success_path_leaves_no_temporaries
        ; test_case "sox failure falls back to original" `Quick
            test_sox_failure_falls_back_to_original
        ; test_case "f raising still cleans up" `Quick test_f_raising_still_cleans_up
        ; test_case "the leak predicate matches the guard's names" `Quick
            test_the_leak_predicate_matches_the_names_the_guard_creates
        ] ) ]
;;
