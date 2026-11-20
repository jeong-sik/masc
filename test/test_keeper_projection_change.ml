open Alcotest
open Masc

module Change = Keeper_projection_change
module Snapshot = Keeper_provider_input_snapshot

let user text = Agent_core.Types.text_message Agent_core.Types.User text
let assistant text = Agent_core.Types.text_message Agent_core.Types.Assistant text

let tool name =
  Agent_core.Tool.create
    ~name
    ~description:"fixture tool"
    ~parameters:[]
    (fun _ -> Ok { Agent_core.Types.content = "ok"; content_blocks = None; _meta = None })
;;

let fixture_tools = [ tool "masc_status" ]

let digest ?(tools = fixture_tools) ?(memo = Change.create_digest_memo ()) messages =
  let seen = Change.snapshot_digest_memo memo in
  let digests, fresh = Change.digest_request ~seen ~tools ~messages in
  Change.remember_digests memo fresh;
  digests
;;

let numbered label count =
  List.init count (fun index -> user (Printf.sprintf "%s-%d" label index))
;;

let render change = Yojson.Safe.to_string (Change.change_to_json change)

let payload_bytes message =
  String.length (Snapshot.payload_bytes (Snapshot.message_payload message))
;;

(* Compares two message lists under the fixture tools, and checks the whole
   change, the tools flag included, through its JSON rendering. Both lists are
   digested through one memo, as two requests of one keeper turn are; most
   fixtures build equal messages as separate records, as projection does. *)
let check_messages label ~previous ~current expected =
  let memo = Change.create_digest_memo () in
  let actual =
    Change.compare_requests
      ~previous:(Change.Request_digested (digest ~memo previous))
      ~current:(digest ~memo current)
  in
  check
    string
    label
    (render
       (Change.Follows_previous_request { messages = expected; tools_changed = false }))
    (render actual)
;;

let test_first_request_of_turn () =
  let change =
    Change.compare_requests ~previous:Change.No_request_yet ~current:(digest [ user "a" ])
  in
  check string "no earlier request" (render Change.First_request_of_turn) (render change)
;;

let test_previous_request_not_digested () =
  let change =
    Change.compare_requests
      ~previous:Change.Request_not_digested
      ~current:(digest [ user "a" ])
  in
  check
    string
    "an undigested request is not skipped over"
    (render Change.Previous_request_not_digested)
    (render change)
;;

let test_digest_memo_commit_is_explicit () =
  let memo = Change.create_digest_memo () in
  let message = user "computed once the owner accepts it" in
  let seen = Change.snapshot_digest_memo memo in
  let _first, first_fresh =
    Change.digest_request ~seen ~tools:fixture_tools ~messages:[ message ]
  in
  check int "first job computed one message digest" 1
    (Change.fresh_message_count first_fresh);
  check int "first job computed one tool schema digest" 1
    (Change.fresh_tool_count first_fresh);
  let seen_before_commit = Change.snapshot_digest_memo memo in
  let _again, repeated_fresh =
    Change.digest_request
      ~seen:seen_before_commit
      ~tools:fixture_tools
      ~messages:[ message ]
  in
  check int "an uncommitted job changed no shared message memo" 1
    (Change.fresh_message_count repeated_fresh);
  check int "an uncommitted job changed no shared tool memo" 1
    (Change.fresh_tool_count repeated_fresh);
  Change.remember_digests memo first_fresh;
  let seen_after_commit = Change.snapshot_digest_memo memo in
  let _cached, cached_fresh =
    Change.digest_request
      ~seen:seen_after_commit
      ~tools:fixture_tools
      ~messages:[ message ]
  in
  check int "the owner commit makes the digest reusable" 0
    (List.length cached_fresh)
;;

(* The operation count the review asked for. An append-one-message turn of R
   requests must serialize and hash each message once and each tool schema
   once across the whole turn: the fresh list is exactly the set of values a
   job hashed, so its size per request is the hashing count. What this pins
   is the O(M + T) hashing term; the O(R * M) lookup term is documented, not
   bounded here, because it is made of memo hits and no encoding. *)
let test_append_only_turn_hashes_each_value_once () =
  let requests = 64 in
  let memo = Change.create_digest_memo () in
  let hashed_messages = ref 0 in
  let hashed_tools = ref 0 in
  let history = ref [] in
  for index = 1 to requests do
    history := !history @ [ user (Printf.sprintf "turn-%d" index) ];
    let seen = Change.snapshot_digest_memo memo in
    let _digests, fresh =
      Change.digest_request ~seen ~tools:fixture_tools ~messages:!history
    in
    let messages_now = Change.fresh_message_count fresh in
    let tools_now = Change.fresh_tool_count fresh in
    check int
      (Printf.sprintf "request %d hashed only the appended message" index)
      1 messages_now;
    check int
      (Printf.sprintf "request %d hashed the tool schema only the first time" index)
      (if index = 1 then List.length fixture_tools else 0)
      tools_now;
    hashed_messages := !hashed_messages + messages_now;
    hashed_tools := !hashed_tools + tools_now;
    Change.remember_digests memo fresh
  done;
  check int "each message was hashed exactly once over the turn" requests
    !hashed_messages;
  check int "each tool schema was hashed exactly once over the turn"
    (List.length fixture_tools) !hashed_tools
;;

(* The tool memo keys on the schema, not the tool value: a rebuilt tool list
   with equal schemas hits, and a schema that differs in any field misses. *)
let test_tool_schema_memo_keys_on_schema_value () =
  let memo = Change.create_digest_memo () in
  let messages = [ user "same messages every time" ] in
  let seen = Change.snapshot_digest_memo memo in
  let _first, first_fresh =
    Change.digest_request ~seen ~tools:[ tool "masc_status" ] ~messages
  in
  check int "first request hashes the schema" 1 (Change.fresh_tool_count first_fresh);
  Change.remember_digests memo first_fresh;
  let seen = Change.snapshot_digest_memo memo in
  let _rebuilt, rebuilt_fresh =
    Change.digest_request ~seen ~tools:[ tool "masc_status" ] ~messages
  in
  check int "a rebuilt tool with an equal schema hits the memo" 0
    (Change.fresh_tool_count rebuilt_fresh);
  let _renamed, renamed_fresh =
    Change.digest_request ~seen ~tools:[ tool "masc_status_v2" ] ~messages
  in
  check int "a schema differing in name misses" 1
    (Change.fresh_tool_count renamed_fresh);
  let _twice, twice_fresh =
    Change.digest_request
      ~seen
      ~tools:[ tool "masc_status_v2"; tool "masc_status_v2" ]
      ~messages
  in
  check int "an equal schema repeated within one request shares a job-local digest"
    1 (Change.fresh_tool_count twice_fresh)
;;

let test_appended () =
  let history = [ user "a"; assistant "b" ] in
  check_messages
    "history extended"
    ~previous:history
    ~current:(history @ [ user "c"; assistant "d" ])
    (Message_list_change.Appended { kept = 2; added = 2 });
  check_messages
    "identical list"
    ~previous:history
    ~current:history
    (Message_list_change.Appended { kept = 2; added = 0 });
  check_messages
    "from an empty list"
    ~previous:[]
    ~current:history
    (Message_list_change.Appended { kept = 0; added = 2 })
;;

let test_signed_zero_json_is_not_memoized_as_the_same_wire () =
  let tool_use input =
    Agent_core.Types.make_message
      ~role:Agent_core.Types.Assistant
      [ Agent_core.Types.ToolUse { id = "call-zero"; name = "measure"; input } ]
  in
  let positive = tool_use (`Assoc [ "value", `Float 0.0 ]) in
  let negative = tool_use (`Assoc [ "value", `Float (-0.0) ]) in
  check_messages
    "signed zero changes provider bytes"
    ~previous:[ positive ]
    ~current:[ negative ]
    (Message_list_change.Diverged_at
       { index = 0
       ; previous_role = Agent_core.Types.Assistant
       ; previous_bytes = payload_bytes positive
       ; current_role = Agent_core.Types.Assistant
       ; current_bytes = payload_bytes negative
       ; previous_count = 1
       ; current_count = 1
       })
;;

let test_block_dropped () =
  check_messages
    "window moved past the oldest messages"
    ~previous:[ user "a"; assistant "b"; user "c"; assistant "d" ]
    ~current:[ user "c"; assistant "d"; user "e" ]
    (Message_list_change.Block_dropped { at = 0; dropped = 2; kept_after = 2; added = 1 });
  check_messages
    "a repeated message reports the smallest drop"
    ~previous:[ user "a"; user "x"; user "x" ]
    ~current:[ user "x"; user "x"; user "z" ]
    (Message_list_change.Block_dropped { at = 0; dropped = 1; kept_after = 2; added = 1 });
  check_messages
    "a block dropped behind a message that stayed first"
    ~previous:[ user "instruction"; user "o1"; assistant "o2"; user "o3"; assistant "r1" ]
    ~current:[ user "instruction"; user "o3"; assistant "r1"; user "n1" ]
    (Message_list_change.Block_dropped { at = 1; dropped = 2; kept_after = 2; added = 1 });
  check_messages
    "a repeated message behind a shared first message"
    ~previous:[ user "x"; user "x"; user "y" ]
    ~current:[ user "x"; user "y"; user "z" ]
    (Message_list_change.Block_dropped { at = 1; dropped = 1; kept_after = 1; added = 1 })
;;

let test_tail_removed () =
  check_messages
    "current list is a strict prefix"
    ~previous:[ user "a"; assistant "b"; user "c" ]
    ~current:[ user "a" ]
    (Message_list_change.Tail_removed { kept = 1; removed = 2 });
  check_messages
    "every message removed"
    ~previous:[ user "a" ]
    ~current:[]
    (Message_list_change.Tail_removed { kept = 0; removed = 1 })
;;

let test_rewritten_in_place () =
  let previous_message = user "b" in
  let current_message = assistant "b rewritten" in
  check_messages
    "one message replaced, the next one still in place"
    ~previous:[ user "a"; previous_message; user "c" ]
    ~current:[ user "a"; current_message; user "c"; user "d" ]
    (Message_list_change.Rewritten_in_place
       { first_index = 1
       ; last_index = 1
       ; rewritten = 1
       ; previous_bytes = payload_bytes previous_message
       ; current_bytes = payload_bytes current_message
       ; first_previous_role = Agent_core.Types.User
       ; first_current_role = Agent_core.Types.Assistant
       ; added = 1
       });
  let old_result = user "tool result, full" in
  let shrunk_result = user "short" in
  let old_second = user "second result, full" in
  let shrunk_second = user "short 2" in
  check_messages
    "two separate older messages shrunk while later ones stay"
    ~previous:[ user "s"; old_result; assistant "a1"; old_second; assistant "a2"; user "u" ]
    ~current:
      [ user "s"; shrunk_result; assistant "a1"; shrunk_second; assistant "a2"; user "u" ]
    (Message_list_change.Rewritten_in_place
       { first_index = 1
       ; last_index = 3
       ; rewritten = 2
       ; previous_bytes = payload_bytes old_result + payload_bytes old_second
       ; current_bytes = payload_bytes shrunk_result + payload_bytes shrunk_second
       ; first_previous_role = Agent_core.Types.User
       ; first_current_role = Agent_core.Types.User
       ; added = 0
       })
;;

let test_diverged_at () =
  let previous_message = user "b" in
  let current_message = assistant "b rewritten" in
  check_messages
    "a difference with nothing aligned after it"
    ~previous:[ user "a"; previous_message ]
    ~current:[ user "a"; current_message; user "c" ]
    (Message_list_change.Diverged_at
       { index = 1
       ; previous_role = Agent_core.Types.User
       ; previous_bytes = payload_bytes previous_message
       ; current_role = Agent_core.Types.Assistant
       ; current_bytes = payload_bytes current_message
       ; previous_count = 2
       ; current_count = 3
       });
  check_messages
    "a longer previous list is never read as a rewrite in place"
    ~previous:[ user "a"; user "b"; user "c"; user "d" ]
    ~current:[ user "a"; user "x"; user "c" ]
    (Message_list_change.Diverged_at
       { index = 1
       ; previous_role = Agent_core.Types.User
       ; previous_bytes = payload_bytes (user "b")
       ; current_role = Agent_core.Types.User
       ; current_bytes = payload_bytes (user "x")
       ; previous_count = 4
       ; current_count = 3
       });
  let rendered =
    Change.compare_requests
      ~previous:(Change.Request_digested (digest [ previous_message ]))
      ~current:(digest [ current_message ])
    |> Change.change_to_json
  in
  let messages = Yojson.Safe.Util.member "messages" rendered in
  check
    string
    "roles are written as provider role names"
    "assistant"
    (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "current_role" messages))
;;

let tools_changed change =
  match change with
  | Change.Follows_previous_request { tools_changed; _ } -> tools_changed
  | Change.First_request_of_turn | Change.Previous_request_not_digested ->
    failf "expected a comparison, got %s" (render change)
;;

let test_tools_flag () =
  let messages = [ user "a" ] in
  let compare ~previous ~current =
    Change.compare_requests ~previous:(Change.Request_digested previous) ~current
    |> tools_changed
  in
  check
    bool
    "same tools"
    false
    (compare ~previous:(digest messages) ~current:(digest messages));
  check
    bool
    "a tool added"
    true
    (compare
       ~previous:(digest messages)
       ~current:(digest ~tools:(fixture_tools @ [ tool "masc_board" ]) messages));
  check
    bool
    "tool order is part of the prefix"
    true
    (compare
       ~previous:(digest ~tools:[ tool "masc_status"; tool "masc_board" ] messages)
       ~current:(digest ~tools:[ tool "masc_board"; tool "masc_status" ] messages));
  check
    bool
    "the flag does not follow the message change"
    false
    (compare ~previous:(digest [ user "x" ]) ~current:(digest [ user "y" ]))
;;

let long_count = 6_000

let test_long_lists () =
  let history = numbered "history" long_count in
  check_messages
    "long distinct history dropped at the front"
    ~previous:history
    ~current:(List.filteri (fun index _ -> index >= 1_500) history @ numbered "new" 20)
    (Message_list_change.Block_dropped
       { at = 0; dropped = 1_500; kept_after = long_count - 1_500; added = 20 });
  check_messages
    "long distinct history dropped behind a pinned first message"
    ~previous:(user "instruction" :: history)
    ~current:
      ((user "instruction" :: List.filteri (fun index _ -> index >= 1_500) history)
       @ numbered "new" 20)
    (Message_list_change.Block_dropped
       { at = 1; dropped = 1_500; kept_after = long_count - 1_500; added = 20 });
  let same = List.init long_count (fun _ -> user "same") in
  check_messages
    "long repeated history dropped at the front"
    ~previous:(user "oldest" :: same)
    ~current:(same @ [ user "newest" ])
    (Message_list_change.Block_dropped { at = 0; dropped = 1; kept_after = long_count; added = 1 });
  check_messages
    "long repeated history rewritten at the tail"
    ~previous:(same @ [ user "a" ])
    ~current:(same @ [ user "b" ])
    (Message_list_change.Diverged_at
       { index = long_count
       ; previous_role = Agent_core.Types.User
       ; previous_bytes = payload_bytes (user "a")
       ; current_role = Agent_core.Types.User
       ; current_bytes = payload_bytes (user "b")
       ; previous_count = long_count + 1
       ; current_count = long_count + 1
       })
;;

(* The parts a snapshot row lists, built from the payloads the snapshot stores:
   one system prompt, the messages, then the tool schemas. *)
let snapshot_parts ?(tools = fixture_tools) messages =
  let sized payload =
    String.length (Snapshot.payload_bytes payload), Snapshot.payload_sha256 payload
  in
  let message_part (message : Agent_core.Types.message) =
    let bytes, sha256 = sized (Snapshot.message_payload message) in
    ( Snapshot.Message { role = Agent_core.Types.role_to_string message.role }
    , bytes
    , sha256 )
  in
  let tool_part tool =
    let bytes, sha256 = sized (Snapshot.tool_schema_payload tool) in
    Snapshot.Tool_schema { name = "fixture" }, bytes, sha256
  in
  List.mapi
    (fun part_index (part_kind, part_bytes, part_sha256) ->
       { Snapshot.part_index; part_kind; part_bytes; part_sha256 })
    (((Snapshot.System_prompt, 0, "system") :: List.map message_part messages)
     @ List.map tool_part tools)
;;

let digests_of_snapshot parts =
  match Change.digests_of_parts parts with
  | Ok digests -> digests
  | Error detail -> failf "snapshot parts did not digest: %s" detail
;;

(* Two turns are compared through their snapshots: the parts must classify as
   the requests they describe would. *)
let test_snapshot_parts_digest_as_their_request () =
  let previous = [ user "a"; assistant "b" ] in
  let current = [ user "a"; assistant "b"; user "c" ] in
  let render_messages change =
    Yojson.Safe.to_string (Message_list_change.to_json change)
  in
  check
    string
    "parts classify as the live request"
    (render_messages (Message_list_change.Appended { kept = 2; added = 1 }))
    (render_messages
       (Change.compare_messages
          ~previous:(digests_of_snapshot (snapshot_parts previous))
          ~current:(digest current)));
  check
    int
    "the system prompt is not a message"
    2
    (Change.message_count (digests_of_snapshot (snapshot_parts previous)));
  check
    bool
    "the tool schemas digest alike"
    false
    (Change.tool_schemas_differ
       ~previous:(digests_of_snapshot (snapshot_parts previous))
       ~current:(digest current));
  check
    bool
    "a tool the snapshot did not carry differs"
    true
    (Change.tool_schemas_differ
       ~previous:(digests_of_snapshot (snapshot_parts previous))
       ~current:(digest ~tools:(fixture_tools @ [ tool "masc_board" ]) current));
  let unknown_role =
    List.map
      (fun (part : Snapshot.part) ->
         match part.part_kind with
         | Snapshot.Message _ ->
           { part with Snapshot.part_kind = Snapshot.Message { role = "narrator" } }
         | Snapshot.System_prompt | Snapshot.Tool_schema _ -> part)
      (snapshot_parts previous)
  in
  check
    bool
    "a stored role no reader knows is refused"
    true
    (Result.is_error (Change.digests_of_parts unknown_role))
;;

let () =
  Alcotest.run
    "keeper projection change"
    [ ( "turn boundary"
      , [ test_case "first request of a turn" `Quick test_first_request_of_turn
        ; test_case
            "a request without digests is not compared across"
            `Quick
            test_previous_request_not_digested
        ; test_case "digest memo commit is explicit" `Quick
            test_digest_memo_commit_is_explicit
        ; test_case "append-only turn hashes each value once" `Quick
            test_append_only_turn_hashes_each_value_once
        ; test_case "tool schema memo keys on schema value" `Quick
            test_tool_schema_memo_keys_on_schema_value
        ] )
    ; ( "message change"
      , [ test_case "appended" `Quick test_appended
        ; test_case "signed zero JSON differs on wire" `Quick
            test_signed_zero_json_is_not_memoized_as_the_same_wire
        ; test_case "block dropped" `Quick test_block_dropped
        ; test_case "tail removed" `Quick test_tail_removed
        ; test_case "rewritten in place" `Quick test_rewritten_in_place
        ; test_case "diverged at" `Quick test_diverged_at
        ; test_case "long lists" `Quick test_long_lists
        ] )
    ; "tool schemas", [ test_case "tools flag" `Quick test_tools_flag ]
    ; ( "snapshots"
      , [ test_case "snapshot parts digest as their request" `Quick
            test_snapshot_parts_digest_as_their_request
        ] )
    ]
;;
