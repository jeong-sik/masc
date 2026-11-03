(** A change of the standing approval rules is announced as
    [approval_rules_changed], and the cached Gate snapshot is gone when the
    event is heard, so a reader that fetches the Gate on it computes the
    rules again. A rule write that leaves the rules as they were sends
    nothing. The snapshot is also gone when [approval:resolved] is heard: the
    resolution's audit row is written after the queue revision that keys the
    snapshot moved. *)

open Masc
module Rules = Keeper_approval_queue_rules

let temp_dir () =
  let dir = Filename.temp_file "gate-rules-announce-" ".dir" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  dir
;;

let event_type frame =
  match Sse.data_payload_of_frame frame with
  | Error Sse.Missing_data_payload -> None
  | Ok payload ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields ->
       (match List.assoc_opt "type" fields with
        | Some (`String name) -> Some name
        | Some _ | None -> None)
     | _ -> None
     | exception Yojson.Json_error _ -> None)
;;

let is_rules_changed frame =
  match Sse.data_payload_of_frame frame with
  | Error Sse.Missing_data_payload -> false
  | Ok payload ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields ->
       List.assoc_opt "type" fields
       = Some (`String Keeper_gate_broadcast.approval_rules_changed_event)
     | _ -> false
     | exception Yojson.Json_error _ -> false)
;;

let input = `Assoc [ "path", `String "/tmp/announced" ]

let upsert ~base_path ~approval_id ~resolution_sequence ~expires_at =
  Rules.upsert_rule ~base_path ~keeper_name:"keeper" ~tool_name:"external-effect" ~input
    ~source_approval_id:approval_id ~resolution_sequence ~expires_at ()
;;

let test_rule_writes_are_announced_after_the_gate_snapshot_is_dropped () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let gate_key = Printf.sprintf "gate:%s;20;60;0" base_path in
  let subscriber_id = Printf.sprintf "gate-rules-announce-%d" (Unix.getpid ()) in
  Fun.protect
    ~finally:(fun () ->
      Sse.unsubscribe_external subscriber_id;
      Dashboard_cache.invalidate gate_key;
      Fs_compat.remove_tree base_path)
    (fun () ->
       Keeper_gate_broadcast.install_before_gate_changed
         Server_dashboard_http.invalidate_gate_snapshots;
       let seed () =
         Dashboard_cache.seed_stale_if_missing gate_key ~stale_for:60.0 (`String "cached")
       in
       let heard = ref [] in
       Sse.subscribe_external ~id:subscriber_id
         ~callback:(fun (ev : Sse.external_event) ->
           if is_rules_changed ev.Sse.ext_frame
           then heard := Dashboard_cache.peek gate_key :: !heard)
         ();
       let expect label count =
         Alcotest.(check int) label count (List.length !heard);
         Alcotest.(check bool) (label ^ ": the Gate snapshot was gone when heard") true
           (List.for_all Option.is_none !heard);
         heard := []
       in
       let ok label = function
         | Ok _ -> ()
         | Error error ->
           Alcotest.failf "%s: %s" label (Rules.rule_store_error_to_string error)
       in
       seed ();
       ok "create" (upsert ~base_path ~approval_id:"approval-1" ~resolution_sequence:1 ~expires_at:None);
       expect "a new rule is announced" 1;
       seed ();
       ok "repeat" (upsert ~base_path ~approval_id:"approval-1" ~resolution_sequence:1 ~expires_at:None);
       expect "a repeated approval is not" 0;
       ok "renew"
         (upsert ~base_path ~approval_id:"approval-2" ~resolution_sequence:2
            ~expires_at:(Some 4_102_444_800.0));
       expect "a renewed expiry is announced" 1;
       let rule_id =
         match Rules.list_rules ~base_path () with
         | Ok [ rule ] -> rule.Rules.id
         | Ok rules -> Alcotest.failf "expected one rule, found %d" (List.length rules)
         | Error error ->
           Alcotest.fail (Rules.rule_store_error_to_string error)
       in
       seed ();
       ok "delete" (Rules.delete_rule ~base_path ~id:rule_id ());
       expect "a deleted rule is announced" 1;
       (match Rules.delete_rule ~base_path ~id:rule_id () with
        | Ok _ -> Alcotest.fail "a missing rule was deleted"
        | Error _ -> ());
       expect "a refused delete is not" 0)
;;

let ensure_keeper_exists ~base_path ~keeper_name =
  let json = `Assoc [ "name", `String keeper_name; "trace_id", `String ("trace-" ^ keeper_name) ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Error detail -> Alcotest.fail detail
  | Ok meta ->
    (match Keeper_meta_store.replace_snapshot (Workspace.default_config base_path) meta with
     | Ok () -> ()
     | Error detail -> Alcotest.fail detail)
;;

let test_a_resolution_is_announced_after_the_gate_snapshot_is_dropped () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let subscriber_id = Printf.sprintf "gate-resolved-announce-%d" (Unix.getpid ()) in
  let gate_key revision = Printf.sprintf "gate:%s;20;60;%d" base_path revision in
  Fun.protect
    ~finally:(fun () ->
      Sse.unsubscribe_external subscriber_id;
      Keeper_approval_queue.For_testing.reset_runtime_state ();
      Fs_compat.remove_tree base_path)
    (fun () ->
       Keeper_gate_broadcast.install_before_gate_changed
         Server_dashboard_http.invalidate_gate_snapshots;
       (match Keeper_approval_queue.install_persistence ~base_path with
        | Ok _ -> ()
        | Error error ->
          Alcotest.fail (Keeper_approval_queue_result.install_error_to_string error));
       let keeper_name = "gate-resolved" in
       ensure_keeper_exists ~base_path ~keeper_name;
       let id =
         match
           Keeper_approval_queue.submit_pending ~origin:Keeper_approval_origin.unavailable
             ~keeper_name ~tool_name:"external-effect" ~call_summary:None ~input ~base_path ()
         with
         | Ok submission -> submission.approval_id
         | Error error ->
           Alcotest.fail (Keeper_approval_queue_result.storage_error_to_string error)
       in
       (* A snapshot kept under the revision the resolution is about to
          publish, as a Gate read between the revision and the audit row
          would keep it. *)
       let next_key =
         gate_key (Keeper_approval_queue.store_revision_for_workspace ~base_path + 1)
       in
       Dashboard_cache.seed_stale_if_missing next_key ~stale_for:60.0 (`String "cached");
       let heard = ref [] in
       Sse.subscribe_external ~id:subscriber_id
         ~callback:(fun (ev : Sse.external_event) ->
           if event_type ev.Sse.ext_frame = Some "approval:resolved"
           then heard := Dashboard_cache.peek next_key :: !heard)
         ();
       (match
          Keeper_approval_queue.resolve_with_policy ~base_path ~id
            ~decision:Keeper_approval_queue_rules_types.Decision.Approve
            ~source:Keeper_approval_queue_rules_types.Human_operator ()
        with
        | Ok _ -> ()
        | Error error -> Alcotest.fail (Keeper_approval_queue.resolve_error_to_string error));
       match !heard with
       | [ snapshot ] ->
         Alcotest.(check bool) "the Gate snapshot is gone when the resolution is heard" true
           (Option.is_none snapshot)
       | heard -> Alcotest.failf "expected one resolution event, heard %d" (List.length heard))
;;

let () =
  Alcotest.run "gate_rules_announce"
    [ ( "rules"
      , [ Alcotest.test_case "rule writes are announced after the Gate snapshot is dropped"
            `Quick test_rule_writes_are_announced_after_the_gate_snapshot_is_dropped
        ] )
    ; ( "resolution"
      , [ Alcotest.test_case "a resolution is announced after the Gate snapshot is dropped"
            `Quick test_a_resolution_is_announced_after_the_gate_snapshot_is_dropped
        ] )
    ]
;;
