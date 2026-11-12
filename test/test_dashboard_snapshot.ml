(** Immutable component publication and workspace/epoch ownership. *)

open Masc

let config = Workspace.default_config "/tmp/dashboard-snapshot-test"

let test_current_starts_empty () =
  Dashboard_snapshot.reset_for_test ();
  Alcotest.(check bool) "no live snapshot before publish"
    true (Option.is_none (Dashboard_snapshot.current ()))
;;

let test_publish_then_current () =
  Dashboard_snapshot.reset_for_test ();
  let snap =
    Dashboard_snapshot.make_for_test ~config
      ~shell:(`String "shell-value")
      ~tools:(`String "tools-value")
      ~telemetry_summary:(`String "ts-value")
      ()
  in
  Dashboard_snapshot.publish_for_test snap;
  match Dashboard_snapshot.current () with
  | None -> Alcotest.fail "expected Some after publish"
  | Some t ->
    Alcotest.(check string) "shell roundtrip"
      "shell-value" (Yojson.Safe.Util.to_string t.shell);
    Alcotest.(check string) "tools roundtrip"
      "tools-value" (Yojson.Safe.Util.to_string t.tools.json);
    Alcotest.(check string) "telemetry_summary roundtrip"
      "ts-value" (Yojson.Safe.Util.to_string t.telemetry_summary)
;;

let test_reset_clears_slot () =
  let snap =
    Dashboard_snapshot.make_for_test ~config
      ~shell:`Null ~tools:`Null
      ~telemetry_summary:`Null ()
  in
  Dashboard_snapshot.publish_for_test snap;
  Alcotest.(check bool) "populated before reset"
    true (Option.is_some (Dashboard_snapshot.current ()));
  Dashboard_snapshot.reset_for_test ();
  Alcotest.(check bool) "empty after reset"
    true (Option.is_none (Dashboard_snapshot.current ()))
;;

let test_generated_at_recent () =
  let before = Unix.gettimeofday () in
  let s =
    Dashboard_snapshot.make_for_test ~config ~shell:`Null ~tools:`Null
      ~telemetry_summary:`Null ()
  in
  let after = Unix.gettimeofday () in
  Alcotest.(check bool) "generated_at >= before"
    true (s.generated_at >= before);
  Alcotest.(check bool) "generated_at <= after"
    true (s.generated_at <= after)
;;

let test_activity_events_cache_retains_last_good () =
  let now_value = ref 100.0 in
  let now () = !now_value in
  let calls = ref 0 in
  let cache = Dashboard_snapshot.For_testing.make_activity_cache () in
  let refresh compute =
    Dashboard_snapshot.For_testing.refresh_activity_events
      ~config ~now ~ttl:10.0 ~cache compute
  in
  let dummy1 = `String "e1" in
  let dummy2 = `String "e2" in
  let first = refresh (fun ~keep:_ -> incr calls; dummy1) in
  Alcotest.(check string) "first success" "e1"
    (Yojson.Safe.Util.to_string first);
  now_value := 105.0;
  let hit = refresh (fun ~keep:_ -> incr calls; dummy2) in
  Alcotest.(check string) "fresh hit" "e1"
    (Yojson.Safe.Util.to_string hit);
  Alcotest.(check int) "fresh hit skips callback" 1 !calls;
  now_value := 111.0;
  let fallback = refresh (fun ~keep:_ -> incr calls; failwith "refresh failed") in
  Alcotest.(check string) "failed refresh keeps last good" "e1"
    (Yojson.Safe.Util.to_string fallback);
  let cold_cache = Dashboard_snapshot.For_testing.make_activity_cache () in
  Alcotest.check_raises "cold failure aborts publish" (Failure "cold")
    (fun () ->
       ignore
         (Dashboard_snapshot.For_testing.refresh_activity_events
            ~config ~now ~ttl:10.0 ~cache:cold_cache
            (fun ~keep:_ -> failwith "cold")))
;;

let test_activity_events_revalidate_public_parents () =
  Masc_test_deps.ensure_rng_initialized ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "board-activity-access" "" in
  let config = Workspace.default_config base_path in
  let rec remove path =
    if Sys.is_directory path then (
      Sys.readdir path |> Array.iter (fun child -> remove (Filename.concat path child));
      Unix.rmdir path)
    else Sys.remove path
  in
  Fun.protect ~finally:(fun () ->
    Board_dispatch.reset_for_test ();
    Board.reset_global_for_test ();
    remove base_path) @@ fun () ->
  ignore (Workspace.init config ~agent_name:None : string);
  Board_dispatch.reset_for_test ();
  Board.reset_global_for_test ();
  let lookup = Recipient_lookup.make (fun candidate ->
    Ok (Result.to_option (Board.Agent_id.parse (Recipient_lookup.Candidate.to_string candidate)))) in
  Result.get_ok (Board_dispatch.init_jsonl ~base_path ~recipient_lookup:lookup ());
  let create visibility content =
    match Board_dispatch.create_post ~author:"writer" ~content ~visibility
      ~post_kind:Board.Human_post () with
    | Ok post -> post
    | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error)
  in
  let public = create Board.Public "public body" in
  let private_ = create Board.Direct "@reader private body" in
  let public_id = Board.Post_id.to_string public.id in
  let private_id = Board.Post_id.to_string private_.id in
  let emit post_id content = ignore (Activity_graph.emit config ~kind:"board.posted"
    ~subject:(Activity_graph.entity ~kind:"post" post_id)
    ~payload:(`Assoc [ "post_id", `String post_id; "content", `String content ]) ()) in
  emit public_id "public body";
  emit private_id "private body from old runtime";
  emit "p-deleted" "orphaned old body";
  let private_comment = Result.get_ok (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id:private_id
    ~author:"writer" ~content:"private comment" ()) in
  ignore (Activity_graph.emit config ~kind:"board.voted"
    ~subject:(Activity_graph.entity ~kind:"comment" (Board.Comment_id.to_string private_comment.id))
    ~payload:(`Assoc [ "target_kind", `String "comment"
      ; "target_id", `String (Board.Comment_id.to_string private_comment.id) ]) ());
  let board_tool = Tool_name.Board_name.to_string Tool_name.Board_name.Board_post in
  List.iter (fun fields ->
    ignore (Activity_graph.emit config ~kind:"tool.called"
      ~payload:(`Assoc (("tool_name", `String board_tool) :: fields)) ()))
    [ [ "tool_args_preview", `String "private body in old tool preview" ]
    ; [ "tool_io_redacted", `Bool true
      ; "content", `String "private body despite a forged redaction flag" ] ];
  ignore (Activity_graph.emit config ~kind:"tool.called"
    ~payload:(`Assoc [ "tool_name", `String board_tool
      ; "success", `Bool true; "tool_io_redacted", `Bool true ]) ());
  let cache = Dashboard_snapshot.For_testing.make_activity_cache () in
  let calls = ref 0 in
  let refresh compute = Dashboard_snapshot.For_testing.refresh_activity_events
    ~config ~now:(fun () -> 100.) ~ttl:10.0 ~cache compute in
  let compute ~keep = incr calls; Activity_graph.recent_json_response config ~raw_limit:1000 ~keep () in
  let first = refresh compute in
  let text = Yojson.Safe.to_string first in
  Alcotest.(check bool) "old private/orphan rows are filtered" false
    (String_util.contains_substring text "private body"
     || String_util.contains_substring text "orphaned old body");
  Alcotest.(check int) "public row and redacted tool metadata remain" 2
    Yojson.Safe.Util.(first |> member "count" |> to_int);
  let second = refresh compute in
  Alcotest.(check bool) "warm projection is reused" true (first == second);
  Alcotest.(check int) "warm request does not rescan Activity" 1 !calls;
  ignore (Result.get_ok (Board_dispatch.delete_post ~authorization:Board.Operator_deletion ~post_id:public_id));
  Alcotest.check_raises "deleted parent cannot authorize fallback" (Failure "refresh failed")
    (fun () -> ignore (refresh (fun ~keep:_ -> failwith "refresh failed")));
  let after = refresh compute in
  Alcotest.(check int) "deletion invalidates the still-warm projection" 2 !calls;
  Alcotest.(check int) "deleted parent is absent but tool metadata remains" 1
    Yojson.Safe.Util.(after |> member "count" |> to_int)
;;

let ready_publisher ?(is_current = fun () -> true) config tools =
  let publisher = Dashboard_snapshot.activate ~config ~is_current in
  Dashboard_snapshot.publish_shell publisher ~shell:(`String "full") ~shell_light:(`String "light");
  Dashboard_snapshot.publish_tools (Dashboard_snapshot.prepare_tools publisher tools);
  Dashboard_snapshot.publish_telemetry publisher (`String "telemetry");
  publisher
;;

let require_snapshot config = match Dashboard_snapshot.current_for_config config with
  | Some snapshot -> snapshot
  | None -> Alcotest.fail "successful components were not published"
;;

let test_tools_component_reuses_complete_representations () =
  Dashboard_snapshot.reset_for_test ();
  let json version = `Assoc ["version", `Int version;
    "tool_inventory", `List (List.init 200 (fun _ -> `String "tool-with-repeated-description"));
    "keeper_waiting_inventory", `Assoc ["waiting", `List [`String "keeper-a"]];
    "effective_keeper_surface", `Null] in
  let publisher = ready_publisher config (json 1) in
  let first = (require_snapshot config).tools in
  let raw = Yojson.Safe.to_string (json 1) in
  Alcotest.(check string) "final decorated AST and encoded identity agree" raw first.encoded.identity;
  Alcotest.(check string) "ETag describes final decorated bytes"
    (Http_server_eio.Response.weak_etag_value raw) first.etag;
  List.iter (fun (accept_encoding, encoding) ->
    let body, headers = Http_response_payload.select_prepared ~accept_encoding first.encoded in
    Alcotest.(check (option string)) "selected encoding" encoding (List.assoc_opt "content-encoding" headers);
    Alcotest.(check (option string)) "representations vary on encoding"
      (Some "Accept-Encoding") (List.assoc_opt "vary" headers);
    if encoding = Some "zstd" then (match Compression_codec.decompress ~orig_size:(String.length raw) body with
      | Ok decoded -> Alcotest.(check string) "compressed projection roundtrip" raw decoded
      | Error detail -> Alcotest.fail detail);
    let retained = (require_snapshot config).tools in
    let again, _ = Http_response_payload.select_prepared ~accept_encoding retained.encoded in
    Alcotest.(check bool) "idle reads retain the exact component" true (first == retained);
    Alcotest.(check bool) "idle reads retain prepared bytes" true (body == again))
    [None, None; Some "gzip", Some "gzip"; Some "zstd,gzip", Some "zstd";
     Some "gzip;q=0,zstd;q=0", None];
  Dashboard_snapshot.publish_tools (Dashboard_snapshot.prepare_tools publisher (json 2));
  let second = (require_snapshot config).tools in
  Alcotest.(check bool) "actual component publication replaces ETag" true (first.etag <> second.etag);
  Alcotest.(check string) "retained immutable snapshot remains readable" raw first.encoded.identity;
  Alcotest.(check string) "new encoded bytes match new AST" (Yojson.Safe.to_string (json 2)) second.encoded.identity;
  Dashboard_snapshot.retire publisher
;;

let test_workspace_epoch_retires_its_own_publisher () =
  Dashboard_snapshot.reset_for_test ();
  let old_current = ref true in
  let old = ready_publisher ~is_current:(fun () -> !old_current) config (`String "old") in
  let retained = require_snapshot config in
  let foreign = Workspace.default_config "/tmp/dashboard-snapshot-other" in
  Alcotest.(check bool) "foreign workspace cannot read the active components" true
    (Option.is_none (Dashboard_snapshot.current_for_config foreign));
  old_current := false;
  Alcotest.(check bool) "scope replacement withdraws Shell before a successor is activated" true
    (Option.is_none (Dashboard_snapshot.shell_for_config config));
  Alcotest.(check bool) "scope replacement withdraws Tools before a successor is activated" true
    (Option.is_none (Dashboard_snapshot.tools_for_config config));
  Alcotest.(check bool) "scope replacement withdraws telemetry before a successor is activated" true
    (Option.is_none (Dashboard_snapshot.telemetry_for_config config));
  let successor = Dashboard_snapshot.activate ~config ~is_current:(fun () -> true) in
  Dashboard_snapshot.publish_tools (Dashboard_snapshot.prepare_tools old (`String "late old answer"));
  Dashboard_snapshot.retire old;
  Alcotest.(check bool) "a same-path successor starts without the prior epoch's data" true
    (Option.is_none (Dashboard_snapshot.current ()));
  Dashboard_snapshot.publish_shell successor ~shell:(`String "new full") ~shell_light:(`String "new light");
  Dashboard_snapshot.publish_tools (Dashboard_snapshot.prepare_tools successor (`String "new tools"));
  Alcotest.(check bool) "Tools success is readable while telemetry is still pending" true
    (Option.is_some (Dashboard_snapshot.tools_for_config config));
  Alcotest.(check bool) "Shell success is readable while telemetry is still pending" true
    (Option.is_some (Dashboard_snapshot.shell_for_config config));
  Alcotest.(check bool) "partial initialization stays distinguishable from a complete observation" true
    (Option.is_none (Dashboard_snapshot.current ()));
  Dashboard_snapshot.publish_telemetry successor (`String "new telemetry");
  Dashboard_snapshot.publish_shell old ~shell:(`String "late full") ~shell_light:(`String "late light");
  Dashboard_snapshot.retire old;
  let current = require_snapshot config in
  Alcotest.(check string) "retired work cannot replace successor shell" "new full"
    (Yojson.Safe.Util.to_string current.shell);
  Alcotest.(check string) "retired work cannot replace successor tools" "new tools"
    (Yojson.Safe.Util.to_string current.tools.json);
  Alcotest.(check string) "previous retained observation is immutable" "old"
    (Yojson.Safe.Util.to_string retained.tools.json);
  Dashboard_snapshot.retire successor;
  Alcotest.(check bool) "the active owner releases its own snapshot" true
    (Option.is_none (Dashboard_snapshot.current ()))
;;

let () = Alcotest.run "Dashboard_snapshot" [
  "storage", [
    Alcotest.test_case "empty before publish" `Quick test_current_starts_empty;
    Alcotest.test_case "publish and retain values" `Quick test_publish_then_current;
    Alcotest.test_case "reset owned slot" `Quick test_reset_clears_slot;
    Alcotest.test_case "same-path epoch replacement and foreign workspace" `Quick test_workspace_epoch_retires_its_own_publisher];
  "representations", [
    Alcotest.test_case "captured publication time" `Quick test_generated_at_recent;
    Alcotest.test_case "prepared Tools representations" `Quick test_tools_component_reuses_complete_representations];
  "public activity", [
    Alcotest.test_case "last-good requires valid authority" `Quick test_activity_events_cache_retains_last_good;
    Alcotest.test_case "Public parents are revalidated" `Quick test_activity_events_revalidate_public_parents]]
;;
