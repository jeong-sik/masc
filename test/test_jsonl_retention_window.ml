(** One retention window decides which JSONL day files get deleted.

    Three readers act on it: the startup prune, the periodic maintenance
    prune, and the catch-up digest's look-back clamp. They used to spell
    [MASC_JSONL_RETENTION_DAYS] and its default separately, so a default
    changed in one place would have let one prune delete files another
    still expected to read.

    They now share {!Env_config_core.jsonl_retention_days}. What this
    suite pins is the pair of properties the digest's fallback depends
    on: the getter reports a non-positive override verbatim (that is how
    "pruning disabled" reaches a caller), and the exported default is
    positive (that is what the digest clamps its scan to instead). *)

open Alcotest

let env_name = "MASC_JSONL_RETENTION_DAYS"

let with_env value f =
  let prev = Sys.getenv_opt env_name in
  (match value with Some v -> Unix.putenv env_name v | None -> Unix.putenv env_name "");
  Fun.protect
    ~finally:(fun () ->
      match prev with Some v -> Unix.putenv env_name v | None -> Unix.putenv env_name "")
    f

let test_unset_yields_the_exported_default () =
  with_env None @@ fun () ->
  check int "unset falls back to the exported default"
    Env_config_core.default_jsonl_retention_days
    (Env_config_core.jsonl_retention_days ())

let test_override_is_honoured () =
  with_env (Some "7") @@ fun () ->
  check int "override wins" 7 (Env_config_core.jsonl_retention_days ())

(* The digest reads a non-positive value as "pruning disabled" and then
   substitutes the default. That only works if the getter passes the
   non-positive value through rather than swallowing it. *)
let test_non_positive_override_reaches_the_caller () =
  with_env (Some "0") @@ fun () ->
  check int "zero is reported, not replaced" 0 (Env_config_core.jsonl_retention_days ());
  with_env (Some "-1") @@ fun () ->
  check int "negative is reported, not replaced" (-1)
    (Env_config_core.jsonl_retention_days ())

(* ... and only if the default the caller substitutes is itself usable as
   a scan bound. A non-positive default would make the digest's fallback
   loop back to "disabled" and scan without limit. *)
let test_exported_default_is_a_usable_bound () =
  check bool "default is positive" true
    (Env_config_core.default_jsonl_retention_days > 0)

(* Malformed input is not an override. *)
let test_unparseable_falls_back () =
  with_env (Some "thirty") @@ fun () ->
  check int "non-numeric falls back to the default"
    Env_config_core.default_jsonl_retention_days
    (Env_config_core.jsonl_retention_days ())

let () =
  run
    "jsonl_retention_window"
    [ ( "getter"
      , [ test_case "unset yields the exported default" `Quick
            test_unset_yields_the_exported_default
        ; test_case "override is honoured" `Quick test_override_is_honoured
        ; test_case "non-positive reaches the caller" `Quick
            test_non_positive_override_reaches_the_caller
        ; test_case "unparseable falls back" `Quick test_unparseable_falls_back
        ] )
    ; ( "default"
      , [ test_case "is a usable scan bound" `Quick
            test_exported_default_is_a_usable_bound
        ] )
    ]
