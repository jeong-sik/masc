(** Which microphone the TUI says a capture would open, read from
    system_profiler's JSON report rather than scraped from its text one. The
    report below is the shape one workstation printed on 2026-09-05: a virtual
    device with no default flag, the built-in microphone marked as the default
    input, and the built-in speaker marked as the default output. The text
    scraper this replaced found the name by walking indentation up to the
    nearest heading, which is a guess about a layout Apple does not promise. *)

open Alcotest

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
    ]
;;
