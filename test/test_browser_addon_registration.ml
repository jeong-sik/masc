open Alcotest
module B = Browser_lane
module Registration = Masc.Browser_addon_registration
let ok = function Ok value -> value | Error Registration.Identity_changed -> fail "identity changed"
  | Error (Registration.Unconfirmed detail) -> fail detail
let uuid raw = match B.client_id_of_string raw with Ok value -> value | Error detail -> fail detail
let client={B.client_id=uuid "0c000000-0000-4000-8000-000000000001";
  browser=B.Firefox;version="158";engine_version="158";transport=B.Webdriver_bidi}
let first="0b000000-0000-4000-8000-000000000001"
let second="0b000000-0000-4000-8000-000000000002"
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun leaf -> remove (Filename.concat path leaf)) (Sys.readdir path);Unix.rmdir path
  | Unix.S_REG|S_LNK|S_CHR|S_BLK|S_FIFO|S_SOCK -> Unix.unlink path
let with_root run =
  let directory=Filename.temp_dir "browser-registration-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> remove directory) (fun () -> run (Filename.concat directory "registrations"))
let unconfirmed = function Error (Registration.Unconfirmed _) -> true | Ok _|Error Identity_changed -> false
let immutable_owner () = with_root (fun root ->
  check (option string) "absent reservation is fresh" None (ok (Registration.find ~root ~client));
  check string "first owner committed" first (ok (Registration.claim ~root ~client ~instance_id:first));
  check string "another proposal preserves original owner" first (ok (Registration.claim ~root ~client ~instance_id:second));
  check (option string) "fresh read retains original after handle loss" (Some first) (ok (Registration.find ~root ~client));
  let changed={client with transport=B.Web_extension} in
  check bool "client ID cannot change identity" true
    (Registration.claim ~root ~client:changed ~instance_id:second=Error Registration.Identity_changed);
  check bool "malformed proposed incarnation is not admitted" true
    (unconfirmed (Registration.claim ~root ~client ~instance_id:"not-a-worker")))
let interrupted_first_write () = with_root (fun root ->
  Unix.mkdir root 0o700;
  let directory=Filename.concat root (B.client_id_to_string client.client_id) in Unix.mkdir directory 0o700;
  check bool "reserved directory without record is not fresh" true (unconfirmed (Registration.find ~root ~client));
  check bool "another worker cannot repair a reserved ID by rebinding" true
    (unconfirmed (Registration.claim ~root ~client ~instance_id:second));
  let path=Filename.concat directory "owner.json" in
  Out_channel.with_open_bin path (fun out -> output_string out "{");Unix.chmod path 0o600;
  check bool "torn record cannot be replaced" true (unconfirmed (Registration.claim ~root ~client ~instance_id:second));
  check string "failed claim preserves original torn bytes" "{" (In_channel.with_open_bin path In_channel.input_all))
let concurrent_claims () = with_root (fun root ->
  let pending=Domain.spawn (fun () -> Registration.claim ~root ~client ~instance_id:first) in
  let other=Registration.claim ~root ~client ~instance_id:second in
  let results=[Domain.join pending;other] in
  let winner=match ok (Registration.find ~root ~client) with Some value -> value | None -> fail "no owner committed" in
  check bool "winner names one original candidate" true (List.mem winner [first;second]);
  List.iter (function
    | Ok instance -> check string "every successful claim agrees" winner instance
    | Error (Registration.Unconfirmed _) -> ()
    | Error Identity_changed -> fail "identical clients cannot conflict") results;
  check string "post-race proposal cannot replace winner" winner
    (ok (Registration.claim ~root ~client ~instance_id:second)))
let ownership () = with_root (fun root ->
  ignore (ok (Registration.claim ~root ~client ~instance_id:first));
  let alias=root^"-alias" in Unix.symlink root alias;
  Fun.protect ~finally:(fun () -> Unix.unlink alias) (fun () ->
    check bool "symlink reservation root is refused" true (unconfirmed (Registration.find ~root:alias ~client)));
  let path=Filename.concat (Filename.concat root (B.client_id_to_string client.client_id)) "owner.json" in
  let linked=root^"-record" in Unix.link path linked;
  Fun.protect ~finally:(fun () -> Unix.unlink linked) (fun () ->
    check bool "hardlinked owner record is refused" true (unconfirmed (Registration.find ~root ~client)));
  Unix.chmod path 0o644;
  check bool "owner record permission changes are not accepted" true (unconfirmed (Registration.find ~root ~client)))
let ()=run "browser addon native registrations" ["ownership",[
  test_case "original owner and identity survive fresh reads" `Quick immutable_owner;
  test_case "interrupted reservation cannot be rebound" `Quick interrupted_first_write;
  test_case "concurrent proposals choose one original worker" `Quick concurrent_claims;
  test_case "private root and record ownership" `Quick ownership]]
