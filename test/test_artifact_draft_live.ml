module Live = Masc.Artifact_draft_live
module Draft = Masc.Artifact_draft
let target = { Draft.artifact_id = "artifact-0123456789abcdef0123456789abcdef"; generation = "019f0000-0000-7000-8000-000000000000" }
let json session = match Live.observe session with Some (frame, _) -> frame | None -> Alcotest.fail "session absent"
let field name json = Yojson.Safe.Util.member name json
let peers session = field "peers" (json session) |> Yojson.Safe.Util.to_list
let with_session ?(base_path="/test") ?(actor="human") f =
  let session = Live.join ~base_path ~actor ~target in Fun.protect ~finally:(fun () -> Live.leave session) (fun () -> f session)
let tests = [
  "connection lifecycle wakes observers and removes position", `Quick, (fun () -> with_session (fun first ->
    let _, pulse = Option.get (Live.observe first) in
    let second = Live.join ~base_path:"/test" ~actor:"keeper" ~target in
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
  "last connection destroys ephemeral room", `Quick, (fun () ->
    let session = Live.join ~base_path:"/test" ~actor:"human" ~target in
    ignore (Live.position session (Some { Artifact_document_engine.anchor = [1]; head = [2] }));
    Live.leave session;
    with_session (fun fresh ->
      Alcotest.(check bool) "no prior document retained" true (field "document" (json fresh) = `Null);
      Alcotest.(check bool) "no prior cursor retained" true (field "position" (List.hd (peers fresh)) = `Null)));
]
let () = Eio_main.run (fun _ -> Alcotest.run "Artifact draft live rooms" ["lifecycle", tests])
