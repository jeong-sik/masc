(** Parity gate between [Keeper_tool_voice_runtime.voice_command]
    enumeration and the [keeper_voice_*] entries registered in
    [Keeper_tool_descriptor.all_descriptors].

    The previous string-classifier wiring (raw [match name with
    "keeper_voice_speak" -> ...]) had no compiler-level link between
    descriptor registration and handler dispatch — adding one without
    the other was a silent dispatch hole.

    This test pins both sides against each other so that a future
    addition of a [keeper_voice_*] descriptor without a matching
    [voice_command] variant (or vice versa) is rejected at test
    time. *)

open Alcotest
module Descriptor = Masc.Keeper_tool_descriptor
module Voice = Masc.Keeper_tool_voice_runtime

let voice_prefix = "keeper_voice_"

let registered_voice_internal_names () : string list =
  Descriptor.all_descriptors ()
  |> List.filter_map (fun d ->
       let n = d.Descriptor.internal_name in
       if String.length n >= String.length voice_prefix
          && String.sub n 0 (String.length voice_prefix) = voice_prefix
       then Some n
       else None)
  |> List.sort String.compare

let enumerated_command_strings () : string list =
  List.map Voice.command_to_string Voice.all_commands |> List.sort String.compare

let pp_list xs = "[" ^ String.concat "; " xs ^ "]"

let test_descriptor_set_equals_enumeration () =
  let registered = registered_voice_internal_names () in
  let enumerated = enumerated_command_strings () in
  if registered <> enumerated
  then
    Alcotest.failf
      "voice descriptor/variant parity broken.\n  descriptors: %s\n  variants:    %s"
      (pp_list registered)
      (pp_list enumerated)

let test_command_round_trip () =
  List.iter
    (fun c ->
      let s = Voice.command_to_string c in
      match Voice.command_of_string s with
      | Some c' when c' = c -> ()
      | Some _ ->
        Alcotest.failf
          "round-trip mismatch for variant rendered as %S — \
           command_of_string returned different variant"
          s
      | None ->
        Alcotest.failf
          "round-trip failed: command_of_string %S = None (must be Some _)"
          s)
    Voice.all_commands

let test_unknown_command_is_none () =
  match Voice.command_of_string "keeper_voice_does_not_exist" with
  | None -> ()
  | Some _ ->
    Alcotest.failf
      "command_of_string accepted an unknown string as a variant"

let test_enumeration_nonempty () =
  if Voice.all_commands = []
  then
    Alcotest.failf "Voice.all_commands is empty — expected at least one variant"

let () =
  Alcotest.run
    "voice_command_descriptor_parity"
    [ ( "parity"
      , [ test_case "enumeration nonempty" `Quick test_enumeration_nonempty
        ; test_case
            "descriptor set equals voice_command enumeration"
            `Quick
            test_descriptor_set_equals_enumeration
        ] )
    ; ( "round_trip"
      , [ test_case
            "command_of_string ∘ command_to_string = Some"
            `Quick
            test_command_round_trip
        ; test_case
            "unknown string yields None"
            `Quick
            test_unknown_command_is_none
        ] )
    ]
