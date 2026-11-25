module A = Masc.Keeper_external_attention

let record ~base_path item =
  A.For_testing.record_with_clock ~now:(fun () -> item.A.received_at) ~base_path item


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
        account = None;
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

let test_account_requires_matching_origin () =
  with_temp_base "keeper-external-attention-account" @@ fun base_path ->
  let user_id = "900000000000000001" in
  let reference = Option.get (Masc.Connector_account_ref.discord_user user_id) in
  let account = Some (A.Account_of_original_message reference) in
  let message = external_message "msg-1" in
  let att = item ~external_message:message () in
  let att = { att with actor = { att.actor with actor_id = Some user_id; account } } in
  check_roundtrip "proven account" A.item_to_json A.item_of_json att;
  Alcotest.(check bool) "original proof can supply the account" true
    (A.original_message_account att = Some reference);
  let older = { att with actor = { att.actor with
    account = Some (A.Account_without_original_proof reference) } } in
  check_roundtrip "older account without proof of original authorship" A.item_to_json A.item_of_json older;
  Alcotest.(check bool) "older observation cannot supply original proof" true
    (Option.is_none (A.original_message_account older));
  (match record ~base_path att with
   | `Recorded -> ()
   | `Duplicate _ -> Alcotest.fail "the first account evidence was already recorded"
   | `Error detail -> Alcotest.fail detail);
  (match A.load_events_result ~base_path ~keeper_name:att.keeper_name with
   | Ok events ->
     let accounts = List.map (fun (A.Recorded row) -> A.original_message_account row) events in
     Alcotest.(check bool) "original proof survives a strict store read" true
       (accounts = [ Some reference ])
   | Error error -> Alcotest.fail (A.read_error_to_string error));
  let mismatched_actor = { att with actor = { att.actor with actor_id = Some "900000000000000002" } } in
  let wrong_surface = { message with surface = discord_surface "other-channel" } in
  List.iter
    (fun (reason, row) ->
      Alcotest.(check bool) (reason ^ " rejected by decoder") true
        (Result.is_error (A.item_of_json (A.item_to_json row)));
      match A.record ~base_path row with
      | `Error _ -> ()
      | _ -> Alcotest.failf "%s accepted by writer" reason)
    [ "different actor", mismatched_actor
    ; "missing original message", { att with external_message = None }
    ; "different message surface", { att with external_message = Some wrong_surface }
    ]
;;

let write_file path contents =
  Fs_compat.mkdir_p (Filename.dirname path);
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)
;;

let test_unsupported_account_does_not_hide_stored_observations () =
  with_temp_base "keeper-external-attention-account-version" @@ fun base_path ->
  let first = item () in
  let encode ?proof account att =
    match A.item_to_json att with
    | `Assoc fields ->
      (match List.assoc_opt "actor" fields with
       | Some (`Assoc actor_fields) ->
         let proof_field = match proof with
           | None -> []
           | Some value -> [ "account_proof", `String value ]
         in
         let actor = `Assoc (("account", account) :: proof_field @ actor_fields) in
         `Assoc [ "event", `String "recorded"
                ; "item", `Assoc (("actor", actor) :: List.remove_assoc "actor" fields) ]
         |> Yojson.Safe.to_string
       | _ -> Alcotest.fail "fixture has no actor")
    | _ -> Alcotest.fail "fixture has no fields"
  in
  let second = item ~dedupe_key:"other-event" () in
  let user_id = "900000000000000001" in
  let known_account = Option.get (Masc.Connector_account_ref.discord_user user_id) in
  let third = item ~dedupe_key:"future-proof-event"
      ~external_message:(external_message "future-proof-message") () in
  let third = { third with actor = { third.actor with actor_id = Some user_id } } in
  let third_without_proof = { third with actor = { third.actor with
    account = Some (A.Account_without_original_proof known_account) } } in
  let unsupported_version = `Assoc [ "kind", `String "discord_user"; "version", `Int 2 ] in
  let unsupported_kind = `Assoc [ "kind", `String "future_user"; "version", `Int 1 ] in
  let path = A.attention_path ~base_path ~keeper_name:first.keeper_name in
  let original = String.concat "\n"
      [ encode unsupported_version first; encode unsupported_kind second
      ; encode ~proof:"discord_original_message_v2"
          (Masc.Connector_account_ref.to_json known_account) third
      ; "" ] in
  write_file path original;
  (match A.load_events_result ~base_path ~keeper_name:first.keeper_name with
   | Ok events ->
     Alcotest.(check bool) "all observations remain readable without original proof" true
       (events = [ A.Recorded first; A.Recorded second; A.Recorded third_without_proof ])
   | Error error -> Alcotest.fail (A.read_error_to_string error));
  Alcotest.(check string) "read preserves original bytes" original (Fs_compat.load_file path);
  let malformed = `Assoc [ "kind", `String "discord_user"; "version", `Int 1 ] in
  write_file path (encode malformed first ^ "\n");
  Alcotest.(check bool) "malformed known keys still reject the row" true
    (Result.is_error (A.load_events_result ~base_path ~keeper_name:first.keeper_name))
;;

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
    match record ~base_path it with
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
  (match record ~base_path first with
   | `Recorded -> ()
   | `Duplicate _ ->
       Alcotest.fail "event older than the dedup window was treated as duplicate"
   | `Error d -> Alcotest.failf "record failed: %s" d);
  (* A recent event is still inside the window and is deduped. *)
  match record ~base_path !last_filler with
  | `Duplicate dup ->
      Alcotest.(check string) "recent duplicate still caught"
        !last_filler.A.event_id dup.A.event_id
  | `Recorded -> Alcotest.fail "recent duplicate inside window was re-recorded"
  | `Error d -> Alcotest.failf "record failed: %s" d

let test_record_dedupes_and_reads_pending () =
  with_temp_base "keeper-external-attention-record" @@ fun base_path ->
  let actor_id = "900000000000000001" in
  let att = item ~external_message:(external_message "msg-1") () in
  let att = { att with actor = { att.actor with actor_id = Some actor_id } } in
  let account =
    Masc.Connector_account_ref.discord_user actor_id
    |> Option.map (fun account -> A.Account_of_original_message account)
  in
  Alcotest.(check bool) "replay has valid account evidence" true (Option.is_some account);
  let replay = { att with actor = { att.actor with account } } in
  (match record ~base_path att with
  | `Recorded -> ()
  | `Duplicate _ -> Alcotest.fail "first record was duplicate"
  | `Error detail -> Alcotest.failf "record failed: %s" detail);
  (match record ~base_path replay with
  | `Duplicate duplicate ->
      Alcotest.(check string) "duplicate event id" att.A.event_id
        duplicate.A.event_id;
      Alcotest.(check bool) "replay keeps first admission without account proof" true
        (Option.is_none duplicate.actor.account)
  | `Recorded -> Alcotest.fail "duplicate record appended again"
  | `Error detail -> Alcotest.failf "duplicate record failed: %s" detail);
  Alcotest.(check int) "one physical recorded event" 1
    (List.length (A.load_events ~base_path ~keeper_name:att.A.keeper_name));
  (match A.load_events_result ~base_path ~keeper_name:att.A.keeper_name with
   | Ok [ A.Recorded recorded ] ->
     Alcotest.(check string)
       "durable writer makes a complete strict row"
       att.A.event_id
       recorded.A.event_id
   | Ok events ->
     Alcotest.failf "expected 1 strict event, got %d" (List.length events)
   | Error error ->
     Alcotest.failf "strict read failed: %s" (A.read_error_to_string error));
  match
    A.load_events ~base_path ~keeper_name:att.A.keeper_name
    |> List.filter_map (function A.Recorded item -> Some item)
  with
  | [ recorded ] ->
      Alcotest.(check string) "recorded event id" att.A.event_id
        recorded.A.event_id
  | recorded ->
      Alcotest.failf "expected 1 recorded item, got %d" (List.length recorded)

let test_strict_reader_rejects_torn_tail () =
  with_temp_base "keeper-external-attention-torn-tail" @@ fun base_path ->
  let keeper_name = "torn-reader" in
  let first = item ~keeper_name ~dedupe_key:"torn:first" ~preview:"first" () in
  let second = item ~keeper_name ~dedupe_key:"torn:second" ~preview:"second" () in
  let first_line =
    Yojson.Safe.to_string (A.event_to_json (A.Recorded first)) ^ "\n"
  in
  let second_line = Yojson.Safe.to_string (A.event_to_json (A.Recorded second)) in
  let path = A.attention_path ~base_path ~keeper_name in
  write_file path (first_line ^ second_line);
  (match A.load_events_result ~base_path ~keeper_name with
   | Error (A.Incomplete_tail { rows_end; end_offset; _ }) ->
     Alcotest.(check int) "complete prefix boundary" (String.length first_line) rows_end;
     Alcotest.(check int)
       "physical file end"
       (String.length first_line + String.length second_line)
       end_offset
   | Error error ->
     Alcotest.failf "wrong strict error: %s" (A.read_error_to_string error)
   | Ok _ -> Alcotest.fail "strict reader accepted a torn final row");
  (match A.load_events ~base_path ~keeper_name with
   | [ A.Recorded recorded ] ->
     Alcotest.(check string)
       "permissive reader keeps the complete prefix"
       first.A.event_id
       recorded.A.event_id
   | events ->
     Alcotest.failf "expected one permissive event, got %d" (List.length events));
  write_file path (first_line ^ second_line ^ "\n");
  match A.load_events_result ~base_path ~keeper_name with
  | Ok events -> Alcotest.(check int) "completed rows pass" 2 (List.length events)
  | Error error ->
    Alcotest.failf "completed fixture stayed unreadable: %s" (A.read_error_to_string error)

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

let test_admission_refuses_an_incomplete_log () =
  with_temp_base "keeper-external-admission-torn" @@ fun base_path ->
  let incoming = item () in
  let path = A.attention_path ~base_path ~keeper_name:incoming.keeper_name in
  write_file path "{\"event\":";
  match A.For_testing.record_with_clock
          ~now:(fun () -> Alcotest.fail "torn log sampled admission time")
          ~base_path incoming with
  | `Error _ ->
    Alcotest.(check string) "torn log is unchanged" "{\"event\":"
      (Fs_compat.load_file path)
  | `Recorded | `Duplicate _ -> Alcotest.fail "torn log accepted admission"
;;

(* The production strict reader must wait across admission's timestamp-to-
   append interval. Pipes pause the writer exactly inside its clock callback;
   the reader uses another process, exercising the descriptor lock too. *)
let test_strict_reader_waits_for_admission () =
  with_temp_base "keeper-external-admission-lock" @@ fun base_path ->
  let incoming = item ~received_at:10.0 () in
  let ready_read, ready_write = Unix.pipe ~cloexec:true () in
  let release_read, release_write = Unix.pipe ~cloexec:true () in
  let signal fd = ignore (Unix.write_substring fd "x" 0 1 : int) in
  let receive fd =
    let byte = Bytes.create 1 in
    if Unix.read fd byte 0 1 <> 1 then Alcotest.fail "child closed before signal"
  in
  let writer = match Unix.fork () with
    | 0 ->
      Unix.close ready_read;
      Unix.close release_write;
      (try
         let now () =
           signal ready_write;
           receive release_read;
           20.0
         in
         (match A.For_testing.record_with_clock ~now ~base_path incoming with
          | `Recorded -> Unix._exit 0
          | `Duplicate _ | `Error _ -> Unix._exit 3)
       with _ -> Unix._exit 2)
    | pid -> pid
  in
  Unix.close ready_write;
  Unix.close release_read;
  receive ready_read;
  Unix.close ready_read;
  let started_read, started_write = Unix.pipe ~cloexec:true () in
  let result_read, result_write = Unix.pipe ~cloexec:true () in
  let reader = match Unix.fork () with
    | 0 ->
      Unix.close release_write;
      Unix.close started_read;
      Unix.close result_read;
      (try
         signal started_write;
         (match A.load_events_result ~base_path ~keeper_name:incoming.keeper_name with
          | Ok [A.Recorded stored] when stored.received_at = 20.0 -> signal result_write
          | Ok _ | Error _ -> Unix._exit 3);
         Unix._exit 0
       with _ -> Unix._exit 2)
    | pid -> pid
  in
  Unix.close started_write;
  Unix.close result_write;
  let released = ref false in
  let release () = if not !released then (released := true; signal release_write) in
  Fun.protect
    ~finally:(fun () ->
      release ();
      Unix.close release_write;
      Unix.close started_read;
      Unix.close result_read;
      List.iter (fun pid ->
        match Unix.waitpid [] pid with
        | _, Unix.WEXITED 0 -> ()
        | _ -> Alcotest.fail "admission lock fixture child failed") [writer; reader])
    (fun () ->
      receive started_read;
      (* Like the existing private-JSONL writer/reader scenario, this short
         interval observes exclusion; it is no production delay or deadline. *)
      let readable, _, _ = Unix.select [result_read] [] [] 0.05 in
      Alcotest.(check int) "no snapshot between admission time and append"
        0 (List.length readable);
      release ();
      receive result_read)
;;

let test_tail_boundary_keeps_complete_row () =
  with_temp_base "keeper-external-tail-boundary" @@ fun base_path ->
  let path = Filename.concat base_path "tail.jsonl" in
  let source = "old\nkept\nlast\n" in
  write_file path source;
  let read max_bytes expected =
    match Fs_compat.update_private_file_tail_durable_locked_result path ~max_bytes
      (fun rows -> None, rows) with
    | Fs_compat.Private_file_succeeded rows ->
      Alcotest.(check string) "tail contains exactly complete boundary rows" expected rows
    | _ -> Alcotest.fail "tail transaction failed" in
  read 10 "kept\nlast\n";
  read 9 "last\n";
  Alcotest.(check string) "read-only decision preserves log" source (Fs_compat.load_file path)
;;

let () =
  Alcotest.run "keeper_external_attention"
    [
      ( "json",
        [ Alcotest.test_case "surface/item/event roundtrip" `Quick test_json_roundtrip
        ; Alcotest.test_case "account requires a matching origin" `Quick
            test_account_requires_matching_origin
        ]
      );
      ( "store",
        [
          Alcotest.test_case "unsupported account keys preserve stored observations" `Quick
            test_unsupported_account_does_not_hide_stored_observations;
          Alcotest.test_case "tail boundary preserves a complete first row" `Quick
            test_tail_boundary_keeps_complete_row;
          Alcotest.test_case "strict reader waits for timestamped admission" `Quick
            test_strict_reader_waits_for_admission;
          Alcotest.test_case "admission refuses a torn log" `Quick
            test_admission_refuses_an_incomplete_log;
          Alcotest.test_case "record dedupes and reads pending" `Quick
            test_record_dedupes_and_reads_pending;
          Alcotest.test_case "record dedup window is bounded (F943)" `Quick
            test_record_dedup_window_bounded;
          Alcotest.test_case "strict reader rejects torn final row" `Quick
            test_strict_reader_rejects_torn_tail;
          Alcotest.test_case "Discord channel/thread lanes are distinct" `Quick
            test_discord_channel_and_thread_conversation_ids_stay_distinct] )]
