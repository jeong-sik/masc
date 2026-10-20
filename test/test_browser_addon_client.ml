open Alcotest
module Client = Masc.Browser_addon_client
module W = Masc.Browser_addon_wire
let ok = function Ok value -> value | Error detail -> fail detail
let scenario () = Eio_main.run (fun env ->
  let directory=Filename.temp_dir "bac-" "" in
  let path=Filename.concat directory "s" in
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Unix.unlink path;Unix.rmdir directory)
    (fun () -> Eio.Switch.run (fun sw ->
      let net=Eio.Stdenv.net env and clock=Eio.Stdenv.clock env in
      Eio.Time.with_timeout_exn clock 5. (fun () ->
      Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
        let socket=Eio.Net.listen ~sw ~backlog:1 net (`Unix path) in
        let entered,enter=Eio.Promise.create () in
        let never,_=Eio.Promise.create () in
        let cancellations=ref 0 in
        let client=ok (Client.create ~socket_path:path ~incarnation:"0b000000-0000-4000-8000-000000000001"
          ~max_message_bytes:4096 ~control_timeout_sec:0.01 ~available:(fun () -> true)) in
        Eio.Fiber.first (fun () -> Eio.Switch.run (fun server_sw ->
          while true do Eio.Switch.check server_sw;
            Eio.Net.accept_fork ~sw:server_sw socket ~on_error:(fun exn -> raise exn) (fun flow _ ->
              let raw=Eio.Buf_read.line (Eio.Buf_read.of_flow flow ~max_size:4096) in
              if Yojson.Safe.Util.member "operation" (Yojson.Safe.from_string raw)=`String "issue" then
                ignore (Eio.Promise.try_resolve enter ());
              Eio.Promise.await never)
          done))
          (fun () ->
            let result=Client.call client ~on_cancel_after_dispatch:(fun () -> incr cancellations) W.Snapshot in
            check bool "silent peer times out after dispatch with unknown outcome" true
              (match result with Error (Client.Outcome_unknown _) -> true | Ok _|Error (Client.Unavailable _) -> false);
            check int "transport timeout is distinct from caller cancellation" 0 !cancellations;
            let client=ok (Client.create ~socket_path:path ~incarnation:"0b000000-0000-4000-8000-000000000001"
              ~max_message_bytes:4096 ~control_timeout_sec:1. ~available:(fun () -> true)) in
            let client_id=ok (Browser_lane.client_id_of_string "0c000000-0000-4000-8000-000000000001") in
            let command=W.Issue {route=Browser_lane.Live_route (Some client_id);verb=Browser_lane.Tabs_list;
              actor=None;timeout_sec=1.;only_if_idle=false} in
            Eio.Fiber.first (fun () ->
              ignore (Client.call client ~on_cancel_after_dispatch:(fun () -> incr cancellations) command);
              fail "cancelled socket call returned")
              (fun () -> Eio.Promise.await entered;Eio.Fiber.yield ());
            check int "post-dispatch caller cancellation requests original owner cleanup" 1 !cancellations;
            Client.revoke client;
            check bool "revoked connection refuses before dispatch" true
              (match Client.call client ~on_cancel_after_dispatch:(fun () -> incr cancellations) W.Snapshot with
               | Error (Client.Unavailable _) -> true | Ok _|Error (Client.Outcome_unknown _) -> false)))))))
let ()=run "browser addon private client" ["transport",[
  test_case "silent peer timeout cancellation and revoked connection" `Quick scenario]]
