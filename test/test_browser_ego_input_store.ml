open Alcotest
open Masc
module Input = Browser_ego_input
module Store = Lane_addon_store
module Release = Browser_ego_release
open Input
open Release
let ok = function Ok value->value|Error detail->fail detail
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name->remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | Unix.S_REG|Unix.S_LNK|Unix.S_CHR|Unix.S_BLK|Unix.S_FIFO|Unix.S_SOCK -> Unix.unlink path
let with_store f = let root=Filename.temp_dir "ego-input-store-" "" in
  Fun.protect ~finally:(fun ()->remove root) (fun ()->f root (Store.create ~root))
let attach store ~space_id ~writer =
  let persistence={Input.read=(fun ()->Store.load_ego_input store ~space_id);
    compare_and_set=(fun ~expected ~replacement->Store.compare_and_set_ego_input store ~space_id ~expected ~replacement);
    active=(fun ()->true)} in
  Input.create_persistent ~persistence ~writer ~space_id
let hold input = ok (Input.within_command input ~command_id:"original" (fun ()->
  Input.begin_holding input ~now:100. ~scope:Input.Page_scope ~tab_id:4 ~page_label:"p2" ~operation:"target_click")) |> ok
let proof () = match Browser_ego_release.judge [0,Browser_ego_release.answer_of_json (`Assoc [])] with
  | Settled (Released proof)->proof|Settled No_hold|Unconfirmed _->fail "fixture proof"
let child_reopen root generation =
  let result=attach (Store.create ~root) ~space_id:51 ~writer:"replacement-child" in
  let passed=match result with
    | Ok input ->
      (match Input.status input with
       | Uncertain pending -> pending.generation=generation && pending.command_id="original"
           && pending.tab_id=4 && pending.page_label="p2" && pending.operation="target_click"
           && pending.scope=Page_scope && Result.is_error (Input.admit input)
       | Ready _ -> false)
    | Error _ -> false in
  exit (if passed then 0 else 1)
let cross_process_reopen () = with_store (fun root store ->
  let first=ok (attach store ~space_id:51 ~writer:"first") in let original=hold first in
  let child=Unix.create_process Sys.executable_name
    [|Sys.executable_name;"--child-reopen";root;original.generation|] Unix.stdin Unix.stdout Unix.stderr in
  let _,status=Unix.waitpid [] child in
  check bool "independent process restores pending before input" true (status=Unix.WEXITED 0);
  check bool "old process cannot settle child's claimed state" true
    (Result.is_error (Input.command_settled first ~generation:original.generation (proof ())));
  let reopened=ok (attach (Store.create ~root) ~space_id:51 ~writer:"third") in
  check bool "full pending identity survives another store/worker" true (Input.status reopened=Uncertain original);
  let unrelated=ok (attach store ~space_id:52 ~writer:"other-space") in
  check bool "another native Space retains its no-known-record baseline" true (Input.status unrelated=Ready Command_settled))
let write_failure_before_effect () = with_store (fun root store ->
  let input=ok (attach store ~space_id:51 ~writer:"first") in
  let path=Filename.concat root "ego-input/51.json" in Unix.unlink path;Unix.mkdir path 0o700;
  let effects=ref 0 in
  let result=ok (Input.within_command input ~command_id:"no-effect" (fun ()->
    match Input.begin_holding input ~now:100. ~scope:Input.Page_scope ~tab_id:1 ~page_label:"p1" ~operation:"click" with
    | Ok _->incr effects;Ok ()|Error detail->Error detail)) in
  check bool "unwritable/nonregular authority refuses input" true (Result.is_error result);
  check int "no effect follows failed write-ahead" 0 !effects;
  check bool "local pending remains blocked" true (Result.is_error (Input.admit input)))
let lock_boundary () = with_store (fun root store ->
  ignore (ok (attach store ~space_id:51 ~writer:"first"));
  let lock=Filename.concat root "ego-input/51.lock" in
  Unix.unlink lock;
  let outside=Filename.concat root "untouched" in
  Out_channel.with_open_bin outside (fun channel->output_string channel "unchanged");
  Unix.symlink outside lock;
  check bool "symlinked lock refuses attachment" true (Result.is_error (attach store ~space_id:51 ~writer:"next"));
  check string "outside lock target unchanged" "unchanged" (In_channel.with_open_bin outside In_channel.input_all))
let () = if Array.length Sys.argv=4 && Sys.argv.(1)="--child-reopen" then child_reopen Sys.argv.(2) Sys.argv.(3)
else run "retained Ego input store" ["durability",[
  test_case "cross-process reopen and writer fencing" `Quick cross_process_reopen;
  test_case "real storage failure refuses effect" `Quick write_failure_before_effect;
  test_case "private lock rejects symlinks" `Quick lock_boundary]]
