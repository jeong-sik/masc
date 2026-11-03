(** The confirmations waiting for an operator announce each change, and a
    reader that answers the announcement sees it: a written confirmation is
    listed when its write is heard and gone when its removal is heard. A
    confirmation that passes its deadline is announced once at the deadline,
    when readers stop listing it, and not again when the store is written
    later. A read that removes confirmations past their deadline changes
    nothing a reader lists, so it is not announced. A deadline read that
    recovers from a failure is announced, since a deadline may have passed
    unseen. *)

open Alcotest

module Expiry = Server_pending_confirm_expiry
module Store = Operator_pending_confirm

let fixture ~token ~expires_at : Store.pending_confirm =
  { confirm_token = token
  ; trace_id = "trace-" ^ token
  ; actor = "operator"
  ; action_type = "broadcast"
  ; target_type = "workspace"
  ; target_id = None
  ; payload = `Assoc [ "message", `String "fixture" ]
  ; delegated_tool = "masc_broadcast"
  ; created_at = "1970-01-01T00:00:00Z"
  ; expires_at
  }

let with_workspace f =
  let base_path = Masc_test_deps.setup_test_workspace () in
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect ~finally:(fun () ->
    Store.install_change_observer (fun ~base_path:_ -> ());
    (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
    Masc_test_deps.cleanup_test_workspace base_path)
    (fun () -> Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Masc.Mcp_server.For_testing.create_state ~base_path in
      let config = Masc.Mcp_server.workspace_config state in
      ignore (Workspace_core.init config ~agent_name:(Some "test"));
      Fs_compat.mkdir_p (Store.operator_dir config);
      f env state config))

let is_change frame =
  match Masc.Sse.data_payload_of_frame frame with
  | Error Masc.Sse.Missing_data_payload -> false
  | Ok payload ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields ->
       List.assoc_opt "type" fields
       = Some (`String Operator_pending_confirm_broadcast.changed_event)
     | _ -> false
     | exception Yojson.Json_error _ -> false)

(* Calls [f] with a list that gains [read ()] each time a change is heard. *)
let hearing ~read f =
  let id = Printf.sprintf "pending-confirms-announce-%d" (Unix.getpid ()) in
  let heard = ref [] in
  Masc.Sse.subscribe_external ~id
    ~callback:(fun (ev : Masc.Sse.external_event) ->
      if is_change ev.Masc.Sse.ext_frame then heard := read () :: !heard)
    ();
  Fun.protect ~finally:(fun () -> Masc.Sse.unsubscribe_external id) (fun () -> f heard)

let check_heard label expected heard =
  check (list bool) label expected (List.rev !heard);
  heard := []

let test_each_store_write_announces_its_change () =
  with_workspace (fun _env _state config ->
    let listed () =
      List.exists (fun (entry : Store.pending_confirm) -> String.equal entry.confirm_token "token-1")
        (Store.read_pending_confirms config)
    in
    hearing ~read:listed (fun heard ->
      (match Store.write_pending_confirms config [ fixture ~token:"token-1" ~expires_at:None ] with
       | Ok () -> ()
       | Error detail -> fail detail);
      check_heard "the written confirmation is listed when heard" [ true ] heard;
      (match Store.remove_pending_confirm config "token-1" with
       | Ok () -> ()
       | Error detail -> fail detail);
      check_heard "the removed confirmation is gone when heard" [ false ] heard))

let test_removing_expired_confirmations_is_not_announced () =
  with_workspace (fun _env _state config ->
    (match Store.write_pending_confirms config
             [ fixture ~token:"expired" ~expires_at:(Some "1970-01-01T00:00:01Z") ] with
     | Ok () -> ()
     | Error detail -> fail detail);
    hearing ~read:(fun () -> ()) (fun heard ->
      check int "the read lists none" 0 (List.length (Store.read_pending_confirms config));
      check int "and its cleanup is not announced" 0 (List.length !heard)))

let test_a_deadline_is_announced_once () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let text =
      Masc_domain.iso8601_of_unix_seconds (Eio.Time.now clock +. 1.5)
    in
    let heard_at = ref [] in
    hearing ~read:(fun () -> Eio.Time.now clock) (fun heard ->
      Eio.Switch.run (fun sw ->
        Expiry.For_testing.start ~sw ~clock ~state
          ~read:(fun _ -> Ok [ fixture ~token:"expiring" ~expires_at:(Some text) ])
          ~invalidate:(fun ~base_path:_ -> ());
        Eio.Time.with_timeout_exn clock 5.0 (fun () ->
          while !heard = [] do Eio.Time.sleep clock 0.01 done);
        heard_at := !heard;
        (* A later write makes the worker look at the store again. Only the
           write is announced, not the deadline that already was. *)
        (match Store.write_pending_confirms config [] with
         | Ok () -> ()
         | Error detail -> fail detail);
        Eio.Time.sleep clock 0.3;
        check int "announced once, then the write" 2 (List.length !heard)));
    match !heard_at, Masc_domain.parse_iso8601_opt text with
    | [ at ], Some deadline -> check bool "at the deadline, not before" true (at >= deadline)
    | _, _ -> fail "expected one announcement and a readable deadline")

let test_a_recovered_deadline_read_is_announced () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let reads = ref 0 in
    let read _ =
      incr reads;
      if !reads = 1 then Error "fixture store unreadable" else Ok []
    in
    hearing ~read:(fun () -> ()) (fun heard ->
      Eio.Switch.run (fun sw ->
        Expiry.For_testing.start ~sw ~clock ~state ~read ~invalidate:(fun ~base_path:_ -> ());
        Eio.Time.with_timeout_exn clock 5.0 (fun () ->
          while !reads = 0 do Eio.Time.sleep clock 0.01 done);
        (* A write makes the worker read again; that read recovers. *)
        (match Store.write_pending_confirms config [] with
         | Ok () -> ()
         | Error detail -> fail detail);
        Eio.Time.sleep clock 0.3;
        check int "the write, then the recovered read" 2 (List.length !heard))))

let () =
  run
    "pending_confirms_announce"
    [ ( "pending confirmations"
      , [ test_case "each store write announces its change" `Quick
            test_each_store_write_announces_its_change
        ; test_case "a deadline is announced once" `Quick test_a_deadline_is_announced_once
        ; test_case "removing expired confirmations is not announced" `Quick
            test_removing_expired_confirmations_is_not_announced
        ; test_case "a recovered deadline read is announced" `Quick
            test_a_recovered_deadline_read_is_announced
        ] )
    ]
