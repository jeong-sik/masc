(** [MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH] has to reach the ceiling it names.

    [Env_config_snapshot] and [Channel_gate]'s signature expose the same
    setting, so the implementation must read the configured value rather than
    a second literal ceiling.

    [Env_config_core.raw_value_opt] goes to [Unix.getenv] on every call with no
    memo, so [putenv] here is observed by the next read. *)

open Alcotest

let with_knob value f =
  let restore =
    match Sys.getenv_opt "MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH" with
    | Some previous -> fun () -> Unix.putenv "MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH" previous
    | None -> fun () -> Unix.putenv "MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH" ""
  in
  Unix.putenv "MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH" value;
  Fun.protect ~finally:restore f
;;

let test_default_when_unset () =
  with_knob "" (fun () ->
    check int "unset keeps the documented 4000" 4000 (Channel_gate.max_content_length ()))
;;

let test_knob_raises_the_ceiling () =
  with_knob "8000" (fun () ->
    check int "the setting is applied" 8000 (Channel_gate.max_content_length ()))
;;

(* The caller compares [String.length trimmed > max_content_length ()], so a
   non-positive ceiling rejects every message rather than admitting more. The
   floor keeps a hostile or fat-fingered setting from turning the gate into a
   total block. *)
let test_non_positive_is_floored () =
  with_knob "0" (fun () ->
    check int "zero cannot silence the channel" 1 (Channel_gate.max_content_length ()));
  with_knob "-1" (fun () ->
    check int "negative cannot silence the channel" 1 (Channel_gate.max_content_length ()))
;;

(* A value the parser rejects must fall back to the default, not to zero.
   MASC_PARSE_WARN is pinned off so the assertion states this module's
   behaviour rather than whatever strict-mode setting the runner inherited —
   under strict mode the shared getter raises instead of defaulting. *)
let test_malformed_falls_back_to_default () =
  let previous = Sys.getenv_opt "MASC_PARSE_WARN" in
  Unix.putenv "MASC_PARSE_WARN" "false";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_PARSE_WARN" (Option.value previous ~default:""))
    (fun () ->
      with_knob "not-a-number" (fun () ->
        check int "malformed keeps the default" 4000 (Channel_gate.max_content_length ())))
;;

let () =
  run
    "channel gate content length knob"
    [ ( "max_content_length"
      , [ test_case "default when unset" `Quick test_default_when_unset
        ; test_case "knob raises the ceiling" `Quick test_knob_raises_the_ceiling
        ; test_case "non-positive is floored" `Quick test_non_positive_is_floored
        ; test_case "malformed falls back" `Quick test_malformed_falls_back_to_default
        ] )
    ]
;;
