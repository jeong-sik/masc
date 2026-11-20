(* The content of one unit of a Keeper's turn log, read as items
   (RFC librarian-call-only-proposes §5.1, §5.3, §5.5): every store's rows in
   the unit's order with the conversation from the one record that holds it,
   what a store does not hold named the way the line names it with the rest
   still read, and a bundle that is there and does not read. *)

open Alcotest
module Unread = Masc.Librarian_unread
module Content = Masc.Librarian_unit_content
module Read_unit = Masc.Librarian_read_unit
module Unit = Masc.Librarian_unit
module Fragments = Masc.Keeper_turn_fragments
module History = Masc.Keeper_context_core_history
module Objects = Agent_core.Checkpoint_objects
module Types = Agent_core.Types

let keeper_name = "keeper-a"
let session_id = "session-1"
let turn_ref = Ids.Turn_ref.make ~trace_id:session_id ~absolute_turn:1

let message ~role text : Types.message =
  { origin = Llm_provider.Types.Conversation
  ; role
  ; content = [ Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let checkpoint messages =
  Agent_core.Checkpoint.
    { provider_binding = None
    ; version = checkpoint_version
    ; session_id
    ; agent_name = "test-agent"
    ; model = "test-model"
    ; system_prompt = None
    ; messages
    ; usage = Agent_core.Types.empty_usage
    ; turn_count = 1
    ; created_at = 1000.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; reasoning_effort = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_core.Types.Off
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; pending_input = None
    ; working_context = None
    }
;;

(* The messages closed as one bundle under the session's objects. *)
let stored_bundle ~session_dir messages =
  match Objects.plan_save (Objects.create_memo ()) Turn_closes (checkpoint messages) with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok plan ->
    Fs_compat.mkdir_p session_dir;
    (match Masc.Keeper_checkpoint_object_store.write ~session_dir plan.objects with
     | Error error -> fail (Masc.Keeper_checkpoint_object_store.write_error_to_string error)
     | Ok (_ : int) -> ());
    (match plan.head.history.turns with
     | [ turn ] -> turn.bundle
     | turns -> failf "expected one closed turn, the plan has %d" (List.length turns))
;;

let size path = if Sys.file_exists path then (Unix.stat path).st_size else 0

let append_raw path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_creat ] 0o600 path (fun channel ->
    Out_channel.output_string channel text)
;;

let external_item preview : Masc.Keeper_external_attention.item =
  { event_id = Masc.Keeper_external_attention.event_id_of_dedupe_key preview
  ; dedupe_key = preview
  ; keeper_name
  ; conversation = { conversation_id = "agent:unit"; surface = Agent }
  ; external_message = None
  ; source_label = "agent"
  ; actor = { actor_id = Some "external"; display_name = Some "External"; authority = External }
  ; urgency = Ambient
  ; content_preview = preview
  ; content_ref = None
  ; received_at = 1.5
  ; metadata = []
  }
;;

(* What each store holds after one turn: two chat rows, two external rows,
   a bundle of three messages, two history rows and one internal row. *)
type stored =
  { stores : Content.stores
  ; session : Masc.Keeper_context_core.session_context
  ; bundle : Objects.digest
  ; session_dir : string
  ; history : int list (** The history file's end after each row. *)
  ; internal : int
  ; chat : int list
  ; external_path : string
  ; internal_path : string
  }

let with_stores f =
  Eio_main.run
  @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = Filename.temp_dir "unit-content" "" in
  let session = Masc.Keeper_context_core.create_session ~session_id ~base_dir in
  let session_dir = session.Keeper_types.session_dir in
  let stores : Content.stores =
    { session_dir =
        (fun ~session ->
          if String.equal session session_id then session_dir else failf "no session %s" session)
    ; base_path = base_dir
    ; keeper_name
    }
  in
  let bundle =
    stored_bundle ~session_dir
      [ message ~role:User "first"; message ~role:Assistant "second"; message ~role:User "third" ]
  in
  let history_path = Fragments.path ~session_dir Main in
  let persist source role text =
    History.persist_message ~keeper_name ~turn_ref ~source session (message ~role text);
    size history_path
  in
  let after_q1 = persist Masc.Keeper_types_support.Direct_user User "q1" in
  let after_a1 = persist Masc.Keeper_types_support.Direct_assistant Assistant "a1" in
  History.persist_message ~keeper_name ~turn_ref ~source:Masc.Keeper_types_support.Internal_assistant
    session (message ~role:Assistant "noted");
  let internal_path = Fragments.path ~session_dir Internal in
  let chat_path = Masc.Keeper_chat_store.chat_path ~base_dir ~keeper_name in
  let speaker : Masc.Keeper_chat_store.speaker =
    { speaker_id = Some "owner"; speaker_name = Some "Owner"; speaker_authority = Owner }
  in
  let chat content =
    Masc.Keeper_chat_store.append_user_message ~base_dir ~keeper_name ~content ~speaker ();
    size chat_path
  in
  let after_c1 = chat "c1" in
  let after_c2 = chat "c2" in
  let external_path = Masc.Keeper_external_attention.attention_path ~base_path:base_dir ~keeper_name in
  List.iter
    (fun preview ->
       append_raw external_path
         (Yojson.Safe.to_string
            (Masc.Keeper_external_attention.event_to_json (Recorded (external_item preview)))
          ^ "\n"))
    [ "e1"; "e2" ];
  f
    { stores
    ; session
    ; bundle
    ; session_dir
    ; history = [ after_q1; after_a1 ]
    ; internal = size internal_path
    ; chat = [ after_c1; after_c2 ]
    ; external_path
    ; internal_path
    }
;;

let range from until : Unit.range = { from; until }
let slice bundle skip take : Masc.Keeper_turn_log.slice = { bundle; skip; take }

let through : Masc.Keeper_turn_log.mark =
  { trace = session_id
  ; closed_messages = 3
  ; session = session_id
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let span source : Unread.span = { line = 100; past_line = 200; at = 5.0; through; next = through; source }

let fragment_text : Fragments.fragment -> string = function
  | Message { message; _ } -> Types.text_of_content message.content
  | Tool_observation { observation; _ } -> "tool " ^ observation.tool_name
;;

let body_text : Read_unit.body -> string = function
  | Chat_row { message = Some chat; _ } -> "chat " ^ chat.content
  | Chat_row { message = None; _ } -> "chat row the reader dropped"
  | External_row item -> "external " ^ item.content_preview
  | Message message -> "message " ^ Types.text_of_content message.content
  | Fragment { file = Main; line = Fragment fragment } -> "history " ^ fragment_text fragment
  | Fragment { file = Internal; line = Fragment fragment } -> "internal " ^ fragment_text fragment
  | Fragment { line = Untagged; _ } -> "untagged"
;;

let range_text ({ from; until } : Unit.range) = Printf.sprintf "%d-%d" from until

let missing_text : Unit.missing_part -> string = function
  | Bundle { skip; take; _ } -> Printf.sprintf "bundle %d+%d" skip take
  | History_bytes range -> "history bytes " ^ range_text range
  | Internal_bytes range -> "internal bytes " ^ range_text range
  | Chat_bytes range -> "chat bytes " ^ range_text range
  | External_rows range -> "external rows " ^ range_text range
  | Undecodable_history_line { offset } -> Printf.sprintf "history line at %d" offset
  | Undecodable_internal_line { offset } -> Printf.sprintf "internal line at %d" offset
  | Undecodable_external_row { row } -> Printf.sprintf "external row %d" row
;;

let read_text stores span =
  match Content.read stores span with
  | Error (Fault (Content_unreadable { line })) -> [ Printf.sprintf "content of %d unreadable" line ]
  | Error (Fault (Line_unreadable _ | Turn_log_replaced _ | Position_lost _)) -> [ "another fault" ]
  | Error (Unread { detail }) -> [ "unread: " ^ detail ]
  | Ok unit_ ->
    let item segment ({ index; body } : Read_unit.item) =
      Printf.sprintf "%s %d %s" segment index (body_text body)
    in
    (match unit_.kind with
     | Turn { unattributed; own; _ } ->
       List.map (item "unattributed") unattributed @ List.map (item "own") own
     | Reset { items; _ } -> List.map (item "reset") items)
    @ List.map (fun part -> "missing " ^ missing_text part) unit_.missing
;;

let files ?(history = range 0 0) ?(internal = range 0 0) () = Unread.Official_files { history; internal }
let checkpoint ?(internal = range 0 0) slices = Unread.Checkpoint { slices; internal }

let every ?(history = range 0 0) ?(internal = range 0 0) slices =
  Unread.Every_record { slices; history; internal }
;;

let segment ?(record = files ()) ?(chat = range 0 0) ?(external_rows = range 0 0) () : Unread.segment =
  { record; chat; external_rows }
;;

(* Each store's rows, a segment at a time: chat, external, then the
   conversation's record. The own segment's items are numbered after the
   unattributed ones. *)
let test_each_store_in_order () =
  with_stores
  @@ fun stored ->
  let after_a1, after_c1, after_c2 =
    match stored.history, stored.chat with
    | [ (_ : int); after_a1 ], [ after_c1; after_c2 ] -> after_a1, after_c1, after_c2
    | _ -> fail "the fixture wrote two history rows and two chat rows"
  in
  let unattributed =
    segment
      ~record:(files ~history:(range 0 after_a1) ~internal:(range 0 stored.internal) ())
      ~chat:(range 0 after_c1) ~external_rows:(range 0 1) ()
  in
  let own =
    segment ~record:(checkpoint [ slice stored.bundle 1 2 ]) ~chat:(range after_c1 after_c2)
      ~external_rows:(range 1 2) ()
  in
  let opened : Read_unit.opened = { runtime = "glm-main"; task = No_task; stimuli = [] } in
  check (list string) "every item, in the unit's order"
    [ "unattributed 0 chat c1"
    ; "unattributed 1 external e1"
    ; "unattributed 2 history q1"
    ; "unattributed 3 history a1"
    ; "unattributed 4 internal noted"
    ; "own 5 chat c2"
    ; "own 6 external e2"
    ; "own 7 message second"
    ; "own 8 message third"
    ]
    (read_text stored.stores
       (span (Turn { turn = 10; outcome = Completed; opened; unattributed; own })))
;;

(* A bundle that is not stored, bytes past a file's end, rows that do not
   decode and rows the external store does not have are named. Everything
   else the unit names is read. *)
let test_what_a_store_does_not_hold () =
  with_stores
  @@ fun stored ->
  let after_a1, after_c2 =
    match List.rev stored.history, List.rev stored.chat with
    | after_a1 :: _, after_c2 :: _ -> after_a1, after_c2
    | _ -> fail "the fixture wrote history and chat rows"
  in
  append_raw stored.internal_path "not json\n";
  append_raw stored.external_path "x\n";
  let absent = Objects.digest_of_bytes "a bundle that was never stored" in
  let read record =
    read_text stored.stores
      (span
         (Announced_reset
            { cause = Recovered
            ; segment =
                segment ~record ~chat:(range after_c2 (after_c2 + 10)) ~external_rows:(range 1 4) ()
            }))
  in
  let chat_and_external =
    [ Printf.sprintf "missing chat bytes %d-%d" after_c2 (after_c2 + 10)
    ; "missing external row 2"
    ; "missing external rows 3-4"
    ]
  in
  check (list string) "the checkpoint's messages that are there, then what is not"
    ([ "reset 0 external e2"; "reset 1 message first" ] @ chat_and_external @ [ "missing bundle 0+1" ])
    (read (checkpoint [ slice absent 0 1; slice stored.bundle 0 1 ]));
  check (list string) "the files' rows that are there, then what is not"
    (("reset 0 external e2" :: chat_and_external)
     @ [ Printf.sprintf "missing history bytes %d-%d" after_a1 (after_a1 + 40)
       ; Printf.sprintf "missing internal line at %d" stored.internal
       ])
    (read
       (files ~history:(range after_a1 (after_a1 + 40))
          ~internal:(range stored.internal (size stored.internal_path)) ()))
;;

(* A bundle that is there and does not match its digest, and one that holds
   fewer messages than a slice takes, stop the read. *)
let test_a_bundle_that_does_not_read () =
  with_stores
  @@ fun stored ->
  let changed = Objects.digest_of_bytes "the bytes this digest names" in
  append_raw (Masc.Keeper_checkpoint_object_store.path ~session_dir:stored.session_dir changed) "other bytes";
  let reading slices =
    read_text stored.stores
      (span (Announced_reset { cause = Recovered; segment = segment ~record:(checkpoint slices) () }))
  in
  check (list string) "a bundle whose bytes changed" [ "content of 100 unreadable" ]
    (reading [ slice changed 0 1 ]);
  check (list string) "a slice past the bundle's messages" [ "content of 100 unreadable" ]
    (reading [ slice stored.bundle 2 2 ])
;;

(* §5.3: each record reads what its turn left nowhere else. One turn on
   Agent Core reads its checkpoint and the internal file, which holds only
   the reply the checkpoint does not replay, and not the main file, which
   says what the checkpoint says. One turn on an official client reads both
   files, its tool observation among them. A stretch that can hold several
   turns reads all three. *)
let test_each_record_reads_what_only_it_holds () =
  with_stores
  @@ fun stored ->
  let history = range 0 (size (Fragments.path ~session_dir:stored.session_dir Main)) in
  let slices = [ slice stored.bundle 0 3 ] in
  let read record =
    read_text stored.stores
      (span (Announced_reset { cause = Recovered; segment = segment ~record () }))
  in
  let messages = [ "reset 0 message first"; "reset 1 message second"; "reset 2 message third" ] in
  check (list string) "one turn on Agent Core: its checkpoint, then the reply it does not replay"
    (messages @ [ "reset 3 internal noted" ])
    (read (checkpoint ~internal:(range 0 stored.internal) slices));
  History.persist_tool_observation ~keeper_name ~turn_ref stored.session ~tool_name:"masc_tasks"
    ~outcome:Tool_result.Ok;
  let internal = range 0 (size stored.internal_path) in
  check (list string) "one turn on an official client: both files"
    [ "reset 0 history q1"; "reset 1 history a1"; "reset 2 internal noted"; "reset 3 internal tool masc_tasks" ]
    (read (files ~history ~internal ()));
  check (list string) "a stretch: every record"
    (messages
     @ [ "reset 3 history q1"; "reset 4 history a1"; "reset 5 internal noted"; "reset 6 internal tool masc_tasks" ])
    (read (every ~history ~internal slices))
;;

let () =
  run "librarian_unit_content"
    [ ( "content"
      , [ test_case "each store in order" `Quick test_each_store_in_order
        ; test_case "what a store does not hold" `Quick test_what_a_store_does_not_hold
        ; test_case "a bundle that does not read" `Quick test_a_bundle_that_does_not_read
        ; test_case "each record reads what only it holds" `Quick test_each_record_reads_what_only_it_holds
        ] )
    ]
;;
