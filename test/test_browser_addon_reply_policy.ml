(* Actual exported-tool -> owner -> live connection wait policy. The BiDi
   connection is scripted and the Eio clock is virtual; no browser, network or
   provider runs. The window is measured on the virtual clock and the deadline
   on the process clock, so elapsed time is compared within a millisecond.
   One owner owns every case: Owner.create is process-wide single admission. *)
open Alcotest
module B = Browser_lane
module Owner = Masc.Browser_addon_owner
module Tool = Masc.Browser_addon_tool
module W = Masc.Browser_addon_wire

let ok = function Ok value -> value | Error detail -> fail detail

let original_reply (result : Mcp_protocol.Mcp_types.tool_result) =
  match result.structured_content with
  | Some (`Assoc fields) ->
      W.reply_of_json (`Assoc (List.filter
        (fun (key, _) -> key <> "browserSelection" && key <> "browserConnection") fields))
      |> ok
  | None | Some _ -> fail "the exported tool must preserve its structured reply"

let policy_at_the_actual_tool_boundary () =
  Eio_mock.Backend.run_full (fun env ->
    let clock = env#clock in
    Time_compat.set_clock (clock :> float Eio.Time.clock_ty Eio.Resource.t);
    Eio.Switch.run (fun sw ->
      let owner = ok (Owner.create
        ~incarnation:"0b000000-0000-4000-8000-000000000071") in
      Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
      let delay = ref 0. and received = ref [] in
      let client_id = ok (B.client_id_of_string "0c000000-0000-4000-8000-000000000071") in
      let client = {B.client_id;browser=B.Firefox;version="fixture";engine_version="fixture";
        transport=B.Webdriver_bidi;space=None} in
      let send command = Owner.dispatch owner {W.incarnation=Owner.incarnation owner;command} in
      (* Each command is answered after [delay] on its own fiber, so a late
         answer to one case never holds up the next. *)
      Eio.Fiber.fork_daemon ~sw (fun () ->
        let rec serve () = match send (W.Poll {client;window_sec=3600.}) with
          | W.Poll_result {command=None;_} -> serve ()
          | W.Poll_result {command=Some command;_} ->
              let wait = !delay in
              received := (match command.verb_json with
                | `Assoc fields -> `Assoc (List.remove_assoc "actor" fields)
                | other -> other) :: !received;
              Eio.Fiber.fork ~sw (fun () ->
                Eio.Time.sleep clock wait;
                ignore (send (W.Deliver {client_id;id=command.id;
                  payload=`Assoc ["ok", `Bool true; "data", `Assoc ["scripted", `Bool true]]})));
              serve ()
          | W.Service_refusal _|Snapshot_result _|Download_reply _|Receipt|Issue_result _ -> `Stop_daemon in
        serve ());
      let rec registered () = if B.connected_clients () = [] then (Eio.Fiber.yield (); registered ()) in
      registered ();
      let invoke verb =
        Tool.invoke ~owner
          ~principal:(Lane_addon_call_context.Host_actor "reply-policy-test")
          (`Assoc ["lane", `String "live"; "clientId", `String (B.client_id_to_string client_id);
            "command", B.verb_json verb])
      in
      let run (label, verb, wait, answered, elapsed) =
        delay := wait;
        received := [];
        let started = Eio.Time.now clock in
        let result = invoke verb in
        check (float 0.001) (label ^ ": original reply window") elapsed
          (Eio.Time.now clock -. started);
        check bool (label ^ ": dispatched exactly once to the selected connection") true
          (!received = [B.verb_json verb]);
        check (option bool) (label ^ ": exported outcome") (Some (not answered)) result.is_error;
        (match original_reply result with
         | W.Issue_result (Ok answer) ->
             (match answer, answered with
              | B.Answered _, true | B.Timed_out, false -> ()
              | (B.Answered _ | Timed_out | Lane_absent | Refused _
                 | Rejected_before_effect _), (true | false) ->
                  fail (label ^ ": expected the original typed answer or timeout"))
         | W.Issue_result (Error _) | Service_refusal _ | Receipt | Snapshot_result _
         | Download_reply _ | Poll_result _ ->
             fail (label ^ ": expected the original typed answer or timeout"));
        if not answered then
          check bool (label ^ ": timeout keeps the original effect uncertainty") true
            (snd (Lane_addon_tool_result.failure result) = Tool_result.Effect_outcome_unknown)
      in
      let goto = B.Page_goto {url="https://example.test/";tab_id=Some 7} in
      let read = B.Page_read {tab_id=Some 7;max_chars=Some 128} in
      let open_tab = B.Page_act (B.Action.Open_tab "https://example.test/") in
      List.iter run [
        "goto accepts a 30-second reply", goto, 30., true, 30.;
        "action retains its longer window", open_tab, 30., true, 30.;
        "ordinary read keeps its original window", read, 30., false, 20.;
        "goto expires when its original window ends", goto, 46., false, 45.;
        "action still expires after its own window", open_tab, 61., false, 60.;
        "ordinary read accepts a timely reply", read, 19., true, 19.;
      ]))

let () = run "browser Add-on reply policy" ["actual exported tool", [
  test_case "navigation and action waits preserve the original reply policy" `Quick
    policy_at_the_actual_tool_boundary]]
