module Live = Masc.Artifact_draft_live
module Draft = Masc.Artifact_draft
let target = { Draft.artifact_id = "artifact-0123456789abcdef0123456789abcdef"; generation = "019f0000-0000-7000-8000-000000000000" }
let json session = match Live.observe session with Some (frame, _) -> frame | None -> Alcotest.fail "session absent"
let field name json = Yojson.Safe.Util.member name json
let peers session = field "peers" (json session) |> Yojson.Safe.Util.to_list
let with_session ?(base_path="/test") ?(actor="human") f =
  let session = Live.join ~source:Live.Dashboard_connection ~base_path ~actor ~target in Fun.protect ~finally:(fun () -> Live.leave session) (fun () -> f session)
let tests = [
  "connection lifecycle wakes observers and removes position", `Quick, (fun () -> with_session (fun first ->
    let _, pulse = Option.get (Live.observe first) in
    let second = Live.join ~source:Live.Dashboard_connection ~base_path:"/test" ~actor:"keeper" ~target in
    Alcotest.(check bool) "join wakes prior observer" true (Eio.Promise.is_resolved pulse);
    Alcotest.(check int) "two peers" 2 (List.length (peers first));
    Live.leave second;
    Alcotest.(check int) "closed peer removed" 1 (List.length (peers first));
    Alcotest.(check bool) "closed session cannot advertise" true (Result.is_error (Live.position second None));
    Alcotest.(check bool) "closed session absent" true (Live.observe second = None)));
  "workspace actor and generation isolation", `Quick, (fun () -> with_session (fun first ->
    with_session ~base_path:"/other" (fun other ->
      Alcotest.(check int) "other workspace isolated" 1 (List.length (peers other));
      List.iter (fun (base_path, actor, target) ->
        Alcotest.(check bool) "session cannot be borrowed" true (Result.is_error (Live.find ~base_path ~actor ~target ~session_id:(Live.id first))))
        ["/other", "human", target; "/test", "spoof", target; "/test", "human", { target with generation = "019f0000-0000-7000-8000-000000000001" }])));
  "durable sequence wins over old reads and never implies presence", `Quick, (fun () -> with_session (fun session ->
    let make sequence actor = match Draft.create ~target ~base_revision:1 ~base_sha256:(String.make 64 'a') ~state:"AAA=" ~actor ~at:"2026-10-25T13:00:00Z" with
      | Error message -> Alcotest.fail message
      | Ok draft ->
        let rec next draft remaining = if remaining = 0 then draft else
          match Draft.advance draft ~state:"AAA=" ~actor ~at:"2026-10-25T13:00:00Z" with
          | Error message -> Alcotest.fail message | Ok draft -> next draft (remaining - 1) in
        next draft sequence in
    Live.publish ~base_path:"/test" ~draft:(make 2 "keeper-writer") ~content:"new";
    Live.publish ~base_path:"/test" ~draft:(make 1 "old-writer") ~content:"old";
    Alcotest.(check string) "new snapshot retained" "new" (field "content" (field "document" (json session)) |> Yojson.Safe.Util.to_string);
    Alcotest.(check int) "author is not a live peer" 1 (List.length (peers session))));
  "each observer receives documents once independently of presence", `Quick, (fun () -> with_session (fun first ->
    Alcotest.(check bool) "no snapshot yet" true (field "document" (json first) = `Null);
    let draft = match Draft.create ~target ~base_revision:1 ~base_sha256:(String.make 64 'a') ~state:"AAA=" ~actor:"writer" ~at:"2026-10-25T13:00:00Z" with
      | Ok draft -> draft | Error message -> Alcotest.fail message in
    let _, before_publish = Option.get (Live.observe first) in
    Live.publish ~base_path:"/test" ~draft ~content:"initial";
    Alcotest.(check bool) "captured pulse wakes" true (Eio.Promise.is_resolved before_publish);
    let document session = field "document" (json session) in
    Alcotest.(check string) "first available snapshot" "initial" (field "content" (document first) |> Yojson.Safe.Util.to_string);
    let second = Live.join ~base_path:"/test" ~actor:"other" ~source:Live.Dashboard_connection ~target in
    Fun.protect ~finally:(fun () -> Live.leave second) (fun () ->
      Alcotest.(check bool) "join is presence only for existing observer" true (document first = `Null);
      Alcotest.(check string) "new observer has its own snapshot" "initial" (field "content" (document second) |> Yojson.Safe.Util.to_string);
      let _, before_position = Option.get (Live.observe first) in
      let position = Some { Artifact_document_engine.anchor = [1]; head = [2] } in
      ignore (Live.position second position);
      Alcotest.(check bool) "cursor wakes stream" true (Eio.Promise.is_resolved before_position);
      Alcotest.(check bool) "cursor does not resend state" true (document first = `Null && document second = `Null);
      let _, unchanged = Option.get (Live.observe first) in
      ignore (Live.position second position);
      Alcotest.(check bool) "identical cursor does not wake" false (Eio.Promise.is_resolved unchanged);
      let newer = match Draft.advance draft ~state:"AAA=" ~actor:"writer" ~at:"2026-10-25T13:00:01Z" with
        | Ok draft -> draft | Error message -> Alcotest.fail message in
      Live.publish ~base_path:"/test" ~draft:newer ~content:"newer";
      List.iter (fun session ->
        Alcotest.(check string) "each peer receives newer sequence" "newer" (field "content" (document session) |> Yojson.Safe.Util.to_string);
        Alcotest.(check bool) "same sequence suppressed" true (document session = `Null)) [first; second];
      Live.publish ~base_path:"/test" ~draft ~content:"stale";
      Alcotest.(check bool) "stale read cannot reannounce" true (document first = `Null);
      Live.leave second;
      with_session ~actor:"other" (fun reconnected ->
        Alcotest.(check string) "fresh session receives current snapshot" "newer" (field "content" (document reconnected) |> Yojson.Safe.Util.to_string)))));
  "last connection destroys ephemeral room", `Quick, (fun () ->
    let session = Live.join ~source:Live.Dashboard_connection ~base_path:"/test" ~actor:"human" ~target in
    ignore (Live.position session (Some { Artifact_document_engine.anchor = [1]; head = [2] }));
    Live.leave session;
    with_session (fun fresh ->
      Alcotest.(check bool) "no prior document retained" true (field "document" (json fresh) = `Null);
      Alcotest.(check bool) "no prior cursor retained" true (field "position" (List.hd (peers fresh)) = `Null)));
]
let () = Eio_main.run (fun _ -> Alcotest.run "Artifact draft live rooms" ["lifecycle", tests])
