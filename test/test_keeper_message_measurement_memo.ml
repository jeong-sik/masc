(** Tests for {!Keeper_message_measurement_memo}
    (RFC finished-turn-result-plans-are-computed-once §8).

    Each walk asks with a freshly built message and freshly copied strings,
    as a run that decoded its checkpoint again does, so a hit can only come
    from equality of value. *)

module Memo = Masc.Keeper_message_measurement_memo
module Types = Agent_core.Types

let fresh text = Bytes.to_string (Bytes.of_string text)

(* Above the 2,048-byte floor of the demotion plan, as the finished results
   that every walk measures. *)
let large_body = String.make 4_096 'x'

let tool_message ~id body : Types.message =
  { origin = Llm_provider.Types.Conversation;  role = Types.Tool
  ; content =
      [ Types.ToolResult
          { tool_use_id = fresh id
          ; content = fresh body
          ; outcome = Types.Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  ; name = None
  ; tool_call_id = Some (fresh id)
  ; metadata = []
  }
;;

let history_bytes message = Masc.Keeper_context_core.message_measurer () message

(* The production history encoder, counting the messages it really encodes
   across every walk's measurer. *)
let counting_encoder ~max_retained_bytes =
  let encoded = ref 0 in
  let make () =
    let measure = Masc.Keeper_context_core.message_measurer () in
    fun message ->
      incr encoded;
      measure message
  in
  Memo.encoder ~max_retained_bytes make, encoded
;;

let walk ~keeper_name encoder message = Memo.measurer ~keeper_name encoder message

let a_later_walk_answers_without_encoding () =
  let encoder, encoded =
    counting_encoder ~max_retained_bytes:Memo.per_keeper_retained_bytes
  in
  let keeper_name = "memo-later-walk" in
  let expected = history_bytes (tool_message ~id:"a" large_body) in
  let first = walk ~keeper_name encoder (tool_message ~id:"a" large_body) in
  let second = walk ~keeper_name encoder (tool_message ~id:"a" large_body) in
  let third = walk ~keeper_name encoder (tool_message ~id:"a" large_body) in
  Alcotest.(check int) "first walk" expected first;
  Alcotest.(check int) "second walk" expected second;
  Alcotest.(check int) "third walk" expected third;
  Alcotest.(check int) "encoded once" 1 !encoded
;;

let a_different_message_is_measured () =
  let encoder, encoded =
    counting_encoder ~max_retained_bytes:Memo.per_keeper_retained_bytes
  in
  let keeper_name = "memo-different-message" in
  let longer_body = large_body ^ "y" in
  let first = walk ~keeper_name encoder (tool_message ~id:"b" large_body) in
  let longer = walk ~keeper_name encoder (tool_message ~id:"b" longer_body) in
  Alcotest.(check int) "its own size" (history_bytes (tool_message ~id:"b" longer_body)) longer;
  Alcotest.(check bool) "not the first answer" true (longer <> first);
  Alcotest.(check int) "both encoded" 2 !encoded
;;

let keepers_and_encoders_keep_their_own_tables () =
  let encoder, encoded =
    counting_encoder ~max_retained_bytes:Memo.per_keeper_retained_bytes
  in
  let other_encoder, other_encoded =
    counting_encoder ~max_retained_bytes:Memo.per_keeper_retained_bytes
  in
  let ask ~keeper_name encoder =
    ignore (walk ~keeper_name encoder (tool_message ~id:"c" large_body) : int)
  in
  ask ~keeper_name:"memo-own-table-a" encoder;
  ask ~keeper_name:"memo-own-table-b" encoder;
  ask ~keeper_name:"memo-own-table-a" other_encoder;
  ask ~keeper_name:"memo-own-table-a" encoder;
  Alcotest.(check int) "a Keeper does not answer for another" 2 !encoded;
  Alcotest.(check int) "an encoder does not answer for another" 1 !other_encoded
;;

let a_message_past_the_bound_is_measured_every_walk () =
  let message () = tool_message ~id:"d" large_body in
  let bytes = history_bytes (message ()) in
  let encoder, encoded = counting_encoder ~max_retained_bytes:(bytes - 1) in
  let keeper_name = "memo-past-the-bound" in
  let first = walk ~keeper_name encoder (message ()) in
  let second = walk ~keeper_name encoder (message ()) in
  Alcotest.(check int) "first answer" bytes first;
  Alcotest.(check int) "second answer" bytes second;
  Alcotest.(check int) "not kept" 2 !encoded
;;

(* The bound holds one of these messages. An entry the walk before asked for
   is kept and the newcomer is not; once two walks have passed it by, it makes
   room. *)
let an_entry_two_walks_skipped_makes_room () =
  let first_message () = tool_message ~id:"e1" large_body in
  let second_message () = tool_message ~id:"e2" large_body in
  let bytes = history_bytes (first_message ()) in
  Alcotest.(check int) "same size" bytes (history_bytes (second_message ()));
  let encoder, encoded = counting_encoder ~max_retained_bytes:bytes in
  let ask message = ignore (walk ~keeper_name:"memo-room" encoder message : int) in
  ask (first_message ());
  ask (second_message ());
  Alcotest.(check int) "the walk before still holds the table" 2 !encoded;
  ask (second_message ());
  Alcotest.(check int) "measured again, and now kept" 3 !encoded;
  ask (second_message ());
  Alcotest.(check int) "answered from the table" 3 !encoded;
  ask (first_message ());
  Alcotest.(check int) "the dropped entry is measured again" 4 !encoded
;;

(* One walk past the bound: the first message fills the table, and every
   later one is measured, answered, and not kept. *)
let one_walk_past_the_bound_answers_every_message () =
  let message index = tool_message ~id:(Printf.sprintf "f%d" index) large_body in
  let indices = [ 0; 1; 2; 3 ] in
  let encoder, encoded = counting_encoder ~max_retained_bytes:(history_bytes (message 0)) in
  let keeper_name = "memo-one-walk" in
  let measure = Memo.measurer ~keeper_name encoder in
  let answers = List.map (fun index -> measure (message index)) indices in
  Alcotest.(check (list int))
    "every size"
    (List.map (fun index -> history_bytes (message index)) indices)
    answers;
  Alcotest.(check int) "each encoded" (List.length indices) !encoded;
  ignore (walk ~keeper_name encoder (message 0) : int);
  Alcotest.(check int) "the first one was kept" (List.length indices) !encoded
;;

let () =
  Alcotest.run "keeper_message_measurement_memo"
    [ ( "walks"
      , [ Alcotest.test_case "a later walk answers without encoding" `Quick
            a_later_walk_answers_without_encoding
        ; Alcotest.test_case "a different message is measured" `Quick
            a_different_message_is_measured
        ; Alcotest.test_case "Keepers and encoders keep their own tables" `Quick
            keepers_and_encoders_keep_their_own_tables
        ] )
    ; ( "bound"
      , [ Alcotest.test_case "a message past the bound is measured every walk" `Quick
            a_message_past_the_bound_is_measured_every_walk
        ; Alcotest.test_case "an entry two walks skipped makes room" `Quick
            an_entry_two_walks_skipped_makes_room
        ; Alcotest.test_case "one walk past the bound answers every message" `Quick
            one_walk_past_the_bound_answers_every_message
        ] )
    ]
;;
