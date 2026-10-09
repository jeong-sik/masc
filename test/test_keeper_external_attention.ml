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

let write_file path contents =
  Fs_compat.mkdir_p (Filename.dirname path);
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)
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
  let att = item () in
  (match record ~base_path att with
  | `Recorded -> ()
  | `Duplicate _ -> Alcotest.fail "first record was duplicate"
  | `Error detail -> Alcotest.failf "record failed: %s" detail);
  (match record ~base_path att with
  | `Duplicate duplicate ->
      Alcotest.(check string) "duplicate event id" att.A.event_id
        duplicate.A.event_id
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

let test_admission_time_replaces_delayed_ingress () =
  with_temp_base "keeper-external-admission" @@ fun base_path ->
  let incoming = item ~received_at:10.0 () in
  let admitted = A.For_testing.record_with_clock
      ~now:(fun () -> 20.0) ~base_path incoming in
  (match admitted with
   | `Recorded -> ()
   | `Duplicate _ -> Alcotest.fail "unexpected initial duplicate"
   | `Error detail -> Alcotest.fail detail);
  (match A.load_events_result ~base_path ~keeper_name:incoming.keeper_name with
   | Ok [A.Recorded stored] ->
     Alcotest.(check (float 0.0)) "persisted admission time" 20.0 stored.received_at
   | Ok _ -> Alcotest.fail "expected one admitted row"
   | Error error -> Alcotest.fail (A.read_error_to_string error));
  (match Masc.Keeper_librarian_input_sources.counterpart_observations_between
           ~base_dir:base_path ~keeper_name:incoming.keeper_name
           ~after:(Some 15.0) ~before:25.0 with
   | Ok observations ->
     Alcotest.(check int) "delayed ingress belongs to the later unread interval"
       1 (List.length observations)
   | Error _ -> Alcotest.fail "counterpart read failed");
  match A.For_testing.record_with_clock
          ~now:(fun () -> Alcotest.fail "duplicate sampled a new admission time")
          ~base_path incoming with
  | `Duplicate existing ->
    Alcotest.(check (float 0.0)) "duplicate keeps original admission" 20.0 existing.received_at
  | `Recorded -> Alcotest.fail "redelivery appended a second row"
  | `Error detail -> Alcotest.fail detail
;;

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

let test_counterpart_cursor_survives_clock_rollback () =
  with_temp_base "keeper-external-rollback" @@ fun base_path ->
  let first = item ~dedupe_key:"first" ~received_at:50.0 () in
  let second = item ~dedupe_key:"second" ~received_at:10.0 () in
  let third = item ~dedupe_key:"third" ~received_at:10.0 () in
  let append incoming = match record ~base_path incoming with
    | `Recorded -> () | `Duplicate _ -> Alcotest.fail "unexpected duplicate"
    | `Error detail -> Alcotest.fail detail in
  let snapshot cursor after before =
    match Masc.Keeper_librarian_input_sources.counterpart_observations_from
      ~external_after:cursor ~base_dir:base_path ~keeper_name:first.keeper_name
      ~after:(Some after) ~before with
    | Ok answer -> answer
    | Error error -> Alcotest.fail (Masc.Keeper_librarian_input_sources.read_error_to_string error) in
  append first;
  let observed, boundary = snapshot 0 0.0 50.0 in
  Alcotest.(check int) "initial snapshot reads first row" 1 (List.length observed);
  append second;
  append third;
  let later, through = snapshot boundary 50.0 10.0 in
  Alcotest.(check int) "rollback and same-time admissions remain visible" 2 (List.length later);
  let retried, _ = snapshot boundary 50.0 10.0 in
  Alcotest.(check int) "unacknowledged failure replays the same rows" 2 (List.length retried);
  let consumed, _ = snapshot through 50.0 10.0 in
  Alcotest.(check int) "acknowledged admission cursor excludes old rows" 0 (List.length consumed)
;;

let test_external_cursor_recovers_memory_receipt () =
  with_temp_base "keeper-external-cursor-recovery" @@ fun base_path ->
  let module Cursor = Masc.Keeper_external_read_cursor in
  let module Current = Masc.Keeper_memory_os_current in
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let runtime_keepers_dir = Filename.concat base_path "runtime" in
  let memory_keepers_dir = Filename.concat base_path "memory" in
  let keeper_name = "cursor-owner" in
  let read () = Cursor.read ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name |> get in
  let initial = read () in
  Alcotest.(check int) "missing cursor replays rather than skips" 0 (Cursor.offset initial);
  let range : Current.durable_range_id =
    {receipt_scope=Filename.concat runtime_keepers_dir "continuity";
     trace_id="cursor-trace";history_start_boundary_line=1;start_atom=0;end_atom=1;
     last_atom_digest=String.make 64 'a';end_boundary_line=2;boundary_lines_seen=2} in
  Cursor.prepare ~runtime_keepers_dir ~keeper_name initial ~through:2
    ~atom:(Some range) ~official:None |> get;
  Alcotest.(check int) "preparation without Memory commit does not consume" 0 (Cursor.offset (read ()));
  ignore (Current.apply_disposition ~revisions:[] ~durable_range_id:range
    ~absorbed:[] ~keepers_dir:memory_keepers_dir ~keeper_id:keeper_name ~now:1.
    ~source:{kind=Current.Librarian;trace_id="cursor-trace"} ~new_claims:[] () |> get);
  (* No acknowledge call: simulate interruption after the real Memory WAL
     committed but before the external cursor and ordinary progress wrote. *)
  Alcotest.(check int) "continuity-scoped Memory receipt recovers exact cursor" 2
    (Cursor.offset (read ()));
  let next = {range with end_atom=2;end_boundary_line=3;boundary_lines_seen=3} in
  Cursor.prepare ~runtime_keepers_dir ~keeper_name (read ()) ~through:3
    ~atom:(Some next) ~official:None |> get;
  Alcotest.(check int) "older receipt cannot acknowledge newer source" 2 (Cursor.offset (read ()))
;;

let () =
  Alcotest.run "keeper_external_attention"
    [
      ( "json",
        [ Alcotest.test_case "surface/item/event roundtrip" `Quick test_json_roundtrip ]
      );
      ( "store",
        [
          Alcotest.test_case "external cursor recovers only its committed Memory receipt" `Quick
            test_external_cursor_recovers_memory_receipt;
          Alcotest.test_case "counterpart cursor survives clock rollback and equal timestamps" `Quick
            test_counterpart_cursor_survives_clock_rollback;
          Alcotest.test_case "tail boundary preserves a complete first row" `Quick
            test_tail_boundary_keeps_complete_row;
          Alcotest.test_case "strict reader waits for timestamped admission" `Quick
            test_strict_reader_waits_for_admission;
          Alcotest.test_case "admission resamples delayed ingress and preserves duplicates" `Quick
            test_admission_time_replaces_delayed_ingress;
          Alcotest.test_case "admission refuses a torn log" `Quick
            test_admission_refuses_an_incomplete_log;
          Alcotest.test_case "record dedupes and reads pending" `Quick
            test_record_dedupes_and_reads_pending;
          Alcotest.test_case "record dedup window is bounded (F943)" `Quick
            test_record_dedup_window_bounded;
          Alcotest.test_case "strict reader rejects torn final row" `Quick
            test_strict_reader_rejects_torn_tail;
          Alcotest.test_case "Discord channel/thread lanes are distinct" `Quick
            test_discord_channel_and_thread_conversation_ids_stay_distinct;
        ] );
    ]
