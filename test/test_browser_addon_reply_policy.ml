(* Actual exported-tool -> owner -> automation wait policy. The backend is
   scripted and the Eio clock is virtual; no browser, network or provider runs.
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
      let execute verb =
        received := verb :: !received;
        Eio.Time.sleep clock !delay;
        B.Answered (`Assoc ["ok", `Bool true; "data", `Assoc ["scripted", `Bool true]])
      in
      ignore (ok (Owner.attach_automation owner ~locate:false ~execute
        ~session:(fun () -> B.Browser_open)
        ~document:(fun ~tab_id:_ -> B.Lane_absent)
        ~cleanup:(fun () -> Ok ())));
      let invoke verb =
        Tool.invoke ~owner
          ~principal:(Lane_addon_call_context.Host_actor "reply-policy-test")
          (`Assoc ["lane", `String "automation"; "command", B.verb_json verb])
      in
      let run (label, verb, wait, answered, elapsed) =
        delay := wait;
        received := [];
        let started = Eio.Time.now clock in
        let result = invoke verb in
        check (float 0.) (label ^ ": original reply window") elapsed
          (Eio.Time.now clock -. started);
        check bool (label ^ ": dispatched exactly once to the selected backend") true
          (!received = [verb]);
        check (option bool) (label ^ ": exported outcome") (Some (not answered)) result.is_error;
        (match original_reply result with
         | W.Issue_result (Ok answer) ->
             (match answer, answered with
              | B.Answered _, true | B.Timed_out, false -> ()
              | (B.Answered _ | Timed_out | Lane_absent | Refused _
                 | Rejected_before_effect _), (true | false) ->
                  fail (label ^ ": expected the original typed answer or timeout"))
         | W.Issue_result (Error _) | Service_refusal _ | Receipt | Snapshot_result _
         | Model_reply _ | Download_reply _ | Poll_result _ ->
             fail (label ^ ": expected the original typed answer or timeout"));
        if not answered then
          check bool (label ^ ": timeout keeps the original effect uncertainty") true
            (snd (Lane_addon_tool_result.failure result) = Tool_result.Effect_outcome_unknown)
      in
      let open_session = B.Session_open {headless=Some true} in
      let goto = B.Page_goto {url="https://example.test/";tab_id=Some 7} in
      let read = B.Page_read {tab_id=Some 7;max_chars=Some 128} in
      let open_tab = B.Page_act (B.Action.Open_tab "https://example.test/") in
      List.iter run [
        "open accepts a 30-second reply", open_session, 30., true, 30.;
        "close accepts a 30-second reply", B.Session_close, 30., true, 30.;
        "goto accepts a 30-second reply", goto, 30., true, 30.;
        "action retains its longer window", open_tab, 30., true, 30.;
        "status keeps its short observation window", B.Session_status, 30., false, 10.;
        "ordinary read keeps its original window", read, 30., false, 20.;
        "open expires when its original window ends", open_session, 61., false, 60.;
        "close expires when its original window ends", B.Session_close, 61., false, 60.;
        "goto expires when its original window ends", goto, 46., false, 45.;
        "action still expires after its own window", open_tab, 61., false, 60.;
        "status accepts a timely reply", B.Session_status, 9., true, 9.;
        "ordinary read accepts a timely reply", read, 19., true, 19.;
      ]))

let () = run "browser Add-on reply policy" ["actual exported tool", [
  test_case "session/navigation waits preserve the original reply policy" `Quick
    policy_at_the_actual_tool_boundary]]
