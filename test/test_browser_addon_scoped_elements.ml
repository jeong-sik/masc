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
      let top = B.Page_elements {tab_id = Some 7; within = Some "nav"} in
      let framed = B.Page_context {tab_id = 7; frame_path = ["#frame"]; mode = `Elements (Some "nav")} in
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
      answer := every_control;
      check (option bool) "an unscoped read is unchanged" (Some false)
        (invoke (B.Page_elements {tab_id = Some 7; within = None})).is_error))

let () = run "Browser add-on scoped elements" ["tool", [
  test_case "scoped answers need their match count" `Quick scoped_answers_need_their_match_count]]
