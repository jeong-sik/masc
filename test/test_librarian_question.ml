(* The text of a reading question (RFC librarian-call-only-proposes §6.1).
   The same inputs give the same bytes, with the two halves on the line after
   the prompt and on the last line. A change to Memory alone moves the front
   half and leaves the back half. A range whose items are all missing makes
   no question and keeps what is missing for the commit line. *)

open Alcotest
module Question = Masc.Librarian_question
module Question_id = Masc.Librarian_question_id
module Read_result = Masc.Librarian_read_result
module Read_unit = Masc.Librarian_read_unit
module Missing = Masc.Librarian_unit
module Log = Masc.Librarian_log
module Lane = Masc.Librarian_memory_lane
module Current = Masc.Keeper_memory_os_current_types
module Types = Masc.Keeper_memory_os_types
module Turn_log = Masc.Keeper_turn_log
module Digest = Agent_core.Checkpoint_objects
module Agent = Agent_core.Types

let lane : Lane.question_side =
  { prompt = "Read the units and answer with one JSON document."
  ; answer_schemas =
      { range = `Assoc [ "type", `String "object"; "title", `String "range" ]
      ; item_alone = `Assoc [ "type", `String "object"; "title", `String "item_alone" ]
      ; room = `Assoc [ "type", `String "object"; "title", `String "room" ]
      }
  ; max_output_tokens = 4096
  ; thinking = Some false
  }
;;

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let mark closed_messages : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages
  ; session = "session-1"
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let from : Log.line =
  Log.Committed
    { seq = 1
    ; at = 1_763_500_000.0
    ; basis = Digest.digest_of_bytes "before"
    ; after = Digest.digest_of_bytes "after"
    ; revision = 2
    ; cause = Log.Adopt { by = "operator"; observed = Digest.digest_of_bytes "after" }
    ; effects = Masc.Librarian_effects.empty
    ; turn_log
    ; turn_log_offset = 0
    ; covers_through = Log.Before_first
    ; covered = mark 0
    ; working_state = Some "triage the release blockers"
    }
;;

let reach : Read_result.reach =
  { line = 300; within = Log.Whole; covered = mark 3; turn_log_offset = 360 }
;;

let authored : Types.origin = { kind = Types.Authored; trace_id = "trace-1" }

let observed claim =
  Types.observed ~claim ~category:Types.Constraint ~now:1_763_510_400.0 ~origin:authored
;;

let memory facts : Current.t =
  { revision = 2
  ; updated_at = 1_763_510_400.0
  ; source = { kind = Current.Librarian; trace_id = "trace-1" }
  ; facts
  ; change = { added = []; removed = []; retained = 0; invalidated = [] }
  }
;;

(* Built again at each call, so equal bytes come from equal values. *)
let facts () =
  let frozen = observed "the release branch is frozen on Fridays" in
  match
    Types.derived
      ~claim:"no deploy goes out on a Friday"
      ~category:Types.Lesson
      ~now:1_763_510_400.0
      ~origin:authored
      ~derivations:[ { rule_id = "rule"; premise_ids = [ Types.memory_id frozen ] } ]
  with
  | Ok derived -> [ frozen; derived ]
  | Error detail -> fail detail
;;

let opened : Read_unit.opened_line =
  Opened_read { runtime = "glm"; task = Turn_log.No_task; stimuli = [] }
;;

let units () : Read_unit.t list =
  [ { line = 120
    ; at = 1_763_600_000.0
    ; kind =
        Read_unit.Turn
          { turn = 40
          ; outcome = Turn_log.Completed
          ; opened
          ; unattributed = []
          ; own =
              [ { index = 0
                ; name = { store = Agent_core; at = 0 }
                ; body = Read_unit.Message (Agent.user_msg "ship the fix before Friday")
                }
              ; { index = 1
                ; name = { store = Agent_core; at = 1 }
                ; body =
                    Read_unit.Message
                      (Agent.make_message
                         ~role:Agent.Assistant
                         [ Agent.ToolUse { id = "call-1"; name = "board_read"; input = `Null } ])
                }
              ; { index = 2
                ; name = { store = Agent_core; at = 2 }
                ; body =
                    Read_unit.Message
                      (Agent.tool_result_msg ~tool_use_id:"call-1" ~content:"two posts" ())
                }
              ]
          }
    ; missing = []
    }
  ; { line = 300
    ; at = 1_763_600_060.0
    ; kind = Read_unit.Reset { cause = Turn_log.Cleared; items = [] }
    ; missing = []
    }
  ]
;;

let made ~shows units =
  match
    Question.make ~lane ~from ~shows ~reach ~trace:"trace-1" ~offered:{ units = 1; head_items = 3 }
      units
  with
  | Question.Made { question; text; schema = (_ : Yojson.Safe.t) } -> question, text
  | Question.Nothing_readable _ -> fail "a range with items made no question"
;;

let ask held units = made ~shows:(With_memory (memory held)) units

let external_person_observation_keeps_its_scope () =
  let module Attention = Masc.Keeper_external_attention in
  let account_id = "900000000000000001" in
  let account_ref = Option.get (Masc.Connector_account_ref.discord_user account_id) in
  let surface =
    Masc.Surface_ref.Discord
      { guild_id = Some "guild"
      ; channel_id = "thread"
      ; channel_name = None
      ; parent_channel_id = Some "channel"
      ; thread_id = Some "thread"
      }
  in
  let item : Masc.Keeper_external_attention.item =
    { event_id = "event"
    ; dedupe_key = "dedupe"
    ; keeper_name = "luna"
    ; conversation = { conversation_id = "discord:guild:channel:thread"; surface }
    ; external_message = Some { surface; message_id = "message"; reply_to_message_id = None }
    ; source_label = "discord"
    ; actor =
        { actor_id = Some account_id
        ; display_name = Some "Nickname"
        ; authority = External
        ; account = Some (Attention.Account_of_original_message account_ref)
        }
    ; urgency = Mention
    ; content_preview = "I prefer summaries in Korean."
    ; content_ref = None
    ; received_at = 1_763_600_000.0
    ; metadata = []
    }
  in
  let unit (item : Attention.item) : Read_unit.t =
    { line = 120
    ; at = item.received_at
    ; kind = Reset { cause = Turn_log.Cleared; items =
        [ { index = 0; name = { store = External; at = 0 }; body = External_row item } ]
      }
    ; missing = []
    }
  in
  let open Yojson.Safe.Util in
  let observation item =
    let _, text = ask [] [ unit item ] in
    let prefix = "units: " in
    let line = List.find (String.starts_with ~prefix) (String.split_on_char '\n' text) in
    String.sub line (String.length prefix) (String.length line - String.length prefix)
    |> Yojson.Safe.from_string |> index 0 |> member "items" |> index 0
  in
  let current = observation item in
  check string "actor id" account_id
    (current |> member "actor" |> member "id" |> to_string);
  let account = current |> member "actor" |> member "account" in
  check string "account kind" "discord_user" (account |> member "kind" |> to_string);
  check int "account version" 1 (account |> member "version" |> to_int);
  check string "account user id" account_id (account |> member "user_id" |> to_string);
  check string "observed name" "Nickname"
    (current |> member "actor" |> member "name" |> to_string);
  check string "message id" "message"
    (current |> member "external_message_id" |> to_string);
  check string "conversation id" "discord:guild:channel:thread"
    (current |> member "conversation_id" |> to_string);
  check bool "complete connector coordinates" true
    (current |> member "surface" |> Yojson.Safe.equal (Masc.Surface_ref.to_json surface));
  let older = { item with actor = { item.actor with
    account = Some (Attention.Account_without_original_proof account_ref) } } in
  let older_actor = observation older |> member "actor" in
  check string "older observation still shows the actor" account_id
    (older_actor |> member "id" |> to_string);
  check bool "older observation supplies no account proof" false
    (List.mem_assoc "account" (to_assoc older_actor))
;;

let same_inputs_same_bytes () =
  let question, text = ask (facts ()) (units ()) in
  let again, text_again = ask (facts ()) (units ()) in
  check string "the text" text text_again;
  check bool "the id" true (Question_id.equal question.id again.id);
  let lines = String.split_on_char '\n' text in
  check string "the line after the prompt" ("question: " ^ question.id.front) (List.nth lines 1);
  check
    string
    "the last line"
    ("question-end: " ^ question.id.back)
    (List.nth lines (List.length lines - 2))
;;

let memory_alone_moves_the_front_half () =
  let question, text = ask (facts ()) (units ()) in
  let revised, revised_text =
    ask [ observed "the release branch is frozen on Fridays and Saturdays" ] (units ())
  in
  check bool "the text changed" false (String.equal text revised_text);
  check bool "the front half changed" false (String.equal question.id.front revised.id.front);
  check string "the back half" question.id.back revised.id.back
;;

let all_missing_asks_nothing () =
  let slice : Turn_log.slice = { bundle = Digest.digest_of_bytes "bundle"; skip = 0; take = 2 } in
  let lost_chat = Missing.Chat_bytes { from = 10; until = 90 } in
  let lost : Read_unit.t list =
    [ { line = 120
      ; at = 1_763_600_000.0
      ; kind =
          Read_unit.Turn
            { turn = 40; outcome = Turn_log.Completed; opened; unattributed = []; own = [] }
      ; missing = [ Missing.Bundle slice ]
      }
    ; { line = 300
      ; at = 1_763_600_060.0
      ; kind = Read_unit.Reset { cause = Turn_log.Cleared; items = [] }
      ; missing = [ lost_chat ]
      }
    ]
  in
  match
    Question.make ~lane ~from ~shows:(With_memory (memory (facts ()))) ~reach ~trace:"trace-1"
      ~offered:{ units = 2; head_items = 0 } lost
  with
  | Question.Made _ -> fail "a range with no item made a question"
  | Question.Nothing_readable { reach = through; missing } ->
    check bool "the reader's reach" true (through = reach);
    check
      bool
      "each unit's missing parts"
      true
      (missing
       = [ { Missing.line = 120; parts = [ Missing.Bundle slice ] }
         ; { Missing.line = 300; parts = [ lost_chat ] }
         ])
;;

(* §7.4: the item alone shows neither Memory nor the working state, so its
   id is the same under every Memory version. *)
let the_item_alone_shows_no_memory () =
  let alone, text = made ~shows:Item_alone (units ()) in
  let lines = String.split_on_char '\n' text in
  let labelled label = List.exists (String.starts_with ~prefix:label) lines in
  check bool "no memory line" false (labelled "memory:");
  check bool "no working state line" false (labelled "working_state:");
  check bool "the units line" true (labelled "units:");
  check bool "no fact is named" true
    (match alone.shown with
     | Item_alone _ -> true
     | Range _ -> false);
  let with_memory, (_ : string) = ask (facts ()) (units ()) in
  check bool "the front half is not the one with Memory" false
    (String.equal alone.id.front with_memory.id.front);
  check string "the back half is the units' either way" with_memory.id.back alone.id.back
;;

(* §7.4 「자리 내기」: Memory and the working state, then one sentence where
   the units were. The front half carries the room schema, so the id is not
   the reading question's under the same Memory. *)
let the_room_question_reads_no_unit () =
  let room = Question.make_room ~lane ~from ~memory:(memory (facts ())) ~trace:"trace-1" () in
  let lines = String.split_on_char '\n' room.text in
  let labels =
    [ "question: "; "memory: "; "working_state: "; "units: "; "make_room: "; "question-end: " ]
  in
  check (list string) "the lines after the prompt"
    [ "question: "; "memory: "; "working_state: "; "make_room: "; "question-end: " ]
    (List.filter_map
       (fun line -> List.find_opt (fun label -> String.starts_with ~prefix:label line) labels)
       lines);
  check bool "the working state of the line it follows" true
    (List.mem {|working_state: "triage the release blockers"|} lines);
  check (list string) "every fact named" [ "m1"; "m2" ] (List.map fst room.question.memory);
  check string "the trace of the item read alone" "trace-1" room.question.trace;
  check bool "the room schema" true (Yojson.Safe.equal lane.answer_schemas.room room.schema);
  let reading, (_ : string) = ask (facts ()) (units ()) in
  check bool "the front half is not the reading question's" false
    (String.equal reading.id.front room.question.id.front)
;;

let molt_room_question_carries_trigger_and_world_index () =
  let trigger =
    Masc.Librarian_lifecycle.Memory_growth_molt_requested
      { current_bytes = 600_000; threshold_bytes = 524_288 }
  in
  let room =
    Question.make_room
      ~world_index:"[world] sqlite WAL busy_timeout=5000"
      ~molt_trigger:trigger
      ~lane
      ~from
      ~memory:(memory (facts ()))
      ~trace:"trace-molt"
      ()
  in
  let lines = String.split_on_char '\n' room.text in
  let labels =
    [ "question: "
    ; "memory: "
    ; "working_state: "
    ; "world_index: "
    ; "units: "
    ; "make_room: "
    ; "molt_trigger: "
    ; "question-end: "
    ]
  in
  check (list string) "molt room lines include world_index and molt_trigger in fixed order"
    [ "question: "; "memory: "; "working_state: "; "world_index: "; "molt_trigger: "; "question-end: " ]
    (List.filter_map
       (fun line -> List.find_opt (fun label -> String.starts_with ~prefix:label line) labels)
       lines);
  check bool "molt_trigger JSON matches trigger codec" true
    (List.mem
       ("molt_trigger: " ^ Yojson.Safe.to_string (Masc.Librarian_lifecycle.molt_trigger_to_json trigger))
       lines);
  let contains_sub ~needle haystack =
    let nlen = String.length needle in
    let hlen = String.length haystack in
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    nlen = 0 || loop 0
  in
  check bool "world_index line carries explicit untrusted workspace notes framing" true
    (List.exists
       (fun line ->
          String.starts_with ~prefix:"world_index: " line
          && contains_sub ~needle:"[UNTRUSTED WORKSPACE NOTES" line)
       lines);
  let plain_room =
    Question.make_room ~lane ~from ~memory:(memory (facts ())) ~trace:"trace-molt" ()
  in
  check bool "world_index changes front half" false
    (String.equal plain_room.question.id.front room.question.id.front);
  check bool "molt_trigger changes back half" false
    (String.equal plain_room.question.id.back room.question.id.back);
  (* Per-category chunked room question filters memory facts while preserving canonical IDs *)
  let all_facts = facts () in
  let cat_room =
    Question.make_room
      ~molt_trigger:trigger
      ~category_filter:Types.Constraint
      ~lane
      ~from
      ~memory:(memory all_facts)
      ~trace:"trace-molt-cat"
      ()
  in
  let expected_constraint_ids =
    List.filter_map
      (fun (f : Types.fact) ->
         if f.category = Types.Constraint then Some (Types.memory_id f) else None)
      all_facts
  in
  check (list string) "category_filter keeps only matching category canonical IDs"
    expected_constraint_ids
    (List.map snd cat_room.question.memory)
;;

let () =
  run
    "librarian_question"
    [ ( "question"
      , [ test_case "the same inputs give the same bytes" `Quick same_inputs_same_bytes
        ; test_case "an external person's observation keeps its scope" `Quick
            external_person_observation_keeps_its_scope
        ; test_case "the item alone shows no Memory" `Quick the_item_alone_shows_no_memory
        ; test_case "the room question reads no unit" `Quick the_room_question_reads_no_unit
        ; test_case
            "the molt room question carries trigger and world index"
            `Quick
            molt_room_question_carries_trigger_and_world_index
        ; test_case
            "a change to Memory alone moves the front half"
            `Quick
            memory_alone_moves_the_front_half
        ; test_case
            "a range whose items are all missing asks nothing"
            `Quick
            all_missing_asks_nothing
        ] )
    ]
;;
