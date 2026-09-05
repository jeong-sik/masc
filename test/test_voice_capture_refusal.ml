(** A capture under a voice config that exists and does not parse.

    No config is voice not set up, and a capture runs on the measured
    defaults. A config that does not parse is a knob the operator set and
    mistyped, and a capture run on the defaults under it would be a dial
    connected to nothing. So it is refused with its reason before a tone is
    played or a microphone opened, and an operator turning
    [\[voice.capture\]] finds out from the capture they just asked for, not
    from a threshold that did not move. *)

open Alcotest
module Bridge = Masc.Voice_bridge

(* The stdlib has no unsetenv, and [Unix.putenv key ""] leaves the variable
   set to an empty string, which a reader that tests presence sees as set.
   The test dependency library carries a C stub for the real call. *)
external unsetenv : string -> unit = "masc_test_unsetenv"

let restore key prior =
  match prior with
  | Some v -> Unix.putenv key v
  | None -> unsetenv key
;;

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect ~finally:(fun () -> restore key prior) f
;;

let without_env key f =
  let prior = Sys.getenv_opt key in
  unsetenv key;
  Fun.protect ~finally:(fun () -> restore key prior) f
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let rec mkdir_p path =
  if path <> "" && not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let write_file path contents =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc contents)
;;

(* MASC_BASE_PATH at a fresh directory, so the only voice config is the one
   written here.

   [Voice_config.load_detailed] reads the [\[voice\]] section of the config
   root's [runtime.toml] before it looks for the JSON file, and the config
   root follows MASC_BASE_PATH only while MASC_CONFIG_DIR is unset. A runner
   whose MASC_CONFIG_DIR carries a [\[voice\]] section would read that
   config in place of this one, so the variable is cleared for the
   duration. *)
let with_explicit_voice_config contents f =
  with_temp_dir "voice-capture-refusal-" @@ fun root ->
  without_env "MASC_CONFIG_DIR" @@ fun () ->
  with_env "MASC_BASE_PATH" root @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" root @@ fun () ->
  let path = Voice_config.config_path () in
  mkdir_p (Filename.dirname path);
  write_file path contents;
  f ()
;;

(* A knob of the wrong type: the string "6" where a number is meant. The
   parser refuses it by name, and that refusal is what the capture reports. *)
let wrong_typed_capture_config =
  {|{ "capture": { "trigger_margin_db": "6" } }|}
;;

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  go 0
;;

let test_a_capture_under_an_invalid_config_is_refused_by_name () =
  with_explicit_voice_config wrong_typed_capture_config (fun () ->
    match Bridge.record_and_transcribe ~agent_id:"tester" () with
    | Ok _ -> fail "a capture under a config that does not parse must not start"
    | Error message ->
      check bool "the refusal says the config is invalid" true
        (contains ~needle:"voice config is invalid" message);
      check bool "and names the key that did not parse" true
        (contains ~needle:"capture.trigger_margin_db" message))
;;

(* The probe a repeating caller takes before its first capture answers the
   same way: no floor, because the capture it was for is not going to run. *)
let test_the_floor_is_not_measured_under_an_invalid_config () =
  with_explicit_voice_config wrong_typed_capture_config (fun () ->
    check (option (float 0.0)) "no floor" None
      (Bridge.measure_noise_floor ~agent_id:"tester" ()))
;;

let () =
  run
    "Voice capture refusal"
    [ ( "invalid config"
      , [ test_case
            "a capture under an invalid config is refused by name"
            `Quick
            test_a_capture_under_an_invalid_config_is_refused_by_name
        ; test_case
            "the floor is not measured under an invalid config"
            `Quick
            test_the_floor_is_not_measured_under_an_invalid_config
        ] )
    ]
;;
