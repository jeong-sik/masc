open Alcotest
module B = Browser_lane
module Lease = B.Upload_lease
module W = Masc.Browser_addon_wire
module Owner = Masc.Browser_addon_owner
module Broker = Masc.Browser_addon_uploads
module Tool = Masc.Browser_addon_tool
let ok = function Ok value -> value | Error detail -> fail detail
let id suffix = "0b000000-0000-4000-8000-0000000000" ^ suffix
let command paths = B.Page_act (B.Action.On_tab
  {tab_id=7;frame_path=["#frame"];interaction=Upload {selector="#file";paths}})
let private_root () = Unix.realpath (Filename.temp_dir ~perms:0o700 "browser-upload-test-" "")
let lease_ok = function Ok value -> value | Error _ -> fail "snapshot preparation failed"
let contents path = In_channel.with_open_bin path In_channel.input_all
let scenario () = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  let root=private_root () in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let uploads=ok (Broker.create ~directory:root) in
    let incarnation=id "01" in
    let owner=ok (Owner.create ~incarnation) in
    ok (Owner.attach_uploads owner uploads);
    let send command=Owner.dispatch owner {W.incarnation;command} in
    let session=Lease.create_owner () and calls=ref 0 and received=ref [] in
    ok (Owner.attach_automation owner ~locate:false ~session:(fun () -> B.Browser_open)
      ~document:(fun ~tab_id:_ -> fail "upload must not read a document")
      ~execute:(function
        | B.Page_act (B.Action.On_tab {interaction=Upload {paths;_};_}) ->
            check bool "worker copies are registered before browser input" true (Lease.pending ~paths);
            Lease.claim ~owner:session ~paths;incr calls;received:=paths;
            B.Answered (`Assoc ["ok",`Bool true;"data",`Assoc ["uploaded",`Bool true]])
        | _ -> fail "upload must dispatch exactly its admitted command")
      ~cleanup:(fun () -> Eio_unix.run_in_systhread (fun () -> Lease.release_owner session);Ok ()));
    let host_paths=ref [] in
    lease_ok (Lease.with_staged_files ~files:["upload.bin",(fun () -> Ok "late-read\000payload")]
      (fun paths ->
        host_paths:=paths;
        let verb=command paths and grant=id "02" in
        check bool "ungranted private Issue is refused" true
          (match send (W.Issue {route=B.Automation_route;verb;actor=Some "keeper/uploader";
              timeout_sec=2.;only_if_idle=false}) with
           | W.Service_refusal {disposition=W.Not_started;_} -> true | _ -> false);
        check bool "private staging performs no browser input" true
          (send (W.Upload_stage {id=grant;actor="keeper/uploader";route=B.Automation_route;verb})=W.Receipt && !calls=0);
        let arguments=`Assoc ["lane",`String "automation";"uploadId",`String grant;"command",B.verb_json verb] in
        let hooks=ok (Masc.Lane_addon_tool_hooks.prepare ~hooks:[Validate_input;Validate_output] Tool.definition) in
        ok (Masc.Lane_addon_tool_hooks.before_call hooks arguments);
        let refused=Tool.invoke ~owner ~principal:(Lane_addon_call_context.Keeper "other") arguments in
        check (option bool) "another principal cannot consume the grant" (Some true) refused.is_error;
        let accepted=Tool.invoke ~owner ~principal:(Lane_addon_call_context.Keeper "uploader") arguments in
        check (option bool) "original exported upload succeeds" (Some false) accepted.is_error;
        ok (Masc.Lane_addon_tool_hooks.after_call hooks accepted);
        check bool "worker uses its own copy" true (!received<>paths);
        check bool "worker copy stays under its original allocation" true
          (List.for_all (fun path -> String.starts_with ~prefix:(root ^ "/uploads/") path) !received);
        let replay=Tool.invoke ~owner ~principal:(Lane_addon_call_context.Keeper "uploader") arguments in
        check (option bool) "a consumed upload cannot replay" (Some true) replay.is_error;
        check int "only one browser input" 1 !calls));
    check bool "host scope removes its original copies" true
      (List.for_all (fun path -> not (Sys.file_exists path)) !host_paths);
    check (list string) "browser may lazily read after host scope ends" ["late-read\000payload"]
      (List.map contents !received);
    check bool "retirement joins original browser and upload cleanup" true (send W.Retire=W.Receipt);
    check bool "confirmed session shutdown releases worker copies" true
      (List.for_all (fun path -> not (Sys.file_exists path)) !received);
    check bool "retired broker directory is gone" false (Sys.file_exists (Filename.concat root "uploads"))))
let discard_and_replacement () = Eio_main.run (fun _env ->
  let root=private_root () in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let broker=ok (Broker.create ~directory:root) in
    lease_ok (Lease.with_staged_files ~files:["source.bin",(fun () -> Ok "authorized")]
      (fun paths ->
        let verb=command paths and route=B.Automation_route and actor="keeper/uploader" in
        let revoked=id "03" in
        Broker.discard broker ~id:revoked;
        check bool "discard fences even a late stage" true
          (Result.is_error (Broker.stage broker ~id:revoked ~actor ~route ~verb));
        let grant=id "04" in
        ok (Broker.stage broker ~id:grant ~actor ~route ~verb);
        let directory=Filename.concat root "uploads" in
        let batch=Sys.readdir directory |> Array.to_list |> List.hd in
        let preserved=Filename.concat root "original-uploads" in
        Unix.rename directory preserved;
        Unix.mkdir directory 0o700;
        let replaced_batch=Filename.concat directory batch in
        Unix.mkdir replaced_batch 0o700;
        let replaced_subdir=Filename.concat replaced_batch "0" in
        Unix.mkdir replaced_subdir 0o700;
        let foreign=Filename.concat replaced_subdir "source.bin" in
        Out_channel.with_open_bin foreign (fun out -> output_string out "replacement-owned");
        Unix.chmod foreign 0o600;
        let refused=try
          Result.is_error (Broker.with_claim broker ~id:grant ~actor ~route ~verb
            (fun _ -> fail "replaced allocation must not reach a browser"))
          with Sys_error _|Fun.Finally_raised (Sys_error _) -> true in
        check bool "replaced root is refused" true refused;
        check string "cleanup never deletes a replacement file" "replacement-owned" (contents foreign)))))
let () = run "browser Addon upload ownership" ["transfer",[
  test_case "public command keeps worker bytes through browser-owned lifetime" `Quick scenario;
  test_case "discard fences late preparation and replaced roots are retained" `Quick discard_and_replacement]]
