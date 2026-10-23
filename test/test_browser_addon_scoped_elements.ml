(* The exported browser_command tool relays a scoped elements read. An
   extension built before [within] answers it with every control; the tool
   refuses that answer instead of returning it as scoped. The backend is
   scripted; no browser runs. *)
open Alcotest
module B = Browser_lane
module Owner = Masc.Browser_addon_owner
module Tool = Masc.Browser_addon_tool

let ok = function Ok value -> value | Error detail -> fail detail

let mentions needle text =
  let width = String.length needle in
  let rec from index =
    index + width <= String.length text
    && (String.sub text index width = needle || from (index + 1)) in
  from 0

let scoped_answers_need_their_match_count () =
  Eio_mock.Backend.run_full (fun env ->
    Time_compat.set_clock (env#clock :> float Eio.Time.clock_ty Eio.Resource.t);
    Eio.Switch.run (fun sw ->
      let owner = ok (Owner.create ~incarnation:"0b000000-0000-4000-8000-000000000072") in
      Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
      let answer = ref `Null in
      let execute _verb = B.Answered (`Assoc ["ok", `Bool true; "data", !answer]) in
      ignore (ok (Owner.attach_automation owner ~locate:false ~execute
        ~session:(fun () -> B.Browser_open)
        ~document:(fun ~tab_id:_ -> B.Lane_absent)
        ~cleanup:(fun () -> Ok ())));
      let invoke verb =
        Tool.invoke ~owner ~principal:(Lane_addon_call_context.Host_actor "scoped-elements-test")
          (`Assoc ["lane", `String "automation"; "command", B.verb_json verb]) in
      let every_control = `Assoc ["tabId", `Int 7; "total", `Int 744; "truncated", `Bool true;
        "elements", `List [`Assoc ["selector", `String "#outside"]]] in
      let scoped = `Assoc ["tabId", `Int 7; "within", `String "nav"; "withinMatches", `Int 1;
        "total", `Int 1; "truncated", `Bool false; "elements", `List []] in
      let top = B.Page_elements {tab_id = Some 7;filter={within=Some "nav";selector=None}} in
      let framed = B.Page_context {tab_id = 7; frame_path = ["#frame"]; mode = `Elements {within=Some "nav";selector=None}} in
      List.iter (fun (label, verb) ->
        answer := every_control;
        let refused = invoke verb in
        check (option bool) (label ^ ": an answer without withinMatches fails") (Some true) refused.is_error;
        check bool (label ^ ": the unscoped controls are not passed on") false
          (Option.exists (fun data -> mentions "#outside" (Yojson.Safe.to_string data))
             refused.structured_content);
        answer := scoped;
        check (option bool) (label ^ ": a scoped answer succeeds") (Some false) (invoke verb).is_error)
        ["top document", top; "frame", framed];
      List.iter (fun (within, selector) ->
        let filter = B.{within; selector = Some selector} in
        let verbs = [B.Page_elements {tab_id=Some 7;filter};
          B.Page_context {tab_id=7;frame_path=["#frame"];mode=`Elements filter}] in
        List.iter (fun verb ->
          List.iter (fun reply ->
            answer := reply;
            check (option bool) "missing, mismatched or negative selector receipt fails"
              (Some true) (invoke verb).is_error)
            [scoped;
             `Assoc ["selector",`String "#wrong";"selectorMatches",`Int 1];
             `Assoc ["selector",`String selector;"selectorMatches",`Int (-1)]];
          answer := `Assoc (["selector",`String selector;"selectorMatches",`Int 0;
            "elements",`List [];"total",`Int 0] @
            (match within with None -> [] | Some scope ->
              ["within",`String scope;"withinMatches",`Int 1]));
          check (option bool) "a confirmed zero-match selector answer succeeds"
            (Some false) (invoke verb).is_error) verbs)
        [None,"[role=row]";Some "nav","[role=row]"];
      answer := every_control;
      check (option bool) "an unscoped read is unchanged" (Some false)
        (invoke (B.Page_elements {tab_id = Some 7;filter={within=None;selector=None}})).is_error))

let () = run "Browser add-on scoped elements" ["tool", [
  test_case "scoped answers need their match count" `Quick scoped_answers_need_their_match_count]]
