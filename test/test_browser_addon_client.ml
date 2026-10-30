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
        let model_waiting,model_wait=Eio.Promise.create () in
        let extension_waiting,extension_wait=Eio.Promise.create () in
        let locating,locate=Eio.Promise.create () in
        let starting,start=Eio.Promise.create () in
        let workflowing,workflow=Eio.Promise.create () in
        let never,_=Eio.Promise.create () in
        let cancellations=ref 0 in
        let client=ok (Client.create ~socket_path:path ~incarnation:"0b000000-0000-4000-8000-000000000001"
          ~max_message_bytes:4096 ~control_timeout_sec:0.01 ~available:(fun () -> true)) in
        Eio.Fiber.first (fun () -> Eio.Switch.run (fun server_sw ->
          while true do Eio.Switch.check server_sw;
            Eio.Net.accept_fork ~sw:server_sw socket ~on_error:(fun exn -> raise exn) (fun flow _ ->
              let raw=Eio.Buf_read.line (Eio.Buf_read.of_flow flow ~max_size:4096) in
              let request=Yojson.Safe.from_string raw in
              if Yojson.Safe.Util.member "operation" request=`String "issue" then (
                match Yojson.Safe.Util.(request |> member "command" |> member "verb") with
                | `String "page.locate" -> ignore (Eio.Promise.try_resolve locate ())
                | `String "session.open" -> ignore (Eio.Promise.try_resolve start ())
                | `String "page.native_workflow" -> ignore (Eio.Promise.try_resolve workflow ())
                | _ -> ignore (Eio.Promise.try_resolve enter ()));
              if Yojson.Safe.Util.member "operation" request=`String "model_wait" then
                ignore (Eio.Promise.try_resolve model_wait ());
              if Yojson.Safe.Util.member "operation" request=`String "extension" then
                ignore (Eio.Promise.try_resolve extension_wait ());
              Eio.Promise.await never)
          done))
          (fun () ->
            let result=Client.call client ~on_cancel_after_dispatch:(fun () -> incr cancellations) W.Snapshot in
            check bool "silent peer times out after dispatch with unknown outcome" true
              (match result with Error (Client.Outcome_unknown _) -> true | Ok _|Error (Client.Unavailable _) -> false);
            check int "transport timeout is distinct from caller cancellation" 0 !cancellations;
            (match Eio.Fiber.first
              (fun () -> `Returned (Client.call client ~on_cancel_after_dispatch:(fun () -> ())
                (W.Model_wait {after=Some "unchanged"})))
              (fun () -> Eio.Promise.await model_waiting;Eio.Time.sleep clock 0.03;`Waiting) with
             | `Waiting -> ()
             | `Returned _ -> fail "model state watch must outlive the quick control timeout");
            (match Eio.Fiber.first
              (fun () -> `Returned (Client.call client ~on_cancel_after_dispatch:(fun () -> ())
                (W.Extension (Masc.Browser_extension_protocol.Release "0b000000-0000-4000-8000-000000000001"))))
              (fun () -> Eio.Promise.await extension_waiting;Eio.Time.sleep clock 0.03;`Waiting) with
             | `Waiting -> ()
             | `Returned _ -> fail "private extension execution must retain the original caller-owned wait");
            (match Eio.Fiber.first
              (fun () -> `Returned (Client.call client ~on_cancel_after_dispatch:(fun () -> ())
                (W.Issue {route=Browser_lane.Automation_route;
                  verb=Browser_lane.Page_locate {tab_id=1;instruction=None};actor=None;
                  timeout_sec=0.001;only_if_idle=false})))
              (fun () -> Eio.Promise.await locating;Eio.Time.sleep clock 0.03;`Waiting) with
             | `Waiting -> ()
             | `Returned _ -> fail "model-backed issue must retain its caller-owned wait");
            (match Eio.Fiber.first
              (fun () -> `Returned (Client.call client ~on_cancel_after_dispatch:(fun () -> ())
                (W.Issue {route=Browser_lane.Stagehand_route;
                  verb=Browser_lane.Session_open {headless=Some true};actor=None;
                  timeout_sec=0.001;only_if_idle=false})))
              (fun () -> Eio.Promise.await starting;Eio.Time.sleep clock 0.03;`Waiting) with
             | `Waiting -> ()
             | `Returned _ -> fail "Chrome startup must retain its owner beyond the quick transport clock");
            let native=ok (Browser_lane.Native_workflow.of_json (`Assoc ["tabId",`Int 1;
              "expectedUrl",`String "https://example.org";"steps",`List [];"maxChars",`Int 1000])) in
            (match Eio.Fiber.first
              (fun () -> `Returned (Client.call client ~on_cancel_after_dispatch:(fun () -> ())
                (W.Issue {route=Browser_lane.Live_route None;verb=Browser_lane.Page_native_workflow native;
                  actor=None;timeout_sec=0.001;only_if_idle=false})))
              (fun () -> Eio.Promise.await workflowing;Eio.Time.sleep clock 0.03;`Waiting) with
             | `Waiting -> ()
             | `Returned _ -> fail "native workflow must retain the SDK-owned wait");
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
(* Exercise the shared client, including the authenticated worker snapshot and
   actual request writes. A classifier-only test misses route leakage here. *)
let transport_policy () = Eio_main.run (fun env ->
  let directory=Filename.temp_dir "bac-policy-" "" in
  let path=Filename.concat directory "s" in
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Unix.unlink path;Unix.rmdir directory)
    (fun () -> Eio.Switch.run (fun sw ->
      let net=Eio.Stdenv.net env and clock=Eio.Stdenv.clock env in
      Eio.Time.with_timeout_exn clock 10. (fun () ->
        Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
          let socket=Eio.Net.listen ~sw ~backlog:8 net (`Unix path) in
          let never,_=Eio.Promise.create () in
          let snapshot_reply=ref None and issues=ref 0 in
          let snapshot_hook=ref (fun () -> ()) in
          let issue_entered=ref (Eio.Promise.create ()) in
          let client=ok (Client.create ~socket_path:path ~incarnation:"0b000000-0000-4000-8000-000000000001"
            ~max_message_bytes:4096 ~control_timeout_sec:0.1 ~available:(fun () -> true)) in
          let call command=Client.call client ~on_cancel_after_dispatch:(fun () -> ()) command in
          let info suffix transport : Browser_lane.client_info = {
            client_id=ok (Browser_lane.client_id_of_string ("0c000000-0000-4000-8000-00000000000" ^ suffix));
            browser=(match transport with Browser_lane.Ego_task_space -> Ego_lite | Web_extension|Webdriver_bidi -> Firefox);
            transport;version="test";engine_version="test";space=(match transport with Browser_lane.Ego_task_space -> Some ({id=51;name="fixture Space"} : Browser_lane.ego_space) | Web_extension|Webdriver_bidi -> None)} in
          let ego=info "1" Ego_task_space and extension=info "2" Web_extension and bidi=info "3" Webdriver_bidi in
          let snapshot clients =
            let owned=`Assoc ["activity",`String "disabled";"registered",`Bool false;
              "session",`String "closed";"locate",`Bool false] in
            W.Snapshot_result (`Assoc ["state",`String "serving";
              "owned_backends",`Assoc ["automation",owned;"stagehand",owned];
              "clients",`List (List.map W.client_to_json clients)]) in
          let click=Browser_lane.Page_interact {tab_id=1;expected_url=Some "https://fixture.test/";
            frame_path=[];action=Browser_lane.Click "#send"} in
          let goto=Browser_lane.Page_goto {url="https://fixture.test/";tab_id=Some 1} in
          let reload=Browser_lane.Page_act (Browser_lane.Action.On_tab {tab_id=1;frame_path=[];
            interaction=Browser_lane.Action.Reload}) in
          let open_tab=Browser_lane.Page_act (Browser_lane.Action.Open_tab "https://fixture.test/") in
          let issue route verb=W.Issue {route;verb;actor=None;timeout_sec=0.001;only_if_idle=false} in
          let refused label command =
            let before= !issues in
            check bool label true (match call command with
              | Error (Client.Unavailable _) -> true | Ok _|Error (Client.Outcome_unknown _) -> false);
            check int "refusal writes no Issue" before !issues in
          let bounded route verb =
            let before= !issues in
            check bool "silent non-Ego peer retains reply window" true (match call (issue route verb) with
              | Error (Client.Outcome_unknown _) -> true | Ok _|Error (Client.Unavailable _) -> false);
            check int "bounded request reached original worker" (before+1) !issues in
          let read clients =
            snapshot_reply := Some (snapshot clients);
            match call W.Snapshot with Ok (W.Snapshot_result _) -> ()
            | Ok (Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _|Service_refusal _)
            | Error _ -> fail "valid worker snapshot rejected" in
          Eio.Fiber.first (fun () -> Eio.Switch.run (fun server_sw ->
            while true do
              Eio.Net.accept_fork ~sw:server_sw socket ~on_error:raise (fun flow _ ->
                let raw=Eio.Buf_read.line (Eio.Buf_read.of_flow flow ~max_size:4096) in
                let request=ok (W.of_json (Yojson.Safe.from_string raw)) in
                match request.command with
                | W.Snapshot ->
                  let reply= !snapshot_reply and hook= !snapshot_hook in
                  hook (); (match reply with
                  | None -> Eio.Promise.await never
                  | Some reply -> Eio.Flow.copy_string (Yojson.Safe.to_string (W.reply_to_json reply) ^ "\n") flow)
                | W.Issue _ -> incr issues; ignore (Eio.Promise.try_resolve (snd !issue_entered) ()); Eio.Promise.await never
                | Retire|Upload_stage _|Upload_discard _|Download_claim _|Download_commit _|Download_release _
                | Model_requests|Model_result _|Model_wait _|Extension _|Poll _|Deliver _|Disconnect _ -> fail "unexpected fixture request")
            done))
            (fun () ->
              refused "unobserved exact live transport refused" (issue (Live_route (Some ego.client_id)) click);
              refused "unselected live transport refused" (issue (Live_route None) click);
              read [ego;extension;bidi];
              List.iter (fun route -> List.iter (bounded route) [click;goto;reload;open_tab])
                [Browser_lane.Automation_route;Stagehand_route;Live_route (Some extension.client_id);Live_route (Some bidi.client_id)];
              List.iter (fun verb ->
                issue_entered := Eio.Promise.create ();
                match Eio.Fiber.first
                (fun () -> `Returned (call (issue (Live_route (Some ego.client_id)) verb)))
                (fun () -> Eio.Promise.await (fst !issue_entered);Eio.Time.sleep clock 0.3;`Waiting) with
               | `Waiting -> () | `Returned _ -> fail "observed Ego SDK operation lost its owner wait")
                [click;goto;reload;open_tab];
              read [extension;bidi];
              refused "replacement snapshot removes old client" (issue (Live_route (Some ego.client_id)) click);
              List.iter (fun reply ->
                read [ego]; snapshot_reply := reply;
                check bool "unsuccessful snapshot rejected" true (match call W.Snapshot with
                  | Error _|Ok (Service_refusal _) -> true
                  | Ok (Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _) -> false);
                refused "failed snapshot clears prior transport" (issue (Live_route (Some ego.client_id)) click))
                [Some (W.Snapshot_result (`Assoc ["state",`String "serving"]));
                 Some (W.Service_refusal {message="retired";disposition=Not_started});None];
              let overlap older newer ~newest_first expected_clients =
                let older_seen,see_older=Eio.Promise.create () in
                let newer_seen,see_newer=Eio.Promise.create () in
                let older_release,release_older=Eio.Promise.create () in
                let newer_release,release_newer=Eio.Promise.create () in
                let older_done,finish_older=Eio.Promise.create () in
                let newer_done,finish_newer=Eio.Promise.create () in
                snapshot_reply := Some older;
                snapshot_hook := (fun () -> Eio.Promise.resolve see_older ();Eio.Promise.await older_release);
                Eio.Fiber.fork ~sw (fun () -> ignore (call W.Snapshot);Eio.Promise.resolve finish_older ());
                Eio.Promise.await older_seen;
                snapshot_reply := Some newer;
                snapshot_hook := (fun () -> Eio.Promise.resolve see_newer ();Eio.Promise.await newer_release);
                Eio.Fiber.fork ~sw (fun () -> ignore (call W.Snapshot);Eio.Promise.resolve finish_newer ());
                Eio.Promise.await newer_seen;
                if newest_first then (
                  Eio.Promise.resolve release_newer ();Eio.Promise.await newer_done;
                  Eio.Promise.resolve release_older ();Eio.Promise.await older_done)
                else (
                  Eio.Promise.resolve release_older ();Eio.Promise.await older_done;
                  refused "old reply cannot publish while latest snapshot pending"
                    (issue (Live_route (Some ego.client_id)) click);
                  Eio.Promise.resolve release_newer ();Eio.Promise.await newer_done);
                snapshot_hook := (fun () -> ());
                refused "stale snapshot cannot restore removed Ego metadata"
                  (issue (Live_route (Some ego.client_id)) click);
                List.iter (fun (client:Browser_lane.client_info) -> bounded (Live_route (Some client.client_id)) click)
                  expected_clients in
              let malformed=W.Snapshot_result (`Assoc ["state",`String "serving"]) in
              List.iter (fun newest_first ->
                overlap (snapshot [ego]) malformed ~newest_first [];
                overlap (snapshot [ego]) (snapshot [extension]) ~newest_first [extension]) [true;false];
              overlap malformed (snapshot [extension]) ~newest_first:true [extension];
              read [ego]; Client.revoke client;
              refused "revoked client cannot use prior metadata" (issue (Live_route (Some ego.client_id)) click)))))))
let silent_selector_reply_window route = Eio_main.run (fun env ->
  let directory=Filename.temp_dir "bac-selector-" "" in
  let path=Filename.concat directory "s" in
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Unix.unlink path;Unix.rmdir directory)
    (fun () -> Eio.Switch.run (fun sw ->
      let net=Eio.Stdenv.net env and clock=Eio.Stdenv.clock env in
      Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
        let socket=Eio.Net.listen ~sw ~backlog:1 net (`Unix path) in
        let dispatched,dispatch=Eio.Promise.create () in
        let never,_=Eio.Promise.create () in
        let cancellations=ref 0 in
        let client=ok (Client.create ~socket_path:path ~incarnation:"0b000000-0000-4000-8000-000000000001"
          ~max_message_bytes:4096 ~control_timeout_sec:0.01 ~available:(fun () -> true)) in
        Eio.Fiber.first (fun () -> Eio.Switch.run (fun server_sw ->
          Eio.Net.accept_fork ~sw:server_sw socket ~on_error:(fun exn -> raise exn) (fun flow _ ->
            ignore(Eio.Buf_read.line(Eio.Buf_read.of_flow flow ~max_size:4096));
            Eio.Promise.resolve dispatch ();
            Eio.Promise.await never);
          Eio.Promise.await never))
          (fun () ->
            let verb=Browser_lane.Page_interact {tab_id=1;frame_path=[];
              expected_url=Some "https://example.test/";action=Browser_lane.Click "#save"} in
            let observed=Eio.Fiber.first
              (fun () -> `Returned(Client.call client ~on_cancel_after_dispatch:(fun () -> incr cancellations)
                (W.Issue {route;verb;actor=None;timeout_sec=0.001;only_if_idle=false})))
              (fun () -> Eio.Promise.await dispatched;Eio.Time.sleep clock 0.03;`Still_waiting) in
            (match observed with
             | `Returned(Error(Client.Outcome_unknown _)) -> ()
             | `Returned(Ok _|Error(Client.Unavailable _)) -> fail "silent dispatched selector lost its unknown outcome"
             | `Still_waiting -> fail "selector request escaped the private reply window");
            check int "reply timeout is distinct from caller cancellation" 0 !cancellations)))))

let private_reply_boundary () = Eio_main.run (fun env ->
  let directory=Filename.temp_dir "bac-private-" "" in
  let path=Filename.concat directory "s" in
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Unix.unlink path;Unix.rmdir directory)
    (fun () -> Eio.Switch.run (fun sw ->
      let net=Eio.Stdenv.net env and clock=Eio.Stdenv.clock env in
      Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
        let socket=Eio.Net.listen ~sw ~backlog:1 net (`Unix path) in
        let client=ok (Client.create ~socket_path:path ~incarnation:"0b000000-0000-4000-8000-000000000001"
          ~max_message_bytes:4096 ~control_timeout_sec:1. ~available:(fun () -> true)) in
        let once raw command =
          let server=Eio.Fiber.fork_promise ~sw (fun () ->
            let flow,_=Eio.Net.accept ~sw socket in
            ignore (Eio.Buf_read.line (Eio.Buf_read.of_flow flow ~max_size:4096));
            Eio.Flow.copy_string (raw ^ "\n") flow) in
          let result=Client.call client ~on_cancel_after_dispatch:(fun () -> ()) command in
          Eio.Promise.await_exn server;result in
        check bool "extension reply cannot be accepted as a model reply" true
          (once (Yojson.Safe.to_string (W.reply_to_json (W.Extension_reply (`String "PRIVATE_REFERENCE_MARKER"))))
            W.Model_requests=Error (Client.Outcome_unknown "unexpected browser service reply"));
        check bool "malformed private reply never echoes payload fragments" true
          (once {|{"reply":"extension","value":"PRIVATE_TOKEN_MARKER|} W.Model_requests
            =Error (Client.Outcome_unknown "malformed browser service reply"))))))
let private_admission_after_connect () = Eio_main.run (fun env ->
  let directory=Filename.temp_dir "bac-admit-" "" in
  let path=Filename.concat directory "s" in
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Unix.unlink path;Unix.rmdir directory)
    (fun () -> Eio.Switch.run (fun sw ->
      let net=Eio.Stdenv.net env and clock=Eio.Stdenv.clock env in
      Eio.Time.with_timeout_exn clock 5. (fun () ->
      Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
        let socket=Eio.Net.listen ~sw ~backlog:1 net (`Unix path) in
        let client=ok (Client.create ~socket_path:path ~incarnation:"0b000000-0000-4000-8000-000000000001"
          ~max_message_bytes:4096 ~control_timeout_sec:1. ~available:(fun () -> true)) in
        let received=Eio.Fiber.fork_promise ~sw (fun () ->
          let flow,_=Eio.Net.accept ~sw socket in
          let buffer=Cstruct.create 1 in
          match Eio.Flow.single_read flow buffer with
          | count -> count
          | exception End_of_file -> 0) in
        let admissions=ref 0 and cancellations=ref 0 in
        let result=Client.call_companion client
          ~admit:(fun () -> incr admissions; !admissions=1)
          ~on_cancel_after_dispatch:(fun () -> incr cancellations)
          (Masc.Browser_extension_protocol.Release "0b000000-0000-4000-8000-000000000001") in
        check bool "post-connect authority denial refuses before writing" true
          (match result with Error (Client.Unavailable _) -> true | Ok _|Error (Client.Outcome_unknown _) -> false);
        check int "authority is read again after connect" 2 !admissions;
        check int "denied extension never reaches the Browser worker" 0 (Eio.Promise.await_exn received);
        check int "pre-dispatch refusal does not claim unknown effects" 0 !cancellations)))))

let ()=run "browser addon private client" ["transport",[
  test_case "silent peer timeout cancellation and revoked connection" `Quick scenario;
  test_case "worker transport scopes SDK-owned waits" `Quick transport_policy;
  test_case "silent automation selector keeps reply window" `Quick
    (fun () -> silent_selector_reply_window Browser_lane.Automation_route);
  test_case "silent Stagehand selector keeps reply window" `Quick
    (fun () -> silent_selector_reply_window Browser_lane.Stagehand_route);
  test_case "fresh companion admission after connect" `Quick private_admission_after_connect;
  test_case "private payload errors and distinct reply kinds" `Quick private_reply_boundary]]
