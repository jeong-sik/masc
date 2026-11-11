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

let external_previews observations =
  List.map
    (fun (observation : Masc.Keeper_counterpart_observation.t) -> observation.content)
    observations

let test_counterpart_cursor_keeps_admission_order () =
  with_temp_base "keeper-external-admission-order" @@ fun base_path ->
  let first = item ~dedupe_key:"first" ~preview:"first" ~received_at:40.0 () in
  let second = item ~dedupe_key:"second" ~preview:"second" ~received_at:30.0 () in
  List.iter (fun incoming -> match record ~base_path incoming with
    | `Recorded -> () | `Duplicate _ -> Alcotest.fail "unexpected duplicate"
    | `Error detail -> Alcotest.fail detail) [ first; second ];
  match Masc.Keeper_librarian_input_sources.counterpart_observations_from
    ~external_after:0 ~base_dir:base_path ~keeper_name:first.keeper_name
    ~after:(Some 0.0) ~before:50.0 with
  | Error error -> Alcotest.fail (Masc.Keeper_librarian_input_sources.read_error_to_string error)
  | Ok (observed, through) ->
    Alcotest.(check (list string)) "a clock rollback does not reorder admissions"
      [ "first"; "second" ] (external_previews observed);
    Alcotest.(check int) "both admissions are in the snapshot" 2 through
;;

let test_counterpart_cursor_stops_at_range_end () =
  with_temp_base "keeper-external-range-end" @@ fun base_path ->
  let earlier = item ~dedupe_key:"earlier" ~preview:"earlier" ~received_at:10.0 () in
  let later = item ~dedupe_key:"later" ~preview:"later" ~received_at:30.0 () in
  let rolled_back = item ~dedupe_key:"rolled-back" ~preview:"rolled-back" ~received_at:15.0 () in
  List.iter (fun incoming -> match record ~base_path incoming with
    | `Recorded -> () | `Duplicate _ -> Alcotest.fail "unexpected duplicate"
    | `Error detail -> Alcotest.fail detail) [ earlier; later; rolled_back ];
  let snapshot cursor after before =
    match Masc.Keeper_librarian_input_sources.counterpart_observations_from
      ~external_after:cursor ~base_dir:base_path ~keeper_name:earlier.keeper_name
      ~after ~before with
    | Ok (observed, through) -> external_previews observed, through
    | Error error -> Alcotest.fail (Masc.Keeper_librarian_input_sources.read_error_to_string error) in
  let first_range, first_through = snapshot 0 None 20.0 in
  Alcotest.(check (list string)) "the first range keeps only its own admissions"
    [ "earlier" ] first_range;
  Alcotest.(check int) "the cursor stops before the later turn's admission" 1 first_through;
  let second_range, second_through = snapshot first_through (Some 20.0) 40.0 in
  Alcotest.(check (list string)) "the next range takes the held rows in admission order"
    [ "later"; "rolled-back" ] second_range;
  Alcotest.(check int) "the next range reaches the end of the log" 3 second_through
;;

let test_external_cursor_recovers_memory_receipt ~with_unread () =
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
    {unread_messages=[];receipt_scope=Filename.concat runtime_keepers_dir "continuity";
     trace_id="cursor-trace";history_start_boundary_line=1;start_atom=0;end_atom=1;
     last_atom_digest=String.make 64 'a';end_boundary_line=2;boundary_lines_seen=2} in
  let range = if not with_unread then range else
    let messages = [Agent_core.Types.make_message ~role:Agent_core.Types.User
      [Agent_core.Types.Text "An unread external source"]] in
    let hole = Masc.Keeper_librarian_unread.for_atom ~trace_id:range.trace_id
      ~history_start_boundary_line:range.history_start_boundary_line ~atom:0 ~message_in_atom:0
      ~messages ~reasons:[Masc.Keeper_librarian_input_refusal.Input_capacity] |> get in
    {range with unread_messages=[hole]} in
  let next = {range with end_atom=2;end_boundary_line=3;boundary_lines_seen=3} in
  let official : Current.official_range_id =
    {receipt_scope=runtime_keepers_dir;after_boundary_line=0;
     turns=[1,Ids.Turn_ref.make ~trace_id:"cursor-official" ~absolute_turn:1];unread_messages=[]} in
  Cursor.prepare ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name initial ~through:2
    ~atom:(Some range) ~official:None |> get;
  Alcotest.(check int) "preparation without Memory commit does not consume" 0 (Cursor.offset (read ()));
  ignore (Current.apply_disposition ~pass:Masc.Keeper_memory_commit_pass.Durable ~revisions:[] ~durable_range_id:range ~official_range_id:official
    ~absorbed:[] ~keepers_dir:memory_keepers_dir ~keeper_id:keeper_name ~now:1.
    ~source:{kind=Current.Librarian;trace_id="cursor-trace"} ~new_claims:[] () |> get);
  (* No acknowledge call: simulate interruption after the real Memory WAL
     committed but before the external cursor and ordinary progress wrote. *)
  let pending_path = Cursor.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name in
  let pending_bytes = Fs_compat.load_file pending_path in
  List.iter (fun (label,through,atom,official,expected_error) ->
    (match Cursor.prepare ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name initial
       ~through ~atom ~official with
     | Error detail -> Alcotest.(check string) (label ^ " refuses for its actual reason") expected_error detail
     | Ok () -> Alcotest.fail (label ^ " preparation was accepted"));
    Alcotest.(check string) (label ^ " leaves the pending cursor unchanged") pending_bytes
      (Fs_compat.load_file pending_path))
    ["backwards", -1, Some range, None, "external attention log shrank behind its read cursor";
     "missing identity", 3, None, None, "external read has no Memory commit identity";
     "already committed atom", 3, Some range, None,
       "a committed Memory range cannot acknowledge a new external snapshot";
     "already committed official", 3, None, Some official,
       "a committed Memory range cannot acknowledge a new external snapshot";
     "new atom with already committed official", 3, Some next, Some official,
       "a committed Memory range cannot acknowledge a new external snapshot"];
  let observed = Cursor.observe ~runtime_keepers_dir ~keeper_name |> get in
  Alcotest.(check int) "observation does not recover a committed Memory receipt" 0
    (Cursor.observation_offset observed);
  Alcotest.(check string) "committed receipt observation leaves pending bytes intact" pending_bytes
    (Fs_compat.load_file pending_path);
  let ledger_path = Current.unread_ledger_path ~keepers_dir:memory_keepers_dir ~keeper_id:keeper_name in
  if with_unread then (
    let cursor_path = Cursor.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name in
    let pending = Fs_compat.load_file cursor_path in
    let previous_ledger = Fs_compat.load_file_opt ledger_path in
    Fs_compat.save_file ledger_path "{";
    (match Cursor.read ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "external acknowledgement bypassed unread ledger failure");
    Alcotest.(check string) "ledger failure preserves the pending cursor" pending
      (Fs_compat.load_file cursor_path);
    match previous_ledger with
    | Some bytes -> Fs_compat.save_file ledger_path bytes
    | None -> Sys.remove ledger_path);
  if not with_unread then (
    (* A valid new preparation still recovers an older committed pending read.
       Its old token must be rejected, and the caller can retry at the new offset. *)
    (match Cursor.prepare ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name initial
       ~through:3 ~atom:(Some next) ~official:None with
     | Error detail -> Alcotest.(check string) "recovery reports the stale token"
         "external admission cursor changed before preparation" detail
     | Ok () -> Alcotest.fail "preparation used a token from before recovery");
    let recovered = Cursor.observe ~runtime_keepers_dir ~keeper_name |> get in
    Alcotest.(check int) "valid preparation recovers the old committed cursor" 2
      (Cursor.observation_offset recovered));
  Alcotest.(check int) "continuity-scoped Memory receipt recovers exact cursor" 2
    (Cursor.offset (read ()));
  if with_unread then (
    (* Read raw bytes before invoking any API that could archive evidence. *)
    let ledger = match Yojson.Safe.from_string (Fs_compat.load_file ledger_path) with
      | `Assoc [("schema_version", `Int 1); ("unread_messages", entries)] ->
        Masc.Keeper_librarian_unread.list_of_json entries |> get
      | _ -> Alcotest.fail "acknowledgement left no strict unread ledger" in
    Alcotest.(check bool) "acknowledged external read retains its unread source durably" true
      (ledger = range.unread_messages));
  (match Cursor.prepare ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name (read ())
     ~through:3 ~atom:(Some range) ~official:None with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "old committed range admitted a new external snapshot");
  Alcotest.(check int) "reused receipt did not consume new rows" 2 (Cursor.offset (read ()));
  Cursor.prepare ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name (read ()) ~through:3
    ~atom:(Some next) ~official:None |> get;
  Alcotest.(check int) "older receipt cannot acknowledge newer source" 2 (Cursor.offset (read ()));
  let path = Cursor.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name in
  let before = Fs_compat.load_file path in
  Alcotest.(check bool) "preflight observes prepared cursor without consuming it" true
    (Cursor.inspect ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name |> get);
  Alcotest.(check string) "preflight never writes or acknowledges pending evidence" before (Fs_compat.load_file path);
  Fs_compat.save_file path {|{"after":0}|};
  (match Cursor.inspect ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name with
   | Error _ -> () | Ok _ -> Alcotest.fail "malformed cursor passed deployment preflight")
;;

let test_counterpart_capture_retains_original_rows_and_dedup_frontier () =
  with_temp_base "keeper-counterpart-capture" @@ fun base_path ->
  let module Sources = Masc.Keeper_librarian_input_sources in
  let module Chat = Masc.Keeper_chat_store in
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let keeper_name = "captured-counterparts" in
  let first = item ~keeper_name ~dedupe_key:"capture-first" ~preview:"first"
      ~received_at:5. () in
  let future = item ~keeper_name ~dedupe_key:"capture-future" ~preview:"future"
      ~external_message:(external_message "capture-future-message") ~received_at:30. () in
  let behind_future = item ~keeper_name ~dedupe_key:"capture-held" ~preview:"held"
      ~received_at:10. () in
  List.iter (fun incoming -> match record ~base_path incoming with
    | `Recorded -> () | `Duplicate _ -> Alcotest.fail "unexpected capture duplicate"
    | `Error detail -> Alcotest.fail detail) [first;future;behind_future];
  let row ~id ~content ~ts extra =
    `Assoc (["id",`String id;"role",`String "user";"content",`String content;
      "ts",`Float ts;"speaker_id",`String "speaker";"speaker_name",`String "Original speaker";
      "speaker_authority",`String "external"] @ extra) |> Yojson.Safe.to_string in
  let duplicate = row ~id:"chat-duplicate" ~content:"duplicate future delivery" ~ts:12.
      ["conversation_id",`String future.conversation.conversation_id;
       "external_message_id",`String "capture-future-message"] in
  let direct = row ~id:"chat-original" ~content:"direct original" ~ts:13. [] in
  let chat_path = Chat.chat_path ~base_dir:base_path ~keeper_name in
  write_file chat_path (duplicate ^ "\n" ^ direct ^ "\n");
  let snapshot = Sources.capture_counterparts ~external_after:0 ~base_dir:base_path
      ~keeper_name ~after:None ~before:20.
    |> Result.map_error Sources.read_error_to_string |> get in
  let snapshot_json = Sources.counterpart_snapshot_to_json snapshot in
  let snapshot_bytes = Yojson.Safe.to_string snapshot_json in
  let content snapshot = Sources.counterpart_observations snapshot |> external_previews in
  Alcotest.(check (list string)) "out-of-range delivery still suppresses its selected chat duplicate"
    ["first";"direct original"] (content snapshot);
  Alcotest.(check int) "original frontier stops at the first future admission" 1
    (Sources.external_through snapshot);
  let captured_rows = match snapshot_json with
    | `Assoc fields -> (match List.assoc "chat_rows" fields with
      | `List rows -> rows | _ -> Alcotest.fail "capture rows missing")
    | _ -> Alcotest.fail "capture envelope missing" in
  let raw row = match row with
    | `Assoc fields -> (match List.assoc "raw_line" fields with
      | `String raw -> raw | _ -> Alcotest.fail "original raw row missing")
    | _ -> Alcotest.fail "invalid raw capture" in
  Alcotest.(check (list string)) "raw selected rows include the deduplicated row in source order"
    [duplicate;direct] (List.map raw captured_rows);
  (match record ~base_path (item ~keeper_name ~dedupe_key:"capture-append" ~preview:"new tail" ~received_at:40. ()) with
   | `Recorded -> () | `Duplicate _ -> Alcotest.fail "unexpected appended duplicate"
   | `Error detail -> Alcotest.fail detail);
  let tail = row ~id:"appended-chat" ~content:"new chat tail" ~ts:14.
      ["conversation_id",`String future.conversation.conversation_id;
       "external_message_id",`String "tail-future-message"] in
  write_file chat_path (duplicate ^ "\n" ^ direct ^ "\n" ^ tail ^ "\n");
  let fresh = Sources.capture_counterparts ~external_after:0 ~base_dir:base_path ~keeper_name
      ~after:None ~before:20. |> Result.map_error Sources.read_error_to_string |> get in
  Sources.snapshot_extends ~original:snapshot ~current:fresh |> get;
  Sources.validate_original_selection snapshot ~base_dir:base_path ~keeper_name
    |> Result.map_error Sources.read_error_to_string |> get;
  let expected_digest = Sources.counterpart_observations_digest snapshot in
  Alcotest.(check bool) "unacknowledged external cursor does not cover the original frontier" false
    (Sources.counterparts_covered_at_frontier snapshot ~counterpart_digest:expected_digest
       ~base_dir:base_path ~keeper_name ~acked_external_offset:0
     |> Result.map_error Sources.read_error_to_string |> get);
  Alcotest.(check bool) "acknowledged external cursor covers the intact original counterparts" true
    (Sources.counterparts_covered_at_frontier snapshot ~counterpart_digest:expected_digest
       ~base_dir:base_path ~keeper_name ~acked_external_offset:1
     |> Result.map_error Sources.read_error_to_string |> get);
  (match record ~base_path (item ~keeper_name ~dedupe_key:"capture-tail-dup" ~preview:"tail dup"
           ~external_message:(external_message "tail-future-message") ~received_at:50. ()) with
   | `Recorded -> () | `Duplicate _ -> Alcotest.fail "unexpected tail duplicate"
   | `Error detail -> Alcotest.fail detail);
  let fresh_digest = Sources.counterpart_observations_digest fresh in
  Alcotest.(check bool) "unacknowledged future delivery that suppresses a selected chat row blocks frontier coverage" false
    (Sources.counterparts_covered_at_frontier fresh ~counterpart_digest:fresh_digest
       ~base_dir:base_path ~keeper_name ~acked_external_offset:1
     |> Result.map_error Sources.read_error_to_string |> get);
  Alcotest.(check bool) "acknowledging the suppressing future delivery restores frontier coverage" true
    (Sources.counterparts_covered_at_frontier fresh ~counterpart_digest:fresh_digest
       ~base_dir:base_path ~keeper_name ~acked_external_offset:5
     |> Result.map_error Sources.read_error_to_string |> get);
  Alcotest.(check int) "accepted source tails never extend the original frontier" 1
    (Sources.external_through snapshot);
  write_file chat_path (row ~id:"replacement" ~content:"changed source" ~ts:13. [] ^ "\n");
  (match Sources.validate_original_selection snapshot ~base_dir:base_path ~keeper_name with
   | Error _ -> () | Ok () -> Alcotest.fail "original chat rewrite remained admissible");
  let restored = Sources.counterpart_snapshot_of_json (Yojson.Safe.from_string snapshot_bytes) |> get in
  Alcotest.(check (list string)) "restoration never rereads rewritten or appended sources"
    ["first";"direct original"] (content restored);
  Alcotest.(check string) "complete original capture is immutable" snapshot_bytes
    (Sources.counterpart_snapshot_to_json restored |> Yojson.Safe.to_string);
  let refused value = match Sources.counterpart_snapshot_of_json value with
    | Error _ -> () | Ok _ -> Alcotest.fail "malformed complete counterpart snapshot accepted" in
  (match snapshot_json with
   | `Assoc fields ->
     refused (`Assoc (("extra",`Null)::fields));
     refused (`Assoc (("before",`Float 20.)::fields));
     refused (`Assoc (List.map (fun (key,value) -> key, if key="external_through" then `Int 2 else value) fields));
     refused (`Assoc (List.map (fun (key,value) -> key, if key="chat_rows" then
       `List [`Assoc ["raw_line",`String duplicate;"projected_line",`String direct]] else value) fields))
   | _ -> Alcotest.fail "capture envelope missing")
;;

let test_counterpart_witness_requires_selected_source_identity () =
  with_temp_base "keeper-counterpart-witness" @@ fun base_path ->
  let module Sources = Masc.Keeper_librarian_input_sources in
  let module Chat = Masc.Keeper_chat_store in
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let covers ~original ~witness = Sources.counterpart_selection_covers
      ~original:(Sources.select_counterparts original) ~witness:(Sources.select_counterparts witness) in
  let may_overlap ~original ~candidate = Sources.counterpart_selection_may_overlap
      ~original:(Sources.select_counterparts original) ~candidate:(Sources.select_counterparts candidate) in
  let keeper_name = "witness-owner" in
  let row ~id ~ts extra =
    `Assoc (["id",`String id;"role",`String "user";"content",`String "same content";
      "ts",`Float ts;"speaker_id",`String "speaker";"speaker_name",`String "Speaker";
      "speaker_authority",`String "external"] @ extra) |> Yojson.Safe.to_string in
  let original_row = row ~id:"original-row" ~ts:10.
      ["conversation_id",`String "discord:guild-1:chan-1";
       "external_message_id",`String "original-message"] in
  let other_row = row ~id:"another-row" ~ts:30. [] in
  let chat_path = Chat.chat_path ~base_dir:base_path ~keeper_name in
  let capture before =
    Sources.capture_counterparts ~external_after:0 ~base_dir:base_path ~keeper_name
      ~after:None ~before |> Result.map_error Sources.read_error_to_string |> get in
  write_file chat_path (original_row ^ "\n");
  let original = capture 15. in
  let changed_projection = match Sources.counterpart_snapshot_to_json original with
    | `Assoc fields ->
      let rows = match List.assoc "chat_rows" fields with
        | `List [`Assoc row] ->
          let projected = match List.assoc "projected_line" row with
            | `String line -> (match Yojson.Safe.from_string line with
              | `Assoc values -> `Assoc (List.map (fun (key,value) ->
                  key, if key="content" then `String "another projection" else value) values)
                  |> Yojson.Safe.to_string
              | _ -> Alcotest.fail "projected chat row must be an object")
            | _ -> Alcotest.fail "projected chat row must be a string" in
          `List [`Assoc (List.map (fun (key,value) ->
            key, if key="projected_line" then `String projected else value) row)]
        | _ -> Alcotest.fail "fixture must retain one chat row" in
      `Assoc (List.map (fun (key,value) -> key, if key="chat_rows" then rows else value) fields)
      |> Sources.counterpart_snapshot_of_json |> get
    | _ -> Alcotest.fail "fixture must retain a snapshot object" in
  Alcotest.(check bool) "the same raw chat row with a different delivered projection is not a witness" false
    (covers ~original ~witness:changed_projection);
  Alcotest.(check bool) "a different projection still retains the matching source" true
    (may_overlap ~original ~candidate:changed_projection);
  write_file chat_path (other_row ^ "\n");
  let plain_chat = capture 40. in
  Alcotest.(check bool) "the same chat ID overlaps without a delivery identity" true
    (may_overlap ~original:plain_chat ~candidate:plain_chat);
  let same_delivery_row = row ~id:"different-chat-id" ~ts:10.
      ["conversation_id",`String "discord:guild-1:chan-1";
       "external_message_id",`String "original-message"] in
  write_file chat_path (same_delivery_row ^ "\n");
  let same_delivery_chat = capture 15. in
  Alcotest.(check bool) "a different chat row is not a complete witness" false
    (covers ~original ~witness:same_delivery_chat);
  Alcotest.(check bool) "chat rows with the same delivery identity may overlap" true
    (may_overlap ~original ~candidate:same_delivery_chat);
  write_file chat_path (original_row ^ "\n");
  let delivery = item ~keeper_name ~dedupe_key:"witness-delivery" ~received_at:20.
      ~preview:"different delivery preview" ~external_message:(external_message "original-message") () in
  (match record ~base_path delivery with
   | `Recorded -> () | `Duplicate _ -> Alcotest.fail "unexpected delivery duplicate"
   | `Error detail -> Alcotest.fail detail);
  let other_conversation = row ~id:"other-conversation" ~ts:30.
      ["conversation_id",`String "discord:guild-1:other";
       "external_message_id",`String "original-message"] in
  write_file chat_path (original_row ^ "\n" ^ other_row ^ "\n" ^ other_conversation ^ "\n");
  let witness = capture 40. in
  let original_input = Sources.counterpart_observations original in
  let witness_input = Sources.counterpart_observations witness in
  Alcotest.(check int) "the original question contained one chat observation" 1 (List.length original_input);
  Alcotest.(check bool) "a different row supplies the same projected value" true
    (List.for_all (fun observation -> List.mem observation witness_input) original_input);
  Alcotest.(check int) "matching message ID in another conversation is not deduplicated" 2
    (List.length (List.filter (fun (observation:Masc.Keeper_counterpart_observation.t) ->
      observation.content="same content") witness_input));
  Alcotest.(check bool) "the deduplicated original is not selected by the witness" false
    (covers ~original ~witness);
  Alcotest.(check bool) "the later delivery may overlap the original chat source" true
    (may_overlap ~original ~candidate:witness);
  let unrelated = Sources.capture_counterparts ~external_after:1 ~base_dir:base_path ~keeper_name
      ~after:(Some 25.) ~before:40. |> Result.map_error Sources.read_error_to_string |> get in
  Alcotest.(check bool) "an unrelated selected chat does not hold this source" false
    (may_overlap ~original ~candidate:unrelated);
  let current_original_window = capture 15. in
  Sources.snapshot_extends ~original ~current:current_original_window |> get;
  Alcotest.(check bool) "the old frontier can already be acknowledged" true
    (Sources.counterparts_covered_at_frontier original
       ~counterpart_digest:(Sources.counterpart_observations_digest original)
       ~base_dir:base_path ~keeper_name ~acked_external_offset:1
     |> Result.map_error Sources.read_error_to_string |> get)
;;

let test_counterpart_witness_requires_order_and_multiplicity () =
  with_temp_base "keeper-counterpart-witness-order" @@ fun base_path ->
  let module Sources = Masc.Keeper_librarian_input_sources in
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let covers ~original ~witness = Sources.counterpart_selection_covers
      ~original:(Sources.select_counterparts original) ~witness:(Sources.select_counterparts witness) in
  let keeper_name = "ordered-witness" in
  List.iter (fun incoming -> match record ~base_path incoming with
    | `Recorded -> () | `Duplicate _ -> Alcotest.fail "unexpected delivery duplicate"
    | `Error detail -> Alcotest.fail detail)
    [item ~keeper_name ~dedupe_key:"first" ~preview:"same" ~received_at:1. ();
     item ~keeper_name ~dedupe_key:"second" ~preview:"same" ~received_at:2. ();
     item ~keeper_name ~dedupe_key:"later" ~preview:"later" ~received_at:3. ()];
  let capture before = Sources.capture_counterparts ~external_after:0 ~base_dir:base_path
      ~keeper_name ~after:None ~before |> Result.map_error Sources.read_error_to_string |> get in
  let original = capture 2. and extended = capture 3. in
  Alcotest.(check bool) "later selected events preserve a real ordered witness" true
    (covers ~original ~witness:extended);
  let reordered = match Sources.counterpart_snapshot_to_json extended with
    | `Assoc fields ->
      let entries = match List.assoc "external_log" fields with
        | `List [first;second;later] -> `List [second;first;later]
        | _ -> Alcotest.fail "fixture must retain three external rows" in
      `Assoc (List.map (fun (key,value) -> key, if key="external_log" then entries else value) fields)
      |> Sources.counterpart_snapshot_of_json |> get
    | _ -> Alcotest.fail "fixture must retain a snapshot object" in
  Alcotest.(check bool) "the two reordered event projections are identical" true
    (Sources.counterpart_observations extended = Sources.counterpart_observations reordered);
  Alcotest.(check bool) "equal projected values cannot hide reversed source order" false
    (covers ~original ~witness:reordered);
  let only_second = Sources.capture_counterparts ~external_after:1 ~base_dir:base_path
      ~keeper_name ~after:None ~before:3. |> Result.map_error Sources.read_error_to_string |> get in
  Alcotest.(check bool) "one equal event cannot stand in for two originals" false
    (covers ~original ~witness:only_second)
;;

let test_counterpart_witness_distinguishes_external_occurrences () =
  with_temp_base "keeper-counterpart-witness-offset" @@ fun base_path ->
  let module Sources = Masc.Keeper_librarian_input_sources in
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let covers ~original ~witness = Sources.counterpart_selection_covers
      ~original:(Sources.select_counterparts original) ~witness:(Sources.select_counterparts witness) in
  let keeper_name = "offset-witness" in
  (match record ~base_path (item ~keeper_name ~dedupe_key:"same-event"
     ~external_message:(external_message "same-message") ~received_at:1. ()) with
   | `Recorded -> () | `Duplicate _ -> Alcotest.fail "unexpected initial duplicate"
   | `Error detail -> Alcotest.fail detail);
  let first = Sources.capture_counterparts ~external_after:0 ~base_dir:base_path ~keeper_name
      ~after:None ~before:2. |> Result.map_error Sources.read_error_to_string |> get in
  let with_events ~after events = match Sources.counterpart_snapshot_to_json first with
    | `Assoc fields ->
      `Assoc (List.map (fun (key,value) -> key,
        if key="external_log" then `List (List.map A.item_to_json events)
        else if key="external_after" then `Int after
        else if key="external_through" then `Int (List.length events)
        else value) fields) |> Sources.counterpart_snapshot_of_json |> get
    | _ -> Alcotest.fail "fixture must retain a snapshot object" in
  let other_at_same_offset = with_events ~after:0
      [item ~keeper_name ~dedupe_key:"other-offset-event" ~received_at:1. ()] in
  Alcotest.(check bool) "a different event at the same offset is not a complete witness" false
    (covers ~original:first ~witness:other_at_same_offset);
  Alcotest.(check bool) "the same external offset alone may overlap" true
    (Sources.counterpart_selection_may_overlap ~original:(Sources.select_counterparts first)
       ~candidate:(Sources.select_counterparts other_at_same_offset));
  let same_id_at_other_offset = with_events ~after:1
      [item ~keeper_name ~dedupe_key:"first-placeholder" ~received_at:1. ();
       item ~keeper_name ~dedupe_key:"same-event" ~received_at:1. ()] in
  Alcotest.(check bool) "the same event ID at another offset may overlap" true
    (Sources.counterpart_selection_may_overlap ~original:(Sources.select_counterparts first)
       ~candidate:(Sources.select_counterparts same_id_at_other_offset));
  let repeated ~after = match Sources.counterpart_snapshot_to_json first with
    | `Assoc fields ->
      let log = match List.assoc "external_log" fields with
        | `List [event] -> `List [event;event]
        | _ -> Alcotest.fail "fixture must retain one external event" in
      `Assoc (List.map (fun (key,value) -> key,
        if key="external_log" then log
        else if key="external_after" then `Int after
        else if key="external_through" then `Int 2
        else value) fields) |> Sources.counterpart_snapshot_of_json |> get
    | _ -> Alcotest.fail "fixture must retain a snapshot object" in
  let both = repeated ~after:0 and second = repeated ~after:1 in
  Alcotest.(check bool) "identical event items have identical delivered projections" true
    (Sources.counterpart_observations first=Sources.counterpart_observations second);
  Alcotest.(check bool) "the same first append remains a valid witness" true
    (covers ~original:first ~witness:both);
  Alcotest.(check bool) "a later identical append cannot stand in for the first" false
    (covers ~original:first ~witness:second);
  Alcotest.(check bool) "the repeated event still retains possible partial evidence" true
    (Sources.counterpart_selection_may_overlap ~original:(Sources.select_counterparts first)
       ~candidate:(Sources.select_counterparts second));
  (match record ~base_path (item ~keeper_name ~dedupe_key:"other-event"
     ~external_message:(external_message "same-message") ~received_at:1.5 ()) with
   | `Recorded -> () | `Duplicate _ -> Alcotest.fail "unexpected second delivery duplicate"
   | `Error detail -> Alcotest.fail detail);
  let other_delivery = Sources.capture_counterparts ~external_after:1 ~base_dir:base_path ~keeper_name
      ~after:None ~before:2. |> Result.map_error Sources.read_error_to_string |> get in
  Alcotest.(check bool) "a different external event is not a complete witness" false
    (covers ~original:first ~witness:other_delivery);
  Alcotest.(check bool) "external events with the same delivery identity may overlap" true
    (Sources.counterpart_selection_may_overlap ~original:(Sources.select_counterparts first)
       ~candidate:(Sources.select_counterparts other_delivery))
;;

let test_cursor_observation_preserves_complete_preparation () =
  with_temp_base "keeper-cursor-observation" @@ fun base_path ->
  let module Cursor = Masc.Keeper_external_read_cursor in
  let module Current = Masc.Keeper_memory_os_current in
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let runtime_keepers_dir = Filename.concat base_path "runtime" in
  let memory_keepers_dir = Filename.concat base_path "memory" in
  let keeper_name = "observation-owner" in
  let cursor_path = Cursor.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name in
  let missing = Cursor.observe ~runtime_keepers_dir ~keeper_name |> get in
  Alcotest.(check int) "missing observation starts at zero" 0 (Cursor.observation_offset missing);
  Alcotest.(check bool) "observation creates no cursor" false (Sys.file_exists cursor_path);
  let atom : Current.durable_range_id =
    {receipt_scope=runtime_keepers_dir;trace_id="observation-trace";history_start_boundary_line=1;
     start_atom=0;end_atom=1;last_atom_digest=String.make 64 'a';end_boundary_line=2;
     boundary_lines_seen=2;unread_messages=[]} in
  let official : Current.official_range_id =
    {receipt_scope=runtime_keepers_dir;after_boundary_line=0;
     turns=[1,Ids.Turn_ref.make ~trace_id:"official-observation" ~absolute_turn:1];unread_messages=[]} in
  let token = Cursor.read ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name |> get in
  Cursor.prepare ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name token
    ~through:2 ~atom:(Some atom) ~official:(Some official) |> get;
  let original = Fs_compat.load_file cursor_path in
  let observation = Cursor.observe ~runtime_keepers_dir ~keeper_name |> get in
  let json = Cursor.observation_to_json observation in
  let restored = Cursor.observation_of_json json |> get in
  Alcotest.(check bool) "both original receipt identities survive the strict codec" true
    (Cursor.observation_matches_preparation restored ~after:0 ~through:2 ~atom:(Some atom) ~official:(Some official));
  Alcotest.(check bool) "different original receipt is not the same preparation" false
    (Cursor.observation_matches_preparation restored ~after:0 ~through:2 ~atom:(Some {atom with end_atom=2}) ~official:(Some official));
  Alcotest.(check string) "observation neither acknowledges nor rewrites" original (Fs_compat.load_file cursor_path);
  Cursor.acknowledge ~runtime_keepers_dir ~keeper_name |> get;
  Alcotest.(check int) "stored observation remains at the original offset after later ACK" 0
    (Cursor.observation_offset restored);
  Alcotest.(check bool) "original complete pending state is stable after later ACK" true
    (Yojson.Safe.equal json (Cursor.observation_to_json restored));
  let refused value = match Cursor.observation_of_json value with
    | Error _ -> () | Ok _ -> Alcotest.fail "malformed cursor observation accepted" in
  (match json with
   | `Assoc fields ->
     refused (`Assoc (("after",`Int 0)::fields));
     refused (`Assoc (("unknown",`Null)::fields));
     refused (`Assoc (List.map (fun (key,value) -> key, if key="pending" then
       `Assoc ["through",`Int 2;"atom",`Null;"official",`Null] else value) fields))
   | _ -> Alcotest.fail "cursor observation envelope missing")
;;

let test_prescan_refuses_selectable_over_capacity_before_tail () =
  with_temp_base "keeper-counterpart-capacity-malformed" @@ fun base_path ->
  let module Sources = Masc.Keeper_librarian_input_sources in
  let keeper_name = "capacity-malformed" in
  let path = A.attention_path ~base_path ~keeper_name in
  (* 4200 selectable rows followed by garbage: the prescan must refuse on the
     row cap before reaching the tail, so no decode error surfaces. *)
  let valid i =
    item ~keeper_name ~dedupe_key:(Printf.sprintf "cap-valid-%d" i) ~received_at:10. ()
    |> fun it -> Yojson.Safe.to_string (A.event_to_json (A.Recorded it)) ^ "\n"
  in
  let garbage = String.make 120 'x' ^ "\n" in
  let lines = Buffer.create (4 * 1024 * 1024) in
  for i = 1 to 4200 do Buffer.add_string lines (valid i) done;
  for _ = 1 to 100 do Buffer.add_string lines garbage done;
  write_file path (Buffer.contents lines);
  match Sources.capture_counterparts ~external_after:0 ~base_dir:base_path ~keeper_name ~after:None ~before:20. with
  | Ok _ -> Alcotest.fail "over-capacity backlog with malformed tail was captured"
  | Error
      (Sources.Counterpart_backlog_over_capacity
        { path = _; rows_past_cursor; bytes_past_cursor; row_cap; byte_cap }) ->
    Alcotest.(check bool) "rows past cursor exceed row cap" true (rows_past_cursor > row_cap);
    Alcotest.(check bool) "bytes past cursor counted" true (bytes_past_cursor > 0);
    Alcotest.(check int) "row cap" 4096 row_cap;
    Alcotest.(check int) "byte cap" 1048576 byte_cap
  | Error error ->
    Alcotest.failf "prescan did not fire before the tail: %s" (Sources.read_error_to_string error)

let test_selection_refuses_rows_over_bytes_unmeasured () =
  with_temp_base "keeper-counterpart-capacity-selection" @@ fun base_path ->
  let module Sources = Masc.Keeper_librarian_input_sources in
  let module Chat = Masc.Keeper_chat_store in
  let keeper_name = "capacity-selection" in
  (* One small external event: the prescan passes and the strict load runs. *)
  (match record ~base_path
           (item ~keeper_name ~dedupe_key:"cap-sel-one" ~received_at:5. ()) with
   | `Recorded -> ()
   | `Duplicate _ -> Alcotest.fail "unexpected selection duplicate"
   | `Error detail -> Alcotest.fail detail);
  (* 4097 chat rows: the combined selection passes the row cap while the
     external backlog stays tiny, so the post-selection backstop refuses
     on row count alone and bytes are never measured. *)
  let row i =
    `Assoc
      [ "id", `String (Printf.sprintf "cap-chat-%d" i)
      ; "role", `String "user"
      ; "content", `String "c"
      ; "ts", `Float 10.
      ; "speaker_id", `String "speaker"
      ; "speaker_name", `String "Speaker"
      ; "speaker_authority", `String "external"
      ]
    |> Yojson.Safe.to_string
  in
  let lines = Buffer.create (900 * 1024) in
  for i = 1 to 4097 do
    Buffer.add_string lines (row i);
    Buffer.add_char lines '\n'
  done;
  write_file (Chat.chat_path ~base_dir:base_path ~keeper_name) (Buffer.contents lines);
  match Sources.capture_counterparts ~external_after:0 ~base_dir:base_path ~keeper_name ~after:None ~before:20. with
  | Ok _ -> Alcotest.fail "rows-over selection was captured"
  | Error (Sources.Counterpart_selection_over_capacity { rows; bytes; row_cap; byte_cap }) ->
    Alcotest.(check bool) "selected rows exceed row cap" true (rows > row_cap);
    Alcotest.(check bool) "bytes were never measured" true (Option.is_none bytes);
    Alcotest.(check int) "row cap" 4096 row_cap;
    Alcotest.(check int) "byte cap" 1048576 byte_cap
  | Error error ->
    Alcotest.failf "wrong refusal for rows-over selection: %s" (Sources.read_error_to_string error)

let test_prescan_refuses_bytes_over_rows_under_backlog () =
  with_temp_base "keeper-counterpart-capacity-bytes" @@ fun base_path ->
  let module Sources = Masc.Keeper_librarian_input_sources in
  let keeper_name = "capacity-bytes" in
  let path = A.attention_path ~base_path ~keeper_name in
  (* 100 fat but decodable rows: past the byte cap on the rendered
     projection while staying under the row cap. *)
  let fat i =
    item ~keeper_name ~dedupe_key:(Printf.sprintf "cap-fat-%d" i) ~received_at:10.
      ~preview:(String.make 20000 'z') ()
    |> fun it -> Yojson.Safe.to_string (A.event_to_json (A.Recorded it)) ^ "\n"
  in
  let lines = Buffer.create (3 * 1024 * 1024) in
  for i = 1 to 100 do Buffer.add_string lines (fat i) done;
  write_file path (Buffer.contents lines);
  match Sources.capture_counterparts ~external_after:0 ~base_dir:base_path ~keeper_name ~after:None ~before:20. with
  | Ok _ -> Alcotest.fail "bytes-over backlog was captured"
  | Error
      (Sources.Counterpart_backlog_over_capacity
        { path = _; rows_past_cursor; bytes_past_cursor; row_cap; byte_cap }) ->
    Alcotest.(check bool) "bytes past cursor exceed byte cap" true (bytes_past_cursor > byte_cap);
    Alcotest.(check bool) "rows stay under row cap" true (rows_past_cursor <= row_cap)
  | Error error ->
    Alcotest.failf "wrong refusal for bytes-over backlog: %s" (Sources.read_error_to_string error)

let test_at_cap_backlog_reaches_strict_reader () =
  with_temp_base "keeper-counterpart-capacity-boundary" @@ fun base_path ->
  let module Sources = Masc.Keeper_librarian_input_sources in
  let keeper_name = "capacity-boundary" in
  let path = A.attention_path ~base_path ~keeper_name in
  let valid i =
    item ~keeper_name ~dedupe_key:(Printf.sprintf "cap-at-%d" i) ~received_at:10. ~preview:"c" ()
    |> fun it -> Yojson.Safe.to_string (A.event_to_json (A.Recorded it)) ^ "\n"
  in
  (* Blank lines ride along: both the prescan and the strict loader skip
     them, so cursor offsets stay aligned. *)
  let write_rows count =
    let lines = Buffer.create (count * 500) in
    for i = 1 to count do
      Buffer.add_string lines (valid i);
      if i mod 100 = 0 then Buffer.add_char lines '\n'
    done;
    write_file path (Buffer.contents lines)
  in
  let capture () =
    Sources.capture_counterparts ~external_after:0 ~base_dir:base_path ~keeper_name ~after:None ~before:20.
  in
  (* Exactly 4096 selectable rows is within cap: the prescan passes and the
     capture succeeds (the chat store was never written, which reads as no
     chat rows). *)
  write_rows 4096;
  (match capture () with
  | Ok snapshot ->
    Alcotest.(check int)
      "at-cap capture selects every row" 4096
      (List.length (Sources.counterpart_observations snapshot))
  | Error error ->
    Alcotest.failf "prescan refused an exactly-at-cap backlog: %s" (Sources.read_error_to_string error));
  (* One more row trips the prescan. *)
  write_rows 4097;
  (match capture () with
  | Ok _ -> Alcotest.fail "rows-over backlog was captured"
  | Error (Sources.Counterpart_backlog_over_capacity _) -> ()
  | Error error ->
    Alcotest.failf "prescan did not fire past the cap: %s" (Sources.read_error_to_string error))

let test_post_before_backlog_does_not_block_selection () =
  with_temp_base "keeper-counterpart-capacity-post-before" @@ fun base_path ->
  let module Sources = Masc.Keeper_librarian_input_sources in
  let keeper_name = "capacity-post-before" in
  let path = A.attention_path ~base_path ~keeper_name in
  (* 10 selectable rows followed by 5000 rows past [before]: rows this pass
     cannot select must not trip the prescan, so a lagging Keeper keeps
     draining its backlog turn by turn. *)
  let row i received_at =
    item ~keeper_name ~dedupe_key:(Printf.sprintf "cap-pb-%d" i) ~received_at ~preview:"c" ()
    |> fun it -> Yojson.Safe.to_string (A.event_to_json (A.Recorded it)) ^ "\n"
  in
  let lines = Buffer.create (3 * 1024 * 1024) in
  for i = 1 to 10 do Buffer.add_string lines (row i 10.) done;
  for i = 11 to 5010 do Buffer.add_string lines (row i 30.) done;
  write_file path (Buffer.contents lines);
  Alcotest.(check bool)
    "fixture exceeds the prescan fast path" true
    ((Unix.stat path).st_size > 262144);
  match Sources.capture_counterparts ~external_after:0 ~base_dir:base_path ~keeper_name ~after:None ~before:20. with
  | Ok snapshot ->
    Alcotest.(check int)
      "only rows within the window are selected" 10
      (List.length (Sources.counterpart_observations snapshot))
  | Error error ->
    Alcotest.failf "post-before rows blocked selection: %s" (Sources.read_error_to_string error)

let test_torn_tail_fails_open_to_strict_reader () =
  with_temp_base "keeper-counterpart-capacity-torn-tail" @@ fun base_path ->
  let module Sources = Masc.Keeper_librarian_input_sources in
  let keeper_name = "capacity-torn-tail" in
  let path = A.attention_path ~base_path ~keeper_name in
  (* 700 small rows plus a torn final fragment without a trailing newline:
     the prescan must fail open so the strict loader reports the torn tail
     authoritatively instead of a capacity refusal. *)
  let row i =
    item ~keeper_name ~dedupe_key:(Printf.sprintf "cap-tt-%d" i) ~received_at:10. ~preview:"c" ()
    |> fun it -> Yojson.Safe.to_string (A.event_to_json (A.Recorded it)) ^ "\n"
  in
  let lines = Buffer.create (512 * 1024) in
  for i = 1 to 700 do Buffer.add_string lines (row i) done;
  Buffer.add_string lines "{";
  write_file path (Buffer.contents lines);
  Alcotest.(check bool)
    "fixture exceeds the prescan fast path" true
    ((Unix.stat path).st_size > 262144);
  match Sources.capture_counterparts ~external_after:0 ~base_dir:base_path ~keeper_name ~after:None ~before:20. with
  | Ok _ -> Alcotest.fail "torn tail backlog was captured"
  | Error (Sources.Counterpart_backlog_over_capacity _) ->
    Alcotest.fail "prescan refused a torn tail instead of failing open"
  | Error (Sources.External_attention_unreadable _) -> ()
  | Error error ->
    Alcotest.failf "wrong error for torn tail: %s" (Sources.read_error_to_string error)

let () =
  Alcotest.run "keeper_external_attention"
    [
      ( "json",
        [ Alcotest.test_case "surface/item/event roundtrip" `Quick test_json_roundtrip ]
      );
      ( "store",
        [
          Alcotest.test_case "counterpart capture preserves original rows and out-of-range dedup identities" `Quick
            test_counterpart_capture_retains_original_rows_and_dedup_frontier;
          Alcotest.test_case "counterpart witness requires the selected source" `Quick
            test_counterpart_witness_requires_selected_source_identity;
          Alcotest.test_case "counterpart witness requires source order and multiplicity" `Quick
            test_counterpart_witness_requires_order_and_multiplicity;
          Alcotest.test_case "counterpart witness distinguishes repeated external occurrences" `Quick
            test_counterpart_witness_distinguishes_external_occurrences;
          Alcotest.test_case "read-only cursor capture preserves complete original preparation" `Quick
            test_cursor_observation_preserves_complete_preparation;
          Alcotest.test_case "external cursor recovers only its committed Memory receipt" `Quick
            (test_external_cursor_recovers_memory_receipt ~with_unread:false);
          Alcotest.test_case "external cursor archives unread evidence before receipt acknowledgement" `Quick
            (test_external_cursor_recovers_memory_receipt ~with_unread:true);
          Alcotest.test_case "counterpart cursor keeps admission order" `Quick
            test_counterpart_cursor_keeps_admission_order;
          Alcotest.test_case "counterpart cursor stops at the range end" `Quick
            test_counterpart_cursor_stops_at_range_end;
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
      ( "capacity",
        [ Alcotest.test_case "prescan refuses selectable over-capacity backlog before the tail" `Quick
            test_prescan_refuses_selectable_over_capacity_before_tail;
          Alcotest.test_case "rows-over selection refuses with bytes unmeasured" `Quick
            test_selection_refuses_rows_over_bytes_unmeasured;
          Alcotest.test_case "bytes-over backlog refuses while rows stay under cap" `Quick
            test_prescan_refuses_bytes_over_rows_under_backlog;
          Alcotest.test_case "at-cap backlog reaches the strict reader" `Quick
            test_at_cap_backlog_reaches_strict_reader;
          Alcotest.test_case "post-before backlog does not block selection" `Quick
            test_post_before_backlog_does_not_block_selection;
          Alcotest.test_case "torn tail fails open to the strict reader" `Quick
            test_torn_tail_fails_open_to_strict_reader;
        ] );
    ]
