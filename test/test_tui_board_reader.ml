module R = Masc_tui_board_reader
let original="# 밤섬\r\n\r\n| Bass VI | C → C♯ → D |\r\n끝 Ω\r\n"
let key : R.key={post_id="original-post";sha256=Digestif.SHA256.(digest_string original |> to_hex);
  bytes=String.length original;name=Some "밤섬.md"}
let require=function Ok value -> value | Error error -> Alcotest.fail error
let request=function Some request -> request | None -> Alcotest.fail "original request not started"
let test_original_and_owners () =
  let first,old=R.open_read ~key R.initial in
  let reopened,current=R.open_read ~key (R.close first) in
  let content=R.validate key original |> require in
  let other,other_request=R.open_read ~key R.initial in
  let refused=R.complete other (request old) (Error "foreign read failure") in
  Alcotest.(check bool) "same-key generation cannot borrow another physical read owner" true
    (R.request_job (request (R.pending refused))==R.request_job (request other_request));
  let first=R.complete first (request old) (Ok content) in
  let other=R.complete other (request other_request) (Ok content) in
  let _,first_preparation=R.start_preparation ~width:40 first in
  let other,other_preparation=R.start_preparation ~width:40 other in
  let refused=R.complete_preparation other (request first_preparation) (Error "foreign preparation failure") in
  Alcotest.(check bool) "same source facts cannot borrow another preparation owner" true
    (R.preparation_job (request (R.pending_preparation refused))==R.preparation_job (request other_preparation));
  let stale=R.complete reopened (request old) (Ok content) in
  Alcotest.(check bool) "closed request cannot settle a same-key reopen" true
    (Result.is_error (R.source stale));
  let ready=R.complete stale (request current) (Ok content) in
  let foreign_key={key with post_id="another-post"} in
  let foreign_content=R.validate foreign_key original |> require in
  let foreign,foreign_request=R.open_read ~key ready in
  let foreign=R.complete foreign (request foreign_request) (Ok foreign_content) in
  Alcotest.(check bool) "another valid source cannot settle this reference" true
    (Result.is_error (R.source foreign));
  let prepared,old_preparation=R.start_preparation ~width:40 ready in
  let switched=R.select R.Markdown prepared in
  let switched,new_preparation=R.start_preparation ~width:20 switched in
  let late=R.complete_preparation switched (request old_preparation) (Ok []) in
  Alcotest.(check bool) "late preparation cannot retire its replacement" true
    (match R.pending_preparation late with Some pending -> pending==request new_preparation | None -> false);
  let ready=R.complete_preparation late (request new_preparation)
    (Ok (R.prepare (request new_preparation))) in
  let searched=match R.search_key ~width:20 ~height:5 ~key:"/" ready with
    | Some reader -> R.search_insert ~width:20 ~height:5 ~text:"밤섬" reader
    | None -> Alcotest.fail "captured attachment did not own search" in
  Alcotest.(check bool) "search stays with the original reference" true
    (Option.equal R.equal_key (R.key ready) (R.key searched));
  Alcotest.(check string) "search cannot rewrite copy authority" original (R.source searched |> require);
  Alcotest.(check bool) "closing discards attachment query" true
    (Option.is_none (Masc_tui_detail_reading.search_query (R.document (R.close searched))));
  Alcotest.(check string) "copy remains exact original CRLF bytes" original (R.source ready |> require);
  Alcotest.(check bool) "close withdraws copy and save authority" true
    (Result.is_error (R.source (R.close ready)) && Option.is_none (R.saved_source (R.close ready)))
let test_integrity_and_binary () =
  Alcotest.(check bool) "wrong digest refuses observed bytes" true
    (Result.is_error (R.validate key (String.make key.bytes 'x')));
  Alcotest.(check bool) "wrong byte length refuses observed bytes" true
    (Result.is_error (R.validate key (original ^ "x")));
  let bytes="\255\000\128" in
  let key={key with sha256=Digestif.SHA256.(digest_string bytes |> to_hex);bytes=String.length bytes} in
  let reader,read=R.open_read ~key R.initial in
  let reader=R.complete reader (request read) (R.validate key bytes) in
  Alcotest.(check bool) "binary cannot become terminal text" true (Result.is_error (R.source reader));
  match R.saved_source reader with
  | Some (_,_,saved) -> Alcotest.(check string) "binary original retained for explicit save" bytes saved
  | None -> Alcotest.fail "verified binary cannot be saved"
let test_binary_workspace_admission () = Eio_main.run (fun _ ->
  let module Decode=Masc.Tui_decode in
  let expected : Decode.server_identity={sid_version="test";sid_binary_commit="test";
    sid_binary_commit_age_s=None;sid_base_path=Decode.Canonical_path.of_path "/owned-workspace";
    sid_masc_root=Decode.Canonical_path.of_path "/owned-workspace/.masc";
    sid_executable_in_worktree=None;sid_state_ready=Some true;sid_uptime=None;
    sid_sse_clients=None;sid_gc=None;sid_scheduler=None} in
  let bound f=Masc_tui_workspace_read.with_binding ~host:"localhost" ~port:8935
    ~expected ~proof:Request_precondition f in
  let receipt=Masc.Workspace.read_precondition_admission_header in
  let seen=ref None in
  let send headers ~path=seen:=Some path;Ok Masc_http_client.{status=200;headers;body=original} in
  let read send=Masc_tui_workspace_read.read_bytes ~send ~host:"localhost" ~port:8935 ~path:"/api/v1/artifact-bytes/digest" in
  Alcotest.(check bool) "unbound binary content is not admitted" true
    (Result.is_error (read (send [receipt])));
  Alcotest.(check bool) "health-only proof cannot authorize binary content" true
    (Masc_tui_workspace_read.with_binding ~host:"localhost" ~port:8935 ~expected
      ~proof:Health_identity (fun () -> Result.is_error (read (send [receipt]))));
  Alcotest.(check bool) "missing binary receipt refuses content" true
    (bound (fun () -> Result.is_error (read (send []))));
  Alcotest.(check bool) "duplicate receipt refuses content" true
    (bound (fun () -> Result.is_error (read (send [receipt;receipt]))));
  Alcotest.(check string) "admitted bytes remain original" original
    (bound (fun () -> read (send [receipt])) |> require);
  let query=Uri.query (Uri.of_string (Option.get !seen)) in
  Alcotest.(check bool) "actual binary GET carries both original roots" true
    (List.assoc_opt "expected_base_path" query=Some ["/owned-workspace"]
     && List.assoc_opt "expected_masc_root" query=Some ["/owned-workspace/.masc"]);
  let sent=ref false in
  let changed ()=Masc_tui_workspace_read.read_bytes
    ~send:(fun ~path:_ -> sent:=true;Ok Masc_http_client.{status=200;headers=[receipt];body=original})
    ~host:"another-server" ~port:8935 ~path:"/api/v1/artifact-bytes/digest" in
  Alcotest.(check bool) "endpoint mismatch never dispatches" true
    (bound (fun () -> Result.is_error (changed ())) && not !sent))
let test_original_job_cancellation () = Eio_main.run (fun _ ->
  Eio.Switch.run (fun sw ->
    let ui=Masc_tui_types.create_state ~workspace:"owned-board-reader"
      ~port:0 ~refresh_interval:0. () in
    let never,_=Eio.Promise.create () in
    let start job =
      let entered,enter=Eio.Promise.create () in
      let released,release=Eio.Promise.create () in
      let cancelled=ref false in
      Masc_tui_workspace_job.fork ~observation:true ~key:job
        ~observe:(function
          | Cancellation_requested -> cancelled:=true
          | Registration_released -> Eio.Promise.resolve release ()) ui ~sw
        (fun () -> Eio.Promise.resolve enter (); Eio.Promise.await never);
      Eio.Promise.await entered;
      cancelled,released in
    let first,old=R.open_read ~key R.initial in
    let old=request old in
    let old_key=R.request_job old in
    Alcotest.(check bool) "the pending request retains its registration key" true
      (old_key==R.request_job (request (R.pending first)));
    let old_cancelled,old_released=start old_key in
    let reopened,current=R.open_read ~key (R.close first) in
    let current=request current in
    let current_key=R.request_job current in
    Alcotest.(check bool) "same-reference reopen owns a different job" false
      (old_key==current_key);
    let current_cancelled,current_released=start current_key in
    Masc_tui_workspace_job.cancel_observation ui ~key:old_key;
    Eio.Promise.await old_released;
    Alcotest.(check bool) "old cancellation reached its original worker" true !old_cancelled;
    Alcotest.(check bool) "replacement worker is still registered" true
      (not !current_cancelled && List.exists (fun (key,_) -> key==current_key)
        ui.workspace_observation_cancellations);
    let ready=R.complete reopened current (R.validate key original) in
    let prepared,preparation=R.start_preparation ~width:40 ready in
    let preparation=request preparation in
    let preparation_key=R.preparation_job preparation in
    Alcotest.(check bool) "preparation retains its own separate job" true
      (preparation_key!=current_key && preparation_key==R.preparation_job
        (request (R.pending_preparation prepared)));
    let preparation_cancelled,preparation_released=start preparation_key in
    let resized,replacement=R.start_preparation ~width:20 prepared in
    let replacement=request replacement in
    Alcotest.(check bool) "resize allocates a new preparation job" false
      (preparation_key==R.preparation_job replacement);
    let late=R.complete_preparation resized preparation (Ok []) in
    Alcotest.(check bool) "late work cannot replace the resized pending job" true
      (R.preparation_job (request (R.pending_preparation late))==R.preparation_job replacement);
    Masc_tui_workspace_job.cancel_observation ui ~key:preparation_key;
    Eio.Promise.await preparation_released;
    Alcotest.(check bool) "preparation cancellation leaves source worker alone" true
      (!preparation_cancelled && not !current_cancelled);
    Masc_tui_workspace_job.cancel_observation ui ~key:current_key;
    Eio.Promise.await current_released;
    Alcotest.(check bool) "the original replacement worker was cancelled" true !current_cancelled;
    Alcotest.(check bool) "cleanup releases every owned registry entry" true
      (ui.workspace_observation_cancellations=[] && ui.workspace_cancellations=[])))
let ()=Alcotest.run "Board original attachment reader" ["authority",[
  Alcotest.test_case "original bytes and superseded physical owners" `Quick test_original_and_owners;
  Alcotest.test_case "integrity and binary save boundary" `Quick test_integrity_and_binary;
  Alcotest.test_case "binary GET workspace admission" `Quick test_binary_workspace_admission;
  Alcotest.test_case "original observation job cancellation" `Quick test_original_job_cancellation]]
