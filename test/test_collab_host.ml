(** Stack 3 tests for RFC-0471: server-side host sessions over an
    in-memory relay — hello/welcome/snapshot, live forward, run liveness,
    membership state, drops, and stop. Each test runs its own Eio switch
    with a capture send; keepers are distinct per test because the latest-op
    map is process-global. *)

open Alcotest

module Frame = Collab_frame
module Link = Collab_link
module Env = Collab_envelope
module Seal = Collab_seal
module Host = Server_collab_host
module Inject = Server_collab_inject
module Events = Masc.Keeper_chat_events
module Event_log = Masc.Keeper_chat_event_log

(* Default injector: no stack-3 path may reach the keeper registry. *)
let silent_injector =
  { Inject.submit_prompt =
      (fun ~base_dir:_ ~keeper:_ ~room:_ ~peer:_ ~label:_ ~text:_ ->
        fail "unexpected submit")
  ; Inject.abort_current =
      (fun ~base_dir:_ ~keeper:_ ~latest_op:_ -> fail "unexpected abort")
  ; Inject.fetch_transcript =
      (fun ~base_dir:_ ~keeper:_ ~max_bytes:_ -> fail "unexpected fetch")
  }
;;

type recorded =
  { mutable prompts : (int * string option * string) list
  ; mutable aborts : string option list
  ; mutable fetches : int list
  }

let recording_injector recorded
    ~on_prompt ~on_abort ~on_fetch : Inject.injector =
  { submit_prompt =
      (fun ~base_dir:_ ~keeper:_ ~room:_ ~peer ~label ~text ->
        recorded.prompts <- recorded.prompts @ [ (peer, label, text) ];
        on_prompt ~peer ~text)
  ; Inject.abort_current =
      (fun ~base_dir:_ ~keeper:_ ~latest_op ->
        recorded.aborts <- recorded.aborts @ [ latest_op ];
        on_abort ~latest_op)
  ; Inject.fetch_transcript =
      (fun ~base_dir:_ ~keeper:_ ~max_bytes ->
        recorded.fetches <- recorded.fetches @ [ max_bytes ];
        on_fetch ~max_bytes)
  }
;;

let fresh_recorded () = { prompts = []; aborts = []; fetches = [] }

let ok_injector recorded : Inject.injector =
  recording_injector recorded
    ~on_prompt:(fun ~peer:_ ~text:_ -> Ok "op-1")
    ~on_abort:(fun ~latest_op:_ -> Inject.Nothing_running)
    ~on_fetch:(fun ~max_bytes:_ ->
      { Inject.text = ""; total_bytes = 0; capped = false })
;;

(* -- capture send ------------------------------------------------------ *)

type capture = {
  mutex : Eio.Mutex.t;
  mutable frames : (int * Frame.frame) list;
  key : Seal.key;
}

let make_capture ~key () =
  { mutex = Eio.Mutex.create (); frames = []; key }
;;

let capture_send cap ~room:_ envelope =
  match Env.unpack envelope with
  | None -> fail "capture: bad envelope"
  | Some (target, sealed) ->
    (match Seal.open_sealed cap.key sealed with
     | Error _ -> fail "capture: unsealable frame"
     | Ok text ->
       (match Frame.frame_of_string text with
        | None -> fail "capture: undecodable frame"
        | Some frame ->
          Eio.Mutex.use_rw ~protect:false cap.mutex (fun () ->
              cap.frames <- cap.frames @ [ (target, frame) ])))
;;

let captured cap =
  Eio.Mutex.use_ro cap.mutex (fun () -> cap.frames)
;;

let wait_for ~clock cap n =
  let rec loop i =
    let count = List.length (captured cap) in
    if count >= n
    then ()
    else if i >= 1000
    then fail (Printf.sprintf "timed out waiting for %d frames" n)
    else (
      Eio.Time.sleep clock 0.005;
      loop (i + 1))
  in
  loop 0
;;

(* -- fixtures ---------------------------------------------------------- *)

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_base_dir f =
  let dir = Filename.temp_file "collab-host-test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let rec ensure_dir d =
  if not (Sys.file_exists d)
  then (
    ensure_dir (Filename.dirname d);
    Unix.mkdir d 0o700)
;;

let write_journal ~base_dir ~keeper ~op rows =
  let root = Event_log.events_dir ~base_dir in
  ensure_dir root;
  let kdir = Filename.concat root keeper in
  ensure_dir kdir;
  let oc = open_out (Filename.concat kdir (op ^ ".jsonl")) in
  List.iter (fun row -> output_string oc (row ^ "\n")) rows;
  close_out oc
;;

let seal_key_of_room (room : Link.room) =
  match Seal.key_of_secret room.Link.key with
  | Ok key -> key
  | Error _ -> fail "room key rejected"
;;

(* Guest envelopes arrive with the relay-rewritten sender peer id in the
   header, never zero; craft them the way the relay delivers them. *)
let guest_envelope ~key ~peer frame =
  let sealed = Seal.seal key (Frame.frame_to_string frame) in
  match Env.pack ~peer sealed with
  | Ok bytes -> bytes
  | Error _ -> fail "pack guest envelope"
;;

let token_of (room : Link.room) =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
    room.Link.write_token
;;

let with_session ~base_dir ~keeper ?(injector = silent_injector) f =
  Eio.Switch.run (fun sw ->
      let cap_ref = ref None in
      let send ~room envelope =
        match !cap_ref with
        | None -> fail "send before capture ready"
        | Some cap -> capture_send cap ~room envelope
      in
      (match Host.start ~sw ~base_dir ~keeper ~send ~injector () with
       | Error _ -> fail "host start"
       | Ok session ->
         let room : Link.room = Host.session_room session in
         cap_ref := Some (make_capture ~key:(seal_key_of_room room) ());
         let cap =
           match !cap_ref with
           | Some cap -> cap
           | None -> fail "unreachable"
         in
         let result = f session cap room in
         Host.stop session;
         result))
;;

let hello_as session cap room ~peer ~token ?(label = None) () =
  let key = seal_key_of_room room in
  let frame =
    Frame.Hello { proto = Collab_wire.proto_version; write_token = token; label }
  in
  Host.handle_envelope session (guest_envelope ~key ~peer frame)
;;

let check_targets msg cap expected =
  let targets = List.map fst (captured cap) in
  check (list int) msg expected targets
;;

let contains needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h
    then false
    else if String.sub haystack i n = needle
    then true
    else loop (i + 1)
  in
  loop 0
;;

(* -- tests ------------------------------------------------------------- *)

let test_hello_view_snapshot () =
  with_base_dir (fun base_dir ->
      write_journal ~base_dir ~keeper:"khello" ~op:"op1"
        [ {|{"seq":0,"ts":1.0,"event":{"type":"run_started"}}|}
        ; {|{"seq":1,"ts":2.0,"event":{"type":"text_delta"}}|}
        ; "{bad json"
        ];
      Eio_main.run (fun _env ->
          with_session ~base_dir ~keeper:"khello"
            (fun session cap room ->
              hello_as session cap room ~peer:7 ~token:None ();
              let frames = captured cap in
              check int "welcome + chunk" 2 (List.length frames);
              check_targets "unicast to 7" cap [ 7; 7 ];
              (match frames with
               | (_, Frame.Welcome w) :: (_, Frame.Snapshot_chunk c) :: [] ->
                 check string "keeper" "khello" w.Frame.header.keeper;
                 check string "snapshot op" "op1" w.Frame.header.operation;
                 check bool "read only" true w.Frame.read_only;
                 check int "entry count" 2 w.Frame.entry_count;
                 check bool "inactive" false w.Frame.state.active;
                 check int "no guests" 0 w.Frame.state.guests;
                 check int "chunk rows" 2 (List.length c.Frame.entries);
                 check bool "final" true c.Frame.final;
                 check
                   string
                   "first row passes through"
                   {|{"seq":0,"ts":1.0,"event":{"type":"run_started"}}|}
                   (Yojson.Safe.to_string
                      (List.nth c.Frame.entries 0))
               | _ -> fail "welcome/chunk shape"))))
;;

let test_hello_control_and_rejects () =
  with_base_dir (fun base_dir ->
      Eio_main.run (fun _env ->
          with_session ~base_dir ~keeper:"khello2"
            (fun session cap room ->
              hello_as session cap room ~peer:1 ~token:(Some (token_of room)) ();
              (match captured cap with
               | (_, Frame.Welcome w) :: (_, Frame.Snapshot_chunk c) :: [] ->
                 check bool "control" false w.Frame.read_only;
                 check int "empty snapshot" 0 w.Frame.entry_count;
                 check string "no op" "" w.Frame.header.operation;
                 check bool "chunk final" true c.Frame.final;
                 check int "chunk empty" 0 (List.length c.Frame.entries)
               | _ -> fail "control welcome shape");
              hello_as session cap room ~peer:2 ~token:(Some "!!!") ();
              (match List.nth (captured cap) 2 with
               | _, Frame.Welcome w ->
                 check bool "bad token views" true w.Frame.read_only
               | _ -> fail "bad token welcome");
              hello_as session cap room ~peer:3 ~token:(Some "AAAA") ();
              (match List.nth (captured cap) 4 with
               | _, Frame.Welcome w ->
                 check bool "short token views" true w.Frame.read_only
               | _ -> fail "short token welcome");
              let key = seal_key_of_room room in
              Host.handle_envelope session
                (guest_envelope ~key ~peer:3
                   (Frame.Hello { proto = 99; write_token = None; label = None }));
              (match List.nth (captured cap) 6 with
               | 3, Frame.Error_frame msg ->
                 check bool "proto named" true (contains "99" msg)
               | _ -> fail "proto error shape");
              check int "no welcome after error" 7 (List.length (captured cap)))))
;;

let test_live_forward_and_state () =
  with_base_dir (fun base_dir ->
      Eio_main.run (fun env ->
          let clock = Eio.Stdenv.clock env in
          with_session ~base_dir ~keeper:"klive"
            (fun session cap room ->
              hello_as session cap room ~peer:7 ~token:None ();
              check int "welcome + chunk" 2 (List.length (captured cap));
              Host.notify_published ~keeper:"klive" ~operation:"op9" ~seq:0
                ~ts:10.0 (Events.Text_delta "hi");
              wait_for ~clock cap 3;
              (match List.nth (captured cap) 2 with
               | 0, Frame.Entry e ->
                 check int "room seq 1" 1 e.Frame.seq;
                 check string "op" "op9" e.Frame.op;
                 check int "op seq" 0 e.Frame.op_seq;
                 check (float 0.0) "ts" 10.0 e.Frame.ts;
                 check
                   string
                   "event json"
                   (Yojson.Safe.to_string
                      (Event_log.keeper_chat_event_to_json
                         (Events.Text_delta "hi")))
                   (Yojson.Safe.to_string e.Frame.event)
               | _ -> fail "live entry shape");
              Host.notify_published ~keeper:"klive" ~operation:"op9" ~seq:1
                ~ts:11.0
                (Events.Run_started { run_id = "r1"; thread_id = "t1" });
              wait_for ~clock cap 5;
              (match
                 (List.nth (captured cap) 3, List.nth (captured cap) 4)
               with
               | (0, Frame.Live_state s), (0, Frame.Entry e) ->
                 check bool "active" true s.Frame.active;
                 check int "room seq 2" 2 e.Frame.seq
               | _ -> fail "state-then-entry order");
              Host.notify_published ~keeper:"klive" ~operation:"op9" ~seq:2
                ~ts:12.0
                (Events.Run_finished { run_id = "r1" });
              wait_for ~clock cap 7;
              (match List.nth (captured cap) 5 with
               | 0, Frame.Live_state s ->
                 check bool "idle again" false s.Frame.active
               | _ -> fail "idle state");
              (* A non-finite ts drops the event, like the journal pager. *)
              Host.notify_published ~keeper:"klive" ~operation:"op9" ~seq:3
                ~ts:Float.infinity
                (Events.Text_delta "nope");
              Eio.Time.sleep clock 0.05;
              check int "poison ts dropped" 7 (List.length (captured cap));
              (* A non-finite embedded float is unjournalable too: the live
                 stream must agree with the journal. *)
              Host.notify_published ~keeper:"klive" ~operation:"op9" ~seq:4
                ~ts:13.0
                (Events.Audio_block
                   { token = "t"
                   ; mime = "audio/wav"
                   ; message_text = "x"
                   ; duration_sec = Some Float.infinity
                   });
              Eio.Time.sleep clock 0.05;
              check int "poison float dropped" 7 (List.length (captured cap));
              (* Failures clear only their own operation's runs. *)
              Host.notify_published ~keeper:"klive" ~operation:"opa" ~seq:0
                ~ts:13.0
                (Events.Run_started { run_id = "ra"; thread_id = "t" });
              Host.notify_published ~keeper:"klive" ~operation:"opb" ~seq:0
                ~ts:13.0
                (Events.Run_started { run_id = "rb"; thread_id = "t" });
              wait_for ~clock cap 10;
              Host.notify_published ~keeper:"klive" ~operation:"opa" ~seq:1
                ~ts:14.0
                (Events.Event_error { message = "boom" });
              wait_for ~clock cap 11;
              (* No state frame before the opa error entry: opb's run keeps the
                 room active, which proves failures clear only their own op. *)
              (match List.nth (captured cap) 10 with
               | 0, Frame.Entry _ -> ()
               | _ -> fail "error entry");
              Host.notify_published ~keeper:"klive" ~operation:"opb" ~seq:1
                ~ts:15.0
                (Events.Event_error { message = "boom" });
              wait_for ~clock cap 13;
              (match List.nth (captured cap) 11 with
               | 0, Frame.Live_state s ->
                 check bool "all idle" false s.Frame.active
               | _ -> fail "final idle"))))
;;

let test_peer_membership_state () =
  with_base_dir (fun base_dir ->
      Eio_main.run (fun _env ->
          with_session ~base_dir ~keeper:"kmem"
            (fun session cap _room ->
              Host.peer_joined session 1;
              Host.peer_joined session 1;
              Host.peer_joined session 2;
              Host.peer_left session 9;
              Host.peer_left session 1;
              Host.peer_left session 1;
              let states =
                List.filter_map
                  (function
                    | 0, Frame.Live_state s -> Some s.Frame.guests
                    | _ -> None)
                  (captured cap)
              in
              check (list int) "guest counts" [ 1; 2; 1 ] states)))
;;

let test_drops () =
  with_base_dir (fun base_dir ->
      Eio_main.run (fun _env ->
          with_session ~base_dir ~keeper:"kdrop"
            (fun session cap room ->
              let key = seal_key_of_room room in
              hello_as session cap room ~peer:5 ~token:None ();
              check int "welcome + chunk" 2 (List.length (captured cap));
              Host.handle_envelope session "xx";
              Host.handle_envelope session
                (match Env.pack ~peer:5 "garbage-ciphertext" with
                 | Ok bytes -> bytes
                 | Error _ -> fail "pack");
              (* Stack 4: a view peer's prompt is refused with an error,
                 not dropped. *)
              Host.handle_envelope session
                (guest_envelope ~key ~peer:5 (Frame.Prompt "nope"));
              (match List.nth (captured cap) 2 with
               | 5, Frame.Error_frame msg ->
                 check bool "control required" true (contains "control" msg)
               | _ -> fail "prompt refusal");
              Host.handle_envelope session
                (guest_envelope ~key ~peer:5
                   (Frame.Welcome
                      { proto = 1
                      ; header = { keeper = "x"; operation = "y" }
                      ; state = { active = false; guests = 0 }
                      ; entry_count = 0
                      ; read_only = false
                      }));
              (* A zero sender can only arrive off-path; it must not mint a
                 broadcast-targeted welcome. *)
              Host.handle_envelope session
                (guest_envelope ~key ~peer:0
                   (Frame.Hello { proto = 1; write_token = None; label = None }));
              check int "rest dropped" 3 (List.length (captured cap)))))
;;

let test_stop_and_stop_all () =
  with_base_dir (fun base_dir ->
      Eio_main.run (fun _env ->
          Eio.Switch.run (fun sw ->
              let start keeper =
                let cap_ref = ref None in
                let send ~room envelope =
                  match !cap_ref with
                  | None -> fail "send before capture"
                  | Some cap -> capture_send cap ~room envelope
                in
                (match Host.start ~sw ~base_dir ~keeper ~send () with
                 | Error _ -> fail "host start"
                 | Ok session ->
                   let room : Link.room = Host.session_room session in
                   let cap =
                     make_capture ~key:(seal_key_of_room room) ()
                   in
                   cap_ref := Some cap;
                   session, cap)
              in
              let sa, capa = start "kstopa" in
              let _sb, capb = start "kstopb" in
              Host.stop sa;
              (match captured capa with
               | (0, Frame.Bye _) :: [] -> ()
               | _ -> fail "bye shape");
              Host.stop sa;
              check int "second stop silent" 1 (List.length (captured capa));
              Host.stop_all ();
              (match captured capb with
               | (0, Frame.Bye _) :: [] -> ()
               | _ -> fail "stop_all bye");
              Host.stop_all ();
              check int "stop_all idempotent" 1 (List.length (captured capb)))))
;;

let test_snapshot_tail_window () =
  with_base_dir (fun base_dir ->
      let pad = String.make 900 'p' in
      let rows =
        List.init 9000 (fun n ->
            Printf.sprintf {|{"seq":%d,"ts":1.0,"event":{"pad":"%s"}}|} n pad)
      in
      write_journal ~base_dir ~keeper:"ktail" ~op:"bigop" rows;
      Eio_main.run (fun _env ->
          with_session ~base_dir ~keeper:"ktail"
            (fun session cap room ->
              hello_as session cap room ~peer:7 ~token:None ();
              let frames = captured cap in
              let welcome =
                match frames with
                | (_, Frame.Welcome w) :: _ -> w
                | _ -> fail "tail welcome"
              in
              check bool "tail cut" true (welcome.Frame.entry_count < 9000);
              check bool "tail nonempty" true (welcome.Frame.entry_count > 0);
              let entries =
                List.concat_map
                  (function
                    | _, Frame.Snapshot_chunk c -> c.Frame.entries
                    | _ -> [])
                  frames
              in
              check int "count matches chunks" welcome.Frame.entry_count
                (List.length entries);
              let seq_of json =
                Yojson.Safe.Util.(json |> member "seq" |> to_int)
              in
              check bool "head cut off" true
                (seq_of (List.hd entries) > 0);
              check int "tail reaches EOF" 8999
                (seq_of (List.hd (List.rev entries))))))
;;

let test_snapshot_map_path () =
  with_base_dir (fun base_dir ->
      write_journal ~base_dir ~keeper:"kmap" ~op:"freshop"
        [ {|{"seq":0,"ts":1.0,"event":{}}|} ];
      Eio_main.run (fun env ->
          let clock = Eio.Stdenv.clock env in
          with_session ~base_dir ~keeper:"kmap"
            (fun session cap room ->
              Host.notify_published ~keeper:"kmap" ~operation:"freshop" ~seq:0
                ~ts:1.0 (Events.Text_delta "live");
              hello_as session cap room ~peer:7 ~token:None ();
              (* The forwarder broadcasts from start, so the notified entry
                 lands before the welcome; the welcome still snapshots the
                 map-pinned operation. *)
              wait_for ~clock cap 3;
              (match captured cap with
               | (0, Frame.Entry e)
                 :: (_, Frame.Welcome w)
                 :: (_, Frame.Snapshot_chunk _) :: [] ->
                 check string "live op" "freshop" e.Frame.op;
                 check int "live op seq" 0 e.Frame.op_seq;
                 check string "map op wins" "freshop" w.Frame.header.operation;
                 check int "one row" 1 w.Frame.entry_count
               | _ -> fail "map welcome"))))
;;

let send_as session cap room ~peer frame =
  let key = seal_key_of_room room in
  Host.handle_envelope session (guest_envelope ~key ~peer frame)
;;

let test_control_prompt () =
  with_base_dir (fun base_dir ->
      Eio_main.run (fun _env ->
          let recorded = fresh_recorded () in
          with_session ~base_dir ~keeper:"kprompt"
            ~injector:(ok_injector recorded)
            (fun session cap room ->
              hello_as session cap room ~peer:1 ~token:(Some (token_of room)) ();
              send_as session cap room ~peer:1 (Frame.Prompt "steer left");
              check int "prompt silent" 2 (List.length (captured cap));
              check
                (list (triple int (option string) string))
                "prompt recorded"
                [ (1, None, "steer left") ]
                recorded.prompts)))
;;

let test_prompt_carries_label () =
  with_base_dir (fun base_dir ->
      Eio_main.run (fun _env ->
          let recorded = fresh_recorded () in
          with_session ~base_dir ~keeper:"kpromptlabel"
            ~injector:(ok_injector recorded)
            (fun session cap room ->
              let token = Some (token_of room) in
              hello_as session cap room ~peer:1 ~token ~label:(Some "  Rin  ") ();
              hello_as session cap room ~peer:2 ~token
                ~label:(Some (String.make 65 'x'))
                ();
              hello_as session cap room ~peer:3 ~token ~label:(Some "   ") ();
              send_as session cap room ~peer:1 (Frame.Prompt "one");
              send_as session cap room ~peer:2 (Frame.Prompt "two");
              send_as session cap room ~peer:3 (Frame.Prompt "three");
              check
                (list (triple int (option string) string))
                "labels ride prompts"
                [ (1, Some "Rin", "one")
                ; (2, None, "two")
                ; (3, None, "three")
                ]
                recorded.prompts)))
;;

let test_prompt_refusals () =
  with_base_dir (fun base_dir ->
      Eio_main.run (fun _env ->
          let recorded = fresh_recorded () in
          with_session ~base_dir ~keeper:"kpromptdeny"
            ~injector:(ok_injector recorded)
            (fun session cap room ->
              hello_as session cap room ~peer:5 ~token:None ();
              send_as session cap room ~peer:5 (Frame.Prompt "nope");
              send_as session cap room ~peer:9 (Frame.Prompt "stranger");
              let errors =
                List.filter_map
                  (function
                    | _, Frame.Error_frame msg -> Some msg
                    | _ -> None)
                  (captured cap)
              in
              check int "two refusals" 2 (List.length errors);
              check
                (list (triple int (option string) string))
                "nothing queued"
                []
                recorded.prompts)))
;;

let test_prompt_failure_and_raise () =
  with_base_dir (fun base_dir ->
      Eio_main.run (fun _env ->
          let recorded = fresh_recorded () in
          let injector =
            recording_injector recorded
              ~on_prompt:(fun ~peer:_ ~text:_ ->
                Error (Inject.Prompt_submit_failed "queue down"))
              ~on_abort:(fun ~latest_op:_ -> Inject.Nothing_running)
              ~on_fetch:(fun ~max_bytes:_ ->
                { Inject.text = ""; total_bytes = 0; capped = false })
          in
          with_session ~base_dir ~keeper:"kpromptfail" ~injector
            (fun session cap room ->
              hello_as session cap room ~peer:1 ~token:(Some (token_of room)) ();
              send_as session cap room ~peer:1 (Frame.Prompt "hi");
              (match List.nth (captured cap) 2 with
               | 1, Frame.Error_frame msg ->
                 check bool "failure named" true (contains "queue down" msg)
               | _ -> fail "failure error"));
          let recorded = fresh_recorded () in
          let injector =
            recording_injector recorded
              ~on_prompt:(fun ~peer:_ ~text:_ -> failwith "registry exploded")
              ~on_abort:(fun ~latest_op:_ -> Inject.Nothing_running)
              ~on_fetch:(fun ~max_bytes:_ ->
                { Inject.text = ""; total_bytes = 0; capped = false })
          in
          with_session ~base_dir ~keeper:"kpromptraise" ~injector
            (fun session cap room ->
              hello_as session cap room ~peer:1 ~token:(Some (token_of room)) ();
              send_as session cap room ~peer:1 (Frame.Prompt "hi");
              (match List.nth (captured cap) 2 with
               | 1, Frame.Error_frame msg ->
                 check bool "raise answered" true (contains "prompt failed" msg);
                 check
                   bool
                   "exception text stays host-side"
                   false
                   (contains "registry exploded" msg)
               | _ -> fail "raise error"))))
;;

let test_abort_wiring () =
  with_base_dir (fun base_dir ->
      Eio_main.run (fun env ->
          let clock = Eio.Stdenv.clock env in
          let recorded = fresh_recorded () in
          with_session ~base_dir ~keeper:"kabortw"
            ~injector:(ok_injector recorded)
            (fun session cap room ->
              hello_as session cap room ~peer:1 ~token:(Some (token_of room)) ();
              (* No operation seen yet: abort names nothing. *)
              send_as session cap room ~peer:1 Frame.Abort;
              check
                (list (option string))
                "abort nothing"
                [ None ]
                recorded.aborts;
              (* After a live turn, abort names the exact op id. *)
              Host.notify_published ~keeper:"kabortw" ~operation:"opZ" ~seq:0
                ~ts:1.0 (Events.Text_delta "x");
              wait_for ~clock cap 3;
              send_as session cap room ~peer:1 Frame.Abort;
              check
                (list (option string))
                "abort names op"
                [ None; Some "opZ" ]
                recorded.aborts;
              (* View aborts are refused and never reach the injector. *)
              hello_as session cap room ~peer:5 ~token:None ();
              send_as session cap room ~peer:5 Frame.Abort;
              check int "no new abort" 2 (List.length recorded.aborts);
              let errors =
                List.filter_map
                  (function
                    | _, Frame.Error_frame msg -> Some msg
                    | _ -> None)
                  (captured cap)
              in
              check int "one refusal" 1 (List.length errors))))
;;

let test_fetch_wiring () =
  with_base_dir (fun base_dir ->
      Eio_main.run (fun _env ->
          let recorded = fresh_recorded () in
          let injector =
            recording_injector recorded
              ~on_prompt:(fun ~peer:_ ~text:_ -> Ok "op-9")
              ~on_abort:(fun ~latest_op:_ -> Inject.Nothing_running)
              ~on_fetch:(fun ~max_bytes ->
                { Inject.text =
                    (if max_bytes = 0 then "" else "scrollback")
                ; total_bytes = 10
                ; capped = max_bytes = 1
                })
          in
          with_session ~base_dir ~keeper:"kfetchw" ~injector
            (fun session cap room ->
              (* View peers may fetch: scrollback is a read. *)
              hello_as session cap room ~peer:5 ~token:None ();
              send_as session cap room ~peer:5
                (Frame.Fetch_transcript { req_id = 7; max_bytes = 1024 });
              (match List.nth (captured cap) 2 with
               | 5, Frame.Transcript t ->
                 check int "req echoed" 7 t.Frame.req_id;
                 check string "text" "scrollback" t.Frame.text;
                 check int "size" 10 t.Frame.new_size;
                 check (option string) "no error" None t.Frame.error
               | _ -> fail "transcript shape");
              (* Caps surface through the error field with partial text. *)
              send_as session cap room ~peer:5
                (Frame.Fetch_transcript { req_id = 8; max_bytes = 1 });
              (match List.nth (captured cap) 3 with
               | 5, Frame.Transcript t ->
                 check int "req echoed" 8 t.Frame.req_id;
                 check bool "cap noted" true (t.Frame.error <> None)
               | _ -> fail "capped shape");
              check (list int) "fetches" [ 1024; 1 ] recorded.fetches)))
;;

let () =
  run
    "collab-host"
    [
      ( "hello",
        [
          test_case "view snapshot" `Quick test_hello_view_snapshot;
          test_case
            "control and rejects"
            `Quick
            test_hello_control_and_rejects;
          test_case "snapshot map path" `Quick test_snapshot_map_path;
          test_case "snapshot tail window" `Quick test_snapshot_tail_window;
        ] );
      ( "live",
        [
          test_case
            "forward and state"
            `Quick
            test_live_forward_and_state;
          test_case "membership state" `Quick test_peer_membership_state;
          test_case "drops" `Quick test_drops;
        ] );
      ( "stop",
        [ test_case "stop and stop_all" `Quick test_stop_and_stop_all ] );
      ( "inject",
        [
          test_case "control prompt" `Quick test_control_prompt;
          test_case "prompt carries label" `Quick test_prompt_carries_label;
          test_case "prompt refusals" `Quick test_prompt_refusals;
          test_case
            "prompt failure and raise"
            `Quick
            test_prompt_failure_and_raise;
          test_case "abort wiring" `Quick test_abort_wiring;
          test_case "fetch wiring" `Quick test_fetch_wiring;
        ] );
    ]
;;
