(** One retention window decides which JSONL day files get deleted.

    Two readers act on it: the startup prune and the periodic maintenance
    prune. They used to spell [MASC_JSONL_RETENTION_DAYS] and its default
    separately, so a default changed in one place would have let one prune
    delete files the other still expected to keep.

    They now share {!Env_config_core.jsonl_retention_days}. This suite pins
    the getter's contract: the documented default, an honoured override, and
    malformed input falling back instead of overriding. *)

open Alcotest

let env_name = "MASC_JSONL_RETENTION_DAYS"

(* The value the .mli documents as the default. Spelled here rather than read
   back from the module so a changed default fails this suite instead of
   passing through it. *)
let documented_default = 30

let with_env value f =
  let prev = Sys.getenv_opt env_name in
  (match value with Some v -> Unix.putenv env_name v | None -> Unix.putenv env_name "");
  Fun.protect
    ~finally:(fun () ->
      match prev with Some v -> Unix.putenv env_name v | None -> Unix.putenv env_name "")
    f

let test_unset_yields_the_documented_default () =
  with_env None @@ fun () ->
  check int "unset falls back to the documented default" documented_default
    (Env_config_core.jsonl_retention_days ())

let test_override_is_honoured () =
  with_env (Some "7") @@ fun () ->
  check int "override wins" 7 (Env_config_core.jsonl_retention_days ())

(* Malformed input is not an override. *)
let test_unparseable_falls_back () =
  with_env (Some "thirty") @@ fun () ->
  check int "non-numeric falls back to the default" documented_default
    (Env_config_core.jsonl_retention_days ())

let () =
  run
    "jsonl_retention_window"
    [ ( "getter"
      , [ test_case "unset yields the documented default" `Quick
            test_unset_yields_the_documented_default
        ; test_case "override is honoured" `Quick test_override_is_honoured
        ; test_case "unparseable falls back" `Quick test_unparseable_falls_back
        ] )
    ]
