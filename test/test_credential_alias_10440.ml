module Types = Masc_domain

(** #10440: pin [Auth.ensure_credential_alias] semantics so the
    short-form alias [<keeper_name>.json] resolves to the same
    UUID file as the canonical long-form
    [keeper-<keeper_name>-agent.json].  Without this, 8/14 keepers
    fall through [load_credential] for the short-form path and
    hit the [feedback_keeper-credential-name-drift] failure mode. *)

let () = Mirage_crypto_rng_unix.use_default ()

open Alcotest
module Auth = Masc_mcp.Auth

let setup_test_room () =
  let unique_id =
    Printf.sprintf "masc-alias-test-%d-%d" (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1000.))
  in
  let tmp = Filename.concat (Filename.get_temp_dir_name ()) unique_id in
  Unix.mkdir tmp 0o755;
  let masc_dir = Filename.concat tmp Common.masc_dirname in
  Unix.mkdir masc_dir 0o755;
  tmp

let cleanup_test_room dir =
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun f -> rm_rf (Filename.concat path f))
        (Sys.readdir path);
      Unix.rmdir path
    end else Sys.remove path
  in
  try rm_rf dir with _ -> ()

let credential_file_path base agent_name =
  Filename.concat base
    (Filename.concat
       (Filename.concat Common.masc_dirname "auth/agents")
       (agent_name ^ ".json"))

let alias_redirect_basename path =
  match Yojson.Safe.from_file path with
  | `Assoc fields ->
      (match List.assoc_opt "redirect_to" fields with
       | Some (`String target) -> Some target
       | _ -> None)
  | _ -> None

let test_alias_creates_redirect () =
  let tmp = setup_test_room () in
  Fun.protect ~finally:(fun () -> cleanup_test_room tmp) @@ fun () ->
  (* Bootstrap canonical credential via ensure_keeper_credential —
     this writes a UUID-backed redirect at keeper-foo-agent.json. *)
  (match
     Auth.ensure_keeper_credential tmp ~agent_name:"keeper-foo-agent"
   with
   | Ok _ -> ()
   | Error e -> failf "bootstrap failed: %s" (Masc_domain.masc_error_to_string e));
  let canonical_path = credential_file_path tmp "keeper-foo-agent" in
  let canonical_target = alias_redirect_basename canonical_path in
  check bool "canonical is a redirect stub"
    true (Option.is_some canonical_target);
  (* Now write the short-form alias. *)
  (match
     Auth.ensure_credential_alias tmp
       ~canonical_name:"keeper-foo-agent" ~alias_name:"foo"
   with
   | Ok () -> ()
   | Error e -> failf "alias failed: %s" (Masc_domain.masc_error_to_string e));
  let alias_path = credential_file_path tmp "foo" in
  check bool "alias file exists" true (Sys.file_exists alias_path);
  check (option string) "alias points at the same UUID file"
    canonical_target (alias_redirect_basename alias_path);
  (* Round-trip lookup via the short-form must return the same
     credential as the canonical. *)
  let direct = Auth.load_credential tmp "keeper-foo-agent" in
  let via_alias = Auth.load_credential tmp "foo" in
  check bool "direct lookup found" true (Option.is_some direct);
  check bool "alias lookup found" true (Option.is_some via_alias);
  let token_of c = (Option.get c : Masc_domain.agent_credential).token in
  check string "alias resolves to same token"
    (token_of direct) (token_of via_alias)

let test_alias_idempotent () =
  let tmp = setup_test_room () in
  Fun.protect ~finally:(fun () -> cleanup_test_room tmp) @@ fun () ->
  let _ =
    Auth.ensure_keeper_credential tmp ~agent_name:"keeper-bar-agent"
  in
  let _ =
    Auth.ensure_credential_alias tmp
      ~canonical_name:"keeper-bar-agent" ~alias_name:"bar"
  in
  let alias_path = credential_file_path tmp "bar" in
  let mtime_before = (Unix.stat alias_path).Unix.st_mtime in
  Unix.sleepf 0.05;
  (match
     Auth.ensure_credential_alias tmp
       ~canonical_name:"keeper-bar-agent" ~alias_name:"bar"
   with
   | Ok () -> ()
   | Error e -> failf "second call failed: %s"
                  (Masc_domain.masc_error_to_string e));
  let mtime_after = (Unix.stat alias_path).Unix.st_mtime in
  check (float 0.001) "second call did not rewrite the file (idempotent)"
    mtime_before mtime_after

let test_self_alias_noop () =
  let tmp = setup_test_room () in
  Fun.protect ~finally:(fun () -> cleanup_test_room tmp) @@ fun () ->
  let _ =
    Auth.ensure_keeper_credential tmp ~agent_name:"keeper-baz-agent"
  in
  match
    Auth.ensure_credential_alias tmp
      ~canonical_name:"keeper-baz-agent" ~alias_name:"keeper-baz-agent"
  with
  | Ok () -> ()
  | Error e -> failf "self-alias should be no-op: %s"
                 (Masc_domain.masc_error_to_string e)

let test_alias_missing_canonical () =
  let tmp = setup_test_room () in
  Fun.protect ~finally:(fun () -> cleanup_test_room tmp) @@ fun () ->
  match
    Auth.ensure_credential_alias tmp
      ~canonical_name:"does-not-exist" ~alias_name:"missing"
  with
  | Ok () -> fail "expected Error for missing canonical"
  | Error _ -> ()

let () =
  run "credential_alias_10440" [
    ("ensure_credential_alias", [
        test_case "creates redirect stub at short-form path" `Quick
          test_alias_creates_redirect;
        test_case "idempotent on second call" `Quick
          test_alias_idempotent;
        test_case "self-alias is a no-op" `Quick
          test_self_alias_noop;
        test_case "errors on missing canonical credential" `Quick
          test_alias_missing_canonical;
      ]);
  ]
