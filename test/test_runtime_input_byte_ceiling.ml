(* [Runtime.declared_input_byte_ceiling_of_runtime_id] answers one question a
   caller cannot answer itself: how many bytes of model input this runtime will
   actually admit. Two declarations bound it and different paths enforce
   different ones, so the rule is that the caller has to satisfy both. These
   pin that rule against a materialized config rather than against the record
   fields, because the fields are what a future refactor moves. *)

open Alcotest
open Masc

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

(* One provider, four bindings: only the ceilings differ between them. *)
let fixture_toml ~cli_path ~oauth_source =
  Printf.sprintf
    {|[providers.p]
protocol = "antigravity-cli"
command = %S
is-non-interactive = true
timeout-s = 30.0

[providers.p.credentials]
type = "file"
path = %S

[models.prompt-only]
api-name = "m"
max-context = 128000
max-prompt-bytes = 131072

[models.body-only]
api-name = "m"
max-context = 128000

[models.both]
api-name = "m"
max-context = 128000
max-prompt-bytes = 131072

[models.body-is-smaller]
api-name = "m"
max-context = 128000
max-prompt-bytes = 524288

[models.neither]
api-name = "m"
max-context = 128000

[p.prompt-only]

[p.body-only]
max-request-body-bytes = 524288

[p.both]
max-request-body-bytes = 524288

[p.body-is-smaller]
max-request-body-bytes = 131072

[p.neither]

[runtime]
default = "p.prompt-only"
|}
    cli_path
    oauth_source
;;

let with_fixture f =
  let base = Filename.temp_file "input-ceiling" ".d" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let cli_path = Filename.concat base "fake-cli" in
  write_file cli_path "#!/bin/sh\nexit 0\n";
  Unix.chmod cli_path 0o700;
  let oauth_source = Filename.concat base "oauth-token" in
  write_file oauth_source "operator-oauth-fixture";
  Unix.chmod oauth_source 0o600;
  let runtime_path = Filename.concat base "runtime.toml" in
  write_file runtime_path (fixture_toml ~cli_path ~oauth_source);
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
      (match Runtime.init_default ~config_path:runtime_path with
       | Ok () -> ()
       | Error e -> failf "fixture config rejected: %s" e);
      (* Control: without this the cases below would all read [None] from an
         unresolved id and agree with each other for the wrong reason. *)
      (match Runtime.get_runtime_by_id "p.both" with
       | Some _ -> ()
       | None -> fail "fixture runtime did not resolve");
      f ())
;;

let ceiling id = Runtime.declared_input_byte_ceiling_of_runtime_id id

let test_one_declaration_is_the_ceiling () =
  with_fixture (fun () ->
    check (option int) "model prompt bytes alone" (Some 131072) (ceiling "p.prompt-only");
    check (option int) "binding request body bytes alone" (Some 524288)
      (ceiling "p.body-only"))
;;

(* The smaller one, whichever declaration it came from. Both directions are
   here because a rule of "the model wins" agrees with the first case and
   disagrees with the second, and only the second tells them apart. *)
let test_both_declared_takes_the_smaller () =
  with_fixture (fun () ->
    check (option int) "the model declares the smaller" (Some 131072) (ceiling "p.both");
    check (option int) "the binding declares the smaller" (Some 131072)
      (ceiling "p.body-is-smaller"))
;;

(* Not a bound of zero and not a raise: the paths that read these declarations
   apply no ceiling when neither is present, and this has to say the same. *)
let test_neither_declared_is_no_ceiling () =
  with_fixture (fun () ->
    check (option int) "neither declared -> no ceiling" None (ceiling "p.neither"))
;;

let test_unknown_runtime_is_no_ceiling () =
  with_fixture (fun () ->
    check (option int) "unknown id -> no ceiling" None (ceiling "p.not-configured"))
;;

let () =
  run "runtime_input_byte_ceiling"
    [ ( "declared ceiling",
        [ test_case "one declaration is the ceiling" `Quick
            test_one_declaration_is_the_ceiling;
          test_case "both declared takes the smaller" `Quick
            test_both_declared_takes_the_smaller;
          test_case "neither declared is no ceiling" `Quick
            test_neither_declared_is_no_ceiling;
          test_case "unknown runtime is no ceiling" `Quick
            test_unknown_runtime_is_no_ceiling ] ) ]
