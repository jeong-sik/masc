(** Which microphone the TUI says a capture would open, read from
    system_profiler's JSON report rather than scraped from its text one. The
    report below is the shape one workstation printed on 2026-09-05: a virtual
    device with no default flag, the built-in microphone marked as the default
    input, and the built-in speaker marked as the default output. The text
    scraper this replaced found the name by walking indentation up to the
    nearest heading, which is a guess about a layout Apple does not promise. *)

open Alcotest
module Device = Masc_tui_audio_device

let report =
  {|{
  "SPAudioDataType" : [
    {
      "_items" : [
        {
          "_name" : "BlackHole 2ch",
          "coreaudio_device_input" : 2,
          "coreaudio_device_output" : 2,
          "coreaudio_device_transport" : "coreaudio_device_type_virtual"
        },
        {
          "_name" : "MacBook Pro 마이크",
          "coreaudio_default_audio_input_device" : "spaudio_yes",
          "coreaudio_device_input" : 1,
          "coreaudio_device_transport" : "coreaudio_device_type_builtin"
        },
        {
          "_name" : "MacBook Pro 스피커",
          "coreaudio_default_audio_output_device" : "spaudio_yes",
          "coreaudio_default_audio_system_device" : "spaudio_yes",
          "coreaudio_device_output" : 2
        }
      ],
      "_name" : "coreaudio_device"
    }
  ]
}|}
;;

let default_input text =
  Masc_tui_audio_device.default_input_of_json (Yojson.Safe.from_string text)
;;

let test_the_selected_input_is_named () =
  check (option string) "the device flagged as default input" (Some "MacBook Pro 마이크")
    (default_input report)
;;

(* The speaker carries a default flag too, for output. It is not an input and
   must not be the answer when no input is selected. *)
let test_a_default_output_is_not_an_input () =
  let only_output =
    {|{ "SPAudioDataType" : [ { "_items" : [
      { "_name" : "MacBook Pro 스피커", "coreaudio_default_audio_output_device" : "spaudio_yes" }
    ] } ] }|}
  in
  check (option string) "no input selected" None (default_input only_output)
;;

let test_a_report_without_the_section_is_none () =
  check (option string) "empty object" None (default_input "{}");
  check (option string) "section with no items" None
    (default_input {|{ "SPAudioDataType" : [ { "_name" : "coreaudio_device" } ] }|})
;;

let probe =
  let pp fmt = function
    | Device.Default_input name -> Format.fprintf fmt "Default_input %S" name
    | Device.No_default_input -> Format.pp_print_string fmt "No_default_input"
    | Device.Probe_failed reason -> Format.fprintf fmt "Probe_failed %S" reason
    | Device.No_probe_on_this_platform ->
      Format.pp_print_string fmt "No_probe_on_this_platform"
  in
  testable pp ( = )
;;

let with_report_file contents f =
  let path = Filename.temp_file "tui-audio-report-" ".json" in
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

(* The probe runs a command and reads what it prints. Each way that can go
   wrong is a reason it reports: not an exception out of the channel's close,
   and not the same answer as a report that marks no default input. *)
let test_a_report_read_from_a_command_names_the_input () =
  with_report_file report (fun path ->
    check probe "read through cat" (Device.Default_input "MacBook Pro 마이크")
      (Device.probe_with ~command:("cat " ^ Filename.quote path)))
;;

let test_a_report_with_no_default_input_says_so () =
  check probe "an empty report" Device.No_default_input
    (Device.probe_with ~command:"printf '{}'")
;;

let test_a_command_that_fails_is_a_reason () =
  check probe "the exit status is the reason, whatever was printed"
    (Device.Probe_failed "exited 3")
    (Device.probe_with ~command:"printf '{}'; exit 3")
;;

let test_a_report_that_is_not_json_is_a_reason () =
  match Device.probe_with ~command:"printf 'not a report'" with
  | Device.Probe_failed _ -> ()
  | Device.Default_input _ | Device.No_default_input | Device.No_probe_on_this_platform ->
    fail "text that is not JSON is not a report"
;;

let () =
  run
    "TUI audio device"
    [ ( "default input"
      , [ test_case "the selected input is named" `Quick test_the_selected_input_is_named
        ; test_case "a default output is not an input" `Quick test_a_default_output_is_not_an_input
        ; test_case
            "a report without the section is none"
            `Quick
            test_a_report_without_the_section_is_none
        ] )
    ; ( "probing"
      , [ test_case
            "a report read from a command names the input"
            `Quick
            test_a_report_read_from_a_command_names_the_input
        ; test_case
            "a report with no default input says so"
            `Quick
            test_a_report_with_no_default_input_says_so
        ; test_case "a command that fails is a reason" `Quick test_a_command_that_fails_is_a_reason
        ; test_case
            "a report that is not JSON is a reason"
            `Quick
            test_a_report_that_is_not_json_is_a_reason
        ] )
    ]
;;
