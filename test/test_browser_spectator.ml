open Alcotest

module Dataset = Masc.Workspace_dataset_event
module Spectator = Server_browser_spectator

let client_a = "01a16363-ef67-7000-ad62-05bcd0320d99"
let client_b = "01a16363-ef68-7000-aee1-37e1be230202"
let revision_a = String.make 64 'a'
let revision_b = String.make 64 'b'

let viewport client_id : Dataset.browser_scope =
  { source = Browser_lane.Lane_name.Live; client_id = Some client_id; tab_id = 2
  ; view = Dataset.Viewport }

let region : Dataset.browser_scope =
  { source = Browser_lane.Lane_name.Live; client_id = Some client_a; tab_id = 7
  ; view = Dataset.Scene
      { scene_view = Browser_lane.Regions
      ; scope = Some { Browser_lane.document_id = "document-a"; node_id = "region-4" } } }

let browser_event (scope : Dataset.browser_scope) revision =
  ("dataset", `String "browser_observation")
  :: Dataset.browser_scope_fields scope @ [ "revision", `String revision ]

let test_scope_round_trip_and_strict_identity () =
  List.iter
    (fun (scope : Dataset.browser_scope) ->
      let fields = browser_event scope revision_a in
      (match Dataset.of_fields fields with
       | Ok (Dataset.Browser_observation observed) ->
           check bool "the exact source/client/tab/view scope survives" true
             (observed.scope = scope);
           check string "the revision remains a freshness hint" revision_a observed.revision
       | Ok _ | Error _ -> fail "a browser observation was not decoded");
      match Spectator.scope_of_request_target
              ("/mcp?sse_kind=observer&" ^ Dataset.browser_scope_query scope) with
      | Ok (Some actual) -> check bool "the observer query preserves the same scope" true (actual = scope)
      | Ok None | Error _ -> fail "a browser observer lost its scope")
    [ viewport client_a; viewport client_b; region
    ; { (viewport client_a) with
        view = Dataset.Scene { scene_view = Browser_lane.Content; scope = None } }
    ; { (viewport client_b) with view = Dataset.Read } ];
  (match Spectator.scope_of_request_target "/mcp?sse_kind=observer" with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "an ordinary observer acquired a browser watcher");
  let invalid =
    [ List.remove_assoc "tabId" (browser_event (viewport client_a) revision_a)
    ; List.remove_assoc "clientId" (browser_event (viewport client_a) revision_a)
    ; List.remove_assoc "revision" (browser_event (viewport client_a) revision_a)
    ; List.remove_assoc "sceneView" (browser_event region revision_a)
    ; ("tabId", `String "2")
      :: List.remove_assoc "tabId" (browser_event (viewport client_a) revision_a)
    ; ("clientId", `String client_a)
      :: browser_event (viewport client_b) revision_a
    ; ("revision", `String "short")
      :: List.remove_assoc "revision" (browser_event (viewport client_a) revision_a) ]
  in
  List.iter
    (fun fields ->
      match Dataset.of_fields fields with
      | Error _ -> ()
      | Ok _ -> fail "an invalid Browser scope or revision was admitted")
    invalid

let test_requests_keep_the_original_browser_target () =
  match Spectator.request_json region with
  | `Assoc fields ->
      check string "the original client is pinned" client_a
        (Yojson.Safe.Util.member "clientId" (`Assoc fields) |> Yojson.Safe.Util.to_string);
      check int "the original tab is pinned" 7
        (Yojson.Safe.Util.member "tabId" (`Assoc fields) |> Yojson.Safe.Util.to_int);
      check string "the scene mode is preserved" "regions"
        (Yojson.Safe.Util.member "view" (`Assoc fields) |> Yojson.Safe.Util.to_string);
      check string "the focused region is preserved" "region-4"
        (Yojson.Safe.Util.member "scope" (`Assoc fields)
         |> Yojson.Safe.Util.member "nodeId" |> Yojson.Safe.Util.to_string)
  | _ -> fail "a browser read request is not an object"

let screenshot ?(elapsed_ms = 1.) ?(bytes = "UE5H") () =
  `Assoc
    [ "source", `String "live"; "clientId", `String client_a; "tabId", `Int 2
    ; "data", `String bytes; "elapsed_ms", `Float elapsed_ms ]

let text ?(elapsed_ms = 1.) ?(body = "first") () =
  `Assoc
    [ "source", `String "live"; "clientId", `String client_a
    ; "page", `Assoc [ "tabId", `Int 2; "text", `String body ]
    ; "elapsed_ms", `Float elapsed_ms ]

let test_changed_observations_only_and_no_image_bytes () =
  let watcher = Spectator.watch (viewport client_a) in
  let first =
    match Spectator.observe watcher (screenshot ~elapsed_ms:17. ()) with
    | Ok (Some observation) -> observation
    | Ok None | Error _ -> fail "the first complete browser observation was not announced"
  in
  check int "only a bounded revision is retained" 64 (String.length first.revision);
  check bool "image bytes are not the event" false
    (String.equal first.revision "UE5H");
  (match Spectator.observe watcher (screenshot ~elapsed_ms:999. ()) with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "elapsed capture time caused a redundant read");
  (match Spectator.observe watcher (screenshot ~elapsed_ms:1000. ~bytes:"QUJD" ()) with
   | Ok (Some changed) -> check bool "new pixels have a new revision" false
       (String.equal changed.revision first.revision)
   | Ok None | Error _ -> fail "changed pixels did not produce a notification");
  let reader = Spectator.watch { (viewport client_a) with view = Dataset.Read } in
  (match Spectator.observe reader (text ~elapsed_ms:4. ()) with
   | Ok (Some _) -> ()
   | Ok None | Error _ -> fail "the first text observation was not announced");
  (match Spectator.observe reader (text ~elapsed_ms:40. ()) with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "elapsed text-read time caused a redundant read");
  match Spectator.observe reader (text ~body:"second" ()) with
  | Ok (Some _) -> ()
  | Ok None | Error _ -> fail "changed visible text did not produce a notification"

let test_revision_rejects_another_target_or_scene () =
  let watcher = Spectator.watch (viewport client_a) in
  (match Spectator.observe watcher (screenshot ~bytes:"" ()) with
   | Ok (Some _) -> ()
   | Ok None | Error _ -> fail "test setup could not establish the initial revision");
  List.iter
    (fun payload ->
      match Spectator.observe watcher payload with
      | Error _ -> ()
      | Ok _ -> fail "an observation for another Browser target was admitted")
    [ `Assoc (List.map (fun (key, value) ->
          key, if String.equal key "clientId" then `String client_b else value)
        (match screenshot () with `Assoc fields -> fields | _ -> assert false))
    ; `Assoc (List.map (fun (key, value) ->
          key, if String.equal key "tabId" then `Int 9 else value)
        (match screenshot () with `Assoc fields -> fields | _ -> assert false)) ];
  let scene_watcher = Spectator.watch region in
  match Spectator.observe scene_watcher
          (`Assoc
            [ "source", `String "live"; "clientId", `String client_a; "tabId", `Int 7
            ; "view", `String "content"; "scope", `Null; "elapsed_ms", `Float 1. ]) with
  | Error _ -> ()
  | Ok _ -> fail "a scene acknowledgement for another view or scope was admitted"

let test_sampling_stops_with_the_observer () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let calls = ref 0 in
      Spectator.For_testing.with_reader
        (fun ~config:_ scope ->
          incr calls;
          match scope.Dataset.view with
          | Dataset.Viewport -> Ok (screenshot ())
          | Dataset.Read | Dataset.Scene _ -> Error "unexpected Browser read")
        (fun () ->
          let stop_promise, stop = Eio.Promise.create () in
          Spectator.start ~sw ~clock:(Eio.Stdenv.clock env) ~stop_promise
            ~scope:(viewport client_a) ~config:(Masc.Workspace.default_config "/fixture");
          Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
          check bool "the visible Browser was sampled" true (!calls > 0);
          Eio.Promise.resolve stop ();
          let stopped = !calls in
          Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
          check int "closing the observer stops Browser sampling" stopped !calls)))

let () =
  run "browser spectator"
    [ "scope",
      [ test_case "round trip and strict identity" `Quick test_scope_round_trip_and_strict_identity
      ; test_case "requests preserve the target" `Quick test_requests_keep_the_original_browser_target ]
    ; "change detection",
      [ test_case "changed observations only, without image bytes" `Quick
          test_changed_observations_only_and_no_image_bytes
      ; test_case "revision rejects another target or scene" `Quick
          test_revision_rejects_another_target_or_scene ]
    ; "lifecycle", [ test_case "observer closure stops sampling" `Quick test_sampling_stops_with_the_observer ] ]
