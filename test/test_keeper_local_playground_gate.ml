open Alcotest

let hatch_key = "MASC_EXEC_ALLOW_LOCAL_PLAYGROUND"
let clear_hatch () = Unix.putenv hatch_key ""
let set_hatch () = Unix.putenv hatch_key "true"

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let test_gate_default_disabled () =
  clear_hatch ();
  check bool "gate off by default" false
    (Env_config_sandbox.Gate.allow_local_playground ())

let test_gate_enabled_via_hatch () =
  set_hatch ();
  Fun.protect ~finally:clear_hatch (fun () ->
      check bool "gate on with hatch" true
        (Env_config_sandbox.Gate.allow_local_playground ()))

let test_disabled_message_names_hatch () =
  check bool "message names the hatch env var" true
    (contains hatch_key Env_config_sandbox.Gate.disabled_message)

let test_env_key_pinned () =
  check string "env_key pinned" hatch_key Env_config_sandbox.Gate.env_key

let () =
  run "Local playground gate"
    [ "gate",
      [ test_case "default disabled" `Quick test_gate_default_disabled
      ; test_case "enabled via hatch" `Quick test_gate_enabled_via_hatch
      ; test_case "message names hatch" `Quick test_disabled_message_names_hatch
      ; test_case "env_key pinned" `Quick test_env_key_pinned
      ] ]
