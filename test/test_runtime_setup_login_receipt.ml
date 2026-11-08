open Alcotest
open Masc
module Receipt = Runtime_setup_login_receipt
module Accounts = Runtime_setup_accounts
module Session = Runtime_setup_login_session

let owner = Session.Agent "owner"
let person = Session.Person "user-1"

let ok = function Ok value -> value | Error _ -> fail "private receipt operation failed"
let restore name = function Some value -> Unix.putenv name value | None -> Unix.unsetenv name
let fixture run =
  let root = Filename.temp_dir ~perms:0o700 "setup-login-recovery-" "" |> Unix.realpath in
  let previous = Sys.getenv_opt "XDG_CONFIG_HOME" in
  Fun.protect ~finally:(fun () ->
    restore "XDG_CONFIG_HOME" previous; Fs_compat.remove_tree root) (fun () ->
    Unix.putenv "XDG_CONFIG_HOME" root;
    Eio_main.run (fun _ -> run root))

let lost_complete () = fixture (fun root ->
  let home = Filename.concat root "native-home" in Unix.mkdir home 0o700;
  let account_ref = Accounts.register_home ~workspace:root ~integration_id:"codex"
    ~cli_path:"codex" ~account_home:home |> ok in
  let initial = {Receipt.login_id = Auth.generate_token (); integration_id = "codex";
    account = Receipt.Published account_ref; status = Receipt.Running} in
  Receipt.save ~workspace:root ~actor:owner initial |> ok;
  let read () = Receipt.load ~workspace:root ~actor:owner ~login_id:initial.login_id |> ok in
  let pending = read () in
  check bool "prepared account recoverable before spawn" true
    (match pending.account with Receipt.Published _ -> true | Receipt.Unselected | Receipt.Linked -> false);
  check bool "reference is not authentication proof" true (pending.status = Receipt.Running);
  let completed = {initial with status = Receipt.Complete Runtime_setup_login_client.Authenticated} in
  Receipt.save ~workspace:root ~actor:owner completed |> ok;
  let recovered = read () in
  check bool "lost SSE complete recovered from disk" true (recovered.status = completed.status);
  check bool "no model invocation claim" true
    (Yojson.Safe.Util.member "invocation_verified" (Receipt.to_json recovered) = `Bool false);
  let retry = {initial with status = Receipt.Cancelled} in
  Receipt.save ~workspace:root ~actor:owner retry |> ok;
  let failed = Receipt.to_json (read ()) in
  check bool "cancel keeps reusable reference" true (Yojson.Safe.Util.member "account_ref" failed <> `Null);
  check bool "cancel has no authentication claim" true (Yojson.Safe.Util.member "authentication" failed = `Null))

let owner_scope_and_storage () = fixture (fun root ->
  let login_id = Auth.generate_token () in
  let receipt = {Receipt.login_id; integration_id = "muse";
    account = Receipt.Unselected; status = Receipt.Interrupted} in
  Receipt.save ~workspace:root ~actor:owner receipt |> ok;
  let alias = Filename.concat root "workspace-alias" in Unix.symlink root alias;
  ignore (Receipt.load ~workspace:alias ~actor:owner ~login_id |> ok);
  check bool "other actor cannot recover" true
    (Receipt.load ~workspace:root ~actor:(Session.Agent "other") ~login_id = Error Receipt.Not_found);
  let other = Filename.concat root "other-workspace" in Unix.mkdir other 0o700;
  check bool "other workspace cannot recover" true
    (Receipt.load ~workspace:other ~actor:owner ~login_id = Error Receipt.Not_found);
  check bool "login path traversal refused" true
    (Receipt.load ~workspace:root ~actor:owner ~login_id:"../escape" = Error Receipt.Not_found);
  let record = match Env_config_core.default_base_path_record_path_opt () with
    | Some record -> record | None -> fail "missing private registry root" in
  let path = Filename.concat (Filename.dirname record)
    ("credentials/setup-logins/" ^ login_id ^ ".json") in
  check int "receipt only readable by owner" 0o600 ((Unix.stat path).st_perm land 0o777);
  let json = Yojson.Safe.from_file path in
  let fields = Yojson.Safe.Util.to_assoc json in
  check (list string) "persistence contains only scope hash and receipt"
    ["receipt"; "scope"] (List.map fst fields |> List.sort String.compare);
  let body = Yojson.Safe.Util.member "receipt" json |> Yojson.Safe.Util.to_assoc in
  check (list string) "no paths, input, output, codes or raw errors stored"
    ["integration_id"; "invocation_verified"; "login_id"; "status"]
    (List.map fst body |> List.sort String.compare);
  Unix.chmod path 0o644;
  check bool "insecure receipt rejected" true
    (Receipt.load ~workspace:root ~actor:owner ~login_id = Error Receipt.Unavailable))

let corrupt_evidence () = fixture (fun root ->
  let login_id = Auth.generate_token () in
  let receipt = {Receipt.login_id; integration_id = "claude";
    account = Receipt.Unselected; status = Receipt.Running} in
  Receipt.save ~workspace:root ~actor:owner receipt |> ok;
  let record = match Env_config_core.default_base_path_record_path_opt () with
    | Some record -> record | None -> fail "missing private registry root" in
  let path = Filename.concat (Filename.dirname record)
    ("credentials/setup-logins/" ^ login_id ^ ".json") in
  let json = Yojson.Safe.from_file path in
  let scope = Yojson.Safe.Util.member "scope" json in
  let invalid = `Assoc ["scope", scope; "receipt", `Assoc [
    "login_id", `String login_id; "integration_id", `String "claude";
    "status", `String "complete"; "authentication", `String "authenticated";
    "invocation_verified", `Bool false]] in
  Auth.save_private_text_file path (Yojson.Safe.to_string invalid);
  check bool "completion without account reference rejected" true
    (Receipt.load ~workspace:root ~actor:owner ~login_id = Error Receipt.Unavailable))

(* Plan D1-4: a person's completed login has its account in the authorization
   log, not in the setup registry, and its receipt is read back; a receipt that
   claims that before the login completed is not. *)
let a_persons_linked_completion () = fixture (fun root ->
  let login_id = Auth.generate_token () in
  let linked = {Receipt.login_id; integration_id = "claude_code";
    account = Receipt.Linked; status = Receipt.Complete Runtime_setup_login_client.Authenticated} in
  Receipt.save ~workspace:root ~actor:person linked |> ok;
  let read = Receipt.load ~workspace:root ~actor:person ~login_id |> ok in
  check bool "read back as linked and complete" true (read = linked);
  check bool "an agent named like the person cannot read it" true
    (Receipt.load ~workspace:root ~actor:(Session.Agent "human:user-1") ~login_id = Error Receipt.Not_found);
  let json = Receipt.to_json read in
  check bool "named linked" true (Yojson.Safe.Util.member "account" json = `String "linked");
  check bool "with no registry reference" true (Yojson.Safe.Util.member "account_ref" json = `Null);
  Receipt.save ~workspace:root ~actor:person {linked with status = Receipt.Running} |> ok;
  check bool "linked before completion rejected" true
    (Receipt.load ~workspace:root ~actor:person ~login_id = Error Receipt.Unavailable))

let () = run "official login recovery" ["receipts", [
  test_case "lost complete and cancellation" `Quick lost_complete;
  test_case "actor workspace and private storage" `Quick owner_scope_and_storage;
  test_case "corrupt completion rejected" `Quick corrupt_evidence;
  test_case "a person's linked completion" `Quick a_persons_linked_completion]]
