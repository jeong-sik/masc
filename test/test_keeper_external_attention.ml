module A = Masc.Keeper_external_attention

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let temp_base_path prefix =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let expect_ok = function
  | Ok () -> ()
  | Error detail -> Alcotest.failf "expected Ok, got Error %s" detail

let discord_surface ?thread_id ?parent_channel_id channel_id =
  A.Discord
    {
      guild_id = Some "guild-1";
      channel_id;
      parent_channel_id;
      thread_id;
    }

let conversation ?(surface = discord_surface "chan-1") id =
  { A.conversation_id = id; surface }

let external_message ?(surface = discord_surface "chan-1") message_id =
  { A.surface = surface; message_id; reply_to_message_id = None }

let item ?(dedupe_key = "discord:chan-1:msg-1") ?(keeper_name = "sangsu")
    ?(conversation = conversation "discord:guild-1:chan-1")
    ?external_message ?(urgency = A.Mention) ?(received_at = 10.0)
    ?(preview = "@sangsu check this") () =
  {
    A.event_id = A.event_id_of_dedupe_key dedupe_key;
    dedupe_key;
    keeper_name;
    conversation;
    external_message;
    source_label = "discord";
    actor =
      {
        actor_id = Some "user-1";
        display_name = Some "Alex";
        authority = Masc.Keeper_chat_store.External;
      };
    urgency;
    content_preview = preview;
    content_ref = None;
    received_at;
    metadata = [ ("fixture", "yes") ];
  }

let check_roundtrip name encode decode value =
  match decode (encode value) with
  | Ok decoded -> Alcotest.(check bool) name true (decoded = value)
  | Error detail -> Alcotest.failf "%s decode failed: %s" name detail

let test_json_roundtrip () =
  let thread_surface =
    discord_surface ~thread_id:"thread-1" ~parent_channel_id:"chan-parent"
      "thread-1"
  in
  let conv = conversation ~surface:thread_surface "discord:guild-1:thread-1" in
  let msg = external_message ~surface:thread_surface "msg-1" in
  let att = item ~conversation:conv ~external_message:msg () in
  check_roundtrip "surface" A.surface_ref_to_json A.surface_ref_of_json
    thread_surface;
  check_roundtrip "conversation" A.conversation_ref_to_json
    A.conversation_ref_of_json conv;
  check_roundtrip "external message" A.external_message_ref_to_json
    A.external_message_ref_of_json msg;
  check_roundtrip "item" A.item_to_json A.item_of_json att;
  check_roundtrip "recorded event" A.event_to_json A.event_of_json
    (A.Recorded att);
  check_roundtrip "claimed event" A.event_to_json A.event_of_json
    (A.Claimed_for_turn
       {
         event_id = att.A.event_id;
         claim_id = "claim-1";
         turn_id = Some 42;
         claimed_at = 20.0;
       });
  check_roundtrip "resolved event" A.event_to_json A.event_of_json
    (A.Resolved
       { event_id = att.A.event_id; resolved_at = 30.0; reason = "replied" })

let with_temp_base name f =
  let base_path = temp_base_path name in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_path with _ -> ())
    (fun () -> f base_path)

let test_record_dedupes_and_reads_pending () =
  with_temp_base "keeper-external-attention-record" @@ fun base_path ->
  let att = item () in
  (match A.record ~base_path att with
  | `Recorded -> ()
  | `Duplicate _ -> Alcotest.fail "first record was duplicate"
  | `Error detail -> Alcotest.failf "record failed: %s" detail);
  (match A.record ~base_path att with
  | `Duplicate duplicate ->
      Alcotest.(check string) "duplicate event id" att.A.event_id
        duplicate.A.event_id
  | `Recorded -> Alcotest.fail "duplicate record appended again"
  | `Error detail -> Alcotest.failf "duplicate record failed: %s" detail);
  Alcotest.(check int) "one physical recorded event" 1
    (List.length (A.load_events ~base_path ~keeper_name:att.A.keeper_name));
  match A.pending_for_keeper ~base_path ~keeper_name:att.A.keeper_name ~limit:10 () with
  | [ pending ] ->
      Alcotest.(check string) "pending event id" att.A.event_id pending.A.event_id
  | pending ->
      Alcotest.failf "expected 1 pending item, got %d" (List.length pending)

let test_claim_resolution_and_ignore_projection () =
  with_temp_base "keeper-external-attention-lifecycle" @@ fun base_path ->
  let one = item ~dedupe_key:"discord:chan-1:msg-1" ~received_at:1.0 () in
  let two = item ~dedupe_key:"discord:chan-1:msg-2" ~received_at:2.0 () in
  ignore (A.record ~base_path one : A.record_result);
  ignore (A.record ~base_path two : A.record_result);
  expect_ok
    (A.claim_for_turn ~base_path ~keeper_name:"sangsu"
       ~event_ids:[ one.A.event_id ] ~claim_id:"claim-1" ~turn_id:(Some 7)
       ~now:10.0 ());
  let pending =
    A.pending_for_keeper ~base_path ~keeper_name:"sangsu" ~now:11.0
      ~claim_stale_after:60.0 ~limit:10 ()
  in
  Alcotest.(check (list string)) "claimed item hidden"
    [ two.A.event_id ]
    (List.map (fun i -> i.A.event_id) pending);
  expect_ok
    (A.mark_resolved ~base_path ~keeper_name:"sangsu"
       ~event_ids:[ one.A.event_id ] ~reason:"replied" ~now:12.0 ());
  expect_ok
    (A.mark_ignored ~base_path ~keeper_name:"sangsu"
       ~event_ids:[ two.A.event_id ] ~reason:"silent" ~now:13.0 ());
  Alcotest.(check int) "all terminal" 0
    (List.length
       (A.pending_for_keeper ~base_path ~keeper_name:"sangsu" ~now:14.0
          ~limit:10 ()))

let test_stale_claim_projects_back_to_pending () =
  with_temp_base "keeper-external-attention-stale-claim" @@ fun base_path ->
  let att = item () in
  ignore (A.record ~base_path att : A.record_result);
  expect_ok
    (A.claim_for_turn ~base_path ~keeper_name:"sangsu"
       ~event_ids:[ att.A.event_id ] ~claim_id:"claim-1" ~turn_id:None
       ~now:10.0 ());
  Alcotest.(check int) "fresh claim hidden" 0
    (List.length
       (A.pending_for_keeper ~base_path ~keeper_name:"sangsu" ~now:11.0
          ~claim_stale_after:5.0 ~limit:10 ()));
  match
    A.pending_for_keeper ~base_path ~keeper_name:"sangsu" ~now:20.0
      ~claim_stale_after:5.0 ~limit:10 ()
  with
  | [ pending ] ->
      Alcotest.(check string) "stale claim recovered" att.A.event_id
        pending.A.event_id
  | pending ->
      Alcotest.failf "expected recovered pending item, got %d"
        (List.length pending)

let test_discord_channel_and_thread_conversation_ids_stay_distinct () =
  let channel =
    conversation ~surface:(discord_surface "chan-1") "discord:guild-1:chan-1"
  in
  let thread =
    conversation
      ~surface:
        (discord_surface ~thread_id:"thread-1" ~parent_channel_id:"chan-1"
           "thread-1")
      "discord:guild-1:thread-1"
  in
  Alcotest.(check bool) "distinct lane ids" true
    (channel.A.conversation_id <> thread.A.conversation_id)

let () =
  Alcotest.run "keeper_external_attention"
    [
      ( "json",
        [ Alcotest.test_case "surface/item/event roundtrip" `Quick test_json_roundtrip ]
      );
      ( "store",
        [
          Alcotest.test_case "record dedupes and reads pending" `Quick
            test_record_dedupes_and_reads_pending;
          Alcotest.test_case "claim, resolve, ignore projection" `Quick
            test_claim_resolution_and_ignore_projection;
          Alcotest.test_case "stale claim projects back to pending" `Quick
            test_stale_claim_projects_back_to_pending;
          Alcotest.test_case "Discord channel/thread lanes are distinct" `Quick
            test_discord_channel_and_thread_conversation_ids_stay_distinct;
        ] );
    ]
