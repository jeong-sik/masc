open Alcotest
module B = Browser_lane
module Lease = B.Upload_lease
module Broker = Masc.Browser_addon_uploads
let ok = function Ok value -> value | Error detail -> fail detail
let id suffix = "0b000000-0000-4000-8000-0000000000" ^ suffix
let command paths = B.Page_act (B.Action.On_tab
  {tab_id=7;interaction=Upload {target=B.Action.File_input "#file";paths}})
let private_root () = Unix.realpath (Filename.temp_dir ~perms:0o700 "browser-upload-test-" "")
let lease_ok = function Ok value -> value | Error _ -> fail "snapshot preparation failed"
let contents path = In_channel.with_open_bin path In_channel.input_all
let discard_and_replacement () = Eio_main.run (fun _env ->
  let root=private_root () in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let broker=ok (Broker.create ~directory:root) in
    lease_ok (Lease.with_staged_files ~files:["source.bin",(fun () -> Ok "authorized")]
      (fun paths ->
        let route=B.Live_route (Some (ok (B.client_id_of_string (id "21")))) in
        let verb=command paths and actor="keeper/uploader" in
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
(* A grant staged for a live connection this worker runs (the ego
   connection) is claimed on that connection's route only; a route that
   names no connection is not staged for. *)
let live_route_grants_are_its_own () = Eio_main.run (fun _env ->
  let root=private_root () in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let broker=ok (Broker.create ~directory:root) in
    lease_ok (Lease.with_staged_files ~files:["source.bin",(fun () -> Ok "authorized")]
      (fun paths ->
        let client value = B.Live_route (Some (ok (B.client_id_of_string value))) in
        let live=client (id "11") and other=client (id "12") and verb=command paths and actor="keeper/uploader" in
        List.iter (fun (name, route) ->
          check bool (name ^ " is not staged for") true (Result.is_error (Broker.stage broker ~id:(id "13") ~actor ~route ~verb)))
          ["a live route without a connection",B.Live_route None];
        let grant=id "14" in
        ok (Broker.stage broker ~id:grant ~actor ~route:live ~verb);
        check bool "another live connection cannot claim it" true
          (Result.is_error (Broker.with_claim broker ~id:grant ~actor ~route:other ~verb (fun _ -> ())));
        let received=ok (Broker.with_claim broker ~id:grant ~actor ~route:live ~verb (function
          | B.Page_act (B.Action.On_tab {interaction=Upload {paths;_};_}) -> paths
          | _ -> fail "the claim must hand back the upload")) in
        check bool "the connection gets the worker's copies" true
          (List.for_all (fun path -> String.starts_with ~prefix:(root ^ "/uploads/") path) received);
        let opener = B.Page_act (B.Action.On_tab {tab_id=7;interaction=Upload {target=B.Action.Chooser_opener "#attach";paths}}) and chooser=id "15" in
        ok (Broker.stage broker ~id:chooser ~actor ~route:live ~verb:opener);
        (match ok (Broker.with_claim broker ~id:chooser ~actor ~route:live ~verb:opener (fun claimed -> claimed)) with
         | B.Page_act (B.Action.On_tab {interaction=Upload {target=B.Action.Chooser_opener "#attach";paths=copies};_}) ->
           check bool "an opener keeps its target and gets the copies" true
             (copies <> paths && List.for_all (fun path -> String.starts_with ~prefix:(root ^ "/uploads/") path) copies)
         | _ -> fail "the claim changed the upload's target")))))
let () = run "browser Addon upload ownership" ["transfer",[
  test_case "discard fences late preparation and replaced roots are retained" `Quick discard_and_replacement;
  test_case "a live connection's grants are its own" `Quick live_route_grants_are_its_own]]
