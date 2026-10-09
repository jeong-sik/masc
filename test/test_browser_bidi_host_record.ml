(** The record a BiDi host keeps of itself, as its readers meet it: the four
    states the TUI and [masc doctor] tell apart, the layout they refuse when
    it is not the one they know, and what the host's side may and may not put
    in it. *)

open Alcotest
module Record = Masc.Browser_bidi_host_record
module Peer = Masc.Browser_bidi_peer
module Status = Masc.Browser_bidi_host_status

(* What masc doctor says of the BiDi host for this workspace, and how it
   rates it. The doctor is another process than the host, as this one is. *)
let doctor base =
  let observed = Onboarding_status.inspect ~base_path:(Some base) in
  match
    List.find_opt
      (fun (c : Onboarding_status.check) -> c.id = Onboarding_status.Browser_bidi_host)
      observed.Onboarding_status.checks
  with
  | Some found -> found.condition, found.message
  | None -> fail "the doctor says nothing of the BiDi host"

(* This executable is also the second process of the lock case: started with
   this argument it takes the record as a host does, says so, and holds it
   until its standard input closes. *)
let holder_argument = "--hold-the-host-record"
let held_marker = "held"
let attached_marker = "attached"
let address = "ws://127.0.0.1:9222/session"

(* How long the reader waits for the other process to say a line. *)
let holder_line_window_sec = 30.

let client raw =
  match Browser_lane.client_id_of_string raw with
  | Ok id -> id
  | Error code -> failwith (raw ^ ": " ^ code)

let first_client = client "0199c0de-0000-7000-8000-000000000001"
let renewed_client = client "0199c0de-0000-7000-8000-000000000002"

let hold base_path =
  match
    Record.take ~base_path ~pid:(Unix.getpid ()) ~bidi_url:address ~client_id:first_client
      ~now:1_791_000_000.
  with
  | Error refusal ->
    print_endline (Record.refusal_message refusal);
    exit 3
  | Ok { held; not_synced = _ } ->
    print_endline held_marker;
    (match In_channel.input_line stdin with
     | Some _ ->
       (match Record.attached held ~now:1_791_000_005. with
        | Ok () -> print_endline attached_marker
        | Error failure -> print_endline (Record.write_failure_message failure));
       ignore (In_channel.input_all stdin : string)
     | None -> ())

let with_workspace f =
  let base = Filename.temp_dir "masc-bidi-host-record-" "" in
  let lane = List.fold_left Filename.concat base [ ".masc"; "browser-lane" ] in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists lane then (
        Unix.chmod lane 0o700;
        Array.iter (fun name -> Sys.remove (Filename.concat lane name)) (Sys.readdir lane));
      List.iter
        (fun dir -> if Sys.file_exists dir then Sys.rmdir dir)
        [ lane; Filename.concat base ".masc"; base ])
    (fun () -> f ~base ~lane)

let first_request = "0199c0de-0000-4000-8000-0000000000a1"

let noted : Record.unacknowledged =
  { request_id = Record.request_id_of_wire first_request
  ; verb = Some Peer.Page_interact
  ; outcome = Record.Unknown
  ; cause = Record.Unconfirmed
  ; at = 1_791_000_030.
  }

let entry : Record.entry =
  { pid = 4242
  ; started_at = 1_791_000_000.
  ; bidi_url = address
  ; client_id = first_client
  ; attached_at = Some 1_791_000_002.
  ; unacknowledged = []
  ; ended = None
  }

let ending : Record.ending =
  { at = 1_791_000_060.; reason = "stopped by SIGINT"; session = Record.No_session_left }

let test_an_entry_reads_back_as_written () =
  List.iter
    (fun (name, written) ->
      check bool name true (Record.entry_of_json (Record.entry_to_json written) = Ok written))
    [ "attached", entry
    ; "still connecting", { entry with attached_at = None }
    ; "polling as an ID a host made", { entry with client_id = Random_id.uuid_v7_value () }
    ; "ended", { entry with ended = Some ending }
    ; "ended with its session left", { entry with ended = Some { ending with session = Session_left } }
    ; ( "ended without knowing of its session"
      , { entry with ended = Some { ending with session = Session_unknown } } )
    ; ( "ended because Firefox refused it a session"
      , { entry with attached_at = None; ended = Some { ending with session = Session_refused } } )
    ; ( "with results nothing acknowledged"
      , { entry with
          unacknowledged =
            [ noted
            ; { noted with outcome = Succeeded; cause = Refused; verb = Some Peer.Tabs_list }
            ; { noted with outcome = Not_started; cause = Not_sent; request_id = None; verb = None }
            ]
        } )
    ]

let all_verbs =
  Peer.[ Browser_info; Tabs_list; Page_read; Page_elements; Page_capture; Page_scene; Page_interact ]

let test_a_verb_is_read_by_the_name_it_was_written_under () =
  List.iter
    (fun verb ->
      let name = Peer.verb_to_wire verb in
      check bool name true (Peer.verb_of_wire name = Some verb))
    all_verbs;
  check bool "a name no verb has" true (Peer.verb_of_wire "page.teleport" = None)

let test_a_request_is_named_only_by_the_uuid_the_server_issues () =
  check (option string) "a UUID is kept, and reads back as the text it was" (Some first_request)
    (Option.map Record.request_id_to_wire (Record.request_id_of_wire first_request));
  check bool "anything else is not" true (Record.request_id_of_wire "https://example.test/private" = None);
  check bool "nor a UUID with more behind it" true
    (Record.request_id_of_wire (first_request ^ "?to=private") = None);
  match Record.entry_to_json { entry with unacknowledged = [ noted ] } with
  | `Assoc fields ->
    (match List.assoc "unacknowledged" fields with
     | `List [ `Assoc one ] ->
       check bool "and is written as it was issued" true (List.assoc "request_id" one = `String first_request)
     | _ -> fail "one result was written")
  | _ -> fail "not an object"

let fields_of json = match json with `Assoc fields -> fields | _ -> fail "not an object"
let replaced name value fields = (name, value) :: List.remove_assoc name fields

(* A reader that met a field it does not know, or missed one it does, would
   be describing a host from part of what was written about it. *)
let test_a_layout_this_reader_does_not_know_is_refused () =
  let fields = fields_of (Record.entry_to_json { entry with unacknowledged = [ noted ]; ended = Some ending }) in
  let refusal name json =
    match Record.entry_of_json json with
    | Error detail -> detail
    | Ok _ -> failf "%s was read as a record" name
  in
  let refused name json = ignore (refusal name json : string) in
  refused "a field more" (`Assoc (("heartbeat_at", `String "2026-10-08T00:00:00Z") :: fields));
  List.iter
    (fun (missing, _) -> refused ("no " ^ missing) (`Assoc (List.remove_assoc missing fields)))
    fields;
  refused "a pid that is none" (`Assoc (replaced "pid" (`Int 0) fields));
  refused "a time that is none" (`Assoc (replaced "started_at" (`String "yesterday") fields));
  refused "not an object" (`List []);
  (* Another layout is named as that, whatever fields it has. *)
  List.iter
    (fun (name, other) ->
      check string name "written as layout 2; this reader knows 1" (refusal name (`Assoc other)))
    [ "another layout with these fields", replaced "schema" (`Int 2) fields
    ; ( "another layout with other fields"
      , ("heartbeat_at", `Null) :: List.remove_assoc "pid" (replaced "schema" (`Int 2) fields) )
    ];
  let noted_fields =
    match List.assoc "unacknowledged" fields with
    | `List [ one ] -> fields_of one
    | _ -> fail "one result was written"
  in
  let with_noted change = `Assoc (replaced "unacknowledged" (`List [ `Assoc (change noted_fields) ]) fields) in
  (* Verbs are added without the layout changing. One added after this
     reader was built costs it the verb's name, not the record. *)
  (match Record.entry_of_json (with_noted (replaced "verb" (`String "page.teleport"))) with
   | Ok { unacknowledged = [ { verb = None; _ } ]; pid; _ } -> check int "the rest is read" entry.pid pid
   | Ok _ -> fail "a verb added later was read as one this build knows"
   | Error detail -> failf "a verb added later cost the whole record: %s" detail);
  refused "a verb that is no name" (with_noted (replaced "verb" (`Int 3)));
  refused "a request ID that is no UUID" (with_noted (replaced "request_id" (`String "r1")));
  refused "a cause this reader does not know" (with_noted (replaced "cause" (`String "lost")));
  refused "an outcome this reader does not know" (with_noted (replaced "outcome" (`String "maybe")));
  refused "a result with a field more" (with_noted (fun noted -> ("why", `String "because") :: noted));
  let with_ending change =
    `Assoc (replaced "ended" (`Assoc (change (fields_of (List.assoc "ended" fields)))) fields)
  in
  refused "a session fate this reader does not know"
    (with_ending (replaced "session_in_firefox" (`String "closed")));
  refused "an ending that says whether, not what" (with_ending (replaced "session_in_firefox" (`Bool true)));
  (* What a host never writes is not read as its word: the reason goes on to
     an operator and to a model, the address and the client ID to a screen. *)
  List.iter
    (fun (name, reason) -> refused name (with_ending (replaced "reason" (`String reason))))
    [ "a reason with a line break", "stopped\nNo BiDi browser host is running"
    ; "a reason with a terminal escape", "stopped \027[2J"
    ; "a reason that is not ASCII", "stopped \xff\xfe"
    ; "a reason longer than a host keeps", String.make 516 'a'
    (* A host writes a backslash only as the start of [\xNN]. *)
    ; "a reason with a bare backslash", {|could not read C:\temp|}
    ; "a reason that ends in a backslash", {|stopped \|}
    ; "a reason with a lower-case mark", {|stopped \x5c|}
    ; "a reason with a lower-case first digit", {|stopped \xaF|}
    ; "a reason with a mark cut short", {|stopped \x5|}
    ; "a reason with a mark whose first digit is not hex", {|stopped \xgA|}
    ; "a reason with a mark whose second digit is not hex", {|stopped \x0Z|}
    ; "a reason with a mark for a byte a host writes as it is", {|stopped \x41|}
    ; "a reason with a mark cut by the length mark", String.make 509 'a' ^ {|\x5...|}
    ];
  List.iter
    (fun (name, reason) ->
      match Record.entry_of_json (with_ending (replaced "reason" (`String reason))) with
      | Ok _ -> ()
      | Error detail -> failf "%s was refused: %s" name detail)
    [ "a reason cut at the limit", String.make 512 'a' ^ "..."
    ; "a reason with the marks a host writes", {|status line: \xFF\x0A\x5Cx41|}
    ; "a reason cut after a mark", String.make 508 'a' ^ {|\x5C...|}
    ];
  List.iter
    (fun (name, url) -> refused name (`Assoc (replaced "bidi_url" (`String url) fields)))
    [ "an address with a query", address ^ "?token=x"
    ; "an address with a password", "ws://operator:secret@127.0.0.1:9222/session"
    ; "an address on another machine", "ws://203.0.113.7:9222/session"
    ; "an address with a line break", address ^ "\nmore"
    (* The URI parser raises on this host instead of answering. The reader
       still answers, with a refusal. *)
    ; "an address whose host is a number no machine has", "ws://127.0.0.99999999999999999999:9222/session"
    ];
  refused "a client ID that is no lane client ID" (`Assoc (replaced "client_id" (`String "holder-client") fields));
  (* A reason longer than the limit is one the host cut, and it marks the cut. *)
  List.iter
    (fun (name, reason) -> refused name (with_ending (replaced "reason" (`String reason))))
    [ "a reason one byte past the limit", String.make 513 'a'
    ; "a reason as long as a cut one, with no mark", String.make 515 'a'
    ]

(* A time read from the record is written back as the text it was read from.
   Cut instead of rounded, about half of all millisecond values lost one
   millisecond each time the record went through a reader and a writer. *)
let test_a_time_is_written_back_as_it_was_read () =
  let text_of json = Yojson.Safe.to_string json in
  for millisecond = 0 to 999 do
    let at = 1_791_000_000. +. (float_of_int millisecond /. 1000.) in
    let written = Record.entry_to_json { entry with started_at = at; attached_at = Some at } in
    match Record.entry_of_json written with
    | Error detail -> failf "millisecond %d was not read back: %s" millisecond detail
    | Ok read ->
      if text_of (Record.entry_to_json read) <> text_of written
      then failf "millisecond %d changed on its way through: %s" millisecond (text_of (Record.entry_to_json read))
  done;
  (* A time between two milliseconds goes to the nearer one. *)
  let started_at json = match json with
    | `Assoc fields -> List.assoc "started_at" fields
    | _ -> fail "not an object" in
  check bool "rounded to the nearest millisecond" true
    (started_at (Record.entry_to_json { entry with started_at = 1_791_000_000.1239 })
     = `String "2026-10-03T04:00:00.124Z"
     && started_at (Record.entry_to_json { entry with started_at = 1_791_000_000.1232 })
        = `String "2026-10-03T04:00:00.123Z")

let state = testable (Fmt.of_to_string (function
  | Record.Never_started -> "never started"
  | Record.Running entry -> Printf.sprintf "running pid %d" entry.pid
  | Record.Ended (entry, ending) -> Printf.sprintf "ended pid %d: %s" entry.pid ending.reason
  | Record.Died entry -> Printf.sprintf "died pid %d" entry.pid
  | Record.Unreadable { detail; held } ->
    Printf.sprintf "unreadable (%s): %s"
      (match held with Some true -> "held" | Some false -> "not held" | None -> "lock unknown") detail))
  ( = )

let said = Fmt.to_to_string (pp state)

let test_what_a_record_and_its_lock_say () =
  let ended = { entry with ended = Some ending } in
  check state "no record" Record.Never_started (Record.state_of ~lock_held:false (Ok None));
  (* With no record the lock is not asked: [observe] answers this row with
     no lock at all, and a host that has taken the lock and not yet written
     its first record reads as none. A second host is still refused by the
     lock. *)
  check state "no record, and a host holds the lock" Record.Never_started
    (Record.state_of ~lock_held:true (Ok None));
  check state "a record and its lock" (Record.Running entry) (Record.state_of ~lock_held:true (Ok (Some entry)));
  check state "a record nobody holds" (Record.Died entry) (Record.state_of ~lock_held:false (Ok (Some entry)));
  check state "an ending" (Record.Ended (ended, ending)) (Record.state_of ~lock_held:false (Ok (Some ended)));
  (* The host has written its ending and not yet exited. *)
  check state "an ending whose host still holds the lock" (Record.Ended (ended, ending))
    (Record.state_of ~lock_held:true (Ok (Some ended)));
  (* A record nobody can read still says whether a host holds the workspace:
     one that does refuses the next host, which then cannot replace it. *)
  check state "a record that cannot be read, under a host"
    (Record.Unreadable { detail = "torn"; held = Some true })
    (Record.state_of ~lock_held:true (Error "torn"));
  check state "a record that cannot be read, with no host"
    (Record.Unreadable { detail = "torn"; held = Some false })
    (Record.state_of ~lock_held:false (Error "torn"))

let start_holder base =
  let from_holder, holder_out = Unix.pipe ~cloexec:true () in
  let holder_in, to_holder = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process Sys.executable_name [| Sys.executable_name; holder_argument; base |]
      holder_in holder_out Unix.stderr
  in
  Unix.close holder_out;
  Unix.close holder_in;
  pid, from_holder, Unix.out_channel_of_descr to_holder

(* The holder says one line at a time and waits to be told before the next,
   so a line is whole once the pipe is readable. *)
let holder_line from_holder =
  match Unix.select [ from_holder ] [] [] holder_line_window_sec with
  | [], _, _ -> fail "the holding process said nothing in time"
  | _ ->
    let bytes = Bytes.create 256 in
    let length = Unix.read from_holder bytes 0 (Bytes.length bytes) in
    String.trim (Bytes.sub_string bytes 0 length)

let take ?(bidi_url = address) ?(client_id = entry.client_id) ~pid base =
  Record.take ~base_path:base ~pid ~bidi_url ~client_id ~now:entry.started_at

let taken ?bidi_url ?client_id ~pid base =
  match take ?bidi_url ?client_id ~pid base with
  | Ok { held; not_synced = None } -> held
  | Ok { not_synced = Some detail; _ } -> fail detail
  | Error refusal -> fail (Record.refusal_message refusal)

let written = function
  | Ok () -> ()
  | Error failure -> fail (Record.write_failure_message failure)

let released held =
  match Record.release held with
  | Ok () -> ()
  | Error detail -> fail detail

let on_disk lane =
  match Yojson.Safe.from_file (Filename.concat lane "bidi-host.json") |> Record.entry_of_json with
  | Ok read -> read
  | Error detail -> fail detail

(* The reader in one process, the host's own writer in another. *)
let test_a_reader_follows_a_host_from_start_to_death () =
  with_workspace @@ fun ~base ~lane ->
  check string "the path a reader names is the file the host writes"
    (Filename.concat lane "bidi-host.json") (Record.record_path ~base_path:base);
  check state "before any host" Record.Never_started (Record.observe ~base_path:base);
  let pid, from_holder, tell = start_holder base in
  let finish () =
    close_out_noerr tell;
    Unix.close from_holder;
    ignore (Unix.waitpid [] pid : int * Unix.process_status)
  in
  (match
     check string "the host took its record" held_marker (holder_line from_holder);
     (match Record.observe ~base_path:base with
      | Record.Running running ->
        check int "the record names the host" pid running.pid;
        check bool "which has no session yet" true (running.attached_at = None)
      | other -> failf "a host that holds its lock is %s" (said other));
     (let condition, message = doctor base in
      check bool "the doctor waits on a host that is connecting" true
        (condition = Onboarding_status.Needs_verification);
      check bool "and says so" true (String_util.contains_substring message "is connecting to"));
     (* A second host for the workspace, which this process stands in for. *)
     (match take ~pid:(Unix.getpid ()) ~bidi_url:"ws://127.0.0.1:9333/session" base with
      | Error (Record.Another_host named) -> check (option int) "it is told who holds it" (Some pid) named
      | Error (Record.Bad_address detail | Record.Unavailable detail) -> fail detail
      | Ok _ -> fail "a second host took a workspace that has one");
     output_string tell "attach\n";
     flush tell;
     check string "the host got its session" attached_marker (holder_line from_holder);
     (match Record.observe ~base_path:base with
      | Record.Running running -> check bool "the record says so" true (running.attached_at <> None)
      | other -> failf "an attached host is %s" (said other));
     (* With no server in this process, as for masc doctor. A host serves
        on the server that lists it, and none is observed here. *)
     (let condition, message = doctor base in
      check bool "outside a server the doctor does not vouch for an attached host" true
        (condition = Onboarding_status.Needs_verification);
      check bool "and names it" true
        (String_util.contains_substring message (Printf.sprintf "(pid %d) is attached to" pid));
      check bool "without a server it does not claim the host polls one" true
        (String_util.contains_substring message "not observed here"));
     check bool "the observation every reader answers from carries the same state" true
       (match (Status.observe ~base_path:base).record with
        | Record.Running _ -> true
        | Record.Never_started | Record.Ended _ | Record.Died _ | Record.Unreadable _ -> false);
     (* Asking needs no leave to write the lock file. *)
     let lock = Filename.concat lane "bidi-host.lock" in
     Unix.chmod lock 0o400;
     (match Record.observe ~base_path:base with
      | Record.Running _ -> Unix.chmod lock 0o600
      | other ->
        Unix.chmod lock 0o600;
        failf "a reader that may only read the lock file read %s" (said other))
   with
   | () -> finish ()
   | exception exn -> finish (); raise exn);
  (* The holder exited without an ending, as a killed host does. *)
  (match Record.observe ~base_path:base with
   | Record.Died dead -> check int "the host that died" pid dead.pid
   | other -> failf "a host that exited without an ending is %s" (said other));
  let condition, message = doctor base in
  check bool "the doctor asks for a host again" true (condition = Onboarding_status.Needs_setup);
  check bool "and says the last one died" true (String_util.contains_substring message "killed or crashed");
  (* This workspace has a record and no launcher, as after a host started
     from an executable on the PATH. *)
  check bool "and does not say to run a launcher that is not there" true
    (String_util.contains_substring message
       "No browser lane is installed in this workspace, so that launcher is not there yet")

(* What a process other than this one finds: it tries to take the workspace,
   as a second host would. Only another process sees the kernel's lock; this
   one is answered from its own list. *)
let held_as_seen_elsewhere base =
  let pid, from_holder, tell = start_holder base in
  let line = holder_line from_holder in
  close_out_noerr tell;
  Unix.close from_holder;
  match Unix.waitpid [] pid, line with
  | (_, Unix.WEXITED 3), said when String.starts_with ~prefix:"another BiDi host" said -> true
  | (_, Unix.WEXITED 0), said when String.equal said held_marker -> false
  | (_, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _)), said ->
    failf "the other process said %S" said

(* A lock belongs to its process: the holder's own test of it says "free" and
   a descriptor it closed would drop it. The process that holds a workspace
   is told so all the same, and keeps it. *)
let test_the_process_that_holds_a_workspace_is_told_so () =
  with_workspace @@ fun ~base ~lane:_ ->
  let held = taken ~pid:100 base in
  let running name =
    match Record.observe ~base_path:base with
    | Record.Running running -> check int name 100 running.pid
    | other -> failf "%s: the holder read %s" name (said other)
  in
  running "the holder reads its own host as running";
  running "and again, having looked once";
  (match take ~pid:200 base with
   | Error (Record.Another_host named) -> check (option int) "a second take here is refused" (Some 100) named
   | Error (Record.Bad_address detail | Record.Unavailable detail) -> fail detail
   | Ok _ -> fail "one process took a workspace twice");
  (* The same directory under another spelling is the same workspace. *)
  (match take ~pid:200 (Filename.concat base ".") with
   | Error (Record.Another_host _) -> ()
   | Error (Record.Bad_address detail | Record.Unavailable detail) -> fail detail
   | Ok _ -> fail "one process took a workspace twice under another spelling");
  (* macOS reaches the data volume under a second real path. The lock is on
     the file, whichever path names it. *)
  (let alias = "/System/Volumes/Data" ^ Unix.realpath base in
   if Sys.file_exists alias then (
     (match Record.observe ~base_path:alias with
      | Record.Running running -> check int "read under its other path" 100 running.pid
      | other -> failf "under its other path the holder read %s" (said other));
     match take ~pid:200 alias with
     | Error (Record.Another_host _) -> ()
     | Error (Record.Bad_address detail | Record.Unavailable detail) -> fail detail
     | Ok _ -> fail "one process took a workspace twice under its other path"));
  running "the holder still reads its host as running";
  (* A record that turns unreadable under a running host is said to be that,
     with the host still holding the workspace. *)
  (let file = Filename.concat (List.fold_left Filename.concat base [ ".masc"; "browser-lane" ]) "bidi-host.json" in
   let whole = In_channel.with_open_bin file In_channel.input_all in
   Out_channel.with_open_bin file (fun channel -> output_string channel "{\"schema\": 1");
   (match Record.observe ~base_path:base with
    | Record.Unreadable { held = Some true; _ } -> ()
    | other -> failf "an unreadable record under a host is %s" (said other));
   Out_channel.with_open_bin file (fun channel -> output_string channel whole));
  check bool "and none of that dropped the lock another process meets" true
    (held_as_seen_elsewhere base);
  released held;
  (match Record.observe ~base_path:base with
   | Record.Died dead -> check int "given up without an ending" 100 dead.pid
   | other -> failf "a host that gave the workspace up without an ending is %s" (said other));
  (match Record.attached held ~now:1_791_000_002. with
   | Error (Record.Not_written _) -> ()
   | Error (Record.Not_synced detail) -> fail detail
   | Ok () -> fail "a host wrote its record after giving the workspace up");
  released held;
  let next = taken ~pid:300 base in
  (match Record.observe ~base_path:base with
   | Record.Running running -> check int "the next host has it" 300 running.pid
   | other -> failf "the next host is %s" (said other));
  released next;
  check bool "given up, it is free to another process too" false (held_as_seen_elsewhere base)

let test_a_host_writes_its_ending_and_the_next_replaces_it () =
  with_workspace @@ fun ~base ~lane ->
  let first = taken ~pid:100 base in
  written (Record.attached first ~now:1_791_000_002.);
  written (Record.client_changed first ~client_id:renewed_client);
  let later = { noted with outcome = Succeeded; verb = None; request_id = None; at = 1_791_000_040. } in
  written (Record.note_unacknowledged first noted);
  written (Record.note_unacknowledged first later);
  written
    (Record.ended first ~reason:"stopped by SIGINT" ~session:Record.Session_left ~now:1_791_000_060.);
  let record = on_disk lane in
  check bool "the ID it polled as last" true (record.client_id = renewed_client);
  check bool "its ending" true
    (record.ended
     = Some { at = 1_791_000_060.; reason = "stopped by SIGINT"; session = Record.Session_left });
  check bool "the results nothing acknowledged, oldest first" true (record.unacknowledged = [ noted; later ]);
  check state "an ending is read as one while its host still holds the lock"
    (Record.Ended (record, Option.get record.ended)) (Record.observe ~base_path:base);
  released first;
  let second = taken ~pid:200 base in
  let replaced = on_disk lane in
  check int "the next host's record" 200 replaced.pid;
  check bool "has no ending" true (replaced.ended = None);
  check bool "and no session yet" true (replaced.attached_at = None);
  check bool "and nothing unacknowledged" true (replaced.unacknowledged = []);
  released second

(* The reason for ending is the one free sentence in the record, and it can
   quote what a peer sent. *)
let test_a_reason_is_written_as_printable_ascii () =
  with_workspace @@ fun ~base ~lane ->
  let reason_of said =
    let held = taken ~pid:100 base in
    written (Record.ended held ~reason:said ~session:Record.No_session_left ~now:1_791_000_060.);
    released held;
    let raw = In_channel.with_open_bin (Filename.concat lane "bidi-host.json") In_channel.input_all in
    String.iter (fun byte -> if byte > '~' then failf "the record holds the byte %C" byte) raw;
    (Option.get (on_disk lane).ended).reason
  in
  check string "a plain reason is itself" "stopped by SIGTERM" (reason_of "stopped by SIGTERM");
  check string "bytes that are not printable ASCII are named"
    "malformed status line: \\xFF\\xFE\\x0A\\x5Cx41" (reason_of "malformed status line: \xff\xfe\n\\x41");
  let long = reason_of (String.make 2000 'a') in
  check string "a long reason is cut and marked" (String.make 512 'a' ^ "...") long;
  let escaped = reason_of (String.make 600 '\xff') in
  check string "and is cut between bytes, not inside one" (String.concat "" (List.init 128 (fun _ -> "\\xFF")) ^ "...")
    escaped

let test_the_address_is_kept_without_what_it_could_carry () =
  with_workspace @@ fun ~base ~lane ->
  let held = taken ~pid:100 ~bidi_url:"ws://127.0.0.1:9222/session?token=not-for-the-record" base in
  check string "the query is left out" address (on_disk lane).bidi_url;
  released held;
  (* Whatever address a host is let in with, the record it writes is one the
     reader takes: a host whose own record read as unreadable would be told
     to be stopped. *)
  List.iter
    (fun bidi_url ->
      with_workspace @@ fun ~base ~lane:_ ->
      let held = taken ~pid:100 ~bidi_url base in
      (match Record.observe ~base_path:base with
       | Record.Running _ -> ()
       | other -> failf "a host let in with %s reads as %s" bidi_url (said other));
      released held)
    [ "ws://[::1]:9222/session"; "ws://localhost:9222/session"; "ws://LOCALHOST:9222/session"
    ; "ws://127.0.0.1:9222/"; "ws://127.0.0.1:9222/a%20b"; "ws://127.0.0.1:9222/session?"
    ; "ws://127.0.0.1:09222/session"; "ws://127.0.0.1:9222/session;token=x"
    ];
  with_workspace @@ fun ~base ~lane ->
  List.iter
    (fun (name, bidi_url) ->
      (match take ~pid:100 ~bidi_url base with
       | Error (Record.Bad_address _) -> ()
       | Error (Record.Another_host _) -> failf "%s: refused as a second host" name
       | Error (Record.Unavailable detail) -> fail detail
       | Ok _ -> failf "%s was taken as a BiDi address" name);
      check bool (name ^ ": nothing was written") false (Sys.file_exists lane))
    [ "an address with a password", "ws://operator:secret@127.0.0.1:9222/session"
    ; "an address on another machine", "ws://203.0.113.7:9222/session"
    ; "an address that is no WebSocket", "http://127.0.0.1:9222/session"
    (* The URI parser raises on this one. A host given it is refused like
       any other bad address, not ended by an exception. *)
    ; "an address whose host is a number no machine has", "ws://127.0.0.99999999999999999999:9222/session"
    ]

(* A lock that cannot be asked leaves a record without an ending unsaid: the
   host may run or be dead. It takes nothing from what does not turn on it. *)
let test_a_lock_that_cannot_be_asked_costs_only_what_turns_on_it () =
  if Unix.geteuid () = 0 then skip ()
  else
    with_workspace @@ fun ~base ~lane ->
    let lock = Filename.concat lane "bidi-host.lock" in
    let held = taken ~pid:100 base in
    released held;
    let unasked () =
      Unix.chmod lock 0o000;
      Fun.protect ~finally:(fun () -> Unix.chmod lock 0o600) (fun () -> Record.observe ~base_path:base)
    in
    (match unasked () with
     | Record.Unreadable { held = None; _ } -> ()
     | other -> failf "a record without an ending, its lock unasked, reads as %s" (said other));
    let again = taken ~pid:100 base in
    written (Record.ended again ~reason:"stopped by SIGINT" ~session:Record.No_session_left ~now:1_791_000_060.);
    released again;
    (match unasked () with
     | Record.Ended (_, { reason; _ }) -> check string "the ending is read all the same" "stopped by SIGINT" reason
     | other -> failf "a record with its ending, its lock unasked, reads as %s" (said other));
    Sys.remove (Filename.concat lane "bidi-host.json");
    check state "and so is the absence of a record" Record.Never_started (unasked ())

(* A host that cannot write its first record does not hold the workspace,
   and what its predecessor left is still there to read. *)
let test_a_host_that_cannot_write_its_record_leaves_the_last_one () =
  if Unix.geteuid () = 0 then skip ()
  else
    with_workspace @@ fun ~base ~lane ->
    let first = taken ~pid:100 base in
    written (Record.note_unacknowledged first noted);
    written (Record.ended first ~reason:"stopped by SIGINT" ~session:Record.No_session_left ~now:1_791_000_060.);
    released first;
    let left = on_disk lane in
    Unix.chmod lane 0o500;
    (match take ~pid:200 base with
     | Error (Record.Unavailable _) -> ()
     | Error (Record.Another_host _) -> fail "refused as a second host"
     | Error (Record.Bad_address detail) -> fail detail
     | Ok _ -> fail "a host took a workspace it cannot write to");
    check bool "the last host's record stands, with its results" true (on_disk lane = left);
    Unix.chmod lane 0o700;
    let next = taken ~pid:300 base in
    check int "and the workspace is free for the next host" 300 (on_disk lane).pid;
    released next

let () =
  match Array.to_list Sys.argv with
  | [ _; argument; base ] when String.equal argument holder_argument -> hold base
  | _ ->
    run "BiDi host record"
      [ ( "layout"
        , [ test_case "an entry reads back as written" `Quick test_an_entry_reads_back_as_written
          ; test_case "a verb is read by the name it was written under" `Quick
              test_a_verb_is_read_by_the_name_it_was_written_under
          ; test_case "a request is named only by the UUID the server issues" `Quick
              test_a_request_is_named_only_by_the_uuid_the_server_issues
          ; test_case "a layout this reader does not know is refused" `Quick
              test_a_layout_this_reader_does_not_know_is_refused
          ; test_case "a time is written back as it was read" `Quick
              test_a_time_is_written_back_as_it_was_read ] )
      ; ( "state"
        , [ test_case "what a record and its lock say" `Quick test_what_a_record_and_its_lock_say
          ; test_case "a reader follows a host from start to death" `Quick
              test_a_reader_follows_a_host_from_start_to_death
          ; test_case "the process that holds a workspace is told so" `Quick
              test_the_process_that_holds_a_workspace_is_told_so ] )
      ; ( "writer"
        , [ test_case "a host writes its ending and the next replaces it" `Quick
              test_a_host_writes_its_ending_and_the_next_replaces_it
          ; test_case "a reason is written as printable ASCII" `Quick
              test_a_reason_is_written_as_printable_ascii
          ; test_case "a lock that cannot be asked costs only what turns on it" `Quick
              test_a_lock_that_cannot_be_asked_costs_only_what_turns_on_it
          ; test_case "the address is kept without what it could carry" `Quick
              test_the_address_is_kept_without_what_it_could_carry
          ; test_case "a host that cannot write its record leaves the last one" `Quick
              test_a_host_that_cannot_write_its_record_leaves_the_last_one ] ) ]
