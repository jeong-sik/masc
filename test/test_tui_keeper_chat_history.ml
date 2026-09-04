open Alcotest

module History = Masc_tui_keeper_chat_history
module Transcript = Masc_tui_keeper_chat_transcript

let addressed ?(ts = 1.0) ?speaker_name ?speaker_id ?surface
    ?(speaker_authority = "owner") content =
  `Assoc
    ([ "id", `String "row"
     ; "role", `String "user"
     ; "content", `String content
     ; "ts", `Float ts
     ; "speaker_authority", `String speaker_authority
     ]
     @ (match speaker_name with
        | None -> []
        | Some name -> [ "speaker_name", `String name ])
     @ (match speaker_id with
        | None -> []
        | Some id -> [ "speaker_id", `String id ])
     @ (match surface with None -> [] | Some json -> [ "surface", json ]))
;;

(* The live store holds 6217 unnamed user rows and 6216 of them carry
   [speaker_authority], so a fixture without it is not a row this pane will
   normally see. [owner] is the operator's own, which is what these cases are
   about; the one row that lacks it falls to unresolved, which is the case
   below. *)
let row ?(ts = 1.0) ~role ?kind ?tool_call_id ?execution_id ?tool_call_name
    ?delivery_key ?transcript_slot ?turn_ref ?(speaker_authority = "owner")
    content =
  `Assoc
    ([ "id", `String "row"
     ; "role", `String role
     ; "content", `String content
     ; "ts", `Float ts
     ]
     @ (if role = "user" then [ "speaker_authority", `String speaker_authority ]
        else [])
     @ (match kind with None -> [] | Some k -> [ "kind", `String k ])
     @ (match delivery_key with None -> [] | Some json -> [ "delivery_key", json ])
     @ (match transcript_slot with
        | None -> []
        | Some json -> [ "transcript_slot", json ])
     @ (match turn_ref with None -> [] | Some id -> [ "turn_ref", `String id ])
     @ (match tool_call_id with
        | None -> []
        | Some id -> [ "tool_call_id", `String id ])
     @ (match execution_id with
        | None -> []
        | Some id -> [ "execution_id", `String id ])
     @ (match tool_call_name with
        | None -> []
        | Some name -> [ "tool_call_name", `String name ]))

let operation_key id =
  `Assoc [ "kind", `String "operation"; "operation_id", `String id ]

let transcript_slot kind = `Assoc [ "kind", `String kind ]

let tool_transcript_slot execution_id ordinal =
  `Assoc
    [ "kind", `String "tool_call"
    ; "execution_id", `String execution_id
    ; "ordinal", `Int ordinal
    ]

let origin_request_id = function
  | History.Delivery_failed { origin_request_id; _ } -> origin_request_id
  | History.Addressed_to_keeper _ | History.Said_by_keeper
  | History.Autonomous_reply
  | History.Tool_calls _ | History.Skill_activity _ | History.Reasoning _
  | History.Gate_activity _ | History.Memory_activity _ -> None

let full_tool_rows = History.tool_rows

let kind_to_string : History.kind -> string = function
  | History.Addressed_to_keeper { speaker; surface } ->
      Printf.sprintf "addressed(%s)" (History.addressed_label speaker surface)
  | History.Said_by_keeper -> "keeper"
  | History.Autonomous_reply -> "autonomous"
  | History.Delivery_failed _ -> "delivery_failed"
  | History.Tool_calls block ->
      Printf.sprintf "tools[%s]" (String.concat " | " (full_tool_rows block))
  | History.Skill_activity skill ->
      Printf.sprintf "skill[%s]"
        (String.concat " | " (Transcript.skill_rows ~full:true skill))
  | History.Reasoning lines ->
      Printf.sprintf "thinking[%s]" (String.concat " | " lines)
  | History.Gate_activity { approval_id; phase; tool; _ } ->
      Printf.sprintf "gate[%s %s%s]" approval_id phase
        (match tool with None -> "" | Some tool -> " " ^ tool)
  | History.Memory_activity _ -> "memory"

(* An assistant row the way an autonomous turn persists it: the server's
   [autonomous_turn] marker, a blank [content], and a [t: "trace"] block of
   steps. [content] is [null] on the wire when the turn said nothing
   ([server_dashboard_http_keeper_api.ml], the autonomous row encoder), so
   the default here is the wire's shape, not an empty string. *)
let autonomous_turn ?(ts = 1.0) ?(content = `Null) ?(marked = true) ?omitted
    ?turn_ref ?skill_activations steps =
  `Assoc
    ([ "id", `String "autonomous:trace-1#54"
     ; "role", `String "assistant"
     ; "content", content
     ; "ts", `Float ts
     ]
    @ (match turn_ref with None -> [] | Some id -> [ "turn_ref", `String id ])
    @ (match skill_activations with
       | None -> []
       | Some json -> [ "skill_activations", json ])
    @ (if marked then
         [ "autonomous_turn", `Assoc [ "turn_id", `String "trace-1#54" ] ]
       else [])
    @ [ ( "blocks"
      , `List
          [ `Assoc
              ([ "t", `String "trace"; "trace", `List steps ]
               @ (match omitted with None -> [] | Some n -> [ "omitted", `Int n ]))
          ] )
      ])

let think_withheld =
  `Assoc [ "kind", `String "think"; "text", `String ""; "content_withheld", `Bool true ]

let reason text = `Assoc [ "kind", `String "reason"; "text", `String text ]

let tool ?execution_id ?tool_call_id ?status ?dur name =
  `Assoc
    ([ "kind", `String "tool"; "name", `String name ]
     @ (match execution_id with
        | None -> []
        | Some id -> [ "execution_id", `String id ])
     @ (match tool_call_id with
        | None -> []
        | Some id -> [ "tool_call_id", `String id ])
     @ (match status with None -> [] | Some s -> [ "status", `String s ])
     @ (match dur with None -> [] | Some d -> [ "dur", `String d ]))

let skill_activation ?(delivery = `Assoc []) ?(actions = [])
    ?(name = "ci-red-attribution") () =
  `Assoc
    [ "identity", `Assoc [ "name", `String name ]
    ; "content_revision", `String "sha256:content-1"
    ; "turn_ref", `String "trace-1#54"
    ; "runtime_id", `String "codex-app-server"
    ; "skill_tool_use_id", `String "skill-use-1"
    ; "delivery", delivery
    ; ( "actions"
      , `List
          (List.map
             (fun tool_name -> `Assoc [ "tool_name", `String tool_name ])
             actions) )
    ]

let skill_projection ?detail ~status activations =
  `Assoc
    ([ "schema", `String "masc.keeper_chat.skill_activations.v1"
     ; "status", `String status
     ; "activations", `List activations
     ]
     @ (match detail with None -> [] | Some value -> [ "detail", `String value ]))

let decode json =
  match History.rows_of_json json with
  | Ok decoded -> decoded
  | Error detail -> failf "expected a decode, got %s" detail

(* A Gate row is drawn from its typed phase, so it has to reach the pane as one.
   The approval id is what folds a run of steps back into the one approval they
   describe; a lifecycle without it is not a step this pane can place, and
   stays in the neutral lane rather than being drawn as a lone approval. *)
let gate_row ~ts ~slot ?approval_id ~phase ?tool ?summary content =
  `Assoc
    [ "id", `String ("gate-" ^ slot)
    ; "role", `String "system"
    ; "content", `String content
    ; "ts", `Float ts
    ; "transcript_slot", `Assoc [ "kind", `String slot ]
    ; ( "approval_lifecycle"
      , `Assoc
          ([ "phase", `String phase ]
           @ (match approval_id with
              | None -> []
              | Some id -> [ "approval_id", `String id ])
           @ (match tool with
              | None -> []
              | Some name -> [ "tool_name", `String name ])
           @ (match summary with
              | None -> []
              | Some text -> [ "call_summary", `String text ])) )
    ]

(* A step row is read on its own, without the pane going back to the request
   row: the summary of what the gated call asked for travels with every
   phase. *)
let test_a_gate_row_carries_its_call_summary () =
  let decoded =
    decode
      (`List
         [ gate_row ~ts:1.0 ~slot:"approval_request" ~approval_id:"appr_01s"
             ~phase:"requested" ~tool:"tool_execute"
             ~summary:"git reflog --date=iso | head -30" ""
         ])
  in
  (match decoded.History.rows with
   | [ row ] -> (
     match row.History.kind with
     | History.Gate_activity { summary; _ } ->
       check (option string) "the summary names what was deferred"
         (Some "git reflog --date=iso | head -30") summary
     | _ -> failf "expected a gate row")
   | rows -> failf "expected one gate row, got %d" (List.length rows))

let test_a_gate_row_carries_its_approval () =
  let decoded =
    decode
      (`List
         [ gate_row ~ts:1.0 ~slot:"approval_request" ~approval_id:"appr_01a"
             ~phase:"requested" ~tool:"Execute" ""
         ; gate_row ~ts:2.0 ~slot:"approval_replay" ~approval_id:"appr_01a"
             ~phase:"replay_applied" ~tool:"Execute" ""
         ])
  in
  check int "nothing was dropped" 0 decoded.History.dropped;
  check (list string) "each step keeps its approval, phase and tool"
    [ "gate[appr_01a requested Execute]"; "gate[appr_01a replay_applied Execute]" ]
    (List.map (fun r -> kind_to_string r.History.kind) decoded.History.rows)

let test_a_lifecycle_without_an_approval_id_is_not_a_gate_row () =
  let decoded =
    decode
      (`List
         [ gate_row ~ts:1.0 ~slot:"approval_replay" ~phase:"replay_applied"
             ~tool:"Execute" "적용 완료"
         ])
  in
  check (list string) "it stays in the neutral lane" [ "memory" ]
    (List.map (fun r -> kind_to_string r.History.kind) decoded.History.rows)

let test_roles_map_to_what_the_pane_draws () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"user" "고쳐줘"
         ; row ~ts:2.0 ~role:"assistant" "고쳤어요"
         ; row ~ts:3.0 ~role:"assistant" ~kind:"transport_failure" "slack 5xx"
         ; row ~ts:4.0 ~role:"system"
             ~delivery_key:
               (`Assoc
                  [ "kind", `String "approval_lifecycle"
                  ; "approval_id", `String "appr_01typed"
                  ])
             ~transcript_slot:(transcript_slot "approval_resolution")
             "승인됨 · Execute"
         ])
  in
  check int "nothing was dropped" 0 decoded.History.dropped;
  check (list string) "each role lands where it belongs"
    [ "addressed(you)"; "keeper"; "delivery_failed"; "memory" ]
    (List.map (fun r -> kind_to_string r.History.kind) decoded.History.rows);
  check (list string) "and the text comes through"
    [ "고쳐줘"; "고쳤어요"; "slack 5xx"; "승인됨 · Execute" ]
    (List.map (fun r -> r.History.text) decoded.History.rows);
  (match (List.nth decoded.History.rows 3).History.kind with
   | History.Gate_activity _ -> failf "unexpected gate row"
   | History.Memory_activity { summary } ->
       check (option string) "a neutral system row stays whole" None summary
   | History.Addressed_to_keeper _ | History.Said_by_keeper
   | History.Autonomous_reply | History.Delivery_failed _
   | History.Tool_calls _ | History.Skill_activity _ | History.Reasoning _ ->
       fail "expected the system row to use the neutral Memory lane")

(* The pane writes its own row when a turn fails, because most error rows are
   notices the server has no row for. A failed turn is the one it does record,
   and it comes back under the operation the client dispatched -- which is what
   lets the pane drop its own copy instead of drawing the failure twice.

   Only an operation key names a turn this client dispatched. A row the server
   wrote under another producer's key reads as [None] rather than handing back
   an id that belongs to someone else. *)
let test_a_failed_turn_names_the_request_it_came_from () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"assistant" ~kind:"transport_failure"
             ~delivery_key:(operation_key "tui-28e58beb") "provider closed the connection"
         ; row ~ts:2.0 ~role:"assistant" ~kind:"transport_failure"
             ~delivery_key:
               (`Assoc
                  [ "kind", `String "fusion_run"; "request_id", `String "fusion-1" ])
             "provider closed the connection"
         ; row ~ts:3.0 ~role:"assistant" ~kind:"transport_failure"
             "provider closed the connection"
         ])
  in
  check int "nothing was dropped" 0 decoded.History.dropped;
  check (list (option string)) "an operation key is the request, anything else is not"
    [ Some "tui-28e58beb"; None; None ]
    (List.map (fun r -> origin_request_id r.History.kind) decoded.History.rows)
;;

let fenced_failure diagnostic =
  Printf.sprintf
    "Keeper request failed: Internal error: [masc_agent_core_error] {\"kind\":\"provider_attempt_effect_fenced\",\"runtime_id\":\"codex_subscription.gpt-5.6-luna\",\"effect_disposition\":\"effect_attempted\",\"diagnostic\":%s}"
    (Yojson.Safe.to_string (`String diagnostic))
;;

let test_runtime_interruption_becomes_a_recovered_lifecycle () =
  let failure =
    fenced_failure "MASC runtime shutdown interrupted the active Codex turn"
  in
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"user" "brief me"
         ; row ~ts:2.0 ~role:"assistant" ~kind:"transport_failure" failure
         ; autonomous_turn ~ts:3.0 ~content:(`String "briefing complete") []
         ])
  in
  let failed = List.nth decoded.History.rows 1 in
  match failed.History.kind with
  | History.Delivery_failed { recovered_at; _ } ->
    check (option (float 0.0)) "later reply is recovery evidence" (Some 3.0)
      recovered_at;
    (match History.present_delivery_failure ?recovered_at failed.History.text with
     | None -> fail "typed runtime interruption was not presented"
     | Some (text, recovered) ->
       check bool "no longer a live error" true recovered;
       check string "compact lifecycle"
         "Runtime shutdown interrupted this turn · lane recovered in a later Keeper reply · same-turn replay blocked to avoid duplicate tool calls · details in Logs"
         text)
  | _ -> fail "expected a delivery failure"
;;

let test_stdout_close_stays_pending_without_a_later_reply () =
  let failure =
    fenced_failure "Provider 'codex_app_server' unavailable: stdout closed"
  in
  let decoded =
    decode (`List [ row ~ts:2.0 ~role:"assistant" ~kind:"transport_failure" failure ])
  in
  match decoded.History.rows with
  | [ { History.kind = History.Delivery_failed { recovered_at; _ }; text; _ } ] ->
    check (option (float 0.0)) "no recovery was invented" None recovered_at;
    (match History.present_delivery_failure ?recovered_at text with
     | None -> fail "provider EOF was not presented"
     | Some (presented, recovered) ->
       check bool "still pending" false recovered;
       check string "compact pending lifecycle"
         "Provider connection closed during this turn · recovery pending · same-turn replay blocked to avoid duplicate tool calls · details in Logs"
         presented)
  | _ -> fail "expected one delivery failure"
;;

let test_unfenced_runtime_shutdown_is_still_typed () =
  match
    History.present_delivery_failure
      "Keeper request failed: MASC runtime shutdown interrupted the active Codex turn"
  with
  | None -> fail "direct shutdown cause was not presented"
  | Some (presented, recovered) ->
    check bool "still pending" false recovered;
    check string "no duplicate-call claim without effect evidence"
      "Runtime shutdown interrupted this turn · recovery pending · details in Logs"
      presented
;;

let test_unrelated_failure_is_not_marked_recovered () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"assistant" ~kind:"transport_failure"
             "Keeper request failed: auth denied"
         ; row ~ts:2.0 ~role:"assistant" "a later reply"
         ])
  in
  match decoded.History.rows with
  | { History.kind = History.Delivery_failed { recovered_at; _ }; text; _ } :: _ ->
    check (option (float 0.0)) "unrelated failure stays a failure" None recovered_at;
    check string "raw detail remains visible" "Keeper request failed: auth denied" text;
    check (option (pair string bool)) "no lifecycle was invented" None
      (History.present_delivery_failure text)
  | _ -> fail "expected the unrelated delivery failure first"
;;

let test_rows_retain_the_exact_turn_identity () =
  let key = operation_key "tui-turn-42" in
  let decoded =
    decode
      (`List
         [ row ~role:"user" ~delivery_key:key
             ~transcript_slot:(transcript_slot "accepted_user") "check it"
         ; row ~role:"tool" ~delivery_key:key
             ~transcript_slot:(tool_transcript_slot "exec-1" 0)
             ~tool_call_name:"Read" "{}"
         ; row ~role:"assistant" ~delivery_key:key
             ~transcript_slot:(transcript_slot "terminal_assistant") "done"
         ])
  in
  check (list (option string)) "every row keeps the producer's operation id"
    [ Some "tui-turn-42"; Some "tui-turn-42"; Some "tui-turn-42" ]
    (List.map (fun row -> row.History.turn_id) decoded.History.rows)
;;

(* The operation id is the delivery key's operation, typed, on every row of
   a direct turn -- and nothing else: an autonomous turn's rows carry their
   turn_ref as turn identity and no operation. *)
let test_rows_carry_the_operation_id_only_for_direct_turns () =
  let key = operation_key "tui-turn-42" in
  let decoded =
    decode
      (`List
         [ row ~role:"user" ~delivery_key:key
             ~transcript_slot:(transcript_slot "accepted_user") "check it"
         ; row ~role:"tool" ~delivery_key:key
             ~transcript_slot:(tool_transcript_slot "exec-1" 0)
             ~tool_call_name:"Read" "{}"
         ; row ~role:"assistant" ~delivery_key:key
             ~transcript_slot:(transcript_slot "terminal_assistant") "done"
         ; row ~role:"system" ~kind:"transport_failure" ~delivery_key:key
             ~transcript_slot:(transcript_slot "failure") "the wire dropped"
         ; autonomous_turn ~turn_ref:"trace-1#54" [ reason "look"; tool "Read" ]
         ; row ~role:"user"
             ~delivery_key:(`Assoc [ "kind", `String "fusion_run"; "request_id", `String "fr-1" ])
             ~transcript_slot:(transcript_slot "accepted_user") "from a fusion run"
         ])
  in
  check (list (option string))
    "every row of the direct turn carries it; autonomous and other keys do not"
    [ Some "tui-turn-42"; Some "tui-turn-42"; Some "tui-turn-42"; Some "tui-turn-42"
    ; None; None; None ]
    (List.map (fun row -> row.History.operation_id) decoded.History.rows);
  check (list (option string)) "turn identity is unchanged beside it"
    [ Some "tui-turn-42"; Some "tui-turn-42"; Some "tui-turn-42"; Some "tui-turn-42"
    ; Some "trace-1#54"; Some "trace-1#54"; Some "fr-1" ]
    (List.map (fun row -> row.History.turn_id) decoded.History.rows)
;;

let test_consecutive_tools_from_different_turns_do_not_merge () =
  let tool turn execution =
    row ~role:"tool" ~delivery_key:(operation_key turn)
      ~transcript_slot:(tool_transcript_slot execution 0)
      ~tool_call_name:"Read" "{}"
  in
  let decoded =
    decode (`List [ tool "turn-one" "exec-1"; tool "turn-two" "exec-2" ])
  in
  check int "two turn identities produce two blocks" 2
    (List.length decoded.History.rows);
  check (list (option string)) "each block keeps its own turn"
    [ Some "turn-one"; Some "turn-two" ]
    (List.map (fun row -> row.History.turn_id) decoded.History.rows)
;;

let test_autonomous_trace_rows_keep_the_turn_ref () =
  let decoded =
    decode
      (`List
         [ autonomous_turn ~turn_ref:"trace-1#54"
             [ reason "look"; tool "Read" ]
         ])
  in
  check (list (option string)) "reasoning, tools and reply share the turn_ref"
    [ Some "trace-1#54"; Some "trace-1#54" ]
    (List.map (fun row -> row.History.turn_id) decoded.History.rows)
;;

(* A [role: "user"] row is whatever was put in front of the keeper, and most of
   them are not the operator. One live keeper carried 92 such rows from 23
   distinct speakers — a keeper, an MCP client, the exact-lane verifier, a
   dozen canaries — and the pane drew every one as "you", which told the
   operator they had said things they had never seen. *)
(* Who sent a row and what the row is labelled are different answers, and the
   pane used to keep only the second. Everything downstream then asked the
   label: the chat's message recall asked [String.equal label "you"], which is
   false for the operator's own lines that came in on any surface but the
   dashboard, so the up-arrow walked past them.

   One live transcript: 23 rows the store calls the owner's, 2 of them on the
   agent surface, against 31 broadcasts from six other senders. *)
let test_an_addressed_row_says_who_sent_it_not_only_what_to_draw () =
  let speaker json =
    match (List.hd (decode (`List [ json ])).History.rows).History.kind with
    | History.Addressed_to_keeper { speaker; _ } -> speaker
    | History.Said_by_keeper | History.Autonomous_reply
    | History.Delivery_failed _ | History.Tool_calls _
    | History.Skill_activity _ | History.Reasoning _
    | History.Gate_activity _ -> failf "unexpected gate row"
    | History.Memory_activity _ ->
        failf "expected an addressed row"
  in
  let is_operator json =
    match speaker json with
    | History.Operator -> true
    | History.Named _ | History.Unresolved _ -> false
  in
  let surface kind = `Assoc [ "kind", `String kind ] in
  check bool "an owner row is the operator" true (is_operator (addressed "hi"));
  (* The label here reads "you . agent", which is why asking the label was
     wrong: the row is still the operator's. *)
  check bool "an owner row that came in on the agent surface is still the operator"
    true
    (is_operator (addressed ~surface:(surface "agent") "hi"));
  check bool "a named broadcast is not the operator" false
    (is_operator
       (addressed ~speaker_authority:"external" ~speaker_name:"sangsu"
          ~surface:(surface "broadcast") "hi"));
  check bool "an unnamed external row is not the operator either" false
    (is_operator (addressed ~speaker_authority:"external" "hi"))

let test_an_addressed_row_is_labelled_by_who_sent_it () =
  let label json =
    match (List.hd (decode (`List [ json ])).History.rows).History.kind with
    | History.Addressed_to_keeper { speaker; surface } ->
        History.addressed_label speaker surface
    | History.Said_by_keeper | History.Autonomous_reply
    | History.Delivery_failed _ | History.Tool_calls _
    | History.Skill_activity _ | History.Reasoning _
    | History.Gate_activity _ -> failf "unexpected gate row"
    | History.Memory_activity _ ->
        failf "expected an addressed row"
  in
  let surface kind extra = `Assoc (("kind", `String kind) :: extra) in
  check string "an unnamed row the store calls the owner's is the operator" "you"
    (label (addressed "hello"));
  (* Who spoke is written down; the surface only says where it came in. The
     pane used to read the absence of a surface as "the operator", so an
     unnamed external speaker on the dashboard lane was drawn as the reader
     themselves. *)
  check string "an unnamed external row is not the reader" "someone"
    (label (addressed ~speaker_authority:"external" "hello"));
  check string "and it keeps the id it came with" "U09L0RH"
    (label (addressed ~speaker_authority:"external" ~speaker_id:"U09L0RH" "hi"));
  (* An authority this build does not know is not a licence to call someone
     the reader. *)
  check string "an authority this build cannot read stays unresolved" "someone"
    (label (addressed ~speaker_authority:"something_new" "hi"));
  check string "the dashboard is an operator surface, so it adds nothing"
    "vincent"
    (label (addressed ~speaker_name:"vincent" ~surface:(surface "dashboard" []) "hi"));
  check string "an agent is named and marked" "bandleader \xc2\xb7 agent"
    (label
       (addressed ~speaker_name:"bandleader" ~surface:(surface "agent" []) "routed"));
  check string "a fleet broadcast does not read like a direct message"
    "codex \xc2\xb7 broadcast"
    (label
       (addressed ~speaker_name:"codex" ~surface:(surface "broadcast" []) "main red"));
  (* The channel comes with it. A Keeper can be bound to several -- one keeper
     has five Discord channels -- and without this every one of them reads as
     the same place. *)
  check string "a connector says which one, and which channel"
    "vincent \xc2\xb7 slack C1"
    (label
       (addressed
          ~speaker_name:"vincent"
          ~surface:(surface "slack" [ "channel_id", `String "C1" ])
          "from slack"));
  (* Discord answers the same question through its own gateway, and the label
     is drawn by the same code. Pinned on both connectors so a fix to one does
     not quietly leave the other reading ids. *)
  check string "a named discord channel reads as the room"
    "nabi \xc2\xb7 discord #\xec\x9d\xbc\xeb\xb0\x98"
    (label
       (addressed ~speaker_name:"nabi"
          ~surface:
            (surface "discord"
               [ "channel_id", `String "1493253256019972230"
               ; "channel_name", `String "\xec\x9d\xbc\xeb\xb0\x98"
               ])
          "from discord"));
  (* The name where the workspace let us ask, the id where it did not. Both
     answer "which room"; only one of them reads as a place. *)
  check string "a named channel reads as the room"
    "vincent \xc2\xb7 slack #kinossam-dev"
    (label
       (addressed ~speaker_name:"vincent"
          ~surface:
            (surface "slack"
               [ "channel_id", `String "C09TK9L4DV4"
               ; "channel_name", `String "kinossam-dev"
               ])
          "from slack"));
  (* A blank name is the absence the resolver reports, not a room called "". *)
  check string "a blank name falls back to the id"
    "vincent \xc2\xb7 slack \xe2\x80\xa6TK9L4DV4"
    (label
       (addressed ~speaker_name:"vincent"
          ~surface:
            (surface "slack"
               [ "channel_id", `String "C09TK9L4DV4"
               ; "channel_name", `String "  "
               ])
          "from slack"));
  (* Discord ids are snowflakes: two channels created minutes apart share a
     long prefix, so the head is the half that does not tell them apart. These
     two are real ids from one Keeper's five bindings. *)
  let discord_label id =
    label
      (addressed ~speaker_name:"nabi"
         ~surface:(surface "discord" [ "channel_id", `String id ])
         "hello")
  in
  check bool "two channels of one Keeper read as two places" false
    (String.equal
       (discord_label "1356818755795157113")
       (discord_label "1356818756755525815"));
  (* An author the producer could not name is not the person reading the pane.
     272 rows from Slack and Discord arrived this way and every one of them
     was drawn as "you". *)
  check string "an unnamed connector author is not the operator"
    "\xe2\x80\xa6L0RHPW7P \xc2\xb7 slack C1"
    (label
       (addressed ~speaker_id:"U09L0RHPW7P" ~speaker_authority:"external"
          ~surface:(surface "slack" [ "channel_id", `String "C1" ])
          "from slack"));
  (* The producer repeating the id in the name field is the store saying it had
     no name, not a person called [U09L0RHPW7P]. *)
  check string "a name that repeats the id is not a name"
    "\xe2\x80\xa6L0RHPW7P \xc2\xb7 slack C1"
    (label
       (addressed ~speaker_id:"U09L0RHPW7P" ~speaker_name:"U09L0RHPW7P"
          ~speaker_authority:"external"
          ~surface:(surface "slack" [ "channel_id", `String "C1" ])
          "from slack"));
  (* And a row with no surface at all is still the operator's own: this pane
     and the dashboard send without one. *)
  check string "an unnamed row with no surface is still you" "you"
    (label (addressed "typed here"));
  check string "a gate goes by its channel label" "hookbot \xc2\xb7 ops-room"
    (label
       (addressed
          ~speaker_name:"hookbot"
          ~surface:(surface "gate" [ "label", `String "ops-room" ])
          "gated"));
  (* A kind this build was not taught draws the name alone. Inventing a badge
     for it would say something the row does not. *)
  check string "an unknown surface is unlabelled, not guessed" "someone"
    (label
       (addressed ~speaker_name:"someone" ~surface:(surface "telepathy" []) "?"))
;;

let test_consecutive_tool_rows_become_one_block () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"user" "봐줘"
         ; row ~ts:2.0 ~role:"tool" ~tool_call_name:"read_file"
             "{\"file_path\":\"lib/a.ml\"}"
         ; row ~ts:3.0 ~role:"tool" ~tool_call_name:"edit_file"
             "{\"file_path\":\"lib/b.ml\"}"
         ; row ~ts:4.0 ~role:"assistant" "봤어요"
         ])
  in
  match decoded.History.rows with
  | [ operator; tools; keeper ] ->
      check string "the operator's line is first" "addressed(you)"
        (kind_to_string operator.History.kind);
      check string "the keeper's line is last" "keeper"
        (kind_to_string keeper.History.kind);
      (match tools.History.kind with
       | History.Tool_calls block ->
           let rows = full_tool_rows block in
           check int "both calls are in one block" 2 (List.length rows);
           check bool "each row names the file it acted on" true
             (List.exists
                (fun r ->
                  String.length r > 0
                  && Option.is_some (String.index_opt r 'a'))
                rows);
           check bool "the rows carry the finished marker" true
             (List.for_all (fun r -> String.length r > 0) rows)
           ; check (list bool)
               "delivery-only rows do not claim a recorded return"
               [ true; true ]
               (List.map
                  (fun (activity : Transcript.tool_activity) ->
                    activity.outcome = Transcript.Outcome_unrecorded)
                  block.activities)
       | History.Addressed_to_keeper _ | History.Said_by_keeper
       | History.Autonomous_reply
       | History.Delivery_failed _ | History.Skill_activity _
       | History.Reasoning _
       | History.Gate_activity _ -> failf "unexpected gate row"
    | History.Memory_activity _ ->
           fail "expected the middle row to be a tool block");
      check (float 0.0) "the block is keyed to its first call" 2.0
        tools.History.at
  | rows -> failf "expected three rows, got %d" (List.length rows)

let test_history_keeps_producer_tool_call_identity () =
  let args_a = "{\"file_path\":\"lib/a.ml\"}" in
  let args_b = "{\"file_path\":\"lib/b.ml\"}" in
  let decoded =
    decode
      (`List
         [ row ~ts:2.0 ~role:"tool" ~tool_call_id:"c1" ~execution_id:"exec-1"
             ~tool_call_name:"read_file" args_a
         ; row ~ts:3.0 ~role:"tool" ~tool_call_id:"c2" ~execution_id:"exec-2"
             ~tool_call_name:"edit_file" args_b
         ])
  in
  match decoded.History.rows with
  | [ { History.kind = History.Tool_calls block; _ } ] ->
      let activities = block.activities in
      check (list (option string)) "producer identities stay in source order"
        [ Some "c1"; Some "c2" ]
        (List.map
           (fun (activity : Transcript.tool_activity) -> activity.call_id)
           activities);
      check (list (option string)) "canonical identities stay separate"
        [ Some "exec-1"; Some "exec-2" ]
        (List.map
           (fun (activity : Transcript.tool_activity) -> activity.execution_id)
           activities);
      check (list string) "the same subject authority names both calls"
        [ "lib/a.ml"; "lib/b.ml" ]
        (List.map
           (fun (activity : Transcript.tool_activity) ->
             Option.value ~default:"" activity.subject)
           activities);
      check (list (option string)) "direct rows do not invent durations"
        [ None; None ]
        (List.map
           (fun (activity : Transcript.tool_activity) -> activity.duration)
           activities);
      check (list bool) "canonical result rows are recorded as returned"
        [ true; true ]
        (List.map
           (fun (activity : Transcript.tool_activity) ->
             activity.outcome = Transcript.Returned)
           activities)
  | rows -> failf "expected one history tool block, got %d rows" (List.length rows)

let test_tool_blocks_separated_by_speech_stay_separate () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"tool" ~tool_call_name:"read_file" "{}"
         ; row ~ts:2.0 ~role:"assistant" "중간 설명"
         ; row ~ts:3.0 ~role:"tool" ~tool_call_name:"edit_file" "{}"
         ])
  in
  check (list string) "speech between two calls breaks the block"
    [ "tools"; "keeper"; "tools" ]
    (decoded.History.rows
     |> List.map (fun r ->
            match r.History.kind with
            | History.Tool_calls _ -> "tools"
            | other -> kind_to_string other))

(* On one live keeper 32 of 183 assistant rows had a blank [content] and a
   trace block behind it -- 1,333 tool steps and 917 withheld reasoning steps
   -- and every one drew as a timestamp over an empty line. *)
let test_an_autonomous_turn_draws_what_it_did () =
  let decoded =
    decode
      (`List
         [ autonomous_turn ~ts:5.0
             [ think_withheld
             ; tool ~execution_id:"trace-1" ~status:"ok" ~dur:"32ms"
                 "masc_task_history"
             ; think_withheld
             ; tool ~execution_id:"trace-2" ~status:"err" ~dur:"1200ms"
                 "tool_execute"
             ; tool ~execution_id:"trace-3" ~status:"pending"
                 "keeper_task_claim"
             ; tool "read_file"
             ]
         ])
  in
  check int "nothing was dropped" 0 decoded.History.dropped;
  match decoded.History.rows with
  | [ thinking; tools ] ->
      check string "the withheld reasoning is counted, not drawn blank"
        "thinking[2 reasoning steps · text not recorded]"
        (kind_to_string thinking.History.kind);
      (match tools.History.kind with
       | History.Tool_calls block ->
           let rows = full_tool_rows block in
           check int "every tool step is a row" 4 (List.length rows);
           let activities = block.activities in
           check (list (option string)) "trace has no provider identities"
             [ None; None; None; None ]
             (List.map
                (fun (activity : Transcript.tool_activity) -> activity.call_id)
                activities);
           check (list (option string)) "trace ids are canonical executions"
             [ Some "trace-1"; Some "trace-2"; Some "trace-3"; None ]
             (List.map
                (fun (activity : Transcript.tool_activity) ->
                  activity.execution_id)
                activities);
           check (list (option string)) "trace durations are not inferred"
             [ Some "32ms"; Some "1200ms"; None; None ]
             (List.map
                (fun (activity : Transcript.tool_activity) -> activity.duration)
                activities);
           let starts_with prefix row =
             String.length row >= String.length prefix
             && String.equal (String.sub row 0 (String.length prefix)) prefix
           in
           let row n = List.nth rows n in
           check bool "a call that returned carries the finished glyph" true
             (starts_with "\xe2\x9c\x93 masc_task_history" (row 0));
           check bool "and its duration" true
             (starts_with "\xe2\x9c\x93 masc_task_history \xc2\xb7 32ms" (row 0));
           check bool "a call that returned an error carries its own glyph" true
             (starts_with "\xe2\x9c\x97 tool_execute" (row 1));
           (* masc #32571 split "started or never returned" into two glyphs:
              a running call is a hollow circle, one that never returned is
              this. The distinction is the point of that change. *)
           check bool "a call the trace never saw finish carries its own glyph"
             true
             (starts_with "! keeper_task_claim" (row 2));
           check bool "a step with no status says it was not recorded" true
             (starts_with "? read_file" (row 3))
       | History.Addressed_to_keeper _ | History.Said_by_keeper
       | History.Autonomous_reply
       | History.Delivery_failed _ | History.Skill_activity _
       | History.Reasoning _
       | History.Gate_activity _ -> failf "unexpected gate row"
    | History.Memory_activity _ ->
           fail "expected the second row to be a tool block");
      check (float 0.0) "both rows are keyed to the turn" 5.0 tools.History.at
  | rows -> failf "expected two rows, got %d" (List.length rows)

let test_exact_skill_evidence_replaces_the_raw_call_and_names_actions () =
  let projection =
    skill_projection ~status:"available"
      [ skill_activation ~actions:[ "Execute"; "Read" ] () ]
  in
  let decoded =
    decode
      (`List
         [ autonomous_turn ~turn_ref:"trace-1#54"
             ~skill_activations:projection
             [ tool ~status:"ok" "keeper_skill"
             ; tool ~status:"ok" "Execute"
             ; tool ~status:"ok" "Read"
             ]
         ])
  in
  match decoded.History.rows with
  | [ skill_row; tools_row ] ->
      (match skill_row.kind with
       | History.Skill_activity skill ->
           check string "the exact ledger names the Skill" "ci-red-attribution"
             skill.skill_name;
           check bool "delivery plus observed actions means used" true
             (skill.state = Transcript.Skill_used);
           check (list string) "the exact action sequence is kept"
             [ "Execute"; "Read" ] skill.actions;
           let rows = Transcript.skill_rows ~full:true skill in
           check string "the strongest evidence state is bold"
             "**ci-red-attribution** \xc2\xb7 **DELIVERED \xc2\xb7 USED** \xc2\xb7 2 actions"
             (List.hd rows);
           check bool "the exact turn proof is visible" true
             (List.exists
                (String.starts_with ~prefix:"  proof \xc2\xb7 turn=trace-1#54")
                rows)
       | other ->
           failf "expected a Skill row, got %s" (kind_to_string other));
      (match tools_row.kind with
       | History.Tool_calls block ->
           check (list string) "the raw Skill tool is replaced, not duplicated"
             [ "Execute"; "Read" ]
             (List.map
                (fun (activity : Transcript.tool_activity) -> activity.tool_name)
                block.activities)
       | other ->
           failf "expected an action Tool block, got %s" (kind_to_string other))
  | rows ->
      failf "expected Skill plus action Tools, got %d row(s): %s"
        (List.length rows)
        (String.concat "; "
           (List.map
              (fun (row : History.row) -> kind_to_string row.kind)
              rows))

let test_served_skill_without_delivery_does_not_claim_use () =
  let projection =
    skill_projection ~status:"available"
      [ skill_activation ~delivery:`Null () ]
  in
  let decoded =
    decode
      (`List
         [ autonomous_turn ~turn_ref:"trace-1#54"
             ~skill_activations:projection
             [ tool ~status:"ok" "keeper_skill" ]
         ])
  in
  match decoded.History.rows with
  | [ { History.kind = History.Skill_activity skill; _ } ] ->
      check bool "served is weaker than delivered" true
        (skill.state = Transcript.Skill_served_only);
      check (list string) "the UI says delivery was not recorded"
        [ "**ci-red-attribution** \xc2\xb7 **SERVED ONLY \xc2\xb7 DELIVERY NOT RECORDED**" ]
        (Transcript.skill_rows ~full:false skill)
  | rows ->
      failf "expected one served-only Skill row, got %d: %s" (List.length rows)
        (String.concat "; "
           (List.map (fun (r : History.row) -> kind_to_string r.kind) rows))

let test_missing_skill_evidence_stays_visible_beside_the_raw_call () =
  let projection =
    skill_projection ~status:"missing"
      ~detail:"No activation matched this exact turn" []
  in
  let decoded =
    decode
      (`List
         [ autonomous_turn ~turn_ref:"trace-1#54"
             ~skill_activations:projection
             [ tool ~status:"ok" "keeper_skill" ]
         ])
  in
  match decoded.History.rows with
  | [ { History.kind = History.Skill_activity warning; _ }
    ; { History.kind = History.Tool_calls raw; _ }
    ] ->
      check bool "the evidence gap is a typed warning" true
        (warning.state = Transcript.Skill_evidence_missing);
      check string "the producer's raw call is retained" "keeper_skill"
        (List.hd raw.activities).tool_name;
      check (option string) "the exact failure reason is visible"
        (Some "No activation matched this exact turn") warning.detail
  | rows ->
      failf "expected warning plus raw Skill tool, got %d row(s)" (List.length rows)

let test_skill_evidence_count_mismatch_retains_every_raw_call () =
  let projection =
    skill_projection ~status:"available" [ skill_activation () ]
  in
  let decoded =
    decode
      (`List
         [ autonomous_turn ~turn_ref:"trace-1#54"
             ~skill_activations:projection
             [ tool ~status:"ok" "keeper_skill"
             ; tool ~status:"ok" "keeper_skill"
             ]
         ])
  in
  match decoded.History.rows with
  | [ { History.kind = History.Skill_activity exact; _ }
    ; { History.kind = History.Skill_activity warning; _ }
    ; { History.kind = History.Tool_calls raw; _ }
    ] ->
      check string "the exact activation is still shown" "ci-red-attribution"
        exact.skill_name;
      check bool "the count mismatch is a visible evidence error" true
        (warning.state = Transcript.Skill_evidence_unavailable);
      check int "neither unmatched raw call is hidden" 2
        (List.length raw.activities)
  | rows ->
      failf "expected exact evidence, warning, and raw calls; got %d row(s)"
        (List.length rows)

let test_a_turn_that_also_spoke_keeps_the_order_it_ran_in () =
  let decoded =
    decode
      (`List
         [ autonomous_turn ~ts:6.0
             ~content:(`String "\xea\xb3\xa0\xec\xb3\xa4\xec\x96\xb4\xec\x9a\x94")
             [ reason "the test names the old label"
             ; tool ~status:"ok" "edit_file"
             ]
         ])
  in
  check (list string) "reasoning, then calls, then what it said"
    [ "thinking[the test names the old label]"; "tools"; "autonomous" ]
    (decoded.History.rows
     |> List.map (fun r ->
            match r.History.kind with
            | History.Tool_calls _ -> "tools"
            | other -> kind_to_string other));
  check string "the text is the keeper's own row"
    "\xea\xb3\xa0\xec\xb3\xa4\xec\x96\xb4\xec\x9a\x94"
    (List.nth decoded.History.rows 2).History.text

let test_steps_the_server_dropped_are_counted () =
  let decoded =
    decode (`List [ autonomous_turn ~omitted:3 [ tool ~status:"ok" "read_file" ] ])
  in
  match decoded.History.rows with
  | [ { History.kind = History.Tool_calls block; _ } ] ->
      let rows = full_tool_rows block in
      check string "the count closes the block"
        "(3 steps not carried by the transcript)"
        (List.nth rows (List.length rows - 1))
  | _ -> fail "expected one tool block"

(* A direct-conversation turn can carry a trace block too: the server joins
   the raw trace onto rows that have a turn ref. Its calls are already in the
   transcript as [role: "tool"] rows, so reading the block as well drew every
   call twice. The marker the server puts on autonomous rows is what tells
   the two apart. *)
let test_a_direct_turn_s_trace_is_not_drawn_twice () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"tool" ~tool_call_name:"read_file" "{}"
         ; autonomous_turn ~ts:2.0 ~marked:false ~content:(`String "done")
             [ think_withheld; tool ~status:"ok" "read_file" ]
         ])
  in
  check (list string) "one tool block from the tool rows, then the text"
    [ "tools"; "keeper" ]
    (decoded.History.rows
     |> List.map (fun r ->
            match r.History.kind with
            | History.Tool_calls _ -> "tools"
            | other -> kind_to_string other))

let test_a_null_content_is_the_wire_s_blank () =
  let decoded =
    decode (`List [ autonomous_turn ~ts:3.0 [ tool ~status:"ok" "read_file" ] ])
  in
  check (list string) "null content draws the trace and no text row"
    [ "tools" ]
    (decoded.History.rows
     |> List.map (fun r ->
            match r.History.kind with
            | History.Tool_calls _ -> "tools"
            | other -> kind_to_string other))

let test_a_blank_turn_with_no_trace_keeps_its_line () =
  (* The server holds an empty row for it; drawing nothing would hide that a
     turn happened. Unchanged from before trace blocks were read. *)
  let decoded = decode (`List [ row ~ts:7.0 ~role:"assistant" "" ]) in
  check (list string) "one keeper row, blank" [ "keeper" ]
    (List.map (fun r -> kind_to_string r.History.kind) decoded.History.rows)

let test_a_blank_autonomous_turn_has_an_explicit_origin () =
  let decoded = decode (`List [ autonomous_turn ~ts:8.0 [] ]) in
  check (list string) "one autonomous row" [ "autonomous" ]
    (List.map (fun r -> kind_to_string r.History.kind) decoded.History.rows)

let test_persisted_identity_and_absolute_turn_survive_projection () =
  let decoded =
    decode
      (`List
         [ autonomous_turn ~turn_ref:"trace-1#54" ~content:(`String "done")
             [ reason "consider"; tool "Execute" ] ])
  in
  check (list (option int)) "one structural turn sequence on every projection"
    [ Some 54; Some 54; Some 54 ]
    (List.map (fun row -> row.History.turn_sequence) decoded.History.rows);
  let identities =
    List.filter_map (fun row -> row.History.structural_id) decoded.History.rows
  in
  check int "one stable identity per projected row" 3
    (List.length (List.sort_uniq String.compare identities))
;;

let test_server_order_is_kept () =
  (* The server appends in order and asks a client not to reposition rows that
     carry no ts. A decoder that sorted would move these three. *)
  let decoded =
    decode
      (`List
         [ row ~ts:9.0 ~role:"user" "first"
         ; row ~ts:0.0 ~role:"assistant" "second"
         ; row ~ts:5.0 ~role:"user" "third"
         ])
  in
  check (list string) "rows stay in the order they arrived"
    [ "first"; "second"; "third" ]
    (List.map (fun r -> r.History.text) decoded.History.rows)

let test_one_unreadable_row_does_not_cost_the_transcript () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"user" "kept"
         ; `Assoc [ "role", `String "wat"; "content", `String "dropped" ]
         ; `String "not even an object"
         ; (* A tool row with no name draws as a bare marker, so it is dropped
              rather than rendered nameless. *)
           row ~ts:2.0 ~role:"tool" "{}"
         ; row ~ts:3.0 ~role:"assistant" "also kept"
         ])
  in
  check int "the three unreadable rows are counted" 3 decoded.History.dropped;
  check (list string) "and the readable ones survive" [ "kept"; "also kept" ]
    (List.map (fun r -> r.History.text) decoded.History.rows)

let test_a_non_array_payload_is_an_error () =
  match History.rows_of_json (`Assoc [ "rows", `List [] ]) with
  | Ok _ -> fail "an object should not decode as a transcript"
  | Error detail ->
      check bool "the error names the shape" true (String.length detail > 0)

let test_a_missing_ts_reads_as_zero_not_a_failure () =
  let decoded =
    decode
      (`List
         [ `Assoc [ "role", `String "user"; "content", `String "no ts here" ] ])
  in
  check int "the row is kept" 0 decoded.History.dropped;
  match decoded.History.rows with
  | [ r ] -> check (float 0.0) "and sorts as the oldest" 0.0 r.History.at
  | rows -> failf "expected one row, got %d" (List.length rows)

(* Paging. The envelope is new; the rows inside are the transcript's, so what
   matters here is the cursor and the "is there more" flag -- getting either
   wrong either stops the pane short of the conversation's start or has it ask
   forever for a page that does not exist. *)

let page json =
  match History.page_of_json json with
  | Ok page -> page
  | Error detail -> failf "expected a page, got %s" detail

let page_envelope ?(has_more = true) ?next_before rows =
  `Assoc
    ([ "schema", `String "masc.keeper_chat_history.page.v1"
     ; "messages", `List rows
     ; "has_more", `Bool has_more
     ]
     @ (match next_before with
        | None -> [ "next_before", `Null ]
        | Some ts -> [ "next_before", `Float ts ]))

let test_a_page_decodes_its_rows_and_cursor () =
  let p =
    page
      (page_envelope ~has_more:true ~next_before:12.5
         [ row ~ts:20.0 ~role:"user" "older question"
         ; row ~ts:21.0 ~role:"assistant" "older answer"
         ])
  in
  check (list string) "the rows read like any other transcript rows"
    [ "older question"; "older answer" ]
    (List.map (fun r -> r.History.text) p.History.decoded.History.rows);
  check bool "more remain" true p.History.has_more;
  check (option (float 0.0)) "and the cursor for them" (Some 12.5)
    p.History.next_before

let test_the_top_of_the_conversation_says_so () =
  let p = page (page_envelope ~has_more:false [ row ~role:"user" "first ever" ]) in
  check bool "nothing older" false p.History.has_more;
  check (option (float 0.0)) "and no cursor to ask with" None
    p.History.next_before

let test_a_missing_has_more_reads_as_no_more () =
  (* Guessing true would leave the pane offering a page the server never
     promised, and every request for it would come back empty. *)
  let p =
    page (`Assoc [ "messages", `List [ row ~role:"user" "only row" ] ])
  in
  check bool "absence is not a promise of more" false p.History.has_more

let test_tool_rows_fold_in_a_page_as_they_do_in_the_transcript () =
  let p =
    page
      (page_envelope ~has_more:false
         [ row ~ts:1.0 ~role:"tool" ~tool_call_name:"read_file" "{}"
         ; row ~ts:2.0 ~role:"tool" ~tool_call_name:"edit_file" "{}"
         ])
  in
  match p.History.decoded.History.rows with
  | [ { History.kind = History.Tool_calls block; _ } ] ->
      let rows = full_tool_rows block in
      check int "consecutive calls are one block here too" 2
        (List.length rows)
  | rows -> failf "expected one folded block, got %d rows" (List.length rows)

let test_a_page_that_is_not_an_object_is_an_error () =
  match History.page_of_json (`List []) with
  | Ok _ -> fail "an array is not a page envelope"
  | Error detail -> check bool "and says so" true (String.length detail > 0)

let test_a_page_without_messages_is_an_error () =
  match History.page_of_json (`Assoc [ "has_more", `Bool true ]) with
  | Ok _ -> fail "a page with no rows array should not decode"
  | Error detail -> check bool "and says so" true (String.length detail > 0)

let contains text needle =
  let rec loop at =
    if at + String.length needle > String.length text
    then false
    else if String.sub text at (String.length needle) = needle
    then true
    else loop (at + 1)
  in
  loop 0
;;

let test_memory_commit_names_added_removed_and_drop_reason () =
  let payload =
    `Assoc
      [ ( "entries"
        , `List
            [ `Assoc
                [ "ok", `Bool true
                ; "outcome", `String "committed"
                ; "recorded_at", `Float 1_700_000_010.0
                ; "revision", `Int 7
                ; "source", `Assoc [ "kind", `String "librarian" ]
                ; ( "change"
                  , `Assoc
                      [ ( "added"
                        , `List
                            [ `Assoc
                                [ "category", `String "fact"
                                ; "claim", `String "the probe uses HTTP/2"
                                ]
                            ] )
                      ; ( "removed"
                        , `List
                            [ `Assoc
                                [ "category", `String "constraint"
                                ; "claim", `String "use the old endpoint"
                                ]
                            ] )
                      ; "retained", `Int 3
                      ] )
                ; ( "dropped"
                  , `List
                      [ `Assoc
                          [ "memory_id", `String "memory-old"
                          ; "reason", `String "superseded by live evidence"
                          ]
                      ] )
                ]
            ] )
      ]
  in
  match History.memory_rows_of_json payload with
  | Error detail -> failf "memory journal decode failed: %s" detail
  | Ok { History.rows = [ row ]; dropped = 0 } ->
      check (float 0.0) "journal timestamp retained" 1_700_000_010.0 row.at;
      check bool "journal has a stable producer identity" true
        (Option.is_some row.structural_id);
      (match row.kind with
       | History.Gate_activity _ -> failf "unexpected gate row"
   | History.Memory_activity { summary } ->
           check (option string) "typed summary is producer-built"
             (Some
                "Librarian committed current memory revision 7 \xc2\xb7 now 1 added, 1 removed, 3 retained")
             summary
       | History.Addressed_to_keeper _ | History.Said_by_keeper
       | History.Autonomous_reply | History.Delivery_failed _
       | History.Tool_calls _ | History.Skill_activity _
       | History.Reasoning _ ->
           fail "journal row lost its Memory activity type");
      List.iter
        (fun needle ->
           check bool needle true (contains row.text needle))
        [ "Librarian committed current memory revision 7"
        ; "now 1 added, 1 removed, 3 retained"
          (* The change is a diff fence. That is what colours the two
             directions, and what keeps a leading [+] out of markdown's list
             grammar -- the renderer used to escape it and nothing consumed
             the escape, so a backslash reached the pane. *)
        (* The journal is fenced as [memory], not [diff]: the sign says whether
           a fact arrived or left and the category takes a colour of its own,
           which two diff colours could not carry. Changed in #30921; this
           expectation was left behind because a pull request runs no checks. *)
        ; "```memory"
        ; "+ [fact] the probe uses HTTP/2"
        ; "- [constraint] use the old endpoint"
        ; "drop memory-old \xe2\x80\x94 superseded by live evidence"
        ]
  | Ok decoded ->
      failf "expected one decoded memory row, got %d/%d"
        (List.length decoded.rows) decoded.dropped
;;

let test_memory_failure_keeps_kind_and_detail () =
  let payload =
    `Assoc
      [ ( "entries"
        , `List
            [ `Assoc
                [ "ok", `Bool true
                ; "outcome", `String "failed"
                ; "recorded_at", `Float 1_700_000_020.0
                ; "trace_id", `String "trace-memory-failure"
                ; "kind", `String "exact_execution_failure"
                ; "detail", `String "provider returned 503"
                ; "snapshot_present", `Bool true
                ; "cadence_deferred", `Bool false
                ]
            ] )
      ]
  in
  match History.memory_rows_of_json payload with
  | Ok { History.rows = [ row ]; dropped = 0 } ->
      check bool "failed observation has a stable producer identity" true
        (Option.is_some row.structural_id);
      (match row.kind with
       | History.Gate_activity _ -> failf "unexpected gate row"
   | History.Memory_activity { summary } ->
           check (option string) "failure summary omits the detail body"
             (Some "Librarian failed \xc2\xb7 exact_execution_failure") summary
       | History.Addressed_to_keeper _ | History.Said_by_keeper
       | History.Autonomous_reply | History.Delivery_failed _
       | History.Tool_calls _ | History.Skill_activity _
       | History.Reasoning _ ->
           fail "failed journal row lost its Memory activity type");
      check bool "failure kind survives" true
        (contains row.text "exact_execution_failure");
      check bool "failure detail survives" true
        (contains row.text "provider returned 503")
  | Ok decoded ->
      failf "expected one failed memory row, got %d/%d"
        (List.length decoded.rows) decoded.dropped
  | Error detail -> failf "memory failure decode failed: %s" detail
;;

let memory_commit_entry ~revision ~recorded_at =
  `Assoc
    [ "ok", `Bool true
    ; "outcome", `String "committed"
    ; "recorded_at", `Float recorded_at
    ; "revision", `Int revision
    ; "source", `Assoc [ "kind", `String "librarian" ]
    ; ( "change"
      , `Assoc
          [ "added", `List []
          ; "removed", `List []
          ; "retained", `Int revision
          ] )
    ; "dropped", `List []
    ]
;;

let memory_failed_entry trace_id =
  `Assoc
    [ "ok", `Bool true
    ; "outcome", `String "failed"
    ; "recorded_at", `Float 1_700_000_020.0
    ; "trace_id", `String trace_id
    ; "kind", `String "exact_execution_failure"
    ; "detail", `String "provider returned 503"
    ; "snapshot_present", `Bool true
    ; "cadence_deferred", `Bool false
    ]
;;

let memory_structural_ids entries =
  match History.memory_rows_of_json (`Assoc [ "entries", `List entries ]) with
  | Ok { History.rows; dropped = 0 } ->
      List.map (fun row -> row.History.structural_id) rows
  | Ok decoded ->
      failf "memory identity fixture dropped %d row(s)" decoded.dropped
  | Error detail -> failf "memory identity fixture failed: %s" detail
;;

let test_memory_identity_survives_a_producer_prepend () =
  let current = memory_commit_entry ~revision:7 ~recorded_at:1_700_000_010.0 in
  let backfill = memory_commit_entry ~revision:6 ~recorded_at:1_800_000_000.0 in
  match memory_structural_ids [ current ], memory_structural_ids [ backfill; current ] with
  | [ Some before ], [ Some backfilled; Some after ] ->
      check string "the existing Journal identity survives prepend" before after;
      check bool "the prepended Journal row has a distinct identity" true
        (not (String.equal backfilled after))
  | before, after ->
      failf "expected stable Journal identities, got %d then %d"
        (List.length before) (List.length after)
;;

let test_failed_memory_identity_includes_trace_id () =
  match memory_structural_ids [ memory_failed_entry "trace-a"; memory_failed_entry "trace-b" ] with
  | [ Some left; Some right ] ->
      check bool "two failure traces have distinct identities" true
        (not (String.equal left right))
  | identities ->
      failf "expected two failed Journal identities, got %d"
        (List.length identities)
;;

let test_unreadable_memory_identity_is_server_supplied () =
  let structural_id = "memory:journal:5:alpha:17" in
  let payload =
    `Assoc
      [ ( "entries"
        , `List
            [ `Assoc
                [ "structural_id", `String structural_id
                ; "ok", `Bool false
                ; "error", `String "journal line is not valid JSON"
                ]
            ] )
      ]
  in
  match History.memory_rows_of_json payload with
  | Ok { History.rows = [ row ]; dropped = 0 } ->
      check (option string) "unreadable row keeps storage identity"
        (Some structural_id) row.structural_id
  | Ok decoded ->
      failf "expected one unreadable Journal row, got %d/%d"
        (List.length decoded.rows) decoded.dropped
  | Error detail -> failf "unreadable Journal fixture failed: %s" detail
;;

(* The store has carried [attachments] since the composer learned to stage a
   file. This reader ignored the field, so a message that arrived with a 70 KB
   image read as the sentence beside it and nothing else -- the only trace was
   the [[Image #1]] the composer had typed into the draft, which is text and
   not a file. *)
let test_a_row_names_the_file_it_carries () =
  let row =
    `Assoc
      [ "id", `String "row"
      ; "role", `String "user"
      ; "content", `String "here it is"
      ; "ts", `Float 1.0
      ; ( "attachments"
        , `List
            [ `Assoc
                [ "id", `String "tui-att-1"
                ; "type", `String "image"
                ; "name", `String "image-1.png"
                ; "size", `Int 70970
                ; "mime_type", `String "image/png"
                ]
            ] )
      ]
  in
  match (decode (`List [ row ])).History.rows with
  | [ r ] ->
    check int "the file is named once" 1
      (List.length r.History.attachments);
    (match r.History.attachments with
     | [ note ] ->
       check string "by its name" "image-1.png"
         note.History.att_name;
       check int "and its size" 70970 note.History.att_bytes;
       check string "and its type" "image/png"
         note.History.att_mime
     | _ -> fail "expected one note");
    (* The words are untouched: the note is drawn beside them, not folded in. *)
    check string "the message still says what it said" "here it is"
      r.History.text
  | rows -> failf "expected one row, got %d" (List.length rows)
;;

(* A row with no file gains nothing. A marker on every row stops being read. *)
let test_a_row_without_a_file_says_nothing () =
  match
    (decode (`List [ addressed ~speaker_name:"vincent" "just words" ]))
      .History.rows
  with
  | [ r ] ->
    check int "no notes" 0 (List.length r.History.attachments)
  | rows -> failf "expected one row, got %d" (List.length rows)
;;

(* A row copied verbatim from a live keeper transcript
   (~/.masc/keeper_chat/analyst.jsonl, 2026-08-25). The pane could not be made
   to scroll back this far by hand, so the row itself is the check: whatever
   the runtime writes has to survive this decoder. *)
let live_attachment_row =
  {json|[{
    "id": "msg-1787650428127921-11",
    "role": "user",
    "content": "첨부한 이미지에 무엇이 보이나요?",
    "ts": 1787650428.127921,
    "attachments": [
      { "id": "probe-1"
      , "type": "image"
      , "name": "vision_probe.png"
      , "size": 2129
      , "mime_type": "image/png"
      , "data": "masc://attachment/probe-1/b40a4fdf6d377a7f23c18089f04b66dfaf8ebed1036aa4faa539ae9d47e6639b"
      }
    ],
    "surface": { "kind": "dashboard" },
    "speaker_authority": "owner",
    "delivery_key": { "kind": "operation", "operation_id": "vision-probe-7431" },
    "transcript_slot": { "kind": "accepted_user" }
  }]|json}

let test_live_row_keeps_its_file () =
  match History.rows_of_json (Yojson.Safe.from_string live_attachment_row) with
  | Error msg -> Alcotest.failf "live row did not decode: %s" msg
  | Ok decoded ->
    Alcotest.(check int) "nothing dropped" 0 decoded.History.dropped;
    (match decoded.History.rows with
     | [ row ] ->
       (match row.History.attachments with
        | [ att ] ->
          Alcotest.(check string) "name" "vision_probe.png" att.History.att_name;
          Alcotest.(check string) "mime" "image/png" att.History.att_mime;
          Alcotest.(check int) "bytes" 2129 att.History.att_bytes
        | other ->
          Alcotest.failf "expected one attachment, got %d" (List.length other))
     | other -> Alcotest.failf "expected one row, got %d" (List.length other))

(* A file posted with no caption arrives with the text empty. Joining on it
   anyway put a blank line above the file, so the reader saw a gap where a
   sentence would be (task-552). *)
let bytes_only n = Printf.sprintf "%dB" n

let test_a_captionless_file_has_no_blank_line_above_it () =
  let notes =
    [ { History.att_name = "shot.png"; att_mime = "image/png"; att_bytes = 12
    ; att_width = None; att_height = None } ]
  in
  let body =
    History.text_with_attachments ~format_bytes:bytes_only ~text:"" ~notes
  in
  Alcotest.(check bool) "no leading newline" false (String.length body > 0 && body.[0] = '\n');
  Alcotest.(check bool) "names the file" true
    (String.length body > 0 && body <> "");
  match String.split_on_char '\n' body with
  | [ only ] -> Alcotest.(check bool) "one line" true (only <> "")
  | other ->
    Alcotest.failf "expected one line, got %d" (List.length other)
;;

(* Whitespace is not a caption either. *)
let test_a_blank_caption_is_treated_as_none () =
  let notes =
    [ { History.att_name = "shot.png"; att_mime = ""; att_bytes = 0
    ; att_width = None; att_height = None } ]
  in
  let body =
    History.text_with_attachments ~format_bytes:bytes_only ~text:"   \n  " ~notes
  in
  Alcotest.(check int) "one line" 1
    (List.length (String.split_on_char '\n' body))
;;

let test_a_caption_stays_above_its_files () =
  let notes =
    [ { History.att_name = "a.png"; att_mime = ""; att_bytes = 0
    ; att_width = None; att_height = None }
    ; { History.att_name = "b.png"; att_mime = ""; att_bytes = 0
    ; att_width = None; att_height = None }
    ]
  in
  let body =
    History.text_with_attachments ~format_bytes:bytes_only ~text:"look" ~notes
  in
  match String.split_on_char '\n' body with
  | [ first; second; third ] ->
    Alcotest.(check string) "caption first" "look" first;
    Alcotest.(check bool) "then a" true (second <> "");
    Alcotest.(check bool) "then b" true (third <> "")
  | other -> Alcotest.failf "expected three lines, got %d" (List.length other)
;;

let test_a_row_with_no_files_is_untouched () =
  Alcotest.(check string) "unchanged" "just words"
    (History.text_with_attachments ~format_bytes:bytes_only ~text:"just words"
       ~notes:[])
;;

(* An image that was measured reads as its pixels, in the order it arrived:
   the bytes answered "how big is the file" and the reader was asking "how
   big is it". A file that was not measured keeps the mime it always had,
   and the number is what a reply can name to mean one file. *)
let test_a_measured_image_names_its_pixels_and_index () =
  let notes =
    [ { History.att_name = "shot.png"; att_mime = "image/png"
      ; att_bytes = 2129
      ; att_width = Some 3456; att_height = Some 2168 }
    ; { History.att_name = "notes.md"; att_mime = "text/markdown"
      ; att_bytes = 40
      ; att_width = None; att_height = None }
    ]
  in
  let body =
    History.text_with_attachments ~format_bytes:bytes_only ~text:"look"
       ~notes
  in
  match String.split_on_char '\n' body with
  | [ caption; first; second ] ->
    Alcotest.(check string) "caption first" "look" caption;
    Alcotest.(check string) "measured image" "\xe2\x8e\x98 #1 shot.png \xc2\xb7 2129B \xc2\xb7 3456\xc3\x972168" first;
    Alcotest.(check string) "unmeasured file keeps its mime"
      "\xe2\x8e\x98 #2 notes.md \xc2\xb7 40B \xc2\xb7 text/markdown" second
  | other ->
    Alcotest.failf "expected three lines, got %d" (List.length other)
;;

(* The store writes width/height beside the payload; the decoder has to read
   them back or every measured row would render as unmeasured. *)
let sized_attachment_row =
  {json|[{
    "id": "msg-1",
    "role": "user",
    "content": "what is in this",
    "ts": 1787650428.0,
    "attachments": [
      { "id": "att-1"
      , "type": "image"
      , "name": "shot.png"
      , "size": 2129
      , "mime_type": "image/png"
      , "data": "masc://attachment/att-1/abc"
      , "width": 3456
      , "height": 2168
      }
    ]
  }]|json}

let test_a_sized_row_decodes_its_pixels () =
  match History.rows_of_json (Yojson.Safe.from_string sized_attachment_row) with
  | Error msg -> Alcotest.failf "sized row did not decode: %s" msg
  | Ok decoded ->
    (match decoded.History.rows with
     | [ row ] ->
       (match row.History.attachments with
        | [ att ] ->
          Alcotest.(check (option int)) "width" (Some 3456) att.History.att_width;
          Alcotest.(check (option int)) "height" (Some 2168) att.History.att_height
        | other ->
          Alcotest.failf "expected one attachment, got %d" (List.length other))
     | other -> Alcotest.failf "expected one row, got %d" (List.length other))
;;

let () =
  run "tui_keeper_chat_history"
    [ ( "rows"
      , [ test_case "roles map to what the pane draws" `Quick
            test_roles_map_to_what_the_pane_draws
        ; test_case "a gate row carries its approval" `Quick
            test_a_gate_row_carries_its_approval
        ; test_case "a gate row carries its call summary" `Quick
            test_a_gate_row_carries_its_call_summary
        ; test_case "a lifecycle without an approval id is not a gate row"
            `Quick test_a_lifecycle_without_an_approval_id_is_not_a_gate_row
        ; test_case "a failed turn names the request it came from" `Quick
            test_a_failed_turn_names_the_request_it_came_from
        ; test_case "runtime interruption becomes a recovered lifecycle" `Quick
            test_runtime_interruption_becomes_a_recovered_lifecycle
        ; test_case "stdout close stays pending without a later reply" `Quick
            test_stdout_close_stays_pending_without_a_later_reply
        ; test_case "unfenced runtime shutdown stays typed" `Quick
            test_unfenced_runtime_shutdown_is_still_typed
        ; test_case "unrelated failure is not marked recovered" `Quick
            test_unrelated_failure_is_not_marked_recovered
        ; test_case "rows carry the operation id only for direct turns" `Quick
            test_rows_carry_the_operation_id_only_for_direct_turns
        ; test_case "rows retain the exact turn identity" `Quick
            test_rows_retain_the_exact_turn_identity
        ; test_case "different turns do not merge their tool blocks" `Quick
            test_consecutive_tools_from_different_turns_do_not_merge
        ; test_case "autonomous trace rows retain turn_ref" `Quick
            test_autonomous_trace_rows_keep_the_turn_ref
        ; test_case "an addressed row says who sent it" `Quick
            test_an_addressed_row_says_who_sent_it_not_only_what_to_draw
        ; test_case "an addressed row is labelled by who sent it" `Quick
            test_an_addressed_row_is_labelled_by_who_sent_it
        ; test_case "consecutive tool rows become one block" `Quick
            test_consecutive_tool_rows_become_one_block
        ; test_case "history keeps producer tool-call identity" `Quick
            test_history_keeps_producer_tool_call_identity
        ; test_case "speech splits tool blocks" `Quick
            test_tool_blocks_separated_by_speech_stay_separate
        ; test_case "the server's order is kept" `Quick test_server_order_is_kept
        ; test_case "an autonomous turn draws what it did" `Quick
            test_an_autonomous_turn_draws_what_it_did
        ; test_case "exact Skill evidence replaces the raw call" `Quick
            test_exact_skill_evidence_replaces_the_raw_call_and_names_actions
        ; test_case "served Skill does not claim delivery" `Quick
            test_served_skill_without_delivery_does_not_claim_use
        ; test_case "missing Skill evidence remains visible" `Quick
            test_missing_skill_evidence_stays_visible_beside_the_raw_call
        ; test_case "Skill evidence count mismatch keeps raw calls" `Quick
            test_skill_evidence_count_mismatch_retains_every_raw_call
        ; test_case "blank autonomous turn keeps its origin" `Quick
            test_a_blank_autonomous_turn_has_an_explicit_origin
        ; test_case "projection keeps stable row and absolute turn identity"
            `Quick
            test_persisted_identity_and_absolute_turn_survive_projection
        ; test_case "a turn that also spoke keeps the order it ran in" `Quick
            test_a_turn_that_also_spoke_keeps_the_order_it_ran_in
        ; test_case "steps the server dropped are counted" `Quick
            test_steps_the_server_dropped_are_counted
        ; test_case "a blank turn with no trace keeps its line" `Quick
            test_a_blank_turn_with_no_trace_keeps_its_line
        ; test_case "a direct turn's trace is not drawn twice" `Quick
            test_a_direct_turn_s_trace_is_not_drawn_twice
        ; test_case "a null content is the wire's blank" `Quick
            test_a_null_content_is_the_wire_s_blank
        ] )
    ; ( "paging"
      , [ test_case "a page decodes its rows and cursor" `Quick
            test_a_page_decodes_its_rows_and_cursor
        ; test_case "the top of the conversation says so" `Quick
            test_the_top_of_the_conversation_says_so
        ; test_case "a missing has_more reads as no more" `Quick
            test_a_missing_has_more_reads_as_no_more
        ; test_case "tool rows fold in a page too" `Quick
            test_tool_rows_fold_in_a_page_as_they_do_in_the_transcript
        ; test_case "a non-object page is an error" `Quick
            test_a_page_that_is_not_an_object_is_an_error
        ; test_case "a page without messages is an error" `Quick
            test_a_page_without_messages_is_an_error
        ] )
    ; ( "tolerance"
      , [ test_case "one unreadable row does not cost the transcript" `Quick
            test_one_unreadable_row_does_not_cost_the_transcript
        ; test_case "a non-array payload is an error" `Quick
            test_a_non_array_payload_is_an_error
        ; test_case "a caption-less file has no blank line above it" `Quick
            test_a_captionless_file_has_no_blank_line_above_it
        ; test_case "a blank caption is treated as none" `Quick
            test_a_blank_caption_is_treated_as_none
        ; test_case "a caption stays above its files" `Quick
            test_a_caption_stays_above_its_files
        ; test_case "a row with no files is untouched" `Quick
            test_a_row_with_no_files_is_untouched
        ; test_case "a measured image names its pixels and index" `Quick
            test_a_measured_image_names_its_pixels_and_index
        ; test_case "a sized row decodes its pixels" `Quick
            test_a_sized_row_decodes_its_pixels
        ; test_case "a live row keeps its file" `Quick
            test_live_row_keeps_its_file
        ; test_case "a row names the file it carries" `Quick
            test_a_row_names_the_file_it_carries
        ; test_case "a row without a file says nothing" `Quick
            test_a_row_without_a_file_says_nothing
        ; test_case "a missing ts reads as zero" `Quick
            test_a_missing_ts_reads_as_zero_not_a_failure
        ] )
    ; ( "memory journal"
      , [ test_case "commit names added removed and drop reason" `Quick
            test_memory_commit_names_added_removed_and_drop_reason
        ; test_case "failure keeps kind and detail" `Quick
            test_memory_failure_keeps_kind_and_detail
        ; test_case "producer prepend keeps structural identities" `Quick
            test_memory_identity_survives_a_producer_prepend
        ; test_case "failed identity includes trace id" `Quick
            test_failed_memory_identity_includes_trace_id
        ; test_case "unreadable row keeps server identity" `Quick
            test_unreadable_memory_identity_is_server_supplied
        ] )
    ]
