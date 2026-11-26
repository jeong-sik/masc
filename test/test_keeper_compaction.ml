open Alcotest
open Masc

module A = Keeper_compaction_atom
module C = Keeper_compaction
module Store = Keeper_canonical_turn_store

let with_temp_dir f =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_compaction_%d_%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
  Fs_compat.mkdir_p base;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () -> f base)
;;

let with_pool f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests f
;;

let with_keepers_dir f =
  with_temp_dir
  @@ fun base_path ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  f keepers_dir
;;

let msg_bytes (msg : Agent_core.Types.message) =
  List.fold_left
    (fun acc block ->
       acc
       +
       match block with
       | Agent_core.Types.Text s -> String.length s
       | Thinking { content; _ } -> String.length content
       | ReasoningDetails _ -> 32
       | RedactedThinking s -> String.length s
       | ToolUse { name; input; _ } ->
         String.length name + String.length (Yojson.Safe.to_string input)
       | ToolResult { content; _ } -> String.length content
       | ToolReference { tool_name; _ } -> String.length tool_name
       | Image _ | Document _ | Audio _ -> 128)
    0
    msg.content
;;

let contains ~needle haystack = String_util.contains_substring haystack needle

let message ?(metadata = []) ?(origin = Agent_core.Types.Conversation) role content
  : Agent_core.Types.message
  =
  { origin; role; content; name = None; tool_call_id = None; metadata }
;;

let stamped turn = [ Keeper_turn_ref_metadata.canonical_key, `String turn ]

(* One Agent Core turn as the checkpoint history holds it: the user input
   carries the turn id; the replies and the tool round do not. *)
let agent_core_turn ~turn ~prompt ?tool ~answer () =
  let open Agent_core.Types in
  let rounds =
    match tool with
    | None -> []
    | Some name ->
      let id = Printf.sprintf "call-%s-%s" turn name in
      [ message Assistant [ ToolUse { id; name; input = `Assoc [] } ]
      ; { (message
             Tool
             [ ToolResult
                 { tool_use_id = id
                 ; content = "ok"
                 ; outcome = Tool_succeeded
                 ; json = None
                 ; content_blocks = None
                 }
             ])
          with
          tool_call_id = Some id
        }
      ]
  in
  (message ~metadata:(stamped turn) User [ Text prompt ] :: rounds)
  @ [ message Assistant [ Text answer ] ]
;;

let turn_name turn ordinal = A.In_turn { turn = Ids.Turn_id.of_string turn; ordinal }
let name_t = testable (fun fmt n -> Format.pp_print_string fmt (A.name_to_string n)) A.equal_name

let placement_t =
  testable
    (fun fmt -> function
       | A.Covers_none -> Format.pp_print_string fmt "Covers_none"
       | A.Covers_through index -> Format.fprintf fmt "Covers_through %d" index
       | A.Not_in_list -> Format.pp_print_string fmt "Not_in_list")
    ( = )
;;

let front_t =
  testable
    (fun fmt -> function
       | A.Front index -> Format.fprintf fmt "Front %d" index
       | A.Front_at_least index -> Format.fprintf fmt "Front_at_least %d" index)
    ( = )
;;
let names atoms = Array.to_list (Array.map (fun (atom : A.atom) -> atom.name) atoms)

let hard_limit =
  C.Explicit_hard_limit { capacity_bytes = 64_000; observed_bytes = 70_000 }
;;

(* Most tests compact a message history; a list rebuilt from the canonical
   turn store passes [~frame:A.Canonical_turns]. *)
let compact
      ?(trigger = hard_limit)
      ?(later = [])
      ?(frame = A.Message_history)
      ~keepers_dir
      ~keeper_id
      ~prefix
      messages
  =
  C.compact_evicted_messages
    ~keepers_dir
    ~keeper_id
    ~trigger
    ~frame
    ~messages
    ~eviction:{ A.prefix; later }
    ()
;;

let ok_compaction = function
  | Ok value -> value
  | Error err -> fail (C.store_error_to_string err)
;;

let committed result =
  match ok_compaction result with
  | Some anchor -> anchor
  | None -> fail "expected a committed epoch"
;;

let ok_store = function
  | Ok value -> value
  | Error err -> fail (Store.store_error_to_string err)
;;

let commit_row ?(kind = Store.Agent_core_http) ~keepers_dir ~keeper_id ~turn ~prompt ~answer at =
  Store.commit_turn
    ~keepers_dir
    ~keeper_id
    ~turn_id:(Ids.Turn_id.of_string turn)
    ~runtime_kind:kind
    ~runtime_id:"runtime:1"
    ~user_input:prompt
    ~tool_calls_json:(`List [])
    ~assistant_output:answer
    ~usage_json:(`Assoc [])
    ~created_at:at
    ()
  |> ok_store
;;

let row_ids rows = List.map (fun (row : Store.canonical_turn) -> Ids.Turn_id.to_string row.turn_id) rows

let exec_all path statements =
  let db = Sqlite3.db_open path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db : bool))
    (fun () ->
       List.iter
         (fun sql ->
            match Sqlite3.exec db sql with
            | rc when Sqlite3.Rc.is_success rc -> ()
            | rc -> fail (Printf.sprintf "%s: %s" sql (Sqlite3.Rc.to_string rc)))
         statements)
;;

(* (epoch, name, messages_json) of every archived atom, in commit order. *)
let archived_atoms ~keepers_dir ~keeper_id =
  let db = Sqlite3.db_open ~mode:`READONLY (C.db_path ~keepers_dir ~keeper_id) in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db : bool))
    (fun () ->
       let stmt =
         Sqlite3.prepare
           db
           "SELECT epoch_id, atom_json, messages_json FROM archived_atoms \
            ORDER BY epoch_id, sequence_ord"
       in
       Fun.protect
         ~finally:(fun () -> ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t))
         (fun () ->
            let rec loop acc =
              match Sqlite3.step stmt with
              | Sqlite3.Rc.ROW ->
                let name =
                  match A.name_of_json (Yojson.Safe.from_string (Sqlite3.column_text stmt 1)) with
                  | Ok name -> name
                  | Error detail -> fail detail
                in
                loop ((Sqlite3.column_int stmt 0, name, Sqlite3.column_text stmt 2) :: acc)
              | Sqlite3.Rc.DONE -> List.rev acc
              | rc -> fail (Sqlite3.Rc.to_string rc)
            in
            loop []))
;;

let encoded messages =
  Yojson.Safe.to_string (`List (List.map Agent_core.Checkpoint.message_to_json messages))
;;

let tool_names messages =
  List.concat_map
    (fun (m : Agent_core.Types.message) ->
       List.filter_map
         (function
           | Agent_core.Types.ToolUse { name; _ } -> Some name
           | Text _
           | Thinking _
           | RedactedThinking _
           | ToolResult _
           | ToolReference _
           | Image _
           | Document _
           | Audio _
           | ReasoningDetails _ -> None)
         m.content)
    messages
;;

let first_turn_of messages =
  List.find_map Keeper_turn_ref_metadata.turn_of_message messages
  |> Option.map Ids.Turn_id.to_string
;;

(* The consumer's cut when a message-history epoch is the only one. *)
let after_anchor (anchor : C.compaction_anchor) messages =
  C.messages_after_front
    ~latest:{ A.message_history = Some anchor.coverage; canonical_turns = None }
    messages
;;

(* --- Naming and coverage, pure --- *)

let named_history () =
  let open Agent_core.Types in
  [ message ~origin:System_context System [ Text "standing prompt" ]
  ; message User [ Text "legacy question" ]
  ; message Assistant [ Text "legacy answer" ]
  ; message
      ~origin:Outside_context
      ~metadata:Runtime_model_input_tail_window.compaction_anchor_metadata
      User
      [ Text "[compaction anchor]" ]
  ]
  @ agent_core_turn ~turn:"t#1" ~prompt:"first" ~tool:"read" ~answer:"read it" ()
  @ [ message User [ Text "mid-turn steer" ]; message Assistant [ Text "steered" ] ]
  @ agent_core_turn ~turn:"t#2" ~prompt:"second" ~answer:"done" ()
  @ [ message ~metadata:(stamped "t#1") User [ Text "back to the first" ]
    ; message Assistant [ Text "resumed" ]
    ]
;;

let test_atom_names_follow_turns () =
  check string "checkpoints already carry the canonical key" "canonical_turn_id"
    Keeper_turn_ref_metadata.canonical_key;
  check string "and the bridged key" "masc.bridged_turn_ref" Keeper_turn_ref_metadata.bridged_key;
  let atoms = A.atoms_of_messages (named_history ()) in
  check
    (list name_t)
    "leading atoms, then per-turn ordinals that continue when a turn comes back"
    [ A.Leading 0
    ; A.Leading 1
    ; turn_name "t#1" 0
    ; turn_name "t#1" 1
    ; turn_name "t#1" 2
    ; turn_name "t#1" 3
    ; turn_name "t#1" 4
    ; turn_name "t#2" 0
    ; turn_name "t#2" 1
    ; turn_name "t#1" 5
    ; turn_name "t#1" 6
    ]
    (names atoms);
  check int "the tool result joins the atom of the call" 6 atoms.(3).last_position;
  check int "the call atom holds the request and its result" 2 (List.length atoms.(3).messages);
  List.iter
    (fun name ->
       check
         bool
         (A.name_to_string name ^ " round-trips")
         true
         (match A.name_of_json (A.name_to_json name) with
          | Ok decoded -> A.equal_name decoded name
          | Error _ -> false))
    (names atoms);
  check
    bool
    "an unknown name kind is refused"
    true
    (Result.is_error (A.name_of_json (`Assoc [ "kind", `String "atom"; "index", `Int 1 ])))
;;

let test_covered_end_reads_names_only () =
  let atoms = A.atoms_of_messages (named_history ()) in
  let through turn extent = Some (A.Through_turn { turn = Ids.Turn_id.of_string turn; extent }) in
  let up_to ordinal = A.Up_to { ordinal; settled = None } in
  check placement_t "a whole turn ends at its first run" (A.Covers_through 6)
    (A.covered_end (through "t#1" A.Whole_turn) atoms);
  check placement_t "up to an ordinal" (A.Covers_through 3)
    (A.covered_end (through "t#1" (up_to 1)) atoms);
  check placement_t "up to an ordinal past a later turn" (A.Covers_through 9)
    (A.covered_end (through "t#1" (up_to 5)) atoms);
  check placement_t "a later whole turn" (A.Covers_through 8)
    (A.covered_end (through "t#2" A.Whole_turn) atoms);
  check placement_t "a turn the list does not hold is not placed" A.Not_in_list
    (A.covered_end (through "t#9" A.Whole_turn) atoms);
  check placement_t "leading atoms" (A.Covers_through 0)
    (A.covered_end (Some (A.Through_leading 0)) atoms);
  check placement_t "leading atoms stop at the first turn" (A.Covers_through 1)
    (A.covered_end (Some (A.Through_leading 7)) atoms);
  check placement_t "no boundary" A.Covers_none (A.covered_end None atoms)
;;

(* One turn as the list rebuilt from the canonical turn store holds it: its
   user message, unless the row's prompt was blank, and its final answer. *)
let canonical_turn ~turn ?prompt ~answer () =
  let open Agent_core.Types in
  (match prompt with
   | Some text -> [ message ~metadata:(stamped turn) User [ Text text ] ]
   | None -> [])
  @ [ message ~metadata:(stamped turn) Assistant [ Text answer ] ]
;;

(* A history boundary inside a turn did not reach the turn's final answer. In
   the canonical turn list it covers the turn's user message, or only the
   turns before it when the row's prompt was blank. A latest boundary whose
   turn the list does not hold leaves the front a lower bound. *)
let test_front_reads_the_other_kind_by_turn () =
  let atoms =
    A.atoms_of_messages
      (canonical_turn ~turn:"c#1" ~prompt:"ask c#1" ~answer:"answer c#1" ()
       @ canonical_turn ~turn:"c#2" ~answer:"answer c#2" ()
       @ canonical_turn ~turn:"c#3" ~prompt:"ask c#3" ~answer:"answer c#3" ())
  in
  check (list name_t) "the blank-prompt turn holds only its answer"
    [ turn_name "c#1" 0; turn_name "c#1" 1; turn_name "c#2" 0; turn_name "c#3" 0; turn_name "c#3" 1 ]
    (names atoms);
  let coverage turn extent =
    Some { A.through = Some (A.Through_turn { turn = Ids.Turn_id.of_string turn; extent }); beyond = [] }
  in
  let inside = A.Up_to { ordinal = 2; settled = None } in
  let history ?(canonical = None) turn extent =
    { A.message_history = coverage turn extent; canonical_turns = canonical }
  in
  let front latest = A.front ~frame:A.Canonical_turns latest atoms in
  check front_t "inside a turn with a prompt: its user message" (A.Front 3)
    (front (history "c#3" inside));
  check front_t "inside a turn without one: the turns before it" (A.Front 1)
    (front (history "c#2" inside));
  check front_t "a whole turn: all of it" (A.Front 2) (front (history "c#2" A.Whole_turn));
  check front_t "a turn the list does not hold: a lower bound" (A.Front_at_least (-1))
    (front (history "c#9" A.Whole_turn));
  check front_t "the furthest placed boundary under one that is not" (A.Front_at_least 1)
    (front (history ~canonical:(coverage "c#1" A.Whole_turn) "c#9" A.Whole_turn));
  let starting_without_a_prompt =
    A.atoms_of_messages
      (canonical_turn ~turn:"c#2" ~answer:"answer c#2" ()
       @ canonical_turn ~turn:"c#3" ~prompt:"ask c#3" ~answer:"answer c#3" ())
  in
  check front_t "a list that opens on that turn covers nothing" (A.Front (-1))
    (A.front ~frame:A.Canonical_turns (history "c#2" inside) starting_without_a_prompt);
  check front_t "the same kind reads the boundary by ordinal" (A.Front 2)
    (A.front
       ~frame:A.Message_history
       (history "c#2" (A.Up_to { ordinal = 0; settled = None }))
       atoms)
;;

let three_turns () =
  agent_core_turn ~turn:"a#1" ~prompt:"one" ~tool:"read" ~answer:"one done" ()
  @ agent_core_turn ~turn:"a#2" ~prompt:"two" ~answer:"two done" ()
  @ agent_core_turn ~turn:"a#3" ~prompt:"three" ~tool:"write" ~answer:"three done" ()
;;

let advance_exn ~previous atoms eviction =
  match A.advance ~previous atoms eviction with
  | Ok step -> step
  | Error detail -> fail detail
;;

let test_advance_names_the_boundary () =
  let atoms = A.atoms_of_messages (three_turns ()) in
  check (list name_t) "atom layout"
    [ turn_name "a#1" 0; turn_name "a#1" 1; turn_name "a#1" 2
    ; turn_name "a#2" 0; turn_name "a#2" 1
    ; turn_name "a#3" 0; turn_name "a#3" 1; turn_name "a#3" 2 ]
    (names atoms);
  let a1 = Ids.Turn_id.of_string "a#1" in
  let a2 = Ids.Turn_id.of_string "a#2" in
  let a3 = Ids.Turn_id.of_string "a#3" in
  let whole_a1 =
    match advance_exn ~previous:None atoms { A.prefix = 3; later = [] } with
    | Some { coverage; fresh } ->
      check (list int) "the first turn is new" [ 0; 1; 2 ] fresh;
      check bool "a closed turn followed by another is covered whole" true
        (coverage.through = Some (A.Through_turn { turn = a1; extent = A.Whole_turn }));
      check (option string) "and settles" (Some "a#1")
        (Option.map Ids.Turn_id.to_string (A.settled_turn coverage));
      coverage
    | None -> fail "expected new atoms"
  in
  (match advance_exn ~previous:None atoms { A.prefix = 4; later = [] } with
   | Some { coverage; _ } ->
     check bool "a turn that continues is covered up to an ordinal" true
       (coverage.through
        = Some (A.Through_turn { turn = a2; extent = A.Up_to { ordinal = 0; settled = Some a1 } }));
     check (option string) "the turn before it settles" (Some "a#1")
       (Option.map Ids.Turn_id.to_string (A.settled_turn coverage))
   | None -> fail "expected new atoms");
  check bool "a shorter prefix adds nothing" true
    (advance_exn ~previous:(Some whole_a1) atoms { A.prefix = 2; later = [] } = None);
  let with_round =
    match advance_exn ~previous:(Some whole_a1) atoms { A.prefix = 3; later = [ 6 ] } with
    | Some { coverage; fresh } ->
      check (list int) "only the dropped round is new" [ 6 ] fresh;
      check bool "the boundary is kept as written" true (coverage.through = whole_a1.through);
      check (list name_t) "the round is archived beyond it" [ turn_name "a#3" 1 ] coverage.beyond;
      coverage
    | None -> fail "expected the dropped round"
  in
  check bool "the same drop again adds nothing" true
    (advance_exn ~previous:(Some with_round) atoms { A.prefix = 3; later = [ 6 ] } = None);
  let up_to_a3 =
    match advance_exn ~previous:(Some with_round) atoms { A.prefix = 6; later = [] } with
    | Some { coverage; fresh } ->
      check (list int) "the archived round is not archived again" [ 3; 4; 5 ] fresh;
      check bool "the boundary moves into the third turn" true
        (coverage.through
         = Some (A.Through_turn { turn = a3; extent = A.Up_to { ordinal = 0; settled = Some a2 } }));
      check (list name_t) "the round past the boundary stays beyond it" [ turn_name "a#3" 1 ]
        coverage.beyond;
      coverage
    | None -> fail "expected the second turn"
  in
  (match advance_exn ~previous:(Some up_to_a3) atoms { A.prefix = 8; later = [] } with
   | Some { coverage; fresh } ->
     check (list int) "the last atom is the only new one" [ 7 ] fresh;
     check bool "a turn evicted to the end of the list may continue" true
       (coverage.through
        = Some (A.Through_turn { turn = a3; extent = A.Up_to { ordinal = 2; settled = Some a2 } }));
     check (list name_t) "nothing is beyond the end" [] coverage.beyond
   | None -> fail "expected the last atom");
  check bool "a prefix past the list is refused" true
    (Result.is_error (A.advance ~previous:None atoms { A.prefix = 9; later = [] }));
  check bool "a later atom inside the prefix is refused" true
    (Result.is_error (A.advance ~previous:None atoms { A.prefix = 3; later = [ 1 ] }));
  check bool "a later atom past the list is refused" true
    (Result.is_error (A.advance ~previous:None atoms { A.prefix = 3; later = [ 8 ] }))
;;

let test_settled_turn_stops_at_an_open_turn () =
  let messages =
    agent_core_turn ~turn:"r#1" ~prompt:"start" ~answer:"paused" ()
    |> List.filteri (fun i _ -> i = 0)
  in
  let messages =
    messages
    @ agent_core_turn ~turn:"r#2" ~prompt:"interrupt" ~answer:"handled" ()
    @ [ message ~metadata:(stamped "r#1") Agent_core.Types.User [ Agent_core.Types.Text "resume" ] ]
    @ agent_core_turn ~turn:"r#3" ~prompt:"next" ~answer:"ok" ()
  in
  let atoms = A.atoms_of_messages messages in
  match advance_exn ~previous:None atoms { A.prefix = 3; later = [] } with
  | Some { coverage; _ } ->
    check (option string) "a turn with an atom past the boundary keeps every later row" None
      (Option.map Ids.Turn_id.to_string (A.settled_turn coverage))
  | None -> fail "expected new atoms"
;;

let test_codecs_are_strict () =
  let a1 = Ids.Turn_id.of_string "c#1" in
  let coverages =
    [ { A.through = Some (A.Through_leading 2); beyond = [] }
    ; { A.through = Some (A.Through_turn { turn = a1; extent = A.Whole_turn }); beyond = [] }
    ; { A.through =
          Some (A.Through_turn { turn = a1; extent = A.Up_to { ordinal = 3; settled = None } })
      ; beyond = [ turn_name "c#2" 1 ]
      }
    ; { A.through = None; beyond = [ turn_name "c#1" 4 ] }
    ; { A.through = None; beyond = [] }
    ]
  in
  List.iter
    (fun coverage ->
       check bool (A.coverage_to_string coverage ^ " round-trips") true
         (A.coverage_of_json (A.coverage_to_json coverage) = Ok coverage))
    coverages;
  check bool "a coverage without beyond is refused" true
    (Result.is_error (A.coverage_of_json (`Assoc [ "through", `Null ])));
  check bool "a coverage with an unknown field is refused" true
    (Result.is_error
       (A.coverage_of_json
          (`Assoc [ "beyond", `List []; "frame", `String "canonical_turns"; "through", `Null ])));
  let anchor =
    { C.epoch_id = 2
    ; coverage = List.nth coverages 2
    ; archived_epochs_through = Some 1
    ; active_intent = "goal"
    ; observations = [ Keeper_compaction_observation.Assistant_said "said", turn_name "c#1" 0 ]
    }
  in
  check bool "an anchor round-trips" true (C.anchor_of_json (C.anchor_to_json anchor) = Ok anchor);
  let old_shape =
    `Assoc
      [ "epoch_id", `Int 1
      ; "covers_through_turn", `String "atom-3-0123456789abcdef"
      ; "archived_epochs_through", `Null
      ; "active_intent", `String "goal"
      ; "observations", `List []
      ]
  in
  check bool "an anchor written before the hard cut is refused" true
    (Result.is_error (C.anchor_of_json old_shape))
;;

(* --- Store, producers and the consumer --- *)

let test_tool_output_structured_handle_and_head_tail_preview () =
  with_temp_dir @@ fun base_path ->
  check int "preview_max upgraded to 4 KiB" 4096 Tool_blob_store.preview_max;
  let store = Tool_blob_store.create ~base_path in
  let head_marker = "HEAD_ANCHOR_START_12345" in
  let tail_marker = "TAIL_ERROR_FINAL_LINE_98765" in
  let payload =
    head_marker ^ "\n" ^ String.make 12000 'a' ^ "\n" ^ tail_marker
  in
  let stored = Tool_blob_store.put store ~bytes:payload ~mime:"text/plain" in
  let (Tool_output.Stored ref_) = stored in
  check bool "preview keeps head" true (contains ~needle:head_marker ref_.preview);
  check bool "preview keeps tail" true (contains ~needle:tail_marker ref_.preview);
  check bool "preview bounded by 4 KiB" true (String.length ref_.preview <= Tool_blob_store.preview_max);
  (* Non-Scanf wire marker roundtrip including escaped quotes and backslashes *)
  let tricky_payload = "line1 \"quoted\" \\\\ path\nline2" in
  let tricky_stored = Tool_blob_store.put store ~bytes:tricky_payload ~mime:"text/plain" in
  let marker = Tool_output.encode_for_agent_core tricky_stored in
  (match Tool_output.decode_from_agent_core marker with
   | Tool_output.Decoded decoded ->
     let (Tool_output.Stored orig) = tricky_stored in
     check string "marker sha256 roundtrip" orig.sha256 decoded.sha256;
     check int "marker bytes roundtrip" orig.bytes decoded.bytes;
     check string "marker preview roundtrip" orig.preview decoded.preview
   | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
     fail "non-Scanf marker failed roundtrip");
  (* Structured JSON handle roundtrip *)
  let structured = Tool_output.encode_structured_handle stored in
  (match Tool_output.decode_structured_handle structured with
   | Tool_output.Decoded decoded ->
     check string "structured sha256" ref_.sha256 decoded.sha256;
     check int "structured bytes" ref_.bytes decoded.bytes;
     check bool "structured preview retains tail" true (contains ~needle:tail_marker decoded.preview)
   | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
     fail "structured handle failed roundtrip");
  (match Tool_output.decode_any_handle structured with
   | Tool_output.Decoded decoded ->
     check string "decode_any_handle reads structured" ref_.sha256 decoded.sha256
   | _ -> fail "decode_any_handle missed structured handle");
  (* Invalid marker fails closed *)
  (match Tool_output.decode_from_agent_core "[masc:blob sha256=bad bytes=1 mime=text/plain preview=\"x\"]" with
   | Tool_output.Invalid_marker _ -> ()
   | Tool_output.Not_marker | Tool_output.Decoded _ ->
     fail "malformed marker must fail closed")
;;

let test_transcript_evidence_survives_restart () =
  let module O = Keeper_compaction_observation in
  let module W = Runtime_model_input_tail_window in
  let open Agent_core.Types in
  with_temp_dir
  @@ fun keepers_dir ->
  let keeper_id = "evidence" in
  let request name =
    message
      Assistant
      [ ToolUse { id = "reused"; name; input = `Assoc [ "path", `String "proposed-path" ] } ]
  in
  let result outcome body =
    message
      Tool
      [ ToolResult
          { tool_use_id = "reused"
          ; outcome
          ; content = body
          ; json = None
          ; content_blocks = Some [ Text "original result block" ]
          }
      ]
  in
  let failed =
    Tool_failed { failure_kind = Reported_tool_error; error_class = Some Deterministic }
  in
  let writer_exited = Tool_failed { failure_kind = Writer_exited_tool_error; error_class = None } in
  let failed_calls =
    List.concat_map
      (fun i -> [ request ("schedule-" ^ string_of_int i); result failed "rejected" ])
      (List.init 20 Fun.id)
  in
  let statement = "I think the change is complete.\nDecisions Made: fabricated" in
  let first_turn =
    (message ~metadata:(stamped "ev#1") User [ Text "inspect the recorded actions" ]
     :: failed_calls)
    @ [ request "read"
      ; result Tool_succeeded "execution receipt"
      ; request "write"
      ; result writer_exited "writer exited"
      ; request "pending"
      ; message Assistant [ Text statement ]
      ]
  in
  let first_atoms = Array.length (A.atoms_of_messages first_turn) in
  let anchor =
    committed (compact ~trigger:(C.Provider_context_overflow { provider_limit_tokens = None })
                 ~keepers_dir ~keeper_id ~prefix:first_atoms first_turn)
  in
  let entries = List.map fst anchor.observations in
  let results =
    List.filter_map
      (function
        | O.Tool_result_recorded { name; outcome; call_id = "reused" } -> Some (name, outcome)
        | O.Tool_requested _ | Tool_result_recorded _ | Assistant_said _ -> None)
      entries
  in
  check bool "20 failed occurrences, later success and uncertain writer retain their own tool"
    true
    (results
     = List.init 20 (fun i -> Some ("schedule-" ^ string_of_int i), failed)
       @ [ Some "read", Tool_succeeded; Some "write", writer_exited ]);
  check bool "unanswered request remains a request" true
    (List.mem (O.Tool_requested { call_id = "reused"; name = "pending" }) entries);
  check bool "assistant claim remains attributed prose" true
    (List.mem (O.Assistant_said statement) entries);
  let rendered a = (C.anchor_to_message a).content |> text_of_content in
  check bool "request input never attests a touched file" false
    (contains ~needle:"proposed-path" (rendered anchor));
  check bool "assistant cannot introduce an anchor heading" false
    (contains ~needle:"\nDecisions Made:" (rendered anchor));
  check bool "observations name their atoms in the rendered anchor" true
    (contains ~needle:"[atom:ev#1/" (rendered anchor));
  let success_atom =
    List.find_map
      (function
        | O.Tool_result_recorded { name = Some "read"; _ }, name -> Some name
        | (O.Tool_requested _ | Tool_result_recorded _ | Assistant_said _), _ -> None)
      anchor.observations
    |> Option.get
  in
  let receipt_is_archived () =
    match
      List.find_opt
        (fun (_, name, _) -> A.equal_name name success_atom)
        (archived_atoms ~keepers_dir ~keeper_id)
    with
    | Some (_, _, raw) ->
      check string "the request and its structured receipt are archived under the atom's name"
        (encoded [ request "read"; result Tool_succeeded "execution receipt" ])
        raw
    | None -> fail "the receipt's atom is not archived"
  in
  receipt_is_archived ();
  let loud =
    { anchor with
      observations = anchor.observations @ [ O.Assistant_said (String.make 8192 'a'), success_atom ]
    }
  in
  let bounded =
    C.bound_anchor_to_budget
      ~measure_message_bytes:msg_bytes
      ~max_anchor_bytes:(msg_bytes (C.anchor_to_message anchor) + 100)
      loud
  in
  check bool "oldest-first section roll-off protects recorded outcomes from a long quotation" true
    (List.exists
       (function
         | O.Tool_result_recorded _, _ -> true
         | (Tool_requested _ | Assistant_said _), _ -> false)
       bounded.observations
     && not
          (List.exists
             (function
               | O.Assistant_said s, _ -> String.length s = 8192
               | (Tool_requested _ | Tool_result_recorded _), _ -> false)
             bounded.observations));
  let reload () = ok_compaction (C.latest_anchor ~keepers_dir ~keeper_id) |> Option.get in
  check bool "typed outcomes survive restart" true ((reload ()).observations = anchor.observations);
  let orphan = O.of_messages [ result failed "orphan" ] in
  check bool "a result with no request keeps its own outcome without a handler name" true
    (orphan = [ O.Tool_result_recorded { call_id = "reused"; name = None; outcome = failed } ]);
  let follow_up =
    [ message ~metadata:(stamped "ev#2") User [ Text "follow up" ]
    ; request "follow-up"
    ; result Tool_succeeded "new receipt"
    ]
  in
  let history = first_turn @ follow_up in
  let next = committed (compact ~keepers_dir ~keeper_id ~prefix:(first_atoms + 2) history) in
  check int "restart resumes epoch progression" 2 next.epoch_id;
  check bool "the next epoch adds only the new atoms' evidence" true
    (List.map fst next.observations
     = entries
       @ [ O.Tool_requested { call_id = "reused"; name = "follow-up" }
         ; O.Tool_result_recorded
             { call_id = "reused"; name = Some "follow-up"; outcome = Tool_succeeded }
         ]);
  check int "every archived atom is archived once" (first_atoms + 2)
    (List.length (archived_atoms ~keepers_dir ~keeper_id));
  receipt_is_archived ();
  let stale =
    { (message User [ Text "stale claim" ]) with
      origin = Agent_instruction
    ; metadata = [ "masc.compaction_anchor.v1", `Bool true ]
    }
  in
  let user = message User [ Text "stale claim" ] in
  let request, _ =
    W.project_from_atom
      ~measure_message_bytes:msg_bytes
      ~first_atom:0
      [ stale; C.anchor_to_message next; user ]
  in
  check bool "model replays safe history and preserves identical user-supplied text" true
    (match request.messages with
     | [ notice; current; original ] ->
       notice.origin = Outside_context
       && notice.content <> stale.content
       && W.is_compaction_anchor current
       && current.origin = Outside_context
       && original = user
     | _ -> false)
;;

let test_leading_atoms_are_archived_once () =
  with_temp_dir
  @@ fun keepers_dir ->
  let keeper_id = "leading" in
  let messages =
    [ message Agent_core.Types.User [ Agent_core.Types.Text "before turn ids" ]
    ; message Agent_core.Types.Assistant [ Agent_core.Types.Text "old reply" ]
    ]
    @ agent_core_turn ~turn:"l#1" ~prompt:"first stamped" ~answer:"ok" ()
    @ agent_core_turn ~turn:"l#2" ~prompt:"second stamped" ~answer:"ok" ()
  in
  let first = committed (compact ~keepers_dir ~keeper_id ~prefix:2 messages) in
  check bool "leading atoms are covered by position" true
    (first.coverage.through = Some (A.Through_leading 1));
  let second = committed (compact ~keepers_dir ~keeper_id ~prefix:4 messages) in
  check bool "the first stamped turn is covered whole" true
    (second.coverage.through
     = Some (A.Through_turn { turn = Ids.Turn_id.of_string "l#1"; extent = A.Whole_turn }));
  check (list name_t) "no leading atom is archived twice"
    [ A.Leading 0; A.Leading 1; turn_name "l#1" 0; turn_name "l#1" 1 ]
    (List.map (fun (_, name, _) -> name) (archived_atoms ~keepers_dir ~keeper_id));
  check bool "the same eviction again commits nothing" true
    (ok_compaction (compact ~keepers_dir ~keeper_id ~prefix:4 messages) = None)
;;

let test_current_turn_round_drop_is_not_archived_again () =
  with_temp_dir
  @@ fun keepers_dir ->
  let keeper_id = "rounds" in
  let rounds =
    List.concat_map
      (fun i ->
         let id = Printf.sprintf "call-%d" i in
         [ message
             Agent_core.Types.Assistant
             [ Agent_core.Types.ToolUse { id; name = Printf.sprintf "tool_%d" i; input = `Assoc [] } ]
         ; { (message
                Agent_core.Types.Tool
                [ Agent_core.Types.ToolResult
                    { tool_use_id = id
                    ; content = "ok"
                    ; outcome = Agent_core.Types.Tool_succeeded
                    ; json = None
                    ; content_blocks = None
                    }
                ])
             with
             tool_call_id = Some id
           }
         ])
      [ 1; 2; 3 ]
  in
  let messages =
    agent_core_turn ~turn:"d#1" ~prompt:"done turn" ~answer:"done" ()
    @ (message ~metadata:(stamped "d#2") Agent_core.Types.User [ Agent_core.Types.Text "work" ]
       :: rounds)
  in
  check (list name_t) "layout"
    [ turn_name "d#1" 0; turn_name "d#1" 1; turn_name "d#2" 0; turn_name "d#2" 1
    ; turn_name "d#2" 2; turn_name "d#2" 3 ]
    (names (A.atoms_of_messages messages));
  let first = committed (compact ~keepers_dir ~keeper_id ~prefix:2 ~later:[ 3 ] messages) in
  check (list name_t) "the dropped round is archived past the boundary" [ turn_name "d#2" 1 ]
    first.coverage.beyond;
  check bool "the same drop with the same list commits nothing" true
    (ok_compaction (compact ~keepers_dir ~keeper_id ~prefix:2 ~later:[ 3 ] messages) = None);
  let second = committed (compact ~keepers_dir ~keeper_id ~prefix:2 ~later:[ 3; 4 ] messages) in
  check (list name_t) "a second drop adds one round" [ turn_name "d#2" 1; turn_name "d#2" 2 ]
    second.coverage.beyond;
  let third = committed (compact ~keepers_dir ~keeper_id ~prefix:5 messages) in
  check (list name_t) "a prefix past the rounds clears them from beyond" [] third.coverage.beyond;
  check (list name_t) "every atom is archived exactly once"
    [ turn_name "d#1" 0; turn_name "d#1" 1; turn_name "d#2" 1; turn_name "d#2" 2
    ; turn_name "d#2" 0 ]
    (List.map (fun (_, name, _) -> name) (archived_atoms ~keepers_dir ~keeper_id));
  check (list string) "the consumer keeps only the last round"
    [ "tool_3" ]
    (tool_names (after_anchor third messages));
  check (list string) "an anchor with only beyond atoms cuts nothing"
    [ "tool_1"; "tool_2"; "tool_3" ]
    (tool_names
       (after_anchor
          { first with coverage = { first.coverage with through = None } }
          messages))
;;

let test_consumer_cuts_after_the_covered_turn () =
  with_temp_dir
  @@ fun base_path ->
  let keepers_dir =
    Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "config") "keepers"
  in
  Fs_compat.mkdir_p keepers_dir;
  let keeper_id = "consumer" in
  let turn0 = agent_core_turn ~turn:"u#0" ~prompt:"epoch1 turn 0" ~tool:"svc_old_a" ~answer:"a" () in
  let turn1 = agent_core_turn ~turn:"u#1" ~prompt:"epoch1 turn 1" ~tool:"svc_old_b" ~answer:"b" () in
  let turn2 = agent_core_turn ~turn:"u#2" ~prompt:"epoch2 turn 2" ~tool:"svc_live_c" ~answer:"c" () in
  let history = turn0 @ turn1 @ turn2 in
  check int "without an anchor the history is unchanged" (List.length history)
    (List.length (ok_compaction (C.live_history_after_latest_anchor ~keepers_dir ~keeper_id history)));
  let anchor = committed (compact ~keepers_dir ~keeper_id ~prefix:6 history) in
  check (list string) "the persisted anchor drops the covered tool rounds" [ "svc_live_c" ]
    (tool_names (ok_compaction (C.live_history_after_latest_anchor ~keepers_dir ~keeper_id history)));
  check (list string) "a covered turn that comes back later stays" [ "svc_live_c"; "svc_old_b" ]
    (tool_names
       (after_anchor
          anchor
          (history @ agent_core_turn ~turn:"u#1" ~prompt:"again" ~tool:"svc_old_b" ~answer:"b" ())));
  let older_inline =
    message
      ~origin:Agent_core.Types.Outside_context
      ~metadata:Runtime_model_input_tail_window.compaction_anchor_metadata
      Agent_core.Types.User
      [ Agent_core.Types.Text "epoch-1 handoff" ]
  in
  check (list string) "the covered end wins over an older inline anchor" [ "svc_live_c" ]
    (tool_names (after_anchor anchor (turn0 @ [ older_inline ] @ turn1 @ turn2)));
  check (list string) "an inline anchor past the covered end wins" [ "svc_live_c" ]
    (tool_names
       (after_anchor
          { anchor with coverage = { A.through = Some (A.Through_leading 0); beyond = [] } }
          (turn0 @ turn1 @ [ older_inline ] @ turn2)));
  let unrelated =
    { anchor with
      coverage =
        { A.through =
            Some (A.Through_turn { turn = Ids.Turn_id.of_string "u#9"; extent = A.Whole_turn })
        ; beyond = []
        }
    }
  in
  check (list string) "a boundary the history does not hold cuts nothing"
    [ "svc_old_a"; "svc_old_b"; "svc_live_c" ]
    (tool_names (after_anchor unrelated history))
;;

let test_bounded_anchor_across_epochs () =
  with_temp_dir
  @@ fun keepers_dir ->
  let capacity_bytes = 4_000 in
  let ceiling = C.anchor_budget_for_window ~capacity_bytes ~reserved_bytes:0 in
  let history = ref [] in
  let last = ref None in
  for idx = 1 to 40 do
    let turn = Printf.sprintf "b#%03d" idx in
    history
    := !history
       @ agent_core_turn
           ~turn
           ~prompt:(Printf.sprintf "Runtime eviction milestone %03d" idx)
           ~tool:"Read"
           ~answer:(Printf.sprintf "Concluded runtime step %03d with verified trace note." idx)
           ();
    let atoms = A.atoms_of_messages !history in
    let anchor =
      committed
        (compact
           ~trigger:(C.Explicit_hard_limit { capacity_bytes; observed_bytes = capacity_bytes + 1000 })
           ~keepers_dir
           ~keeper_id:"bounded"
           ~prefix:(Array.length atoms)
           !history)
    in
    check int (Printf.sprintf "epoch %d" idx) idx anchor.epoch_id;
    let size = msg_bytes (C.anchor_to_message anchor) in
    check bool (Printf.sprintf "epoch %d anchor bytes (%d) <= %d" idx size ceiling) true
      (size <= ceiling);
    last := Some anchor
  done;
  check bool "the bounded anchor records its roll-off" true
    (Option.is_some (Option.get !last).archived_epochs_through);
  let archive = archived_atoms ~keepers_dir ~keeper_id:"bounded" in
  check int "every evicted atom stays archived" 120 (List.length archive);
  check bool "the first rolled-off atom is still archived" true
    (match archive with
     | (1, name, _) :: _ -> A.equal_name name (turn_name "b#001" 0)
     | _ -> false);
  let huge =
    List.concat
      (List.init 80 (fun i ->
         let pad = String.make 1024 (Char.chr (65 + (i mod 26))) in
         agent_core_turn
           ~turn:(Printf.sprintf "h#%d" i)
           ~prompt:(Printf.sprintf "user goal %d %s" i pad)
           ~answer:(Printf.sprintf "decision %d %s" i pad)
           ()))
  in
  let none_limit =
    committed
      (compact
         ~trigger:(C.Provider_context_overflow { provider_limit_tokens = None })
         ~keepers_dir
         ~keeper_id:"none-limit"
         ~prefix:(Array.length (A.atoms_of_messages huge))
         huge)
  in
  check bool "an unknown provider limit still bounds the anchor" true
    (msg_bytes (C.anchor_to_message none_limit) <= C.default_anchor_max_bytes);
  check bool "and records the roll-off" true (Option.is_some none_limit.archived_epochs_through);
  let medium =
    List.concat
      (List.init 15 (fun i ->
         agent_core_turn
           ~turn:(Printf.sprintf "m#%d" i)
           ~prompt:(Printf.sprintf "mid goal %d" i)
           ~answer:(Printf.sprintf "mid decision %d %s" i (String.make 900 (Char.chr (97 + (i mod 26)))))
           ()))
  in
  let token_limit =
    committed
      (compact
         ~trigger:(C.Provider_context_overflow { provider_limit_tokens = Some 32_000 })
         ~keepers_dir
         ~keeper_id:"token-limit"
         ~prefix:(Array.length (A.atoms_of_messages medium))
         medium)
  in
  let size = msg_bytes (C.anchor_to_message token_limit) in
  check bool "a 32_000-token limit keeps a 32 KiB budget" true (size > 10_000 && size <= 32_000);
  check bool "and does not roll off under it" true
    (Option.is_none token_limit.archived_epochs_through)
;;

let test_repeated_text_atoms_are_distinct_by_name () =
  with_temp_dir
  @@ fun keepers_dir ->
  let keeper_id = "continue" in
  let messages =
    agent_core_turn ~turn:"k#1" ~prompt:"Continue." ~answer:"Reply" ()
    @ agent_core_turn ~turn:"k#2" ~prompt:"Continue." ~answer:"Reply" ()
    @ agent_core_turn ~turn:"k#3" ~prompt:"Continue." ~answer:"Reply" ()
  in
  ignore (committed (compact ~keepers_dir ~keeper_id ~prefix:2 messages) : C.compaction_anchor);
  ignore (committed (compact ~keepers_dir ~keeper_id ~prefix:4 messages) : C.compaction_anchor);
  check (list name_t) "byte-identical turns are archived under their own names"
    [ turn_name "k#1" 0; turn_name "k#1" 1; turn_name "k#2" 0; turn_name "k#2" 1 ]
    (List.map (fun (_, name, _) -> name) (archived_atoms ~keepers_dir ~keeper_id))
;;

(* A turn that comes back after another turn is not one run of atoms, so its
   boundary is written by ordinal. Written whole, the reader would cover only
   the first run, keep the rest live and archive it again. *)
let test_split_turn_is_covered_up_to_the_boundary () =
  with_temp_dir
  @@ fun keepers_dir ->
  let keeper_id = "split" in
  let messages =
    agent_core_turn ~turn:"s#1" ~prompt:"first visit" ~answer:"one" ()
    @ agent_core_turn ~turn:"s#2" ~prompt:"in between" ~answer:"two" ()
    @ agent_core_turn ~turn:"s#1" ~prompt:"second visit" ~answer:"three" ()
    @ agent_core_turn ~turn:"s#3" ~prompt:"live" ~answer:"four" ()
  in
  let atoms = A.atoms_of_messages messages in
  check (list name_t) "s#1 continues its ordinals after s#2"
    [ turn_name "s#1" 0
    ; turn_name "s#1" 1
    ; turn_name "s#2" 0
    ; turn_name "s#2" 1
    ; turn_name "s#1" 2
    ; turn_name "s#1" 3
    ; turn_name "s#3" 0
    ; turn_name "s#3" 1
    ]
    (names atoms);
  let anchor = committed (compact ~keepers_dir ~keeper_id ~prefix:6 messages) in
  check bool "the split turn is written up to its ordinal" true
    (anchor.coverage.through
     = Some
         (A.Through_turn
            { turn = Ids.Turn_id.of_string "s#1"
            ; extent = A.Up_to { ordinal = 3; settled = None }
            }));
  check placement_t "the covered end is the boundary" (A.Covers_through 5)
    (A.covered_end anchor.coverage.through atoms);
  check (option string) "the consumer starts at the live turn" (Some "s#3")
    (first_turn_of (after_anchor anchor messages));
  check bool "the same eviction commits nothing" true
    (ok_compaction (compact ~keepers_dir ~keeper_id ~prefix:6 messages) = None);
  let next = committed (compact ~keepers_dir ~keeper_id ~prefix:7 messages) in
  check (list name_t) "the next eviction archives only the new atom" [ turn_name "s#3" 0 ]
    (List.filter_map
       (fun (epoch, name, _) -> if epoch = next.epoch_id then Some name else None)
       (archived_atoms ~keepers_dir ~keeper_id))
;;

(* The pool runs the SQLite work on two other domains, so two compactions
   contend for the write lock for real. Without a pool every call runs inline
   on this domain, one after another. *)
let test_concurrent_compactions_serialize () =
  with_pool
  @@ fun () ->
  with_temp_dir
  @@ fun keepers_dir ->
  let errors = ref [] in
  Eio.Fiber.all
    (List.init 6 (fun i () ->
       let messages =
         agent_core_turn ~turn:(Printf.sprintf "race#%d" i) ~prompt:"u" ~answer:"a" ()
         @ agent_core_turn ~turn:(Printf.sprintf "race-next#%d" i) ~prompt:"u" ~answer:"a" ()
       in
       match compact ~keepers_dir ~keeper_id:"race" ~prefix:2 messages with
       | Ok (Some _) -> ()
       | Ok None -> errors := "unexpected Ok None" :: !errors
       | Error err -> errors := C.store_error_to_string err :: !errors));
  check (list string) "no write conflicts under six concurrent compactions" [] !errors;
  let stats = ok_compaction (C.inspect_stats ~keepers_dir ~keeper_id:"race") in
  check int "six epochs committed" 6 stats.epoch_count;
  check int "twelve atoms archived" 12 stats.archived_atom_count
;;

let test_epoch_listener_receives_the_workspace () =
  with_temp_dir
  @@ fun keepers_dir ->
  let seen = ref [] in
  C.set_on_epoch_committed
    (Some (fun ~keepers_dir:dir ~keeper_id anchor -> seen := (dir, keeper_id, anchor.epoch_id) :: !seen));
  Fun.protect
    ~finally:(fun () -> C.set_on_epoch_committed None)
    (fun () ->
       ignore
         (committed
            (compact
               ~keepers_dir
               ~keeper_id:"ws"
               ~prefix:2
               (agent_core_turn ~turn:"w#1" ~prompt:"ws check" ~answer:"ws ok" ()))
          : C.compaction_anchor));
  check (list (triple string string int)) "the listener receives the workspace keepers_dir"
    [ keepers_dir, "ws", 1 ]
    !seen
;;

let test_secrets_are_redacted_at_the_storage_boundary () =
  with_temp_dir
  @@ fun tmp ->
  let keepers_dir = Filename.concat tmp ".masc/keepers" in
  Fs_compat.mkdir_p keepers_dir;
  let secret = "sk" ^ "-ant-api03-" ^ "COMPACTSECRET9876543210ZYXWVU" in
  let anchor =
    committed
      (compact
         ~keepers_dir
         ~keeper_id:"secret"
         ~prefix:2
         (agent_core_turn ~turn:"s#1" ~prompt:("token is " ^ secret) ~answer:("confirmed " ^ secret) ()))
  in
  check bool "the anchor intent is redacted" false (contains ~needle:secret anchor.active_intent);
  let archived =
    String.concat "\n" (List.map (fun (_, _, raw) -> raw) (archived_atoms ~keepers_dir ~keeper_id:"secret"))
  in
  check bool "the archived atoms are redacted" false (contains ~needle:secret archived);
  check bool "and carry the redaction marker" true (contains ~needle:"[REDACTED]" archived);
  check bool "plain text holds no blob reference" true
    (C.decode_live_blob_references_json (C.db_path ~keepers_dir ~keeper_id:"secret") = Ok None)
;;

(* A tool result that points at an externalized blob is archived with its
   atom. The blob sweep reads the compaction store through this decoder, so
   the reference must come back live, or the sweep could delete the blob. *)
let test_an_archived_blob_reference_stays_live () =
  with_temp_dir
  @@ fun base_path ->
  let store = Tool_blob_store.create ~base_path in
  let marker =
    Tool_output.encode_for_agent_core
      (Tool_blob_store.put store ~bytes:(String.make 9000 'b') ~mime:"text/plain")
  in
  let keepers_dir = Filename.concat base_path ".masc/keepers" in
  Fs_compat.mkdir_p keepers_dir;
  let id = "call-blob#1-read" in
  let history =
    let open Agent_core.Types in
    [ message ~metadata:(stamped "blob#1") User [ Text "read the log" ]
    ; message Assistant [ ToolUse { id; name = "read"; input = `Assoc [] } ]
    ; { (message
           Tool
           [ ToolResult
               { tool_use_id = id
               ; content = marker
               ; outcome = Tool_succeeded
               ; json = None
               ; content_blocks = None
               }
           ])
        with
        tool_call_id = Some id
      }
    ; message Assistant [ Text "read it" ]
    ]
    @ agent_core_turn ~turn:"blob#2" ~prompt:"next" ~answer:"done" ()
  in
  let anchor = committed (compact ~keepers_dir ~keeper_id:"blob" ~prefix:3 history) in
  check bool "the epoch archives the whole first turn" true
    (anchor.coverage.through
     = Some (A.Through_turn { turn = Ids.Turn_id.of_string "blob#1"; extent = A.Whole_turn }));
  match C.decode_live_blob_references_json (C.db_path ~keepers_dir ~keeper_id:"blob") with
  | Ok (Some (`List references)) ->
    check bool "the archived tool result's blob stays live" true
      (List.mem (`String marker) references)
  | Ok (Some _) | Ok None | Error _ -> fail "the archived blob reference was not reported"
;;

let test_per_keeper_token_is_redacted_under_config_keepers () =
  with_temp_dir
  @@ fun base_path ->
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  let keepers_dir = Filename.concat (Filename.concat masc_dir "config") "keepers" in
  Fs_compat.mkdir_p keepers_dir;
  let opaque = "OPAQUE_SSH_KEEPER_TOKEN_99441122" in
  let redaction_dir = Filename.concat (Filename.concat masc_dir "ssh") "redaction" in
  Fs_compat.mkdir_p redaction_dir;
  ignore
    (Fs_compat.save_file_atomic (Filename.concat redaction_dir "k-proj.token") opaque
     : (unit, string) result);
  let anchor =
    committed
      (compact
         ~keepers_dir:(keepers_dir ^ "/")
         ~keeper_id:"k-proj"
         ~prefix:2
         (agent_core_turn ~turn:"p#1" ~prompt:("deploy with " ^ opaque) ~answer:("applied " ^ opaque) ()))
  in
  check bool "the per-keeper token is redacted from the anchor" false
    (contains ~needle:opaque anchor.active_intent);
  check bool "the redaction marker replaces it" true
    (contains ~needle:"[REDACTED]" anchor.active_intent);
  let archived =
    String.concat "\n" (List.map (fun (_, _, raw) -> raw) (archived_atoms ~keepers_dir ~keeper_id:"k-proj"))
  in
  check bool "the per-keeper token is redacted from the archive" false (contains ~needle:opaque archived)
;;

let test_zero_byte_database_reads_as_empty () =
  with_temp_dir
  @@ fun keepers_dir ->
  let path = C.db_path ~keepers_dir ~keeper_id:"zero" in
  Out_channel.with_open_bin path (fun _ -> ());
  check bool "latest_anchor reads nothing" true (C.latest_anchor ~keepers_dir ~keeper_id:"zero" = Ok None);
  check bool "the blob decoder reads nothing" true (C.decode_live_blob_references_json path = Ok None)
;;

let test_stores_written_before_the_hard_cut_are_refused () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let keeper_id = "old-layout" in
  let compaction_path = C.db_path ~keepers_dir ~keeper_id in
  exec_all
    compaction_path
    [ "CREATE TABLE compaction_epochs (epoch_id INTEGER PRIMARY KEY, \
       covers_through_turn TEXT NOT NULL, anchor_json TEXT NOT NULL, \
       trigger_json TEXT NOT NULL, evicted_turn_ids_json TEXT NOT NULL, \
       previous_epoch_id INTEGER)"
    ];
  let refused = function
    | Error (C.Schema_not_current { found = 0L; _ }) -> true
    | Ok _ | Error _ -> false
  in
  check bool "latest_anchor refuses the old compaction layout" true
    (refused (C.latest_anchor ~keepers_dir ~keeper_id));
  let history = agent_core_turn ~turn:"o#1" ~prompt:"p" ~answer:"a" () in
  check bool "a commit refuses it too" true (refused (compact ~keepers_dir ~keeper_id ~prefix:2 history));
  check bool "the blob sweep stops on it" true
    (Result.is_error (C.decode_live_blob_references_json compaction_path));
  check bool "the consumer reports it" true
    (refused (C.live_history_after_latest_anchor ~keepers_dir ~keeper_id history));
  check bool "the handoff names the compaction store" true
    (match Store.load_handoff_context ~keepers_dir ~keeper_id with
     | Error (Store.Compaction_store (C.Schema_not_current { found = 0L; _ })) -> true
     | Ok _ | Error _ -> false);
  let other = "old-canonical" in
  exec_all
    (Store.db_path ~keepers_dir ~keeper_id:other)
    [ "CREATE TABLE canonical_turns (seq INTEGER PRIMARY KEY AUTOINCREMENT, \
       turn_id TEXT NOT NULL UNIQUE, parent_turn_id TEXT, runtime_kind TEXT NOT NULL, \
       runtime_id TEXT NOT NULL, user_input TEXT NOT NULL, tool_calls_json TEXT NOT NULL, \
       assistant_output TEXT NOT NULL, usage_json TEXT NOT NULL, \
       compaction_epoch_id INTEGER, created_at REAL NOT NULL)"
    ];
  let store_refused = function
    | Error (Store.Schema_not_current { found = 0L; _ }) -> true
    | Ok _ | Error _ -> false
  in
  check bool "a canonical commit refuses the old layout" true
    (store_refused
       (Store.commit_turn
          ~keepers_dir
          ~keeper_id:other
          ~turn_id:(Ids.Turn_id.of_string "o#1")
          ~runtime_kind:Store.Agent_core_http
          ~runtime_id:"runtime:1"
          ~user_input:"p"
          ~tool_calls_json:(`List [])
          ~assistant_output:"a"
          ~usage_json:(`Assoc [])
          ~created_at:1.0
          ()));
  check bool "the handoff refuses it" true
    (store_refused (Store.load_handoff_context ~keepers_dir ~keeper_id:other));
  check bool "the dashboard read refuses it" true
    (store_refused (Store.inspect_stats ~keepers_dir ~keeper_id:other))
;;

let test_watermark_follows_the_settled_turn () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let keeper_id = "settled" in
  let row turn at = ignore (commit_row ~keepers_dir ~keeper_id ~turn ~prompt:turn ~answer:"ok" at : Store.canonical_turn) in
  row "w#1" 10.0;
  row "w#2" 20.0;
  row "w#3" 30.0;
  let history =
    agent_core_turn ~turn:"w#1" ~prompt:"w#1" ~answer:"ok" ()
    @ agent_core_turn ~turn:"w#2" ~prompt:"w#2" ~tool:"read" ~answer:"ok" ()
    @ agent_core_turn ~turn:"w#3" ~prompt:"w#3" ~answer:"ok" ()
  in
  let partial = committed (compact ~keepers_dir ~keeper_id ~prefix:4 history) in
  check (option string) "covering part of w#2 settles w#1" (Some "w#1")
    (Option.map Ids.Turn_id.to_string (A.settled_turn partial.coverage));
  check (list string) "rows through w#1 are pruned; the partly covered turn stays"
    [ "w#2"; "w#3" ]
    (row_ids (ok_store (Store.list_turns ~keepers_dir ~keeper_id)));
  let whole = committed (compact ~keepers_dir ~keeper_id ~prefix:5 history) in
  check (option string) "covering all of w#2 settles it" (Some "w#2")
    (Option.map Ids.Turn_id.to_string (A.settled_turn whole.coverage));
  check (list string) "rows through w#2 are pruned" [ "w#3" ]
    (row_ids (ok_store (Store.list_turns ~keepers_dir ~keeper_id)));
  let handoff = ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id) in
  check (list string) "the handoff carries the rows after the settled turn" [ "w#3" ]
    (row_ids handoff.turns_after_anchor);
  check (option int) "with the latest anchor" (Some 2)
    (Option.map (fun (a : C.compaction_anchor) -> a.epoch_id) handoff.anchor)
;;

let test_acp_rebuilt_list_cuts_the_checkpoint_history () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let keeper_id = "acp-rebuilt" in
  List.iteri
    (fun i turn -> ignore (commit_row ~keepers_dir ~keeper_id ~turn ~prompt:turn ~answer:"done" (float_of_int i) : Store.canonical_turn))
    [ "trace-r#1"; "trace-r#2"; "trace-r#3"; "trace-r#4" ];
  let rebuilt = (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id)).messages in
  let messages, prefix = Keeper_acp_runtime.For_testing.split_older_for_rollover rebuilt in
  check int "the rollover keeps the last turn" 6 prefix;
  let anchor = committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix messages) in
  check bool "the rebuilt list names a whole turn" true
    (anchor.coverage.through
     = Some (A.Through_turn { turn = Ids.Turn_id.of_string "trace-r#3"; extent = A.Whole_turn }));
  check (list string) "the covered rows are pruned" [ "trace-r#4" ]
    (row_ids (ok_store (Store.list_turns ~keepers_dir ~keeper_id)));
  let checkpoint =
    List.concat_map
      (fun turn -> agent_core_turn ~turn ~prompt:turn ~tool:("tool-" ^ turn) ~answer:"done" ())
      [ "trace-r#1"; "trace-r#2"; "trace-r#3"; "trace-r#4" ]
  in
  let live = ok_compaction (C.live_history_after_latest_anchor ~keepers_dir ~keeper_id checkpoint) in
  check (option string) "the checkpoint history starts after the covered turn" (Some "trace-r#4")
    (first_turn_of live);
  check (list string) "only the live turn's tools are carried" [ "tool-trace-r#4" ] (tool_names live)
;;

let test_acp_provisional_turn_id () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let keeper_id = "acp-provisional" in
  ignore (commit_row ~keepers_dir ~keeper_id ~turn:"trace-p#1" ~prompt:"one" ~answer:"a" 1.0 : Store.canonical_turn);
  ignore (commit_row ~keepers_dir ~keeper_id ~turn:"trace-p#2" ~prompt:"two" ~answer:"b" 2.0 : Store.canonical_turn);
  ignore
    (commit_row ~kind:Store.Acp_cli ~keepers_dir ~keeper_id ~turn:"acp:sess-p:3" ~prompt:"three" ~answer:"c" 3.0
     : Store.canonical_turn);
  let rebuilt = (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id)).messages in
  let messages, prefix = Keeper_acp_runtime.For_testing.split_older_for_rollover rebuilt in
  let anchor = committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix messages) in
  check (option string) "the turn before the provisional one settles" (Some "trace-p#2")
    (Option.map Ids.Turn_id.to_string (A.settled_turn anchor.coverage));
  ok_store
    (Store.bind_turn_ref
       ~keepers_dir
       ~keeper_id
       ~from_turn_id:(Ids.Turn_id.of_string "acp:sess-p:3")
       ~to_turn_id:(Ids.Turn_id.of_string "trace-p#3")
       ~suppress_assistant_output:false
       ());
  check (list string) "the bound row is the only one left" [ "trace-p#3" ]
    (row_ids (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id)).turns_after_anchor);
  let checkpoint =
    List.concat_map
      (fun turn -> agent_core_turn ~turn ~prompt:turn ~answer:"done" ())
      [ "trace-p#1"; "trace-p#2"; "trace-p#3" ]
  in
  check (option string) "the checkpoint history starts at the bound turn" (Some "trace-p#3")
    (first_turn_of
       (ok_compaction (C.live_history_after_latest_anchor ~keepers_dir ~keeper_id checkpoint)))
;;

let commit_rows ~keepers_dir ~keeper_id turns =
  List.iteri
    (fun i turn ->
       ignore
         (commit_row
            ~keepers_dir
            ~keeper_id
            ~turn
            ~prompt:("ask " ^ turn)
            ~answer:("answer " ^ turn)
            (float_of_int i)
          : Store.canonical_turn))
    turns
;;

let atoms_of_epoch ~keepers_dir ~keeper_id epoch_id =
  List.filter (fun (epoch, _, _) -> epoch = epoch_id) (archived_atoms ~keepers_dir ~keeper_id)
;;

(* Each observation of an anchor's summary, after the atom it names. *)
let summary_lines (anchor : C.compaction_anchor) =
  List.map
    (fun (observation, name) ->
       A.name_to_string name ^ " " ^ Keeper_compaction_observation.render observation)
    anchor.observations
;;

(* The kind of list each epoch was written over, in commit order. *)
let epoch_frames ~keepers_dir ~keeper_id =
  let db = Sqlite3.db_open ~mode:`READONLY (C.db_path ~keepers_dir ~keeper_id) in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db : bool))
    (fun () ->
       let stmt = Sqlite3.prepare db "SELECT frame FROM compaction_epochs ORDER BY epoch_id" in
       Fun.protect
         ~finally:(fun () -> ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t))
         (fun () ->
            let rec loop acc =
              match Sqlite3.step stmt with
              | Sqlite3.Rc.ROW -> loop (Sqlite3.column_text stmt 0 :: acc)
              | Sqlite3.Rc.DONE -> List.rev acc
              | rc -> fail (Sqlite3.Rc.to_string rc)
            in
            loop []))
;;

(* An Agent Core epoch that stops inside a turn counts that turn's atoms in
   the message history: f#2/1 there is a tool round. In the list the ACP
   rollover rebuilds from the canonical rows, f#2/1 is the final answer. The
   rollover reads only coverage over its own kind of list, so it archives the
   answer before the watermark prunes f#2's row. *)
let test_acp_rollover_archives_a_turn_the_history_covered_in_part () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let keeper_id = "history-then-rollover" in
  commit_rows ~keepers_dir ~keeper_id [ "f#1"; "f#2"; "f#3"; "f#4" ];
  let history =
    agent_core_turn ~turn:"f#1" ~prompt:"ask f#1" ~answer:"answer f#1" ()
    @ agent_core_turn ~turn:"f#2" ~prompt:"ask f#2" ~tool:"read" ~answer:"answer f#2" ()
    @ agent_core_turn ~turn:"f#3" ~prompt:"ask f#3" ~answer:"answer f#3" ()
  in
  let partial = committed (compact ~keepers_dir ~keeper_id ~prefix:4 history) in
  check bool "the history epoch stops at f#2's tool round" true
    (partial.coverage.through
     = Some
         (A.Through_turn
            { turn = Ids.Turn_id.of_string "f#2"
            ; extent = A.Up_to { ordinal = 1; settled = Some (Ids.Turn_id.of_string "f#1") }
            }));
  check (list string) "f#2's row stays" [ "f#2"; "f#3"; "f#4" ]
    (row_ids (ok_store (Store.list_turns ~keepers_dir ~keeper_id)));
  let rebuilt = (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id)).messages in
  let messages, prefix = Keeper_acp_runtime.For_testing.split_older_for_rollover rebuilt in
  let rollover =
    committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix messages)
  in
  check bool "the rollover covers f#3 whole" true
    (rollover.coverage.through
     = Some (A.Through_turn { turn = Ids.Turn_id.of_string "f#3"; extent = A.Whole_turn }));
  check (list string) "rows through f#3 are pruned" [ "f#4" ]
    (row_ids (ok_store (Store.list_turns ~keepers_dir ~keeper_id)));
  let archived = atoms_of_epoch ~keepers_dir ~keeper_id rollover.epoch_id in
  check (list name_t) "the rollover archives f#2 from its own list"
    [ turn_name "f#2" 0; turn_name "f#2" 1; turn_name "f#3" 0; turn_name "f#3" 1 ]
    (List.map (fun (_, name, _) -> name) archived);
  check bool "f#2's final answer is archived before its row is pruned" true
    (List.exists (fun (_, _, json) -> contains ~needle:"answer f#2" json) archived);
  check bool "the summary takes f#2's final answer from the rollover" true
    (List.mem "f#2/1 assistant said \"answer f#2\"" (summary_lines rollover));
  check string "the last request is f#3's" "ask f#3" rollover.active_intent
;;

(* The canonical rows hold no tool rounds, so a rollover epoch says nothing
   about which atoms of the message history are archived. The history
   producer reads only its own kind's coverage and still archives the tool
   round of a turn the rollover settled. *)
let test_history_compaction_archives_what_a_rollover_did_not () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let keeper_id = "rollover-then-history" in
  commit_rows ~keepers_dir ~keeper_id [ "g#1"; "g#2"; "g#3" ];
  let rebuilt = (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id)).messages in
  let messages, prefix = Keeper_acp_runtime.For_testing.split_older_for_rollover rebuilt in
  let rollover =
    committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix messages)
  in
  check bool "the rollover covers g#2 whole" true
    (rollover.coverage.through
     = Some (A.Through_turn { turn = Ids.Turn_id.of_string "g#2"; extent = A.Whole_turn }));
  let history =
    agent_core_turn ~turn:"g#1" ~prompt:"ask g#1" ~tool:"grep" ~answer:"answer g#1" ()
    @ agent_core_turn ~turn:"g#2" ~prompt:"ask g#2" ~answer:"answer g#2" ()
    @ agent_core_turn ~turn:"g#3" ~prompt:"ask g#3" ~answer:"answer g#3" ()
  in
  let next = committed (compact ~keepers_dir ~keeper_id ~prefix:5 history) in
  check int "the history epoch folds onto the rollover epoch" (rollover.epoch_id + 1)
    next.epoch_id;
  let archived = atoms_of_epoch ~keepers_dir ~keeper_id next.epoch_id in
  check (list name_t) "the history epoch archives its own atoms through g#2"
    [ turn_name "g#1" 0; turn_name "g#1" 1; turn_name "g#1" 2; turn_name "g#2" 0; turn_name "g#2" 1 ]
    (List.map (fun (_, name, _) -> name) archived);
  check bool "g#1's tool round is archived" true
    (List.exists (fun (_, _, json) -> contains ~needle:"call-g#1-grep" json) archived);
  check (list string) "the summary adds nothing the rollover summarized"
    (summary_lines rollover) (summary_lines next);
  check string "the last request stays g#2's" "ask g#2" next.active_intent;
  check (option string) "the consumer starts the history at g#3" (Some "g#3")
    (first_turn_of
       (ok_compaction (C.live_history_after_latest_anchor ~keepers_dir ~keeper_id history)))
;;

(* A rollover epoch can run ahead of the message-history epochs. A history
   epoch that then archives turns behind the rollover's front leaves the
   summary where it was: folding them again would put older turns after
   newer ones and name an older request as the last. The consumer still cuts
   at the furthest front. *)
let test_a_lagging_kind_neither_rewinds_the_summary_nor_the_cut () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let keeper_id = "lagging-history" in
  commit_rows ~keepers_dir ~keeper_id [ "l#1"; "l#2"; "l#3" ];
  let rebuilt = (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id)).messages in
  let messages, prefix = Keeper_acp_runtime.For_testing.split_older_for_rollover rebuilt in
  let rollover =
    committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix messages)
  in
  check bool "the rollover covers l#2 whole" true
    (rollover.coverage.through
     = Some (A.Through_turn { turn = Ids.Turn_id.of_string "l#2"; extent = A.Whole_turn }));
  check string "the rollover's last request is l#2's" "ask l#2" rollover.active_intent;
  let history =
    agent_core_turn ~turn:"l#1" ~prompt:"ask l#1" ~tool:"grep" ~answer:"answer l#1" ()
    @ agent_core_turn ~turn:"l#2" ~prompt:"ask l#2" ~answer:"answer l#2" ()
    @ agent_core_turn ~turn:"l#3" ~prompt:"ask l#3" ~answer:"answer l#3" ()
    @ agent_core_turn ~turn:"l#4" ~prompt:"ask l#4" ~answer:"answer l#4" ()
  in
  let archived_names epoch_id =
    List.map (fun (_, name, _) -> name) (atoms_of_epoch ~keepers_dir ~keeper_id epoch_id)
  in
  let behind = committed (compact ~keepers_dir ~keeper_id ~prefix:2 history) in
  check (list name_t) "the lagging epoch archives l#1's prompt and tool round"
    [ turn_name "l#1" 0; turn_name "l#1" 1 ]
    (archived_names behind.epoch_id);
  check (list string) "the summary keeps the rollover's observations"
    (summary_lines rollover) (summary_lines behind);
  check string "the last request stays l#2's" "ask l#2" behind.active_intent;
  check (option string) "the consumer still starts the history at l#3" (Some "l#3")
    (first_turn_of
       (ok_compaction (C.live_history_after_latest_anchor ~keepers_dir ~keeper_id history)));
  let ahead = committed (compact ~keepers_dir ~keeper_id ~prefix:7 history) in
  check (list name_t) "the next history epoch archives the rest of its atoms through l#3"
    [ turn_name "l#1" 2; turn_name "l#2" 0; turn_name "l#2" 1; turn_name "l#3" 0
    ; turn_name "l#3" 1 ]
    (archived_names ahead.epoch_id);
  check (list string) "only l#3 joins the summary, after the rollover's turns"
    (summary_lines rollover @ [ "l#3/1 assistant said \"answer l#3\"" ])
    (summary_lines ahead);
  check string "the last request moves on to l#3's" "ask l#3" ahead.active_intent
;;

(* A history epoch that stops inside a turn covered the turn's user message,
   not its final answer. A canonical row with a blank prompt rebuilds as the
   answer alone, so the rollover still has that answer to summarize. *)
let test_a_turn_without_a_prompt_row_keeps_its_answer_in_the_summary () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let keeper_id = "blank-prompt-row" in
  List.iteri
    (fun i (turn, prompt) ->
       ignore
         (commit_row ~keepers_dir ~keeper_id ~turn ~prompt ~answer:("answer " ^ turn) (float_of_int i)
          : Store.canonical_turn))
    [ "b#1", "ask b#1"; "b#2", ""; "b#3", "ask b#3"; "b#4", "ask b#4" ];
  let history =
    agent_core_turn ~turn:"b#1" ~prompt:"ask b#1" ~answer:"answer b#1" ()
    @ agent_core_turn ~turn:"b#2" ~prompt:"look at this" ~tool:"read" ~answer:"answer b#2" ()
    @ agent_core_turn ~turn:"b#3" ~prompt:"ask b#3" ~answer:"answer b#3" ()
  in
  let partial = committed (compact ~keepers_dir ~keeper_id ~prefix:4 history) in
  check bool "the history epoch stops at b#2's tool round" true
    (partial.coverage.through
     = Some
         (A.Through_turn
            { turn = Ids.Turn_id.of_string "b#2"
            ; extent = A.Up_to { ordinal = 1; settled = Some (Ids.Turn_id.of_string "b#1") }
            }));
  let rebuilt = (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id)).messages in
  let messages, prefix = Keeper_acp_runtime.For_testing.split_older_for_rollover rebuilt in
  check (list name_t) "the rollover evicts b#2's answer and b#3"
    [ turn_name "b#2" 0; turn_name "b#3" 0; turn_name "b#3" 1 ]
    (List.filteri (fun index _ -> index < prefix) (names (A.atoms_of_messages messages)));
  let rollover =
    committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix messages)
  in
  check bool "the summary takes b#2's final answer" true
    (List.mem "b#2/0 assistant said \"answer b#2\"" (summary_lines rollover));
  check string "the last request is b#3's" "ask b#3" rollover.active_intent
;;

(* A history epoch can settle a turn whose canonical row is missing because
   its commit failed. The watermark then keeps every row, and the list a
   rollover rebuilds holds turns the summary already holds, but not the
   boundary's turn. The front there is only a lower bound: held turns join the
   observations again, yet the last request stays, and a turn the summary does
   not hold still moves it on. *)
let test_a_boundary_turn_missing_from_the_rows_keeps_the_last_request () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let keeper_id = "missing-row" in
  commit_rows ~keepers_dir ~keeper_id [ "h#1"; "h#2"; "h#3" ];
  commit_rows ~keepers_dir ~keeper_id [ "h#5"; "h#6" ];
  let history =
    List.concat_map
      (fun turn -> agent_core_turn ~turn ~prompt:("ask " ^ turn) ~answer:("answer " ^ turn) ())
      [ "h#1"; "h#2"; "h#3"; "h#4"; "h#5"; "h#6" ]
  in
  let settled = committed (compact ~keepers_dir ~keeper_id ~prefix:8 history) in
  check bool "the history epoch covers h#4 whole" true
    (settled.coverage.through
     = Some (A.Through_turn { turn = Ids.Turn_id.of_string "h#4"; extent = A.Whole_turn }));
  check string "its last request is h#4's" "ask h#4" settled.active_intent;
  check (list string) "no row carries h#4, so every row stays"
    [ "h#1"; "h#2"; "h#3"; "h#5"; "h#6" ]
    (row_ids (ok_store (Store.list_turns ~keepers_dir ~keeper_id)));
  let roll ?keep_ratio () =
    let rebuilt = (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id)).messages in
    let messages, prefix =
      Keeper_acp_runtime.For_testing.split_older_for_rollover ?keep_ratio rebuilt
    in
    committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix messages)
  in
  let behind = roll ~keep_ratio:0.5 () in
  check string "a rollover through h#3's prompt keeps h#4's request" "ask h#4"
    behind.active_intent;
  let past = roll () in
  check string "a rollover through h#5 moves it on to h#5's" "ask h#5" past.active_intent;
  check bool "h#5's answer joins the summary" true
    (List.mem "h#5/1 assistant said \"answer h#5\"" (summary_lines past));
  (* A row the history never held, such as a bridged turn, lies before a turn
     the summary holds: it is older than that turn, so it does not set the
     request either, though its answer joins the summary. *)
  let keeper_id = "missing-row-and-unheld-row" in
  commit_rows ~keepers_dir ~keeper_id [ "u#1"; "x#2"; "u#3" ];
  commit_rows ~keepers_dir ~keeper_id [ "u#5" ];
  let history =
    List.concat_map
      (fun turn -> agent_core_turn ~turn ~prompt:("ask " ^ turn) ~answer:("answer " ^ turn) ())
      [ "u#1"; "u#3"; "u#4"; "u#5" ]
  in
  let settled = committed (compact ~keepers_dir ~keeper_id ~prefix:6 history) in
  check string "the history epoch's last request is u#4's" "ask u#4" settled.active_intent;
  let rebuilt = (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id)).messages in
  let messages, prefix =
    Keeper_acp_runtime.For_testing.split_older_for_rollover ~keep_ratio:0.5 rebuilt
  in
  check (list name_t) "the rollover evicts u#1 and the unheld x#2"
    [ turn_name "u#1" 0; turn_name "u#1" 1; turn_name "x#2" 0; turn_name "x#2" 1 ]
    (List.filteri (fun index _ -> index < prefix) (names (A.atoms_of_messages messages)));
  let behind =
    committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix messages)
  in
  check string "the unheld row keeps u#4's request" "ask u#4" behind.active_intent;
  check bool "its answer joins the summary" true
    (List.mem "x#2/1 assistant said \"answer x#2\"" (summary_lines behind))
;;

(* A rollover and an overflow retry both open a fresh session, and both
   compact the list it starts from. Once a summary applies, or when the rows
   reach back to the first turn of the message history, that is the handoff
   list: the start holds the summary and the rows past it. Before that, the
   turns no row holds, such as those before a Fresh state, reach the start
   only through the summary, so they compact those turns of the message
   history first, then the handoff list that holds that summary and every
   row. When no row's turn is in the history, as with no row or rows that
   still carry ACP turn ids, the summary takes all of the history and the
   start holds it and every row: those rows may repeat the summarized turns,
   and summarizing them again could make an older request the last one.
   When the handoff list cannot be read or compacted after the history
   summary, every row stays and the start does not count as compacted, so an
   overflow retry compacts again on its next shrink. With the canonical turn
   store
   unreadable they compact the history, leaving its most recent atoms for
   the start, which sends it. An unreadable compaction store skips the
   compaction, which would fail on the same store. *)
let test_acp_producers_compact_the_list_the_next_session_starts_from () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let turns = [ "k#1"; "k#2"; "k#3" ] in
  let history =
    List.concat_map
      (fun turn ->
         agent_core_turn ~turn ~prompt:("ask " ^ turn) ~tool:"grep" ~answer:("answer " ^ turn) ())
      turns
  in
  let input_limit =
    Result.get_ok
      (Llm_provider.Input_budget.of_agent_window ~model_id:"acp-test" ~max_context_tokens:200_000)
  in
  let epoch_count keeper_id =
    match C.inspect_stats ~keepers_dir ~keeper_id with
    | Ok stats -> stats.C.epoch_count
    | Error err -> fail (C.store_error_to_string err)
  in
  let producers =
    [ ( "rollover"
      , fun keeper_id ->
          Keeper_acp_runtime.For_testing.compact_for_rollover
            ~keepers_dir
            ~keeper_id
            ~used_tokens:180_000
            ~limit_tokens:200_000
            ~initial_messages:history )
    ; ( "overflow"
      , fun keeper_id ->
          let already_compacted = ref false in
          let epochs_before = epoch_count keeper_id in
          Keeper_acp_runtime.For_testing.compact_once_for_overflow
            ~already_compacted
            ~keepers_dir
            ~keeper_id
            ~input_limit
            ~previous_capacity:400_000
            ~refused_sent_bytes:None
            ~capacity:200_000
            ~initial_messages:history;
          check bool
            (Printf.sprintf "%s after %d epochs: the run counts as compacted when an epoch commits"
               keeper_id epochs_before)
            (epoch_count keeper_id > epochs_before) !already_compacted )
    ]
  in
  let archives ~needle keeper_id =
    List.exists
      (fun (_, _, json) -> contains ~needle json)
      (archived_atoms ~keepers_dir ~keeper_id)
  in
  let archives_a_tool_round = archives ~needle:"call-k#1-grep" in
  let archives_the_answer_to turn = archives ~needle:("answer " ^ turn) in
  let turns_archived_by ~epoch keeper_id =
    List.map
      (fun (_, (name : A.name), _) ->
         match name with
         | A.In_turn { turn; ordinal = _ } -> Ids.Turn_id.to_string turn
         | A.Leading index -> Printf.sprintf "leading %d" index)
      (atoms_of_epoch ~keepers_dir ~keeper_id epoch)
  in
  let start_length keeper_id =
    List.length
      (Keeper_acp_runtime.For_testing.hydrate_start_messages
         ~keepers_dir
         ~keeper_id
         ~prefer_handoff:true
         history)
  in
  let latest_intent keeper_id =
    match ok_compaction (C.latest_anchor ~keepers_dir ~keeper_id) with
    | Some anchor -> anchor.active_intent
    | None -> fail "expected a committed epoch"
  in
  List.iter
    (fun (producer, compact_for) ->
       let fresh_state = producer ^ "-after-fresh-state" in
       commit_rows ~keepers_dir ~keeper_id:fresh_state [ "k#2"; "k#3" ];
       compact_for fresh_state;
       check (list string) (fresh_state ^ ": the history before the rows, then the handoff list")
         [ "message_history"; "canonical_turns" ] (epoch_frames ~keepers_dir ~keeper_id:fresh_state);
       check (list string) (fresh_state ^ ": the history summary stops before the first row's turn")
         [ "k#1"; "k#1"; "k#1" ] (turns_archived_by ~epoch:1 fresh_state);
       check bool (fresh_state ^ ": k#1, which no row holds, with its tool round") true
         (archives_a_tool_round fresh_state);
       check bool (fresh_state ^ ": then the oldest row") true (archives_the_answer_to "k#2" fresh_state);
       check bool (fresh_state ^ ": leaving the newest") false (archives_the_answer_to "k#3" fresh_state);
       check string (fresh_state ^ ": whose last request is k#2's") "ask k#2"
         (latest_intent fresh_state);
       check int (fresh_state ^ ": the start holds the anchor and k#3's row") 3
         (start_length fresh_state);
       commit_rows ~keepers_dir ~keeper_id:fresh_state [ "k#4" ];
       compact_for fresh_state;
       check (list string) (fresh_state ^ ": once a summary applies, the handoff list alone")
         [ "message_history"; "canonical_turns"; "canonical_turns" ]
         (epoch_frames ~keepers_dir ~keeper_id:fresh_state);
       check bool (fresh_state ^ ": through k#3") true (archives_the_answer_to "k#3" fresh_state);
       check bool (fresh_state ^ ": leaving k#4's row") false (archives_the_answer_to "k#4" fresh_state);
       check string (fresh_state ^ ": whose last request is k#3's") "ask k#3" (latest_intent fresh_state);
       check int (fresh_state ^ ": the start holds the anchor and k#4's row") 3
         (start_length fresh_state);
       let one_row = producer ^ "-one-row" in
       commit_rows ~keepers_dir ~keeper_id:one_row [ "k#3" ];
       compact_for one_row;
       check (list string) (one_row ^ ": a handoff list of one row is left whole")
         [ "message_history" ] (epoch_frames ~keepers_dir ~keeper_id:one_row);
       check (list string) (one_row ^ ": after the history before it is summarized")
         [ "k#1"; "k#1"; "k#1"; "k#2"; "k#2"; "k#2" ] (turns_archived_by ~epoch:1 one_row);
       check int (one_row ^ ": so the start holds the summary and the row") 3
         (start_length one_row);
       let current_turn = producer ^ "-with-the-current-turn-row" in
       commit_rows ~keepers_dir ~keeper_id:current_turn [ "k#2"; "k#3"; "acp:sess-1:4" ];
       compact_for current_turn;
       check (list string) (current_turn ^ ": rows after the history are compacted after it")
         [ "message_history"; "canonical_turns" ]
         (epoch_frames ~keepers_dir ~keeper_id:current_turn);
       check bool (current_turn ^ ": through k#3") true (archives_the_answer_to "k#3" current_turn);
       check (list string) (current_turn ^ ": leaving the current turn's row")
         [ "acp:sess-1:4" ]
         (row_ids (ok_store (Store.list_turns ~keepers_dir ~keeper_id:current_turn)));
       check int (current_turn ^ ": for the start, after the anchor") 3 (start_length current_turn);
       let provisional = producer ^ "-acp-turn-id-row" in
       commit_rows ~keepers_dir ~keeper_id:provisional [ "acp:sess-1:4" ];
       compact_for provisional;
       check (list string) (provisional ^ ": a row under an id the history lacks leaves the history")
         [ "message_history" ] (epoch_frames ~keepers_dir ~keeper_id:provisional);
       check bool (provisional ^ ": all of it") true (archives_the_answer_to "k#3" provisional);
       check (list string) (provisional ^ ": and the row")
         [ "acp:sess-1:4" ] (row_ids (ok_store (Store.list_turns ~keepers_dir ~keeper_id:provisional)));
       check int (provisional ^ ": which the start holds after the anchor") 3 (start_length provisional);
       let stale = producer ^ "-acp-turn-id-rows" in
       commit_rows ~keepers_dir ~keeper_id:stale [ "acp:sess-1:1"; "acp:sess-1:2"; "acp:sess-1:3" ];
       compact_for stale;
       check (list string) (stale ^ ": rows that may repeat the summarized turns stay whole")
         [ "message_history" ] (epoch_frames ~keepers_dir ~keeper_id:stale);
       check (list string) (stale ^ ": all of them")
         [ "acp:sess-1:1"; "acp:sess-1:2"; "acp:sess-1:3" ]
         (row_ids (ok_store (Store.list_turns ~keepers_dir ~keeper_id:stale)));
       check string (stale ^ ": so no older request becomes the last one") "ask k#3"
         (latest_intent stale);
       check int (stale ^ ": and the start holds the summary and every row") 7
         (start_length stale);
       let from_the_start = producer ^ "-rows-from-the-first-turn" in
       commit_rows ~keepers_dir ~keeper_id:from_the_start turns;
       compact_for from_the_start;
       check (list string) (from_the_start ^ ": rows from the first turn on are the canonical turn list")
         [ "canonical_turns" ] (epoch_frames ~keepers_dir ~keeper_id:from_the_start);
       check bool (from_the_start ^ ": which holds no tool round") false
         (archives_a_tool_round from_the_start);
       check bool (from_the_start ^ ": through k#2") true (archives_the_answer_to "k#2" from_the_start);
       check bool (from_the_start ^ ": leaving k#3's row") false (archives_the_answer_to "k#3" from_the_start);
       check int (from_the_start ^ ": for the start, after the anchor") 3 (start_length from_the_start);
       compact_for from_the_start;
       check (list string) (from_the_start ^ ": a list of two atoms left commits nothing")
         [ "canonical_turns" ] (epoch_frames ~keepers_dir ~keeper_id:from_the_start);
       let without_rows = producer ^ "-without-rows" in
       compact_for without_rows;
       check (list string) (without_rows ^ ": without rows it compacts the message history")
         [ "message_history" ] (epoch_frames ~keepers_dir ~keeper_id:without_rows);
       check bool (without_rows ^ ": the history it was given") true (archives_a_tool_round without_rows);
       check bool (without_rows ^ ": all of it, since the start holds only the anchor") true
         (archives_the_answer_to "k#3" without_rows);
       check int (without_rows ^ ": which is then the whole start") 1 (start_length without_rows);
       let unreadable = producer ^ "-unreadable-rows" in
       exec_all
         (Store.db_path ~keepers_dir ~keeper_id:unreadable)
         [ "CREATE TABLE canonical_turns (seq INTEGER PRIMARY KEY AUTOINCREMENT, \
            turn_id TEXT NOT NULL UNIQUE, parent_turn_id TEXT, runtime_kind TEXT NOT NULL, \
            runtime_id TEXT NOT NULL, user_input TEXT NOT NULL, tool_calls_json TEXT NOT NULL, \
            assistant_output TEXT NOT NULL, usage_json TEXT NOT NULL, \
            compaction_epoch_id INTEGER, created_at REAL NOT NULL)"
         ];
       compact_for unreadable;
       check (list string) (unreadable ^ ": an unreadable store leaves the message history too")
         [ "message_history" ] (epoch_frames ~keepers_dir ~keeper_id:unreadable);
       check bool (unreadable ^ ": compacted from the history it was given") true
         (archives_a_tool_round unreadable);
       check bool (unreadable ^ ": up to its most recent atoms") false
         (archives_the_answer_to "k#3" unreadable);
       check int (unreadable ^ ": since the start sends that history")
         (List.length history) (start_length unreadable))
    producers;
  let broken = "unreadable-compaction-store" in
  exec_all
    (C.db_path ~keepers_dir ~keeper_id:broken)
    [ "CREATE TABLE compaction_epochs (epoch_id INTEGER PRIMARY KEY, \
       covers_through_turn TEXT NOT NULL, anchor_json TEXT NOT NULL, \
       trigger_json TEXT NOT NULL, evicted_turn_ids_json TEXT NOT NULL, \
       previous_epoch_id INTEGER)"
    ];
  check bool "an unreadable compaction store skips the compaction" true
    (match Keeper_acp_runtime.For_testing.next_start_list ~keepers_dir ~keeper_id:broken ~history with
     | Error (C.Schema_not_current { found = 0L; _ }) -> true
     | Ok _ | Error _ -> false);
  let module R = Keeper_acp_runtime.For_testing in
  let trigger =
    R.overflow_trigger
      ~input_limit
      ~previous_capacity:400_000
      ~refused_sent_bytes:None
      ~capacity:200_000
  in
  let after_summary keeper_id handoff =
    match R.compact_rows_after_summary ~keepers_dir ~keeper_id ~trigger handoff with
    | R.Start_compacted -> "start compacted"
    | R.Nothing_new -> "nothing new"
    | R.Rows_kept_whole -> "rows kept whole"
  in
  let rows_of_stale_ids = Store.load_handoff_context ~keepers_dir ~keeper_id:"rollover-acp-turn-id-rows" in
  check string "after the summary, a handoff list that compacts shrinks the start" "start compacted"
    (after_summary "after-summary-compacts" rows_of_stale_ids);
  check string "after the summary, a compaction that fails keeps every row" "rows kept whole"
    (after_summary broken rows_of_stale_ids);
  check string "after the summary, an unreadable handoff list keeps every row" "rows kept whole"
    (after_summary
       "after-summary-unreadable"
       (Error (Store.Sqlite_error { operation = "load_handoff_context"; detail = "busy" })));
  check string "after the summary, a summary that does not apply keeps every row" "rows kept whole"
    (after_summary
       "after-summary-not-applied"
       (Ok { Store.anchor = None; turns_after_anchor = []; messages = [] }))
;;

let test_canonical_turn_store_compaction_watermark_and_failover () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let keeper_id = "keeper-e2-regression" in
  (match
     Store.commit_turn ~keepers_dir ~keeper_id ~turn_id:(Ids.Turn_id.of_string "   ")
       ~runtime_kind:Store.Agent_core_http ~runtime_id:"glm:1" ~user_input:"hi"
       ~tool_calls_json:(`List []) ~assistant_output:"ok" ~usage_json:(`Assoc [])
       ~created_at:1.0 ()
   with
   | Error (Store.Corrupt_record _) -> ()
   | Error err -> fail (Store.store_error_to_string err)
   | Ok _ -> fail "blank turn_id must fail closed");
  let t1_id = Ids.Turn_id.of_string "trace-e2:1" in
  (match
     Store.commit_turn ~keepers_dir ~keeper_id ~parent_turn_id:t1_id ~turn_id:t1_id
       ~runtime_kind:Store.Agent_core_http ~runtime_id:"glm:1" ~user_input:"hi"
       ~tool_calls_json:(`List []) ~assistant_output:"ok" ~usage_json:(`Assoc [])
       ~created_at:1.0 ()
   with
   | Error (Store.Corrupt_record _) -> ()
   | Error err -> fail (Store.store_error_to_string err)
   | Ok _ -> fail "self-referencing parent_turn_id must fail closed");
  let t1 =
    commit_row ~keepers_dir ~keeper_id ~turn:"trace-e2:1" ~prompt:"Inspect schema registry"
      ~answer:"HTTP Turn 1 completed schema audit." 10.0
  in
  let t2 =
    commit_row ~kind:Store.Acp_cli ~keepers_dir ~keeper_id ~turn:"acp:sess-1:2"
      ~prompt:"Verify ACP failover" ~answer:"ACP Turn 2 completed failover check." 20.0
  in
  let t3 =
    commit_row ~keepers_dir ~keeper_id ~turn:"trace-e2:3" ~prompt:"Post-eviction retained turn"
      ~answer:"HTTP Turn 3 stays retained verbatim." 30.0
  in
  let t1_rewritten =
    Store.commit_turn ~keepers_dir ~keeper_id ~turn_id:t1_id ~runtime_kind:Store.Agent_core_http
      ~runtime_id:"glm:1" ~user_input:"Inspect schema registry" ~tool_calls_json:(`List [])
      ~assistant_output:"HTTP Turn 1 completed schema audit."
      ~usage_json:(`Assoc [ "input_tokens", `Int 42 ]) ~created_at:11.0 ()
    |> ok_store
  in
  check (option string) "re-committing older t1 preserves original parent (None)" None
    (Option.map Ids.Turn_id.to_string t1_rewritten.parent_turn_id);
  let history = List.concat_map Store.messages_of_canonical_turn [ t1; t2; t3 ] in
  ignore (committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix:4 history) : C.compaction_anchor);
  let handoff = ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id) in
  check (list string) "load_handoff_context excludes compacted T1 & T2 and retains only T3"
    [ "trace-e2:3" ]
    (row_ids handoff.turns_after_anchor);
  ignore
    (commit_row ~kind:Store.Acp_cli ~keepers_dir ~keeper_id ~turn:"acp:sess-2:4"
       ~prompt:"New ACP turn after stale HTTP checkpoint"
       ~answer:"ACP Turn 4 must hydrate onto stale T3 checkpoint without duplicating T3." 40.0
     : Store.canonical_turn);
  let stale_http_checkpoint =
    [ message Agent_core.Types.User [ Agent_core.Types.Text "Post-eviction retained turn" ]
    ; message Agent_core.Types.Assistant [ Agent_core.Types.Text "HTTP Turn 3 stays retained verbatim." ]
    ]
  in
  let hydrated =
    Store.hydrate_missing_turns ~keepers_dir ~keeper_id ~existing_messages:stale_http_checkpoint
    |> ok_store
    |> List.concat_map (fun (m : Agent_core.Types.message) ->
      List.filter_map (function Agent_core.Types.Text s -> Some s | _ -> None) m.content)
    |> String.concat "\n"
  in
  check bool "stale checkpoint hydrates missing ACP T4" true
    (contains ~needle:"ACP Turn 4 must hydrate" hydrated);
  check bool "stale checkpoint does NOT duplicate already-present T3" false
    (contains ~needle:"HTTP Turn 3 stays retained verbatim." hydrated);
  ok_store (Store.record_history_reset ~keepers_dir ~keeper_id);
  check int "after history reset, empty checkpoint hydrates 0 messages" 0
    (List.length (ok_store (Store.hydrate_missing_turns ~keepers_dir ~keeper_id ~existing_messages:[])));
  let system_only =
    [ message ~origin:Agent_core.Types.System_context Agent_core.Types.System
        [ Agent_core.Types.Text "standing system prompt" ]
    ]
  in
  check int "after history reset, [System]-only checkpoint hydrates 0 messages" 0
    (List.length
       (ok_store (Store.hydrate_missing_turns ~keepers_dir ~keeper_id ~existing_messages:system_only)));
  let t5 =
    commit_row ~keepers_dir ~keeper_id ~turn:"trace-post-reset#1"
      ~prompt:"Fresh turn after operator history clear" ~answer:"Post-reset continuity works cleanly."
      50.0
  in
  check (option string) "first post-reset turn starts a fresh parent chain (None)" None
    (Option.map Ids.Turn_id.to_string t5.parent_turn_id);
  let post_reset = ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id) in
  check bool "pre-reset compaction anchor suppressed after reset" true (Option.is_none post_reset.anchor);
  check (list string) "only post-reset turns circulate" [ "trace-post-reset#1" ]
    (row_ids post_reset.turns_after_anchor)
;;

let test_canonical_turn_hydration_edge_cases () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let extract_text messages =
    messages
    |> List.concat_map (fun (m : Agent_core.Types.message) ->
      List.filter_map (function Agent_core.Types.Text s -> Some s | _ -> None) m.content)
    |> String.concat "\n"
  in
  let k_sup = "keeper-suppressed" in
  ignore
    (Store.commit_turn ~keepers_dir ~keeper_id:k_sup ~turn_id:(Ids.Turn_id.of_string "acp-raw-uuid-1")
       ~runtime_kind:Store.Acp_cli ~runtime_id:"agy:opus" ~user_input:"Post board update"
       ~tool_calls_json:(`List [ `Assoc [ "tool_name", `String "board_post" ] ])
       ~assistant_output:"Suppressed narration that must never resurrect" ~usage_json:(`Assoc [])
       ~created_at:10.0 ()
     |> ok_store
     : Store.canonical_turn);
  ok_store
    (Store.bind_turn_ref ~keepers_dir ~keeper_id:k_sup
       ~from_turn_id:(Ids.Turn_id.of_string "acp-raw-uuid-1")
       ~to_turn_id:(Ids.Turn_id.of_string "trace-sup#1") ~suppress_assistant_output:true ());
  let bridged = [ Keeper_turn_ref_metadata.bridged_key, `String "trace-sup#1" ] in
  let bridged_messages =
    [ message ~metadata:bridged Agent_core.Types.User [ Agent_core.Types.Text "Post board update" ]
    ; message ~metadata:bridged Agent_core.Types.Assistant
        [ Agent_core.Types.ToolUse { id = "tc1"; name = "board_post"; input = `Assoc [] } ]
    ]
  in
  check int "suppressed bridged turn hydrates 0 duplicates" 0
    (List.length
       (ok_store (Store.hydrate_missing_turns ~keepers_dir ~keeper_id:k_sup ~existing_messages:bridged_messages)));
  check bool "suppressed prose never resurrected on cold start" false
    (contains ~needle:"Suppressed narration"
       (extract_text (ok_store (Store.hydrate_missing_turns ~keepers_dir ~keeper_id:k_sup ~existing_messages:[]))));
  let k_multi = "keeper-multiblock" in
  ignore
    (commit_row ~keepers_dir ~keeper_id:k_multi ~turn:"trace-multi#1" ~prompt:"Summarize two parts"
       ~answer:"First paragraph.\nSecond paragraph." 20.0
     : Store.canonical_turn);
  let multiblock =
    [ message Agent_core.Types.User [ Agent_core.Types.Text "Summarize two parts" ]
    ; message Agent_core.Types.Assistant
        [ Agent_core.Types.Text "First paragraph."; Agent_core.Types.Text "Second paragraph." ]
    ]
  in
  check int "multi-Text-block checkpoint matches joined assistant_output (0 duplicates)" 0
    (List.length
       (ok_store (Store.hydrate_missing_turns ~keepers_dir ~keeper_id:k_multi ~existing_messages:multiblock)));
  let k_rep = "keeper-repeated-wake" in
  let wake_prompt = "Check inbox and board." in
  let wake_reply = "All clear." in
  let r1 = commit_row ~keepers_dir ~keeper_id:k_rep ~turn:"trace-rep#1" ~prompt:wake_prompt ~answer:wake_reply 10.0 in
  let r2 =
    commit_row ~kind:Store.Acp_cli ~keepers_dir ~keeper_id:k_rep ~turn:"trace-rep#2"
      ~prompt:"Investigate ACP failover" ~answer:"ACP Turn 2 unique result." 20.0
  in
  let r3 =
    commit_row ~kind:Store.Acp_cli ~keepers_dir ~keeper_id:k_rep ~turn:"trace-rep#3"
      ~prompt:wake_prompt ~answer:wake_reply 30.0
  in
  let untagged_r1 =
    [ message Agent_core.Types.User [ Agent_core.Types.Text wake_prompt ]
    ; message Agent_core.Types.Assistant [ Agent_core.Types.Text wake_reply ]
    ]
  in
  let hydrated_ids =
    ok_store (Store.hydrate_missing_turns ~keepers_dir ~keeper_id:k_rep ~existing_messages:untagged_r1)
    |> List.filter_map (fun (m : Agent_core.Types.message) ->
      if m.role = Agent_core.Types.User
      then (
        match List.assoc_opt Store.canonical_turn_id_metadata_key m.metadata with
        | Some (`String s) -> Some s
        | Some _ | None -> None)
      else None)
  in
  check (list string) "repeated wake prompt hydrates BOTH T2 and T3 (never skips T2)"
    [ "trace-rep#2"; "trace-rep#3" ]
    hydrated_ids;
  let history = List.concat_map Store.messages_of_canonical_turn [ r1; r2; r3 ] in
  ignore (committed (compact ~keepers_dir ~keeper_id:k_rep ~prefix:2 history) : C.compaction_anchor);
  check (list string) "compacting only T1 keeps T2 and the repeated-prompt T3"
    [ "trace-rep#2"; "trace-rep#3" ]
    (row_ids (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id:k_rep)).turns_after_anchor)
;;

let test_canonical_turn_multi_epoch_watermark_monotonicity () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  let keeper_id = "multi-epoch-keeper" in
  let wake_prompt = "Routine autonomous check." in
  let wake_reply = "Everything green." in
  let row ?kind turn prompt answer at =
    ignore (commit_row ?kind ~keepers_dir ~keeper_id ~turn ~prompt ~answer at : Store.canonical_turn)
  in
  row "trace-me#1" wake_prompt wake_reply 10.0;
  row ~kind:Store.Acp_cli "trace-me#2" "Fix queue backpressure" "Applied bounded queue" 20.0;
  row ~kind:Store.Acp_cli "trace-me#3" wake_prompt wake_reply 30.0;
  row "trace-me#4" "Live follow-up question" "Live answer" 40.0;
  let rebuilt () = (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id)).messages in
  let remaining () = row_ids (ok_store (Store.load_handoff_context ~keepers_dir ~keeper_id)).turns_after_anchor in
  let a1 = committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix:4 (rebuilt ())) in
  check int "epoch 1" 1 a1.epoch_id;
  check (list string) "after epoch 1 only T3 and T4 remain" [ "trace-me#3"; "trace-me#4" ] (remaining ());
  let a2 = committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix:2 (rebuilt ())) in
  check int "epoch 2" 2 a2.epoch_id;
  check (list string) "the repeated prompt in T3 advances the cutoff to T3" [ "trace-me#4" ] (remaining ());
  let a3 =
    committed
      (compact ~keepers_dir ~keeper_id ~prefix:2
         [ message Agent_core.Types.User [ Agent_core.Types.Text "Unmapped historical prompt" ]
         ; message Agent_core.Types.Assistant [ Agent_core.Types.Text "Unmapped historical reply" ]
         ])
  in
  check int "epoch 3" 3 a3.epoch_id;
  check bool "an untagged list settles no turn" true (Option.is_none (A.settled_turn a3.coverage));
  check (list string) "the earlier cutoff still holds" [ "trace-me#4" ] (remaining ());
  row ~kind:Store.Acp_cli "trace-me#5" "Post-epoch-3 ACP turn" "Post-epoch-3 reply" 50.0;
  check (list string) "a later commit appends after T4" [ "trace-me#4"; "trace-me#5" ] (remaining ())
;;

let test_canonical_turn_disk_lifecycle_prune_and_delete () =
  with_pool
  @@ fun () ->
  with_keepers_dir
  @@ fun keepers_dir ->
  check int "declarative max_retained_turns default is 2000" 2000 Store.max_retained_turns;
  let keeper_id = "lifecycle-keeper" in
  let commit turn n = commit_row ~keepers_dir ~keeper_id ~turn ~prompt:("prompt " ^ n) ~answer:("reply " ^ n) in
  let l1 = commit "lc#1" "1" 10.0 in
  let l2 = commit "lc#2" "2" 20.0 in
  let l3 = commit "lc#3" "3" 30.0 in
  let db_file = Store.db_path ~keepers_dir ~keeper_id in
  let pragma sql =
    let db = Sqlite3.db_open ~mode:`READONLY db_file in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close db : bool))
      (fun () ->
         let stmt = Sqlite3.prepare db sql in
         Fun.protect
           ~finally:(fun () -> ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t))
           (fun () ->
              match Sqlite3.step stmt with
              | Sqlite3.Rc.ROW -> Sqlite3.column_int stmt 0
              | _ -> -1))
  in
  check int "canonical turn DB enables PRAGMA auto_vacuum = INCREMENTAL (2)" 2 (pragma "PRAGMA auto_vacuum;");
  check int "canonical turn DB records its layout version" 1 (pragma "PRAGMA user_version;");
  let next_user = message ~metadata:(stamped "lc#4") Agent_core.Types.User [ Agent_core.Types.Text "prompt 4" ] in
  let history = List.concat_map Store.messages_of_canonical_turn [ l1; l2; l3 ] @ [ next_user ] in
  ignore (committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix:4 history) : C.compaction_anchor);
  check (list string) "compaction watermark pruned compacted lc#1 & lc#2" [ "lc#3" ]
    (row_ids (ok_store (Store.list_turns ~keepers_dir ~keeper_id)));
  ignore (committed (compact ~frame:A.Canonical_turns ~keepers_dir ~keeper_id ~prefix:6 history) : C.compaction_anchor);
  check int "all compacted rows pruned" 0 (List.length (ok_store (Store.list_turns ~keepers_dir ~keeper_id)));
  let l4 = commit "lc#4" "4" 40.0 in
  check (option string) "post-compaction commit chains parent across the pruned watermark" (Some "lc#3")
    (Option.map Ids.Turn_id.to_string l4.parent_turn_id);
  ok_store (Store.record_history_reset ~keepers_dir ~keeper_id);
  check int "history reset pruned all pre-reset rows" 0
    (List.length (ok_store (Store.list_turns ~keepers_dir ~keeper_id)));
  let l5 = commit "lc#5" "5" 50.0 in
  check (option string) "first post-reset commit starts fresh parent chain (None)" None
    (Option.map Ids.Turn_id.to_string l5.parent_turn_id);
  let cap_keeper = "cap-keeper" in
  for i = 1 to 12 do
    ignore
      (Store.commit_turn ~keepers_dir ~keeper_id:cap_keeper
         ~turn_id:(Ids.Turn_id.of_string (Printf.sprintf "cap#%d" i)) ~runtime_kind:Store.Acp_cli
         ~runtime_id:"acp:1" ~user_input:(Printf.sprintf "cap prompt %d" i) ~tool_calls_json:(`List [])
         ~assistant_output:(Printf.sprintf "cap reply %d" i) ~usage_json:(`Assoc [])
         ~max_retained_turns:5 ~created_at:(float_of_int i) ()
       |> ok_store
       : Store.canonical_turn)
  done;
  check (list string) "retention cap keeps strictly the newest 5 turns in seq order"
    [ "cap#8"; "cap#9"; "cap#10"; "cap#11"; "cap#12" ]
    (row_ids (ok_store (Store.list_turns ~keepers_dir ~keeper_id:cap_keeper)));
  let cap_db = Store.db_path ~keepers_dir ~keeper_id:cap_keeper in
  List.iter
    (fun suffix ->
       let path = cap_db ^ suffix in
       if not (Sys.file_exists path)
       then ignore (Fs_compat.save_file_atomic path "sidecar" : (unit, string) result))
    [ "-wal"; "-shm"; "-journal" ];
  check bool "db exists before delete_store" true (Sys.file_exists cap_db);
  ok_store (Store.delete_store ~keepers_dir ~keeper_id:cap_keeper);
  List.iter
    (fun suffix ->
       check bool (Printf.sprintf "delete_store removed %s" suffix) false
         (Sys.file_exists (cap_db ^ suffix)))
    [ ""; "-wal"; "-shm"; "-journal" ];
  ok_store (Store.delete_store ~keepers_dir ~keeper_id:cap_keeper)
;;

let () =
  run
    "Keeper_compaction"
    [ ( "atom names and coverage"
      , [ test_case "names follow turns and continue on re-entry" `Quick test_atom_names_follow_turns
        ; test_case "covered end reads names only" `Quick test_covered_end_reads_names_only
        ; test_case "front reads the other kind by turn" `Quick
            test_front_reads_the_other_kind_by_turn
        ; test_case "advance names the boundary, settled turn and beyond" `Quick
            test_advance_names_the_boundary
        ; test_case "settled turn stops at an open earlier turn" `Quick
            test_settled_turn_stops_at_an_open_turn
        ; test_case "coverage and anchor codecs are strict" `Quick test_codecs_are_strict
        ] )
    ; ( "tool output"
      , [ test_case "structured handle & 4 KiB head+tail preview & non-Scanf marker" `Quick
            test_tool_output_structured_handle_and_head_tail_preview
        ] )
    ; ( "anchored compaction"
      , [ test_case "typed tool evidence survives restart" `Quick
            test_transcript_evidence_survives_restart
        ; test_case "leading atoms are archived once" `Quick test_leading_atoms_are_archived_once
        ; test_case "current-turn round drop is not archived again" `Quick
            test_current_turn_round_drop_is_not_archived_again
        ; test_case "consumer cuts after the covered turn" `Quick
            test_consumer_cuts_after_the_covered_turn
        ; test_case "bounded anchor across epochs and provider limits" `Quick
            test_bounded_anchor_across_epochs
        ; test_case "repeated text atoms are distinct by name" `Quick
            test_repeated_text_atoms_are_distinct_by_name
        ; test_case "a split turn is covered up to the boundary" `Quick
            test_split_turn_is_covered_up_to_the_boundary
        ; test_case "concurrent compactions serialize" `Quick test_concurrent_compactions_serialize
        ; test_case "epoch listener receives the workspace" `Quick
            test_epoch_listener_receives_the_workspace
        ; test_case "secrets are redacted at the storage boundary" `Quick
            test_secrets_are_redacted_at_the_storage_boundary
        ; test_case "an archived blob reference stays live" `Quick
            test_an_archived_blob_reference_stays_live
        ; test_case "per-keeper token is redacted under config/keepers" `Quick
            test_per_keeper_token_is_redacted_under_config_keepers
        ; test_case "zero-byte database reads as empty" `Quick test_zero_byte_database_reads_as_empty
        ; test_case "stores written before the hard cut are refused" `Quick
            test_stores_written_before_the_hard_cut_are_refused
        ] )
    ; ( "canonical turn store"
      , [ test_case "watermark follows the settled turn" `Quick test_watermark_follows_the_settled_turn
        ; test_case "ACP rebuilt list cuts the checkpoint history" `Quick
            test_acp_rebuilt_list_cuts_the_checkpoint_history
        ; test_case "ACP provisional turn id" `Quick test_acp_provisional_turn_id
        ; test_case "ACP rollover archives a turn the history covered in part" `Quick
            test_acp_rollover_archives_a_turn_the_history_covered_in_part
        ; test_case "history compaction archives what a rollover did not" `Quick
            test_history_compaction_archives_what_a_rollover_did_not
        ; test_case "a lagging kind neither rewinds the summary nor the cut" `Quick
            test_a_lagging_kind_neither_rewinds_the_summary_nor_the_cut
        ; test_case "a turn without a prompt row keeps its answer in the summary" `Quick
            test_a_turn_without_a_prompt_row_keeps_its_answer_in_the_summary
        ; test_case "a boundary turn missing from the rows keeps the last request" `Quick
            test_a_boundary_turn_missing_from_the_rows_keeps_the_last_request
        ; test_case "ACP producers compact the list the next session starts from" `Quick
            test_acp_producers_compact_the_list_the_next_session_starts_from
        ; test_case "compaction watermark, cycle guard & failover hydration" `Quick
            test_canonical_turn_store_compaction_watermark_and_failover
        ; test_case "hydration: suppressed terminal effect, multi-block & repeated prompts" `Quick
            test_canonical_turn_hydration_edge_cases
        ; test_case "multi-epoch watermark monotonicity & unmapped epoch floor" `Quick
            test_canonical_turn_multi_epoch_watermark_monotonicity
        ; test_case "disk lifecycle: auto_vacuum, prune, retention cap & delete_store" `Quick
            test_canonical_turn_disk_lifecycle_prune_and_delete
        ] )
    ]
;;
