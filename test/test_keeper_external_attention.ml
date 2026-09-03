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

let discord_surface ?thread_id ?parent_channel_id channel_id =
  A.Discord
    {
      guild_id = Some "guild-1";
      channel_id;
      channel_name = None;
      parent_channel_id;
      thread_id;
    }

let conversation ?(surface = discord_surface "chan-1") id =
  { A.conversation_id = id; surface }

let external_message ?(surface = discord_surface "chan-1") message_id =
  { A.surface = surface; message_id; reply_to_message_id = None }

let item ?(dedupe_key = "discord:chan-1:msg-1") ?(keeper_name = "alpha")
    ?(conversation = conversation "discord:guild-1:chan-1")
    ?external_message ?(urgency = A.Mention) ?(received_at = 10.0)
    ?(preview = "@alpha check this") () =
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
    (A.Recorded att)

let with_temp_base name f =
  let base_path = temp_base_path name in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_path with _ -> ())
    (fun () -> f base_path)

(* F943: [record] dedups against a bounded recent tail, not the whole
   (unbounded) store. A duplicate inside the window is still suppressed;
   one pushed past the window is re-appended (rare, harmless). This pins
   both halves of that contract and, by recording past the window
   without parsing the whole file each time, exercises the O(window)
   path. *)
let test_record_dedup_window_bounded () =
  with_temp_base "keeper-external-attention-window" @@ fun base_path ->
  let keeper_name = "windowkeeper" in
  let mk i =
    item ~keeper_name
      ~dedupe_key:(Printf.sprintf "discord:chan-1:msg-%d" i)
      ()
  in
  let record_exn it =
    match A.record ~base_path it with
    | `Recorded -> ()
    | `Duplicate _ -> Alcotest.fail "unexpected duplicate while filling"
    | `Error d -> Alcotest.failf "record failed: %s" d
  in
  (* The oldest event, then enough distinct fillers to push it out of the
     dedup window. Size the count from the measured per-event byte cost
     so the test self-adjusts if the window or item shape changes. *)
  let first = mk 0 in
  record_exn first;
  let line_bytes =
    String.length (Yojson.Safe.to_string (A.event_to_json (A.Recorded first)))
    + 1 (* newline *)
  in
  let fillers = (A.dedup_window_bytes / line_bytes) + 64 in
  let last_filler = ref first in
  for i = 1 to fillers do
    let it = mk i in
    record_exn it;
    last_filler := it
  done;
  let evidence_events =
    A.load_recent_evidence_events ~base_path ~keeper_name
  in
  Alcotest.(check bool)
    "memory evidence window is independent from dedup window"
    true
    (List.exists
       (function
         | A.Recorded recorded ->
           String.equal recorded.A.event_id first.A.event_id)
       evidence_events);
  (* The oldest event has scrolled past the window: re-recording it is a
     fresh append, not a duplicate. *)
  (match A.record ~base_path first with
   | `Recorded -> ()
   | `Duplicate _ ->
       Alcotest.fail "event older than the dedup window was treated as duplicate"
   | `Error d -> Alcotest.failf "record failed: %s" d);
  (* A recent event is still inside the window and is deduped. *)
  match A.record ~base_path !last_filler with
  | `Duplicate dup ->
      Alcotest.(check string) "recent duplicate still caught"
        !last_filler.A.event_id dup.A.event_id
  | `Recorded -> Alcotest.fail "recent duplicate inside window was re-recorded"
  | `Error d -> Alcotest.failf "record failed: %s" d

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
  match
    A.load_events ~base_path ~keeper_name:att.A.keeper_name
    |> List.filter_map (function A.Recorded item -> Some item)
  with
  | [ recorded ] ->
      Alcotest.(check string) "recorded event id" att.A.event_id
        recorded.A.event_id
  | recorded ->
      Alcotest.failf "expected 1 recorded item, got %d" (List.length recorded)

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
          Alcotest.test_case "record dedup window is bounded (F943)" `Quick
            test_record_dedup_window_bounded;
          Alcotest.test_case "Discord channel/thread lanes are distinct" `Quick
            test_discord_channel_and_thread_conversation_ids_stay_distinct;
        ] );
    ]
