open Alcotest
module Client = Masc_tui_msx_tick

let revision c = String.make 64 c
let reference ?(width = 1) ?(height = 1) revision =
  ["revision", `String revision; "width", `Int width; "height", `Int height]
let inline ?(width = 1) ?(height = 1) revision rgb =
  `Assoc (["kind", `String "inline"; "rgb_base64", `String (Base64.encode_string rgb)]
    @ reference ~width ~height revision)
let retained ?(width = 1) ?(height = 1) revision =
  `Assoc (["kind", `String "retained"] @ reference ~width ~height revision)
let frame ?(width = 1) ?(height = 1) ?(player = "alice") number pixels =
  `Assoc ["loaded", `Bool true; "number", `Int number;
    "change_count", `Int number; "incarnation", `String "msx-test";
    "width", `Int width;
    "height", `Int height; "mode", `String "GRAPHIC4";
    "cartridge", `Null; "disk", `String "game.dsk";
    "players", `List [`Assoc ["who", `String player]]; "pixels", pixels]
let auth token = ["Authorization", "Bearer " ^ token; "X-MASC-Agent", "operator"]
let known body = Yojson.Safe.Util.member "known_pixels" (Yojson.Safe.from_string body)
let require = function Ok value -> value | Error e -> fail e
let loaded = function Client.Advanced (Some frame, Some _) -> frame
  | Advanced (None,None) -> fail "no frame"
  | Advanced (Some _,None) | Advanced (None,Some _) -> fail "frame and mark disagree"
  | Not_started _ -> fail "tick was refused"
  | Worker_unavailable _ -> fail "tick found no worker"
let failure = function Error _ -> () | Ok _ -> fail "failure returned a successful frame"
let fetch ?(host = "localhost") ?(port = 8935) ?(headers = auth "a") cache request =
  Client.fetch cache ~host ~port ~headers ~request:(fun ~body -> Result.map (fun json -> 200,json) (request ~body))

let test_retained_metadata () =
  let cache = Client.create () and tag = revision 'a' in
  let initial = fetch cache (fun ~body ->
    check bool "first request has no retained pixels" true (known body = `Null);
    Ok (frame 1 (inline tag "rgb"))) |> require |> loaded in
  let allocated = Gc.allocated_bytes () in
  for number = 2 to 101 do
    let observation = fetch cache (fun ~body ->
      check bool "advertise exact pixels" true (known body = `Assoc (reference tag));
      Ok (frame ~player:"bob" number (retained tag))) |> require in
    check (option int) "tick mark follows its frame" (Some number)
      (match observation with Advanced (_,mark) -> Option.map (fun (mark : Masc_tui_machine_live.mark) -> mark.count) mark
       | Not_started _ | Worker_unavailable _ -> None);
    let current = loaded observation in
    check int "clock is fresh" number current.msx_number;
    check (option (list string)) "players are fresh" (Some ["bob"])
      (Option.map (fun (m : Masc_tui_types.msx_meta) -> m.msx_players) current.msx_meta);
    check bool "retained pixels reuse immutable decoded bytes" true (current.msx_rgb == initial.msx_rgb)
  done;
  Printf.printf "100 retained MSX tick client responses allocate %.0f bytes (includes test assertions)\n%!"
    (Gc.allocated_bytes () -. allocated);
  let changed = fetch cache (fun ~body:_ ->
    Ok (frame ~width:2 102 (inline ~width:2 (revision 'b') "newrgb"))) |> require |> loaded in
  check int "new geometry" 2 changed.msx_width;
  check string "new pixels" "newrgb" changed.msx_rgb;
  let repeated = fetch cache (fun ~body ->
    check bool "new reference advertised" true
      (known body = `Assoc (reference ~width:2 (revision 'b')));
    Ok (frame ~width:2 103 (retained ~width:2 (revision 'b')))) |> require |> loaded in
  check bool "changed pixels are then retained" true (changed.msx_rgb == repeated.msx_rgb);
  check bool "ejection clears display" true
    ((fetch cache (fun ~body:_ -> Ok (`Assoc ["loaded", `Bool false])) |> require) = Client.Advanced (None, None));
  failure (fetch cache (fun ~body ->
    check bool "ejection clears advertised pixels" true (known body = `Null);
    Ok (frame 104 (retained tag))))

let test_rejected_responses () =
  let tag = revision 'a' in
  let bad_responses =
    [ Error "HTTP 401"; Error "HTTP 503"; Error "connection closed";
      Ok (`List []); Ok (`Assoc ["loaded", `Bool true]);
      Ok (`Assoc ["loaded", `Bool true; "number", `Int 2; "width", `Int 1;
        "height", `Int 1; "mode", `String "GRAPHIC4"; "cartridge", `Null;
        "disk", `Null; "players", `List [];
        "pixels", inline tag "rgb"]);
      Ok (frame 2 (retained (revision 'b')));
      Ok (frame ~width:2 2 (retained tag));
      Ok (frame 2 (inline tag "too long"));
      Ok (frame 2 (`Assoc (["kind", `String "inline"; "rgb_base64", `String "!"] @ reference tag))) ] in
  List.iter (fun response ->
    let cache = Client.create () in
    ignore (fetch cache (fun ~body:_ -> Ok (frame 1 (inline tag "rgb"))) |> require);
    let calls = ref 0 in
    failure (fetch cache (fun ~body:_ -> incr calls; response));
    check int "failed mutation is never retried" 1 !calls;
    failure (fetch cache (fun ~body ->
      check bool "failure clears cached pixels" true (known body = `Null);
      Ok (frame 3 (retained tag))))) bad_responses;
  failure (fetch (Client.create ()) (fun ~body:_ -> Ok (frame 1 (retained tag))));
  let calls = ref 0 in
  let cancellation = Eio.Cancel.Cancelled Exit in
  let propagated =
    try
      ignore (fetch (Client.create ()) (fun ~body:_ -> incr calls; raise cancellation));
      false
    with Eio.Cancel.Cancelled _ as error -> error == cancellation in
  check bool "cancellation propagates unchanged" true propagated;
  check int "cancelled mutation is never retried" 1 !calls

let test_scope () =
  let cache = Client.create () in
  List.iter (fun (host, port, headers) ->
    ignore (fetch cache ~host ~port ~headers (fun ~body ->
      check bool "different scope never advertises old pixels" true (known body = `Null);
      Ok (frame 1 (inline (revision 'a') "rgb"))) |> require))
    ["host-a", 8935, auth "a"; "host-b", 8935, auth "a";
     "host-b", 8936, auth "a"; "host-b", 8936, auth "b";
     "host-b", 8936, []; "host-a", 8935, auth "a"]

let test_late_response () =
  let cache = Client.create () in
  List.iter (fun older_response ->
    ignore (fetch cache ~headers:(auth "a") (fun ~body:_ ->
      (* No lock may be held across the request callback. A newer request
         completes while this request is awaiting its response. *)
      ignore (fetch cache ~headers:(auth "b") (fun ~body:_ ->
        Ok (frame 2 (inline (revision 'b') "new"))) |> require);
      older_response));
    let current = fetch cache ~headers:(auth "b") (fun ~body ->
      check bool "late completion cannot replace or clear new scope" true
        (known body = `Assoc (reference (revision 'b')));
      Ok (frame 3 (retained (revision 'b')))) |> require |> loaded in
    check string "new pixels survive" "new" current.msx_rgb)
    [Ok (frame 1 (inline (revision 'a') "old")); Error "old request failed"]

let test_activity_refusal_and_recovery () =
  let cache = Client.create () and tag = revision 'a' in
  let initial = fetch cache (fun ~body:_ -> Ok (frame 1 (inline tag "rgb"))) |> require |> loaded in
  List.iter (fun (code,refusal) ->
    let calls = ref 0 in
    let reply = Client.fetch cache ~host:"localhost" ~port:8935 ~headers:(auth "a") ~request:(fun ~body:_ ->
      incr calls; Ok (409,`Assoc ["ok",`Bool false;"code",`String code])) in
    check bool "typed refusal is known before execution" true (reply=Ok (Client.Not_started refusal));
    check int "refusal does not retry POST" 1 !calls;
    let policy = Client.policy_after_tick reply in
    check bool "off switches to read-only observation" true (policy=Client.Observing refusal);
    check bool "read failure cannot resume execution" true (Client.policy_after_activity policy (Error "read failed")=policy);
    let read wire = Client.decode_activity (`Assoc ["schema",`String "masc.msx-activity/v1";"activity",`String wire]) in
    check bool "unobserved continues reads only" true
      (Client.policy_after_activity policy (read "unobserved")=Client.Observing Activity_unobserved);
    check bool "off continues reads only" true (Client.policy_after_activity policy (read "off")=Client.Observing Off);
    check bool "on read permits a subsequent tick" true (Client.policy_after_activity policy (read "on")=Client.Advancing);
    let resumed = fetch cache (fun ~body ->
      check bool "typed refusal preserves pixel basis" true (known body=`Assoc (reference tag));
      Ok (frame 2 (retained tag))) |> require |> loaded in
    check bool "retained pixels survive off/on" true (resumed.msx_rgb == initial.msx_rgb))
    ["activity_disabled",Client.Off;"activity_unobserved",Client.Activity_unobserved];
  let unknown = Client.policy_after_tick (Error "connection lost") in
  check bool "lost mutation has unknown outcome" true (unknown=Client.Outcome_unknown);
  check bool "even observed on cannot retry an unknown mutation" true
    (Client.policy_after_activity unknown (Ok Client.Enabled)=Client.Outcome_unknown)

(* The route answers {code, ok, message}; the terminal used to match exactly
   {code, ok} for the activity codes, so a real activity refusal became an
   unknown outcome and stopped the tick. The server's own encoder produces the
   body here, with a field the terminal has never heard of beside it. *)
let test_refusal_body_is_not_matched_by_field_set () =
  List.iter (fun (code, refusal) ->
    let body = match Msx_wire.encode ~code "refused before execution" with
      | `Assoc fields -> `Assoc (fields @ ["added_later", `Bool true])
      | other -> other in
    let result = Client.fetch (Client.create ()) ~host:"localhost" ~port:8935 ~headers:[]
      ~request:(fun ~body:_ -> Ok (409, body)) in
    check bool "a refusal with a message and an extra field is still known" true
      (result = Ok (Client.Not_started refusal));
    check bool "and does not stop the tick" true
      (Client.policy_after_tick result = Client.Observing refusal))
    [Msx_wire.Activity_disabled, Client.Off;
     Msx_wire.Activity_unobserved, Client.Activity_unobserved;
     Msx_wire.Workspace_precondition_failed, Client.Workspace_changed];
  List.iter (fun code ->
    let result = Client.fetch (Client.create ()) ~host:"localhost" ~port:8935 ~headers:[]
      ~request:(fun ~body:_ -> Ok (409, Msx_wire.encode ~code "not a start refusal")) in
    failure result)
    [Msx_wire.Worker_unavailable; Msx_wire.Outcome_unknown]

(* A 503 is two different answers. [worker_unavailable] ran nothing, so the
   next poll asks again and the retained pixels stay; [outcome_unknown] may have
   run, so the poll stops until the operator observes. A 503 with neither code
   proves nothing, and stops the poll too. *)
let test_unavailable_worker_keeps_polling () =
  let cache = Client.create () and tag = revision 'a' in
  let initial = fetch cache (fun ~body:_ -> Ok (frame 1 (inline tag "rgb"))) |> require |> loaded in
  let calls = ref 0 in
  let reply = Client.fetch cache ~host:"localhost" ~port:8935 ~headers:(auth "a") ~request:(fun ~body:_ ->
    incr calls;
    Ok (503, Msx_wire.encode ~code:Msx_wire.Worker_unavailable "No attached shared Add-on provides masc_msx_step")) in
  check bool "the answer names the missing worker" true
    (reply = Ok (Client.Worker_unavailable (Some "No attached shared Add-on provides masc_msx_step")));
  check int "an unavailable worker is not retried inside the call" 1 !calls;
  check bool "the poll keeps advancing" true (Client.policy_after_tick reply = Client.Advancing);
  let resumed = fetch cache (fun ~body ->
    check bool "the retained pixel basis survives the unavailable worker" true
      (known body = `Assoc (reference tag));
    Ok (frame 2 (retained tag))) |> require |> loaded in
  check bool "retained pixels are reused after the worker returns" true (resumed.msx_rgb == initial.msx_rgb)

let test_lost_tick_answer_stops_polling () =
  let stops label answer =
    let reply = Client.fetch (Client.create ()) ~host:"localhost" ~port:8935 ~headers:[]
      ~request:(fun ~body:_ -> Ok answer) in
    failure reply;
    check bool (label ^ " leaves the outcome unknown") true
      (Client.policy_after_tick reply = Client.Outcome_unknown) in
  stops "outcome_unknown" (503, Msx_wire.encode ~code:Msx_wire.Outcome_unknown "reply lost");
  stops "a 503 with no code" (503, `Assoc ["ok", `Bool false; "message", `String "gateway"]);
  stops "a 503 that is not JSON refusal" (503, `String "upstream");
  stops "a 503 carrying an activity code" (503, Msx_wire.encode ~code:Msx_wire.Activity_disabled "off")

let test_workspace_refusal_is_unstarted_and_cannot_rearm () =
  let cache = Client.create () in
  let tag = revision 'a' in
  ignore (fetch cache (fun ~body:_ -> Ok (frame 1 (inline tag "rgb"))) |> require);
  let calls = ref 0 in
  let result = Client.fetch cache ~host:"localhost" ~port:8935 ~headers:(auth "a")
    ~request:(fun ~body:_ -> incr calls; Ok (409, `Assoc
      ["ok", `Bool false; "code", `String "workspace_precondition_failed";
       "message", `String "workspace precondition failed"])) in
  check bool "workspace refusal precedes execution" true (result = Ok (Client.Not_started Workspace_changed));
  check int "workspace refusal cannot retry POST" 1 !calls;
  let policy = Client.policy_after_tick result in
  check bool "new workspace activity cannot authorize captured workspace" true
    (Client.policy_after_activity policy (Ok Client.Enabled) = policy);
  ignore (fetch cache (fun ~body ->
    check bool "known refusal retains original pixel evidence" true (known body = `Assoc (reference tag));
    Ok (frame 2 (retained tag))) |> require)

let test_malformed_activity_is_not_permission () =
  List.iter (fun json -> check bool "invalid observation refused" true (Result.is_error (Client.decode_activity json)))
    [`Assoc []; `Assoc ["schema",`String "masc.msx-activity/v1"];
     `Assoc ["schema",`String "masc.msx-activity/v1";"activity",`Bool true];
     `Assoc ["schema",`String "masc.msx-activity/v1";"activity",`String "enabled"];
     `Assoc ["schema",`String "masc.msx-activity/v1";"activity",`String "on";"activity",`String "off"]];
  List.iter (fun (status,json) ->
    let result = Client.fetch (Client.create ()) ~host:"localhost" ~port:8935 ~headers:[] ~request:(fun ~body:_ -> Ok (status,json)) in
    failure result;
    check bool "unrecognized refusal remains uncertain" true (Client.policy_after_tick result=Client.Outcome_unknown))
    [200,`Assoc ["ok",`Bool false;"code",`String "activity_disabled"];
     409,`Assoc ["ok",`Bool false;"code",`String "other"];
     409,`Assoc ["ok",`Bool true;"code",`String "activity_disabled"];
     409,`Assoc ["ok",`Bool false;"message",`String "machines.msx is off"]]

(* A refused answer reaches the screen as the sentence for its code, never as
   the JSON. Each code the server can send reads to a sentence, and the codes
   read differently from one another: the terminal branches on the code. *)
let test_refusal_body_reads_as_a_sentence () =
  let body code message = Yojson.Safe.to_string (Msx_wire.encode ?code message) in
  let sentence code message =
    match Client.refusal_sentence (body code message) with
    | Some sentence -> sentence
    | None -> fail "a refusal body gave no sentence" in
  let said = "the server's own words" in
  let with_message = List.map (fun code -> sentence (Some code) said) Msx_wire.all_of_code in
  List.iter (fun sentence ->
    check bool "the server's words are kept" true
      (let n = String.length said and m = String.length sentence in
       let rec go i = i + n <= m && (String.sub sentence i n = said || go (i + 1)) in
       go 0);
    check bool "it is not the JSON" false (String.contains sentence '{'))
    with_message;
  check int "each code reads differently" (List.length Msx_wire.all_of_code)
    (List.length (List.sort_uniq String.compare with_message));
  List.iter (fun code ->
    match Client.refusal_sentence (body (Some code) "") with
    | Some _ -> ()
    | None -> fail "a coded refusal with an empty message gave no sentence")
    Msx_wire.all_of_code;
  check (option string) "a plain message without a code is the message" (Some said)
    (Client.refusal_sentence (body None said));
  List.iter (fun raw ->
    check (option string) ("not an MSX refusal: " ^ raw) None (Client.refusal_sentence raw))
    [ "not json"; "[]"; {|{"error":"words"}|}; {|{"ok":true,"message":"fine"}|};
      {|{"ok":false,"code":"nope","message":"m"}|}; {|{"ok":false}|} ]

(* The notice a tick left because no worker answered is retired by the next
   advance, and only that notice. *)
let test_worker_down_notice_is_retired_by_identity () =
  let down = Some (Client.worker_unavailable_notice (Some "no worker")) in
  check (option string) "still the notice on screen: retired" None
    (Client.notice_after_advance ~notice:down ~worker_down_notice:down);
  let replaced = Some "Checkpoint refused: slot is full" in
  check (option string) "replaced by another notice: kept" replaced
    (Client.notice_after_advance ~notice:replaced ~worker_down_notice:down);
  let same_words = Some (String.concat "" [ Option.get down ]) in
  check bool "same words written elsewhere are a different notice" true
    (Client.notice_after_advance ~notice:same_words ~worker_down_notice:down == same_words);
  check (option string) "no worker-down notice outstanding: nothing retired" replaced
    (Client.notice_after_advance ~notice:replaced ~worker_down_notice:None);
  check (option string) "no notice at all stays none" None
    (Client.notice_after_advance ~notice:None ~worker_down_notice:None)

let () =
  run "retained MSX tick"
    ["response protocol",
      [test_case "a refusal is read by code, not by field set" `Quick test_refusal_body_is_not_matched_by_field_set;
       test_case "an unavailable worker keeps the poll advancing" `Quick test_unavailable_worker_keeps_polling;
       test_case "a lost tick answer stops the poll" `Quick test_lost_tick_answer_stops_polling;
       test_case "workspace refusal never executes or rearms from activity" `Quick test_workspace_refusal_is_unstarted_and_cannot_rearm;
       test_case "typed activity refusal preserves pixels and resumes only from observation" `Quick test_activity_refusal_and_recovery;
       test_case "malformed activity cannot authorize execution" `Quick test_malformed_activity_is_not_permission;
       test_case "a refusal body reads as a sentence by its code" `Quick test_refusal_body_reads_as_a_sentence;
       test_case "the worker-down notice is retired by identity" `Quick test_worker_down_notice_is_retired_by_identity;
       test_case "fresh metadata with retained and replaced pixels" `Quick test_retained_metadata;
       test_case "malformed or failed responses never retry or resurrect" `Quick test_rejected_responses;
       test_case "server and credential scope" `Quick test_scope;
       test_case "late responses cannot republish old pixels" `Quick test_late_response]]
