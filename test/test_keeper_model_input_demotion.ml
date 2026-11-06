(** Tests for {!Keeper_model_input_demotion} (RFC-0363).

    The load-bearing property is soundness of the size bound: {!Demotion.plan}
    substitutes a placeholder, the window chooses a cut against that
    measurement, and only then are the real markers written. If the
    placeholder ever measures smaller than the marker that replaces it, a
    request that fit the plan exceeds the cap after materialization. Every
    other case here is an input shape that was found — during the RFC's
    adversarial review — to break that direction. *)

module Demotion = Masc.Keeper_model_input_demotion
module Types = Agent_core.Types
module Window = Runtime_model_input_tail_window

(* The production encoder, not a test-local one: the bound is only meaningful
   against the encoder the window will use, and a simplified stand-in would
   hide exactly the JSON escaping that makes a marker larger than it looks. *)
(* History in these fixtures holds media by reference; every agent, runtime
   config and projector here reads the bytes back from this store. *)
let test_media_store = Agent_core.History.Memory_store.create ()

let stored_source ~media_type raw =
  match test_media_store.put ~media_type ~raw with
  | Ok stored -> Agent_core.Types.Stored stored
  | Error error -> failwith (Agent_core.Error.to_string (Agent_core.Error.Media error))

let measure_message_bytes (m : Types.message) =
  String.length
    (Yojson.Safe.to_string (Masc.Keeper_context_core.message_to_json m))
;;

(* The stored JSON as a lane's own measure: one JSON escape over every body
   the result holds. Tests that name no provider plan against it. *)
let stored_wire_bytes (m : Types.message) = Some (measure_message_bytes m)

let tool_message ?(content_blocks = None) ~id body : Types.message =
  { origin = Llm_provider.Types.Conversation;  role = Types.Tool
  ; content =
      [ Types.ToolResult
          { tool_use_id = id
          ; content = body
          ; outcome = Types.Tool_succeeded
          ; json = None
          ; content_blocks
          }
      ]
  ; name = None
  ; tool_call_id = Some id
  ; metadata = []
  }
;;

let assistant text : Types.message =
  { origin = Llm_provider.Types.Conversation;  role = Types.Assistant
  ; content = [ Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let history_with_tool_bodies bodies =
  List.concat
    (List.mapi
       (fun i body ->
          [ assistant (Printf.sprintf "call %d" i)
          ; tool_message ~id:(Printf.sprintf "call-%d" i) body
          ])
       bodies)
;;

let content_of (m : Types.message) =
  List.filter_map
    (fun (block : Types.content_block) ->
       match block with
       | Types.ToolResult { content; _ } -> Some content
       | _ -> None)
    m.content
;;

let markers messages = List.concat_map content_of messages

(* --- Turn boundary: the keeper keeps what it is working on --------------- *)

(* The assembly demotes results from earlier turns and leaves this turn's
   alone. Stated against the seeded history rather than a count of recent
   results: a keeper that read a file this turn has to still see what it read,
   and a keeper that read one three turns ago has an address for it. *)
let this_turns_results_survive_the_boundary () =
  let body i = String.make 4_000 (Char.chr (Char.code 'a' + i)) in
  let earlier = history_with_tool_bodies [ body 0; body 1 ] in
  let this_turn = history_with_tool_bodies [ body 2 ] in
  let messages = earlier @ this_turn in
  let demote_before =
    Window.first_atom_at_or_after
      messages
      ~message_index:(List.length earlier)
  in
  let planned =
    Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before messages
  in
  let transmitted = markers planned.Demotion.messages in
  Alcotest.(check int)
    "every result is still present"
    3
    (List.length transmitted);
  Alcotest.(check bool)
    "this turn's result is verbatim"
    true
    (List.exists (fun body -> String.equal body (String.make 4_000 'c')) transmitted);
  Alcotest.(check int)
    "and both earlier ones became addresses"
    2
    (List.length planned.Demotion.pending)
;;

(* A turn that has produced nothing yet must not demote its own seed out from
   under itself before it has read anything. *)
let a_turn_that_produced_nothing_demotes_everything_before_it () =
  let messages = history_with_tool_bodies [ String.make 4_000 'a' ] in
  let demote_before =
    Window.first_atom_at_or_after
      messages
      ~message_index:(List.length messages)
  in
  let planned =
    Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before messages
  in
  Alcotest.(check int)
    "the seeded history is all earlier work"
    1
    (List.length planned.Demotion.pending)
;;

(* [earlier] ends
   with an Assistant that issued a call whose Tool answer has not been
   recorded yet — the checkpoint captured a dangling tool cycle at the turn
   boundary, exactly the shape [Keeper_transcript_unit]'s [protected_suffix]
   exists to handle elsewhere. On request 1 (before the answer exists)
   [first_atom_at_or_after] returns one value; once the answer lands on
   request 2, it returns a different one. Confirm the drift is real, then
   confirm it is inert: the disputed atom has no [ToolResult] content on the
   request where the value differs, so [plan] demotes the same set either
   way, and the completed atom is never split once it exists. *)
let a_split_atom_at_the_boundary_never_gets_demoted_half () =
  let earlier =
    history_with_tool_bodies [ String.make 4_000 'e' ] @ [ assistant "dangling call" ]
  in
  let dangling_result = tool_message ~id:"dangling" (String.make 4_000 'd') in
  let boundary = List.length earlier in
  let messages_request_1 = earlier in
  let messages_request_2 = earlier @ [ dangling_result ] in
  let demote_before_1 =
    Window.first_atom_at_or_after messages_request_1 ~message_index:boundary
  in
  let demote_before_2 =
    Window.first_atom_at_or_after messages_request_2 ~message_index:boundary
  in
  Alcotest.(check bool)
    "the boundary value does drift across the dangling call"
    true
    (demote_before_1 <> demote_before_2);
  let planned_1 =
    Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:demote_before_1 messages_request_1
  in
  let planned_2 =
    Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:demote_before_2 messages_request_2
  in
  Alcotest.(check int)
    "request 1 has nothing demotable at the disputed atom yet"
    1
    (List.length planned_1.Demotion.pending);
  Alcotest.(check int)
    "request 2 demotes the same count once the answer exists"
    1
    (List.length planned_2.Demotion.pending);
  Alcotest.(check bool)
    "the completed dangling call survives verbatim, not split"
    true
    (List.exists
       (String.equal (String.make 4_000 'd'))
       (markers planned_2.Demotion.messages))
;;

(* --- 1. Bound soundness (RFC-0363 §6 test 2) -------------------------- *)

(* The placeholder must bound the real marker for every byte range, because
   [encode_for_agent_core] renders the preview with [%S] — bytes outside 0x20-0x7E
   expand fourfold — and the JSON encoder then escapes those escapes. A Korean
   body and a body of raw high bytes are the cases that broke the RFC's first
   draft, where the bound was stated as a flat 200-300 bytes. *)
let short_aged_result_uses_exact_preview () =
  let messages = history_with_tool_bodies [String.make 700 'a'] in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int) "short result selects a smaller planned reference" 1
    (List.length planned.Demotion.pending);
  Alcotest.(check bool) "reference shrinks provider-bound message" true
    (List.fold_left (fun sum m -> sum + measure_message_bytes m) 0 planned.messages
     < List.fold_left (fun sum m -> sum + measure_message_bytes m) 0 messages)
;;

let bound_holds_for body_label body =
  let store = Tool_blob_store.create ~base_path:(Filename.temp_dir "demote" "") in
  let messages = history_with_tool_bodies [ body ] in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  match planned.Demotion.pending with
  | [] ->
    (* Not demoted: the only admissible reason is that the placeholder did not
       shrink the message, which is itself the bound holding. *)
    ()
  | pending ->
    let planned_bytes =
      List.fold_left
        (fun acc m -> acc + measure_message_bytes m)
        0
        planned.Demotion.messages
    in
    let outcome =
      Demotion.materialize
        ~store
        ~addresses:(Demotion.create_address_memo ())
        ~pending
        planned.Demotion.messages
    in
    Alcotest.(check int)
      (body_label ^ ": no revert in a healthy store")
      0
      outcome.Demotion.reverted;
    let real_bytes =
      List.fold_left
        (fun acc m -> acc + measure_message_bytes m)
        0
        outcome.Demotion.messages
    in
    Alcotest.(check bool)
      (Printf.sprintf
         "%s: materialized (%d) must not exceed the planned bound (%d)"
         body_label
         real_bytes
         planned_bytes)
      true
      (real_bytes <= planned_bytes)
;;

(* Guard against a vacuous suite. Every assertion below is of the form "the
   demoted form is no larger" or "this shape is not demoted", and all of them
   hold trivially if [plan] never demotes anything. One case must therefore
   assert the positive direction: a 4,000-byte ASCII body is far larger than
   any marker, so it must be demoted, and the demotion must actually shrink
   the transmitted bytes. *)
let demotion_actually_happens () =
  let body = String.make 4000 'a' in
  let messages = history_with_tool_bodies [ body ] in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int)
    "a 4KB ASCII tool body is demoted"
    1
    (List.length planned.Demotion.pending);
  let before =
    List.fold_left (fun acc m -> acc + measure_message_bytes m) 0 messages
  in
  let after =
    List.fold_left
      (fun acc m -> acc + measure_message_bytes m)
      0
      planned.Demotion.messages
  in
  Alcotest.(check bool)
    (Printf.sprintf "and it shrinks the transmitted view (%d -> %d)" before after)
    true
    (after < before);
  Alcotest.(check bool)
    "the body is gone from the transmitted view"
    false
    (List.exists (fun c -> String.equal c body) (markers planned.Demotion.messages))
;;

let bound_is_sound () =
  bound_holds_for "ascii" (String.make 4000 'a');
  bound_holds_for "korean" (String.concat "" (List.init 500 (fun _ -> "한국어 실측 ")));
  bound_holds_for
    "all-byte-values"
    (String.init 4000 (fun i -> Char.chr (i mod 256)));
  bound_holds_for "newlines" (String.concat "\n" (List.init 800 (fun i -> string_of_int i)))
;;

(* --- 3. Invalid markers are excluded (§6 test 4) ----------------------- *)

(* A marker-shaped payload that fails to parse must not be stored: giving a
   corrupt body a permanent content address hides the corruption instead of
   leaving it visible. *)
let invalid_markers_are_not_demoted () =
  let corrupt = Tool_output.marker_prefix ^ " sha256=not-a-digest bytes=x]" in
  Alcotest.(check bool)
    "fixture really is marker-shaped"
    true
    (Tool_output.is_marker corrupt);
  (match Tool_output.decode_from_agent_core corrupt with
   | Tool_output.Invalid_marker _ -> ()
   | Tool_output.Not_marker | Tool_output.Decoded _ ->
     Alcotest.fail "fixture must decode as Invalid_marker");
  let messages = history_with_tool_bodies [ corrupt ] in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int)
    "corrupt marker yields no pending demotion"
    0
    (List.length planned.Demotion.pending)
;;

(* --- 4. Already-demoted results are not re-stored ---------------------- *)

let stored_results_are_not_demoted_again () =
  let store = Tool_blob_store.create ~base_path:(Filename.temp_dir "demote" "") in
  let marker =
    Tool_output.encode_for_agent_core
      (Tool_blob_store.put store ~bytes:(String.make 4000 'a') ~mime:"text/plain")
  in
  let messages = history_with_tool_bodies [ marker ] in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int)
    "an existing marker is not demoted again"
    0
    (List.length planned.Demotion.pending)
;;

(* [materialize] binds each retained placeholder to its original occurrence.
   A lookup that answered with another entry would still
   write a well-formed marker, pointing at another result's bytes, so each
   stored blob is read back and compared with the body its message held. *)
let each_marker_stores_its_own_body () =
  let store = Tool_blob_store.create ~base_path:(Filename.temp_dir "demote" "") in
  let bodies = List.init 40 (fun i -> Printf.sprintf "result %d:" i ^ String.make 4000 'a') in
  let messages = history_with_tool_bodies bodies in
  let planned =
    Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:(List.length bodies) messages
  in
  Alcotest.(check int)
    "every aged body is planned"
    (List.length bodies)
    (List.length planned.Demotion.pending);
  let outcome =
    Demotion.materialize
      ~store
      ~addresses:(Demotion.create_address_memo ())
      ~pending:planned.Demotion.pending
      planned.Demotion.messages
  in
  Alcotest.(check int) "no revert in a healthy store" 0 outcome.Demotion.reverted;
  let stored =
    List.map
      (fun content ->
         match Tool_output.decode_from_agent_core content with
         | Tool_output.Decoded reference ->
           (match Tool_blob_store.fetch store ~sha256:reference.Tool_output.sha256 with
            | Ok (Some bytes) -> bytes
            | Ok None -> Alcotest.fail "a marker names a blob the store does not hold"
            | Error error ->
              Alcotest.fail (Tool_blob_store.fetch_error_to_string error))
         | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
           Alcotest.fail "every planned body leaves as a marker")
      (markers outcome.Demotion.messages)
  in
  Alcotest.(check (list string)) "each marker stores its own body" bodies stored
;;

(* A tool ID is local to a closed cycle, not a history-wide content key. *)
let closed_cycle ~id body =
  [ { (assistant "") with
      content = [Types.ToolUse {id; name = "echo"; input = `Assoc []}] }
  ; tool_message ~id body
  ]
;;

let fetch_body store marker =
  match Tool_output.decode_from_agent_core marker with
  | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
    Alcotest.fail "expected a stored result reference"
  | Tool_output.Decoded reference ->
    (match Tool_blob_store.fetch store ~sha256:reference.Tool_output.sha256 with
     | Ok (Some bytes) -> bytes
     | Ok None -> Alcotest.fail "reference has no stored body"
     | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error))
;;

let with_demotion_store f =
  let base_path = Filename.temp_dir "demote-occurrences" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () -> f (Tool_blob_store.create ~base_path))
;;

(* --- 2. content_blocks = Some: each text body leaves (RFC-0363 §3.1.2) --- *)

(* An MCP result as Keepers store it: [content] is the plain copy of its
   text, and the blocks hold the text and a screenshot. *)
let screenshot () =
  Types.Image
    { media_type = "image/png"; source = stored_source ~media_type:"image/png" "aW1hZ2U=" }
;;

let structured_result ~id ~content blocks =
  tool_message ~content_blocks:(Some blocks) ~id content
;;

(* The [content] and blocks of a message holding one structured result. *)
let result_parts (message : Types.message) =
  match message.content with
  | [ Types.ToolResult { content; content_blocks = Some blocks; _ } ] -> content, blocks
  | _ -> Alcotest.fail "expected one result with content_blocks = Some"
;;

let inner_text (block : Types.content_block) =
  match block with
  | Types.Text text -> text
  | Types.Thinking _ | Types.ReasoningDetails _ | Types.RedactedThinking _
  | Types.ToolUse _ | Types.ToolResult _ | Types.Image _ | Types.Document _
  | Types.Audio _ -> Alcotest.fail "expected a Text block"
;;

(* Every text body a message's results hold: each [content], then the [Text]
   blocks of a structured result. *)
let result_texts (message : Types.message) =
  List.concat_map
    (fun (block : Types.content_block) ->
       match block with
       | Types.ToolResult { content; content_blocks = None; _ } -> [ content ]
       | Types.ToolResult { content; content_blocks = Some blocks; _ } ->
         content
         :: List.filter_map
              (fun (inner : Types.content_block) ->
                 match inner with
                 | Types.Text text -> Some text
                 | Types.Thinking _ | Types.ReasoningDetails _ | Types.RedactedThinking _
                 | Types.ToolUse _ | Types.ToolResult _ | Types.Image _ | Types.Document _
                 | Types.Audio _ -> None)
              blocks
       | Types.Text _ | Types.Thinking _ | Types.ReasoningDetails _
       | Types.RedactedThinking _ | Types.ToolUse _ | Types.Image _ | Types.Document _
       | Types.Audio _ -> [])
    message.content
;;

(* [content] and each [Text] block leave as markers; the image stays, the
   same block in the same place. *)
let structured_result_demotes_each_text_body () =
  let content = String.make 4_000 'q' in
  let image = screenshot () in
  let blocks =
    [ Types.Text (String.make 4_000 'r'); image; Types.Text (String.make 3_000 's') ]
  in
  let messages = [ assistant "call"; structured_result ~id:"c0" ~content blocks ] in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int) "content and both Text blocks are planned" 3
    (List.length planned.Demotion.pending);
  let planned_content, planned_blocks = result_parts (List.nth planned.Demotion.messages 1) in
  Alcotest.(check bool) "content leaves as a marker" true (Tool_output.is_marker planned_content);
  (match planned_blocks with
   | [ first; kept; second ] ->
     Alcotest.(check bool) "the first Text block leaves as a marker" true
       (Tool_output.is_marker (inner_text first));
     Alcotest.(check bool) "the image is the same block" true (kept == image);
     Alcotest.(check bool) "the second Text block leaves as a marker" true
       (Tool_output.is_marker (inner_text second))
   | _ -> Alcotest.fail "the result keeps its three blocks");
  Alcotest.(check bool) "the durable source is untouched" true
    (result_parts (List.nth messages 1) = (content, blocks))
;;

(* The whole result shrinks under the measurer, but Anthropic sends only the
   blocks: a short [Text] block that became a marker would grow there. *)
let a_text_block_shorter_than_its_marker_stays () =
  let long = String.make 9_000 'w' in
  let short = "pressed Enter" in
  let messages =
    [ assistant "call"
    ; structured_result ~id:"k0" ~content:(long ^ short) [ Types.Text long; Types.Text short ]
    ]
  in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int) "content and the long Text block are planned" 2
    (List.length planned.Demotion.pending);
  let planned_content, planned_blocks = result_parts (List.nth planned.Demotion.messages 1) in
  Alcotest.(check bool) "content leaves as a marker" true (Tool_output.is_marker planned_content);
  match planned_blocks with
  | [ first; second ] ->
    Alcotest.(check bool) "the long Text block leaves as a marker" true
      (Tool_output.is_marker (inner_text first));
    Alcotest.(check string) "the short Text block stays" short (inner_text second)
  | _ -> Alcotest.fail "the result keeps its two blocks"
;;

let structured_cycle ~id ~content blocks =
  [ { (assistant "") with
      content = [ Types.ToolUse { id; name = "screenshot"; input = `Assoc [] } ] }
  ; structured_result ~id ~content blocks
  ]
;;

let longest_run c text =
  let best = ref 0 in
  let run = ref 0 in
  String.iter
    (fun at ->
       if Char.equal at c
       then (
         incr run;
         best := max !best !run)
       else run := 0)
    text;
  !best
;;

(* The lanes a structured result can go out on, each with its own encoder:
   OpenAI chat, Responses, Anthropic, Gemini, Ollama and GLM. *)
let structured_lanes =
  let open Agent_core.Llm_provider in
  let lane name ?request_path kind build =
    let config = Provider_config.make ~kind ~model_id:"structured-result-fixture"
        ~base_url:"http://localhost" ?request_path ~max_tokens:4096 () in
    let encode messages =
      match Agent_core.History.to_wire_messages test_media_store messages with
      | Ok messages -> build ~config ~messages ()
      | Error error -> Alcotest.fail (Agent_core.Error.to_string (Agent_core.Error.Media error)) in
    name, Masc.Keeper_model_input_wire_bytes.measurer ~config, encode in
  [ lane "openai chat" Provider_config.OpenAI_compat
      (fun ~config ~messages () -> Backend_openai.build_request ~config ~messages ())
  ; lane "responses" ~request_path:"/v1/responses" Provider_config.OpenAI_compat
      (fun ~config ~messages () -> Backend_openai_responses.build_request ~config ~messages ())
  ; lane "anthropic" Provider_config.Anthropic
      (fun ~config ~messages () -> Backend_anthropic.build_request ~config ~messages ())
  ; lane "gemini" Provider_config.Gemini
      (fun ~config ~messages () -> Backend_gemini.build_request ~config ~messages ())
  ; lane "ollama" Provider_config.Ollama
      (fun ~config ~messages () -> Backend_ollama.build_request ~config ~messages ())
  ; lane "glm" Provider_config.Glm
      (fun ~config ~messages () -> Backend_glm.build_request ~config ~messages ())
  ]
;;

(* Each lane plans against its own encoder, and its request never grows: a
   body the lane sends leaves as a marker, and one it does not send, or one
   whose marker is longer once the lane has escaped both, stays. The
   fixtures cover a result with an image and one without, ASCII and
   quote-heavy bodies. *)
let structured_bodies_leave_every_provider_wire () = with_demotion_store @@ fun store ->
  let content = String.make 4_000 'q' in
  let wire fixture blocks =
    let messages = structured_cycle ~id:"shot" ~content blocks in
    List.iter
      (fun (lane, measure_wire_bytes, encode) ->
         let name = fixture ^ ", " ^ lane in
         let planned = Demotion.plan ~measure_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
         Alcotest.(check bool) (name ^ ": the lane chooses a body") true
           (planned.Demotion.pending <> []);
         let outcome = Demotion.materialize ~store ~addresses:(Demotion.create_address_memo ())
             ~pending:planned.Demotion.pending planned.Demotion.messages in
         Alcotest.(check int) (name ^ ": a healthy store reverts nothing") 0 outcome.Demotion.reverted;
         let source = encode messages in
         let sent = encode outcome.Demotion.messages in
         Alcotest.(check bool) (name ^ ": the source request carries a body") true
           (max (longest_run 'q' source) (longest_run 'r' source) >= String.length content);
         Alcotest.(check bool) (name ^ ": content does not reach the wire") true
           (longest_run 'q' sent < String.length content);
         Alcotest.(check bool) (name ^ ": the Text block does not reach the wire") true
           (longest_run 'r' sent < String.length content);
         Alcotest.(check bool) (name ^ ": the request does not grow") true
           (String.length sent < String.length source);
         Alcotest.(check bool) (name ^ ": materialized wire fits planned wire") true
           (String.length sent <= String.length (encode planned.Demotion.messages)))
      structured_lanes
  in
  wire "with an image" [ Types.Text (String.make 4_000 'r'); screenshot () ];
  wire "text only" [ Types.Text (String.make 4_000 'r') ];
  wire "quotes and backslashes" [ Types.Text (String.make 4_000 'r' ^ String.concat "" (List.init 500 (fun _ -> "\"\\\n"))) ]
;;

(* 433 Korean syllables, 1,299 bytes. [%S] writes the preview's 198 bytes as
   [\ddd], so the marker is 1,116 bytes under one JSON escape, shorter than
   the body's 1,301, and 1,514 under two, longer than the body's 1,299. The
   lanes that send the blocks as one JSON string keep the body; Anthropic,
   which escapes once, takes the marker; Gemini sends [content] only. *)
let a_short_korean_block_stays_on_lanes_that_escape_twice () = with_demotion_store @@ fun store ->
  let korean = String.concat "" (List.init 433 (fun _ -> "\234\176\128")) in
  Alcotest.(check int) "the body is 1,299 bytes" 1_299 (String.length korean);
  let messages = structured_cycle ~id:"ko" ~content:"" [ Types.Text korean ] in
  let chosen measure_wire_bytes =
    List.length
      (Demotion.plan ~measure_wire_bytes ~measure_message_bytes ~demote_before:1 messages).Demotion.pending
  in
  Alcotest.(check int) "one JSON escape takes the marker" 1 (chosen stored_wire_bytes);
  List.iter
    (fun (lane, measure_wire_bytes, encode) ->
       let expected =
         List.assoc lane
           [ "openai chat", 0; "responses", 0; "anthropic", 1; "gemini", 0; "ollama", 0; "glm", 0 ]
       in
       Alcotest.(check int) (lane ^ ": bodies chosen") expected (chosen measure_wire_bytes);
       let planned = Demotion.plan ~measure_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
       let outcome = Demotion.materialize ~store ~addresses:(Demotion.create_address_memo ())
           ~pending:planned.Demotion.pending planned.Demotion.messages in
       Alcotest.(check bool) (lane ^ ": the request does not grow") true
         (String.length (encode outcome.Demotion.messages) <= String.length (encode messages)))
    structured_lanes
;;

(* A stored reference is not stored again and a corrupt marker stays
   visible, inside the blocks as in [content]. Both are longer than a marker
   of their own, so only the marker check keeps them: the stored preview is
   Korean, which [%S] writes as four bytes per byte. *)
let structured_markers_are_left_as_they_are () = with_demotion_store @@ fun store ->
  let stored =
    Tool_output.encode_for_agent_core
      (Tool_blob_store.put store ~bytes:(String.concat "" (List.init 2_000 (fun _ -> "가")))
         ~mime:"text/plain")
  in
  let stored_block = Types.Text stored in
  let corrupt_block =
    Types.Text (Tool_output.marker_prefix ^ " sha256=not-a-digest bytes=x " ^ String.make 4_000 'x' ^ "]")
  in
  let messages =
    [ assistant "call"
    ; structured_result ~id:"c0" ~content:(String.make 4_000 'q')
        [ stored_block; corrupt_block; Types.Text (String.make 4_000 'r') ]
    ]
  in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int) "only the plain bodies are planned" 2 (List.length planned.Demotion.pending);
  match snd (result_parts (List.nth planned.Demotion.messages 1)) with
  | [ first; second; third ] ->
    Alcotest.(check bool) "the stored reference is the same block" true (first == stored_block);
    Alcotest.(check bool) "the corrupt marker is the same block" true (second == corrupt_block);
    Alcotest.(check bool) "the plain Text block leaves as a marker" true
      (Tool_output.is_marker (inner_text third))
  | _ -> Alcotest.fail "the result keeps its three blocks"
;;

(* Two lanes that send one body of a structured result each: Gemini sends
   [content] of a text-only result, Anthropic its [Text] blocks. Each counts
   that body alone, so a plan against it chooses that body alone. *)
let content_lane (message : Types.message) =
  Some (String.length (fst (result_parts message)))
;;

let blocks_lane (message : Types.message) =
  Some
    (List.fold_left
       (fun sum (inner : Types.content_block) ->
          match inner with
          | Types.Text text -> sum + String.length text
          | Types.Thinking _ | Types.ReasoningDetails _ | Types.RedactedThinking _
          | Types.ToolUse _ | Types.ToolResult _ | Types.Image _ | Types.Document _
          | Types.Audio _ -> sum)
       0
       (snd (result_parts message)))
;;

(* A body whose write fails keeps its original text, and the result's other
   body keeps the marker that was written. A first, healthy write of one body
   alone, planned against a lane that sends only that body, puts it in the
   store; the blocked store then skips that address and fails the other. *)
let one_failed_write ~written_lane ~failed_body () = with_demotion_store @@ fun store ->
  let content = String.make 5_000 'q' in
  let text = String.make 3_000 'r' in
  let image = screenshot () in
  let messages = [ assistant "call"; structured_result ~id:"c0" ~content [ Types.Text text; image ] ] in
  let addresses = Demotion.create_address_memo () in
  let one =
    Demotion.plan ~measure_wire_bytes:written_lane ~measure_message_bytes ~demote_before:1 messages
  in
  Alcotest.(check int) "the lane chooses one body" 1 (List.length one.Demotion.pending);
  let first = Demotion.materialize ~store ~addresses ~pending:one.Demotion.pending
      one.Demotion.messages in
  Alcotest.(check int) "that body is written" 0 first.Demotion.reverted;
  let both = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int) "both bodies are planned" 2 (List.length both.Demotion.pending);
  let blocked = Filename.temp_file "demote-structured-blocked" "" in
  Fun.protect ~finally:(fun () -> Sys.remove blocked) @@ fun () ->
  let outcome =
    Demotion.materialize ~store:(Tool_blob_store.create ~base_path:blocked) ~addresses
      ~pending:both.Demotion.pending both.Demotion.messages
  in
  Alcotest.(check int) "only the other body failed" 1 outcome.Demotion.reverted;
  let sent_content, sent_blocks = result_parts (List.nth outcome.Demotion.messages 1) in
  match sent_blocks, failed_body with
  | [ sent_text; kept ], `Text ->
    Alcotest.(check string) "content keeps the reference that was written" content
      (fetch_body store sent_content);
    Alcotest.(check string) "the failed Text block is its original" text (inner_text sent_text);
    Alcotest.(check bool) "the image is the same block" true (kept == image)
  | [ sent_text; kept ], `Content ->
    Alcotest.(check string) "the failed content is its original" content sent_content;
    Alcotest.(check string) "the Text block keeps the reference that was written" text
      (fetch_body store (inner_text sent_text));
    Alcotest.(check bool) "the image is the same block" true (kept == image)
  | ([] | [ _ ] | _ :: _ :: _ :: _), (`Text | `Content) ->
    Alcotest.fail "the result keeps its two blocks"
;;

let a_failed_text_write_keeps_the_written_content =
  one_failed_write ~written_lane:content_lane ~failed_body:`Text
;;

let a_failed_content_write_keeps_the_written_text =
  one_failed_write ~written_lane:blocks_lane ~failed_body:`Content
;;

(* Each body is stored as its own blob, and a second plan over the same
   source replays what the first wrote. *)
let structured_bodies_are_stored_and_replayed () = with_demotion_store @@ fun store ->
  let content = String.make 4_000 'q' in
  let first = String.make 4_000 'r' in
  let second = String.make 3_000 's' in
  let messages =
    [ assistant "call"
    ; structured_result ~id:"c0" ~content [ Types.Text first; screenshot (); Types.Text second ]
    ]
  in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  let outcome = Demotion.materialize ~store ~addresses:(Demotion.create_address_memo ())
      ~pending:planned.Demotion.pending planned.Demotion.messages in
  Alcotest.(check int) "a healthy store reverts nothing" 0 outcome.Demotion.reverted;
  Alcotest.(check (list string)) "each marker opens its own body" [ content; first; second ]
    (List.map (fetch_body store) (result_texts (List.nth outcome.Demotion.messages 1)));
  let captured = Demotion.capture_materialized ~pending:planned.Demotion.pending
      ~before:planned.Demotion.messages ~after:outcome.Demotion.messages in
  Alcotest.(check bool) "the outcome is captured" true (Option.is_some captured);
  let again = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check bool) "the second plan sends what the first wrote" true
    (Demotion.replay_materialized captured ~pending:again.Demotion.pending again.Demotion.messages
     = outcome.Demotion.messages)
;;

let repeated_id_bodies () =
  let prefix = String.make Tool_blob_store.preview_max 'p' in
  [prefix ^ String.make 4000 'a'; prefix ^ String.make 4000 'b']
;;

let repeated_ids_keep_distinct_payloads () = with_demotion_store @@ fun store ->
  let bodies = repeated_id_bodies () in
  let messages = List.concat_map (closed_cycle ~id:"reused") bodies in
  (match Masc.Keeper_transcript_unit.validate_provider_transcript messages with
   | Ok () -> ()
   | Error error ->
     Alcotest.fail (Masc.Keeper_transcript_unit.show_provider_transcript_error error));
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:2 messages in
  let outcome = Demotion.materialize ~store ~addresses:(Demotion.create_address_memo ())
      ~pending:planned.pending planned.messages in
  Alcotest.(check int) "both occurrences were planned" 2 (List.length planned.pending);
  Alcotest.(check (list string)) "each repeated ID opens its exact body" bodies
    (List.map (fetch_body store) (markers outcome.messages));
  Alcotest.(check (list string)) "durable source remains verbatim" bodies (markers messages);
  let bytes = List.fold_left (fun n m -> n + measure_message_bytes m) 0 in
  Alcotest.(check bool) "distinct placeholders still bound stored references" true
    (bytes outcome.messages <= bytes planned.messages)
;;

let cut_repeated_id_stores_only_retained_payload () = with_demotion_store @@ fun store ->
  let bodies = repeated_id_bodies () in
  let messages = List.concat_map (closed_cycle ~id:"reused") bodies in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:2 messages in
  let projection, _ = Window.project_from_atom ~measure_message_bytes ~first_atom:1 planned.messages in
  let outcome = Demotion.materialize ~store ~addresses:(Demotion.create_address_memo ())
      ~pending:planned.pending projection.messages in
  Alcotest.(check (list string)) "cut retains the second occurrence's body"
    [List.nth bodies 1] (List.map (fetch_body store) (markers outcome.messages));
  Alcotest.(check int) "removed occurrence was never written" 1
    (List.length (Tool_blob_store.list_all store))
;;

let memo_revalidates_rewritten_source () = with_demotion_store @@ fun store ->
  let addresses = Demotion.create_address_memo () in
  let project body =
    let source = closed_cycle ~id:"reused" body in
    let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 source in
    Demotion.materialize ~store ~addresses ~pending:planned.pending planned.messages
  in
  let bodies = repeated_id_bodies () in
  let first = project (List.nth bodies 0) in
  let second = project (List.nth bodies 1) in
  Alcotest.(check (list string)) "memo never rebinds a rewritten occurrence"
    bodies (List.map (fetch_body store) (markers first.messages @ markers second.messages))
;;

let unplanned_marker_does_not_bind_by_text () = with_demotion_store @@ fun store ->
  let source = closed_cycle ~id:"reused" (String.make 4000 'a') in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 source in
  let marker = List.hd (markers planned.messages) in
  (* This is a distinct block with byte-identical marker text and the same
     tool ID, not the placeholder owned by the plan. *)
  let unrelated = tool_message ~id:"reused" marker in
  let outcome = Demotion.materialize ~store ~addresses:(Demotion.create_address_memo ())
      ~pending:planned.pending [unrelated] in
  Alcotest.(check (list string)) "unplanned marker remains byte-exact" [marker]
    (markers outcome.messages);
  Alcotest.(check int) "foreign marker causes no write" 0
    (List.length (Tool_blob_store.list_all store))
;;

let failed_write_restores_each_original_block () =
  let base_path = Filename.temp_file "demote-blocked" "" in
  Fun.protect ~finally:(fun () -> Sys.remove base_path) @@ fun () ->
  let messages = List.concat_map (closed_cycle ~id:"reused") (repeated_id_bodies ()) in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:2 messages in
  let outcome = Demotion.materialize ~store:(Tool_blob_store.create ~base_path)
      ~addresses:(Demotion.create_address_memo ()) ~pending:planned.pending planned.messages in
  Alcotest.(check int) "both failed writes are counted" 2 outcome.reverted;
  List.iter2
    (fun (original : Types.message) (restored : Types.message) ->
       List.iter2 (fun before after ->
         Alcotest.(check bool) "exact original block restored" true (before == after))
         original.content restored.content)
    messages outcome.messages
;;

(* Completed arguments use the real normalized-reference codec and reader. *)
let argument_cycle ~id input =
  [ { (assistant "") with
      content = [Types.ToolUse {id; name = "execute"; input}] }
  ; tool_message ~id "done"
  ]
;;

let argument_inputs messages =
  List.concat_map (fun (message : Types.message) ->
    List.filter_map (function Types.ToolUse {input; _} -> Some input | _ -> None)
      message.content) messages
;;

let bind_arguments ?(replay_prefix = Masc.Keeper_replay_prefix.unchanged)
    ~completed_before ~seed messages =
  match Demotion.bind_completed_arguments ~completed_before ~seed ~replay_prefix messages with
  | Ok arguments -> arguments
  | Error _ -> Alcotest.fail "completed seed failed to bind to the actual request"
;;

let argument_reference input =
  match Tool_output.normalized_artifact_ref_of_json input with
  | Tool_output.Decoded_normalized_artifact_ref reference -> reference
  | Tool_output.Not_normalized_artifact_ref
  | Tool_output.Invalid_normalized_artifact_ref _ -> Alcotest.fail "expected argument reference"
;;

let long_arguments suffix =
  `Assoc ["command", `String (String.concat "" (List.init 1200 (fun _ -> "echo \"한글\"\n")) ^ suffix);
          "path", `String "/tmp/argument-example"; "flags", `List [`Bool true; `Int 7]]
;;

let completed_arguments_restore_through_reader () =
  let base_path = Filename.temp_dir "demote-arguments" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let store = Tool_blob_store.create ~base_path in
  let inputs = [long_arguments "first"; long_arguments "second"] in
  let seed = List.concat_map (argument_cycle ~id:"reused") inputs in
  let thought = Types.Thinking {signature = Some "exact-signature"; content = "compare earlier decisions"} in
  let redacted = Types.RedactedThinking "opaque-reasoning" in
  let details = Types.ReasoningDetails {reasoning_content = Some "retained reasoning"; details = []} in
  let seed = match seed with
    | first :: rest -> {first with content = thought :: redacted :: details :: first.content;
        metadata = ["origin", `String "retained"]} :: rest
    | [] -> Alcotest.fail "nonempty fixture" in
  (* Core can deserialize the request separately from its retained raw seed. *)
  let request = List.map (fun message ->
    Masc.Keeper_context_core.message_of_json (Masc.Keeper_context_core.message_to_json message)) seed in
  let completed_arguments = bind_arguments ~completed_before:2 ~seed request in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~completed_arguments ~measure_message_bytes ~demote_before:0 request in
  Alcotest.(check int) "both repeated-ID argument occurrences are planned" 2 (List.length planned.pending);
  let outcome = Demotion.materialize ~store ~addresses:(Demotion.create_address_memo ())
      ~pending:planned.pending planned.messages in
  let read input =
    let reference = argument_reference input in
    Alcotest.(check string) "argument MIME" "application/json" reference.mime;
    let rec pages offset chunks count =
      let _, page = Masc.Keeper_artifact_read.handle_with_page ~base_path
          ~args:(`Assoc ["sha256", `String reference.sha256; "offset", `Int offset]) in
      match page with
      | None -> Alcotest.fail "existing reader did not return a page"
      | Some page ->
        let bytes = match page.encoding with
          | Masc.Keeper_artifact_read.Utf_8 -> page.content
          | Masc.Keeper_artifact_read.Base64 -> Base64.decode_exn page.content in
        let chunks = bytes :: chunks in
        if page.eof then String.concat "" (List.rev chunks), count + 1
        else (
          Alcotest.(check bool) "reader makes byte progress" true (page.next_offset > offset);
          pages page.next_offset chunks (count + 1)) in
    let bytes, count = pages 0 [] 0 in
    Alcotest.(check bool) "large argument uses actual reader paging" true (count > 1);
    Yojson.Safe.from_string bytes in
  let restored = List.map read (argument_inputs outcome.messages) in
  Alcotest.(check bool) "each repeated ID restores its exact argument JSON" true (restored = inputs);
  Alcotest.(check bool) "durable raw inputs remain exact" true (argument_inputs seed = inputs);
  List.iter2 (fun (before : Types.message) (after : Types.message) ->
    Alcotest.(check bool) "all message metadata remains exact" true
      (before.role = after.role && before.name = after.name
       && before.tool_call_id = after.tool_call_id && before.metadata = after.metadata);
    List.iter2 (fun original projected -> match original, projected with
      | Types.ToolUse a, Types.ToolUse b ->
        Alcotest.(check bool) "call ID and name preserved" true (a.id = b.id && a.name = b.name)
      | _ -> Alcotest.(check bool) "nonargument blocks including signature are identical" true
          (original == projected)) before.content after.content) request outcome.messages
;;

let argument_seed_never_expands_after_recovery () =
  let input = long_arguments "closed" in
  let old = argument_cycle ~id:"old" input in
  let open_call = { (assistant "") with
    content = [Types.ToolUse {id = "interrupted"; name = "execute"; input = long_arguments "open"}]} in
  let seed = old @ [open_call] in
  let admitted = match Masc.Keeper_transcript_unit.close_open_cycles seed with
    | Ok closed -> closed.messages
    | Error error -> Alcotest.fail (Masc.Keeper_transcript_unit.show_structural_error error) in
  let completed_arguments = bind_arguments ~completed_before:10 ~seed admitted in
  let later = admitted @ argument_cycle ~id:"new" (long_arguments "this turn") in
  (* Even a result resend through the complete later history cannot promote
     the interrupted seed or this turn's new arguments. *)
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~completed_arguments ~measure_message_bytes ~demote_before:99 later in
  match argument_inputs planned.messages with
  | first :: rest ->
    ignore (argument_reference first);
    Alcotest.(check bool) "recovered and new input remain verbatim" true
      (rest = [long_arguments "open"; long_arguments "this turn"])
  | [] -> Alcotest.fail "missing tool uses"
;;

let arguments_require_the_complete_cycle_before_boundary () =
  let input = long_arguments "cross-boundary" in
  let seed =
    [ { (assistant "") with content = [Types.ToolUse {id="spanning"; name="execute"; input}] }
    ; assistant "still waiting for that call"
    ; tool_message ~id:"spanning" "done"
    ] in
  (match Masc.Keeper_transcript_unit.validate_provider_transcript seed with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Masc.Keeper_transcript_unit.show_provider_transcript_error error));
  let completed_arguments = bind_arguments ~completed_before:1 ~seed seed in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~completed_arguments ~measure_message_bytes ~demote_before:0 seed in
  Alcotest.(check int) "opener before boundary is insufficient without closer" 0 (List.length planned.pending);
  let completed_arguments = bind_arguments ~completed_before:2 ~seed seed in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~completed_arguments ~measure_message_bytes ~demote_before:0 seed in
  Alcotest.(check int) "whole completed cycle is eligible" 1 (List.length planned.pending)
;;

let argument_binding_rejects_rewritten_seed () =
  let seed = argument_cycle ~id:"old" (long_arguments "original") in
  let rewritten = argument_cycle ~id:"old" (long_arguments "changed") in
  let bound = Demotion.bind_completed_arguments ~completed_before:1 ~seed
      ~replay_prefix:Masc.Keeper_replay_prefix.unchanged rewritten in
  Alcotest.(check bool) "rewritten canonical prefix rejected" true
    (match bound with
     | Error (Demotion.Argument_seed_prefix_mismatch _) -> true
     | Error (Demotion.Invalid_argument_seed _ | Demotion.Argument_replay_prefix_mismatch _
             | Demotion.Argument_occurrence_mismatch) | Ok _ -> false)
;;

let media_projection_binds_actual_argument_positions () =
  let input = long_arguments "media" in
  let canonical = match argument_cycle ~id:"media" input with
    | first :: rest -> {first with content =
        Types.Image {media_type = "image/png"; source = (stored_source ~media_type:"image/png" "aW1hZ2U=")}
        :: first.content} :: rest
    | [] -> Alcotest.fail "nonempty fixture" in
  (* The Keeper's dispatch prefix is the history the text-only strip leaves;
     a provider's own image degrade runs on the wire form, after this. *)
  let caps = {Agent_core.Llm_provider.Capabilities.default_capabilities with supports_image_input = false} in
  let stripped, _ = Runtime_agent.strip_unsupported_modality_messages caps canonical in
  let replay_prefix = Masc.Keeper_replay_prefix.media_degraded
      ~canonical_prefix:canonical ~dispatch_prefix:stripped in
  let completed_arguments = bind_arguments ~replay_prefix ~completed_before:1 ~seed:canonical stripped in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~completed_arguments ~measure_message_bytes ~demote_before:0 stripped in
  Alcotest.(check int) "removed preceding Image shifts ToolUse but retains eligibility" 1
    (List.length planned.pending);
  (* A later independently rebuilt value at the same position has no frozen
     source identity, even if it happens to be structurally equal. *)
  let rewritten = List.map (fun message -> Masc.Keeper_context_core.message_of_json
      (Masc.Keeper_context_core.message_to_json message)) stripped in
  let later = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~completed_arguments ~measure_message_bytes ~demote_before:0 rewritten in
  Alcotest.(check int) "replaced source cannot use frozen eligibility" 0 (List.length later.pending)
;;

let argument_cut_and_failed_store_preserve_occurrences () = with_demotion_store @@ fun store ->
  let inputs = [long_arguments "first"; long_arguments "second"] in
  let seed = List.concat_map (argument_cycle ~id:"reused") inputs in
  let completed_arguments = bind_arguments ~completed_before:2 ~seed seed in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~completed_arguments ~measure_message_bytes ~demote_before:0 seed in
  let projection, _ = Window.project_from_atom ~measure_message_bytes ~first_atom:1 planned.messages in
  let outcome = Demotion.materialize ~store ~addresses:(Demotion.create_address_memo ())
      ~pending:planned.pending projection.messages in
  Alcotest.(check int) "only surviving argument is stored" 1 (List.length (Tool_blob_store.list_all store));
  let reference = argument_reference (List.hd (argument_inputs outcome.messages)) in
  (match Tool_blob_store.fetch store ~sha256:reference.sha256 with
   | Ok (Some bytes) -> Alcotest.(check bool) "retained occurrence stores its own input" true
       (Yojson.Safe.from_string bytes = List.nth inputs 1)
   | Ok None | Error _ -> Alcotest.fail "retained argument not readable");
  let base_path = Filename.temp_file "argument-store-blocked" "" in
  Fun.protect ~finally:(fun () -> Sys.remove base_path) @@ fun () ->
  let failed = Demotion.materialize ~store:(Tool_blob_store.create ~base_path)
      ~addresses:(Demotion.create_address_memo ()) ~pending:planned.pending planned.messages in
  Alcotest.(check int) "both failures counted" 2 failed.reverted;
  List.iter2 (fun (before : Types.message) (after : Types.message) ->
    List.iter2 (fun a b -> Alcotest.(check bool) "failed write restores exact source" true (a == b))
      before.content after.content) seed failed.messages
;;

let arguments_obey_each_provider_wire_bound () = with_demotion_store @@ fun store ->
  let open Agent_core.Llm_provider in
  let seed = argument_cycle ~id:"escaped" (long_arguments "\"\\\n") in
  let completed_arguments = bind_arguments ~completed_before:1 ~seed seed in
  let codec kind build =
    let config = Provider_config.make ~kind ~model_id:"argument-projection-fixture"
        ~base_url:"http://localhost" ~max_tokens:4096 () in
    let encode messages =
      match Agent_core.History.to_wire_messages test_media_store messages with
      | Ok messages -> build ~config ~messages ()
      | Error error -> Alcotest.fail (Agent_core.Error.to_string (Agent_core.Error.Media error)) in
    let measure_message_bytes message = String.length (encode [message]) in
    let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~completed_arguments ~measure_message_bytes ~demote_before:0 seed in
    Alcotest.(check int) "actual wire selects argument demotion" 1 (List.length planned.pending);
    let outcome = Demotion.materialize ~store ~addresses:(Demotion.create_address_memo ())
        ~pending:planned.pending planned.messages in
    Alcotest.(check bool) "actual encoded request shrinks" true
      (String.length (encode outcome.messages) < String.length (encode seed));
    Alcotest.(check bool) "materialized wire fits planned wire bound" true
      (String.length (encode outcome.messages) <= String.length (encode planned.messages)) in
  codec Provider_config.OpenAI_compat (fun ~config ~messages () -> Backend_openai.build_request ~config ~messages ());
  codec Provider_config.Anthropic (fun ~config ~messages () -> Backend_anthropic.build_request ~config ~messages ());
  codec Provider_config.Gemini (fun ~config ~messages () -> Backend_gemini.build_request ~config ~messages ())
;;

(* Exercise the Keeper safety wrapper with provenance minted by the actual
   Anthropic producer, real stored references, and the final provider wire. *)
module Signed_provider = Masc.Keeper_turn_driver_try_provider

let signed_argument_config () =
  let open Agent_core.Llm_provider in
  Provider_config.make ~kind:Provider_config.Anthropic
    ~model_id:"claude-sonnet-5-5" ~base_url:"https://api.anthropic.com"
    ~max_tokens:4096 ~system_prompt:"signed argument fixture"
    ~model_capabilities_override:
      { (Capabilities.capabilities_of_kind Provider_config.Anthropic) with
        reasoning_replay_override = Capabilities.Force_latest_user_turn_tool_calls }
    ()
;;

let signed_argument_tools =
  [`Assoc ["name", `String "execute"; "description", `String "execute fixture";
           "input_schema", `Assoc ["type", `String "object"]]]
;;

let signed_user text = { (assistant text) with role = Types.User }

(* The wire folds a user message into the tool result before it only when the
   message carries the [Tool_result_followup] origin (or [Recovery_instruction]);
   a [Conversation] user message stays a separate wire message. *)
let signed_tool_followup text =
  { (signed_user text) with origin = Llm_provider.Types.Tool_result_followup }

let stamp_signed_call ~config ~prefix ~id input =
  let open Agent_core.Llm_provider in
  let content =
    [Types.Thinking {content = "signed argument reasoning"; signature = Some "sig-argument"};
     Types.ToolUse {id; name = "execute"; input}] in
  let media_ok = function
    | Ok value -> value
    | Error error -> Alcotest.fail (Agent_core.Error.to_string (Agent_core.Error.Media error)) in
  let reasoning_prefix = Backend_anthropic.transmitted_reasoning_prefix
      ~config ~messages:(media_ok (Agent_core.History.to_wire_messages test_media_store prefix))
      ~tools:signed_argument_tools ~response_content:content () in
  Alcotest.(check bool) "actual producer minted prefix provenance" true
    (Option.is_some reasoning_prefix);
  let capability = match Reasoning_dialect.replay_capability_for_provider_config config with
    | Ok capability -> capability
    | Error detail -> Alcotest.fail detail in
  let response : Types.api_response =
    { id = "signed-argument-response"; model = "claude-sonnet-5-5"
    ; unreadable_tool_uses = []
    ; stop_reason = Types.EndTurn; content; usage = None
    ; telemetry = Some { Types.default_inference_telemetry with
        reasoning_source = Some capability.target; reasoning_prefix } } in
  match Types.assistant_message_of_response response with
  | Ok message -> media_ok (Agent_core.History.of_wire_message test_media_store message)
  | Error _ -> Alcotest.fail "actual sourced response could not be recorded"
;;

let with_signed_argument_store f =
  let base_path = Filename.temp_dir "demote-signed-arguments" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () -> f ~base_path (Tool_blob_store.create ~base_path))
;;

let signed_argument_view ?frozen_arguments ?materialize ~base_path ~store ~config messages =
  let atom_count = snd (Window.annotate messages) in
  let completed_arguments = match frozen_arguments with
    | None -> Some (bind_arguments ~completed_before:atom_count ~seed:messages messages)
    | Some arguments -> arguments in
  let first_digest = match Window.atom_opening_digest messages 0 with
    | Some digest -> digest
    | None -> Alcotest.fail "signed fixture must open atom zero" in
  let addresses = Demotion.create_address_memo () in
  let materialize = match materialize with
    | Some materialize -> materialize
    | None -> fun ~pending projected ->
      (Demotion.materialize ~store ~addresses ~pending projected).messages in
  match Signed_provider.For_testing.request_view
    ~to_wire:(Agent_core.History.to_wire_message (Agent_core.History.Memory_store.create ()))
    ?completed_arguments
    ~tools:signed_argument_tools ~provider_config:config ~measure_message_bytes
    ~measure_wire_bytes:(Masc.Keeper_model_input_wire_bytes.measurer ~config)
    ~front:(Some { Masc.Keeper_carried_front.first_atom = 0
      ; front = Model_input_front.At_atom first_digest
      ; source = Masc.Keeper_carried_front.Ledger })
    ~accepted:None ~history_digest_at:(Window.atom_opening_digest messages)
    ~current_turn_results:(Signed_provider.Current_turn_demoted { refused_atom_count = atom_count })
    ~base_path
    ~turn_boundary:(Masc.Keeper_carried_front.Turn_boundary {end_atom = atom_count})
    ~materialize
    messages
  with
  | Ok view -> view
  | Error error -> Alcotest.fail (Agent_core.Error.to_string (Agent_core.Error.Media error))
;;

let assert_signed_argument_wire ~config ~reasoning_index messages =
  let messages =
    match Agent_core.History.to_wire_messages test_media_store messages with
    | Ok messages -> messages
    | Error error -> Alcotest.fail (Agent_core.Error.to_string (Agent_core.Error.Media error)) in
  let open Agent_core.Llm_provider in
  (match Backend_anthropic.retained_prefix_reasoning_indices
      ~config ~tools:signed_argument_tools messages with
   | Ok (Some indices) -> Alcotest.(check (list int))
       "retained reasoning names the original message occurrence" [reasoning_index] indices
   | Ok None | Error _ -> Alcotest.fail "Anthropic prefix projection failed");
  let body = Backend_anthropic.build_request ~config ~messages ~tools:signed_argument_tools () in
  let wire_blocks = Yojson.Safe.Util.(Yojson.Safe.from_string body |> member "messages" |> to_list)
    |> List.concat_map (fun message -> Yojson.Safe.Util.(member "content" message |> to_list)) in
  let reasoning = List.filter (fun block ->
      Yojson.Safe.Util.member "type" block = `String "thinking") wire_blocks in
  Alcotest.(check int) "the actual provider wire retains one signed block" 1 (List.length reasoning);
  let thought = List.hd reasoning in
  Alcotest.(check string) "actual wire preserves signed thinking content" "signed argument reasoning"
    Yojson.Safe.Util.(member "thinking" thought |> to_string);
  Alcotest.(check string) "actual wire preserves the signature" "sig-argument"
    Yojson.Safe.Util.(member "signature" thought |> to_string);
  List.filter_map (fun block ->
      if Yojson.Safe.Util.member "type" block = `String "tool_use"
      then Some (Yojson.Safe.Util.member "input" block) else None) wire_blocks
;;

let assert_stored_argument store original input =
  let reference = argument_reference input in
  Alcotest.(check string) "signed-prefix argument reference MIME" "application/json" reference.mime;
  match Tool_blob_store.fetch store ~sha256:reference.sha256 with
  | Ok (Some bytes) -> Alcotest.(check string) "real reference stores the exact original argument"
      (Yojson.Safe.to_string original) bytes
  | Ok None | Error _ -> Alcotest.fail "signed-prefix argument reference has no stored payload"
;;

let signed_call_keeps_its_own_arguments () = with_signed_argument_store @@ fun ~base_path store ->
  let config = signed_argument_config () in
  let input = long_arguments "signed same-message input" in
  let user = signed_user "perform the signed call" in
  let signed = stamp_signed_call ~config ~prefix:[user] ~id:"signed" input in
  let source = [user; signed; tool_message ~id:"signed" "done"] in
  ignore (assert_signed_argument_wire ~config ~reasoning_index:1 source : Yojson.Safe.t list);
  let view = signed_argument_view ~base_path ~store ~config source in
  Alcotest.(check bool) "changing the signed message forces argument protection" true
    view.argument_prefix_protected;
  let inputs = assert_signed_argument_wire ~config ~reasoning_index:1 view.carried in
  Alcotest.(check bool) "the signed ToolUse input remains exact on actual wire" true (inputs = [input])
;;

let signed_prefix_protects_only_earlier_argument_occurrences () =
  with_signed_argument_store @@ fun ~base_path store ->
  let config = signed_argument_config () in
  let input = long_arguments "same immutable call before and after reasoning" in
  let call = List.hd (argument_cycle ~id:"reused" input) in
  let result = tool_message ~id:"reused" "done" in
  let prefix = [signed_user "compare old work"; call; result] in
  let signed = stamp_signed_call ~config ~prefix ~id:"signed" (`Assoc []) in
  (* The very same immutable Assistant and Tool records occur on both sides
     of reasoning. Protection must follow source occurrences, not identity. *)
  let source = prefix @ [signed; tool_message ~id:"signed" "done"; call; result] in
  let view = signed_argument_view ~base_path ~store ~config source in
  Alcotest.(check bool) "the earlier creation prefix was protected" true view.argument_prefix_protected;
  let inputs = assert_signed_argument_wire ~config ~reasoning_index:3 view.carried in
  match inputs with
  | [earlier; signed_input; later] ->
    Alcotest.(check bool) "earlier argument remains exact" true (earlier = input);
    Alcotest.(check bool) "signed call remains exact" true (signed_input = `Assoc []);
    assert_stored_argument store input later
  | _ -> Alcotest.fail "expected both occurrences and the signed call on actual wire"
;;

let signed_prefix_can_reproduce_already_demoted_arguments () =
  with_signed_argument_store @@ fun ~base_path store ->
  let config = signed_argument_config () in
  let input = long_arguments "already transmitted as an argument artifact" in
  let prefix = signed_user "inspect stored earlier work" :: argument_cycle ~id:"earlier" input in
  let arguments = bind_arguments ~completed_before:2 ~seed:prefix prefix in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~completed_arguments:arguments ~measure_message_bytes ~demote_before:0 prefix in
  let transmitted = (Demotion.materialize ~store ~addresses:(Demotion.create_address_memo ())
      ~pending:planned.pending planned.messages).messages in
  let original_reference = List.hd (argument_inputs transmitted) in
  assert_stored_argument store input original_reference;
  let signed = stamp_signed_call ~config ~prefix:transmitted ~id:"signed" (`Assoc []) in
  let source = prefix @ [signed; tool_message ~id:"signed" "done"] in
  let view = signed_argument_view ~base_path ~store ~config source in
  Alcotest.(check bool) "an exact already-demoted creation prefix needs no fallback" false
    view.argument_prefix_protected;
  let inputs = assert_signed_argument_wire ~config ~reasoning_index:3 view.carried in
  match inputs with
  | [restored_reference; signed_input] ->
    Alcotest.(check bool) "the actual stored reference is reproduced exactly" true
      (restored_reference = original_reference);
    Alcotest.(check bool) "the signed call remains exact" true (signed_input = `Assoc [])
  | _ -> Alcotest.fail "expected the stored prefix and the signed call"
;;

let signed_prefix_tracks_replay_projection_and_tool_user_merge () =
  with_signed_argument_store @@ fun ~base_path store ->
  let config = signed_argument_config () in
  let earlier_input = long_arguments "before empty removal and tool-user merge" in
  let later_input = long_arguments "after signed message" in
  let excluded = { (assistant "") with content =
      [Types.Thinking {content = "unsourced earlier reasoning"; signature = Some "unproven"}] } in
  let followup = "follow up immediately after the tool result" in
  let prefix = [signed_user "first ask"; excluded]
    @ argument_cycle ~id:"earlier" earlier_input
    @ [signed_tool_followup followup] in
  let signed = stamp_signed_call ~config ~prefix ~id:"signed" (`Assoc []) in
  let source = prefix @ [signed; tool_message ~id:"signed" "done"]
    @ argument_cycle ~id:"later" later_input in
  let wire_source = match Agent_core.History.to_wire_messages test_media_store source with
    | Ok messages -> messages
    | Error error -> Alcotest.fail (Agent_core.Error.to_string (Agent_core.Error.Media error)) in
  let projection = match Agent_core.Llm_provider.Backend_anthropic.project_history config wire_source with
    | Ok projection -> projection
    | Error _ -> Alcotest.fail "signed fixture projection failed" in
  Alcotest.(check (list int)) "the actual replay projection removes the empty Assistant" [1]
    projection.removed_empty_assistant_indices;
  ignore (assert_signed_argument_wire ~config ~reasoning_index:5 source : Yojson.Safe.t list);
  let wire_messages = Agent_core.Llm_provider.Backend_anthropic.build_request
      ~config ~messages:wire_source ~tools:signed_argument_tools ()
    |> Yojson.Safe.from_string |> Yojson.Safe.Util.member "messages" |> Yojson.Safe.Util.to_list in
  Alcotest.(check bool) "actual wire merges ToolResult and following User text" true
    (List.exists (fun message ->
       let blocks = Yojson.Safe.Util.(member "content" message |> to_list) in
       List.exists (fun block -> Yojson.Safe.Util.member "type" block = `String "tool_result") blocks
       && List.exists (fun block -> Yojson.Safe.Util.member "text" block = `String followup) blocks)
       wire_messages);
  let view = signed_argument_view ~base_path ~store ~config source in
  Alcotest.(check bool) "source-index protection survives projection and merging" true
    view.argument_prefix_protected;
  let inputs = assert_signed_argument_wire ~config ~reasoning_index:5 view.carried in
  match inputs with
  | [earlier; signed_input; later] ->
    Alcotest.(check bool) "the argument before shifted signed reasoning remains exact" true
      (earlier = earlier_input);
    Alcotest.(check bool) "the signed call remains exact" true (signed_input = `Assoc []);
    assert_stored_argument store later_input later
  | _ -> Alcotest.fail "expected all three call inputs after actual merging"
;;

let signed_prefix_revalidates_after_a_failed_store_write () =
  with_signed_argument_store @@ fun ~base_path store ->
  let config = signed_argument_config () in
  let input = long_arguments "prefix restored after a real storage failure" in
  let prefix = signed_user "inspect the earlier call" :: argument_cycle ~id:"earlier" input in
  let first = signed_argument_view ~base_path ~store ~config prefix in
  assert_stored_argument store input (List.hd (argument_inputs first.carried));
  let first_signed = stamp_signed_call ~config ~prefix:first.carried ~id:"signed-one" (`Assoc []) in
  ignore (assert_signed_argument_wire ~config ~reasoning_index:3
    (first.carried @ [first_signed; tool_message ~id:"signed-one" "done"]) : Yojson.Safe.t list);
  let second_source = prefix @ [first_signed; tool_message ~id:"signed-one" "done"] in
  let blocked = Filename.temp_file "signed-argument-write-blocked" "" in
  Fun.protect ~finally:(fun () -> Sys.remove blocked) @@ fun () ->
  (* A regular file cannot host .masc/tool_blobs. Use the real materializer
     with that store, rather than synthesizing a restored message list. *)
  let failed = signed_argument_view ~frozen_arguments:first.completed_arguments
      ~base_path ~store:(Tool_blob_store.create ~base_path:blocked) ~config second_source in
  Alcotest.(check bool) "storage failure restored the exact earlier argument" true
    (List.hd (argument_inputs failed.carried) = input);
  let next_signed = stamp_signed_call ~config ~prefix:failed.carried ~id:"signed-two" (`Assoc []) in
  let third_source = second_source @ [next_signed; tool_message ~id:"signed-two" "done"] in
  let recovered = signed_argument_view ~frozen_arguments:failed.completed_arguments
      ~base_path ~store ~config third_source in
  Alcotest.(check bool) "a later successful write cannot invalidate the new raw-bound signature" true
    recovered.argument_prefix_protected;
  let inputs = assert_signed_argument_wire ~config ~reasoning_index:5 recovered.carried in
  Alcotest.(check bool) "the newly signed raw prefix remains exact on real wire" true
    (List.hd inputs = input);
  let followup = signed_argument_view ~frozen_arguments:recovered.completed_arguments
      ~base_path ~store ~config third_source in
  let followup_inputs = assert_signed_argument_wire ~config ~reasoning_index:5 followup.carried in
  Alcotest.(check bool) "the narrowed frozen set cannot re-enable the old argument" true
    (List.hd followup_inputs = input)
;;

let signed_prefix_replays_the_first_mixed_storage_outcome () =
  with_signed_argument_store @@ fun ~base_path store ->
  let config = signed_argument_config () in
  let input = long_arguments "argument storage succeeds while result storage fails" in
  let result_body = "blocked result blob: " ^ String.make 4000 'r' in
  let call = List.hd (argument_cycle ~id:"earlier" input) in
  let prefix = [signed_user "preserve the actual result outcome"; call;
                tool_message ~id:"earlier" result_body] in
  let signed = stamp_signed_call ~config ~prefix ~id:"signed" (`Assoc []) in
  let source = prefix @ [signed; tool_message ~id:"signed" "done"] in
  let result_sha = Agent_core_sha256.(to_hex (digest_string result_body)) in
  let result_target = Filename.concat
      (Filename.concat (Tool_blob_store.root_dir store) (String.sub result_sha 0 2)) result_sha in
  (* Only this result's exact blob filename is a directory. Other addresses,
     including the argument in the same materialization, remain writable. *)
  Fs_compat.mkdir_p result_target;
  let calls = ref 0 in
  let addresses = Demotion.create_address_memo () in
  let materialize ~pending projected =
    incr calls;
    let outcome = Demotion.materialize ~store ~addresses ~pending projected in
    if !calls = 1 then (
      Alcotest.(check bool) "the first real materialization includes a failed write" true
        (outcome.reverted > 0);
      Alcotest.(check bool) "the failed result is restored byte-for-byte" true
        (List.mem result_body (markers outcome.messages));
      assert_stored_argument store input (List.hd (argument_inputs outcome.messages));
      (* A forbidden second materialization would now store the result and
         produce a different baseline. Comparisons must replay the first one. *)
      Unix.rmdir result_target);
    outcome.messages in
  let view = signed_argument_view ~materialize ~base_path ~store ~config source in
  Alcotest.(check int) "candidate, baseline and final share one materialization effect" 1 !calls;
  Alcotest.(check bool) "the argument-induced signed-prefix loss is detected" true
    view.argument_prefix_protected;
  Alcotest.(check bool) "the final comparison retains the original failed-result outcome" true
    (List.mem result_body (markers view.carried));
  let inputs = assert_signed_argument_wire ~config ~reasoning_index:3 view.carried in
  Alcotest.(check bool) "the protected original argument and signed call reach actual wire" true
    (inputs = [input; `Assoc []])
;;

(* Addressing a body is a sha256 over the whole of it; the write is skipped for
   an address this process already wrote, so on a long-lived keeper the hashing
   is all [materialize] does, and doing it on the calling fiber held the main
   Eio domain for 0.7 to 1.6 seconds per provider request (rtev, 2026-09-16).
   With the pool's only worker busy, materialize waits for it. *)
let busy_worker_polls = 50
let busy_worker_poll_interval_s = 0.01

(* A request the memo answers does no pool work at all, so any wait here is the
   regression, not slowness. *)
let memo_hit_budget_s = 5.0

let materialize_addresses_each_body_once_per_attempt () =
  let store = Tool_blob_store.create ~base_path:(Filename.temp_dir "demote" "") in
  let bodies = List.init 8 (fun i -> Printf.sprintf "body %d:" i ^ String.make 4000 'a') in
  let messages = history_with_tool_bodies bodies in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let previous_pool = Domain_pool_ref.get () in
  Fun.protect
    ~finally:(fun () ->
      match previous_pool with
      | None -> Domain_pool_ref.clear_for_tests ()
      | Some previous -> Domain_pool_ref.set previous)
  @@ fun () ->
  Domain_pool_ref.set (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
  let occupied, occupied_u = Eio.Promise.create () in
  let release, release_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
      Eio.Promise.resolve occupied_u ();
      Eio.Promise.await release));
  Eio.Promise.await occupied;
  let addresses = Demotion.create_address_memo () in
  let materialize () =
    let planned =
      Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:(List.length bodies) messages
    in
    Demotion.materialize
      ~store
      ~addresses
      ~pending:planned.Demotion.pending
      planned.Demotion.messages
  in
  let first = ref None in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.both
    (fun () -> first := Some (materialize ()))
    (fun () ->
      let rec wait polls =
        if polls > 0 && Option.is_none !first
        then (
          Eio.Time.sleep clock busy_worker_poll_interval_s;
          wait (polls - 1))
      in
      wait busy_worker_polls;
      Alcotest.(check bool)
        "the first request waits for the busy worker"
        true
        (Option.is_none !first);
      Eio.Promise.resolve release_u ());
  let first =
    match !first with
    | None -> Alcotest.fail "materialize never finished"
    | Some outcome -> outcome
  in
  (* The attempt's later requests demote the same aged results. With the
     worker occupied again, a second materialize through the same memo
     finishes anyway: it addressed nothing. *)
  let occupied, occupied_u = Eio.Promise.create () in
  let release, release_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
      Eio.Promise.resolve occupied_u ();
      Eio.Promise.await release));
  Eio.Promise.await occupied;
  (* A bounded wait, not an unbounded one: if the memo ever stops answering,
     this call submits a job the occupied worker can never run, and without the
     timeout the suite would hang until CI kills it rather than name the
     regression. *)
  let second =
    match
      Eio.Time.with_timeout clock memo_hit_budget_s (fun () -> Ok (materialize ()))
    with
    | Ok outcome -> outcome
    | Error `Timeout ->
      Eio.Promise.resolve release_u ();
      Alcotest.fail "a second request through the memo waited for the pool"
  in
  Eio.Promise.resolve release_u ();
  let stored outcome =
    List.map
      (fun content ->
         match Tool_output.decode_from_agent_core content with
         | Tool_output.Decoded reference ->
           (match Tool_blob_store.fetch store ~sha256:reference.Tool_output.sha256 with
            | Ok (Some bytes) -> bytes
            | Ok None -> Alcotest.fail "a marker names a blob the store does not hold"
            | Error error ->
              Alcotest.fail (Tool_blob_store.fetch_error_to_string error))
         | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
           Alcotest.fail "every planned body leaves as a marker")
      (markers outcome.Demotion.messages)
  in
  Alcotest.(check int) "no revert in a healthy store" 0 first.Demotion.reverted;
  Alcotest.(check int) "nor on the second request" 0 second.Demotion.reverted;
  Alcotest.(check (list string)) "each marker stores its own body" bodies (stored first);
  Alcotest.(check (list string)) "and the memo names the same ones" bodies (stored second)
;;

(* --- 5. Atoms retained by the raw cut keep their bodies ---------------- *)

let raw_cut_retained_atoms_are_verbatim () =
  let old_body = String.make 4000 'a' in
  let retained_body = String.make 4000 'b' in
  let messages = history_with_tool_bodies [ old_body; retained_body ] in
  let planned = Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int)
    "only the atom below the raw cut is demoted"
    1
    (List.length planned.Demotion.pending);
  Alcotest.(check bool)
    "the raw-cut-retained body stays verbatim"
    true
    (List.exists
       (fun content -> String.equal content retained_body)
       (markers planned.Demotion.messages))
;;

(* --- 6. [plan] honours whatever boundary it is handed ------------------- *)

let plan_honours_a_monotonic_boundary () =
  let body = String.make 4000 'a' in
  let build atoms =
    List.concat
      (List.init atoms (fun i ->
         [ assistant (Printf.sprintf "call %d" i)
         ; tool_message ~id:(Printf.sprintf "c%d" i) body
         ]))
  in
  let bytes messages =
    List.fold_left (fun total message -> total + measure_message_bytes message) 0 messages
  in
  (* Sixty atoms plus slack for the fixed preamble fit; a sixty-first 4KB
     result does not. The authoritative cut must therefore stay at 60 while
     the raw suffix grows from 10 through 60 atoms, then jump to 120. *)
  let capacity_bytes = bytes (build Window.atoms_per_window) + 1024 in
  let projected atoms =
    let messages = build atoms in
    match
      Window.project_with_drop
        ~measure_message_bytes
        ~capacity_bytes
        ~reserved_bytes:0
        messages
    with
    | Error error ->
      Alcotest.fail (Window.budget_error_to_string error)
    | Ok raw ->
      let planned =
        Demotion.plan ~measure_wire_bytes:stored_wire_bytes
          ~measure_message_bytes
          ~demote_before:raw.dropped_atoms
          messages
      in
      raw.dropped_atoms, List.length planned.Demotion.pending
  in
  let first_cut = Window.atoms_per_window in
  List.iter
    (fun atoms ->
       let dropped, demoted = projected atoms in
       Alcotest.(check int)
         (Printf.sprintf "raw cut stays fixed at %d atoms" atoms)
         first_cut
         dropped;
       Alcotest.(check int)
         (Printf.sprintf "demotion stays anchored at %d atoms" atoms)
         first_cut
         demoted)
    [ first_cut + 10; first_cut + 11; first_cut + 27; first_cut * 2 ];
  let dropped, demoted = projected ((first_cut * 2) + 1) in
  Alcotest.(check int) "raw cut advances by one window" (first_cut * 2) dropped;
  Alcotest.(check int)
    "demotion advances only with that raw cut"
    (first_cut * 2)
    demoted
;;

(* 길이를 재려고 메시지를 문자열로 만들던 것을 재사용 버퍼로 바꿨다
   ([message_measurer]). [Yojson.Safe.to_string] 이 곧 [to_buffer] 다음
   [Buffer.contents] 이므로 바이트 수가 같아야 한다. 이스케이프가 필요한 문자와
   멀티바이트에서 특히 그렇고, 버퍼를 비우지 않으면 두 번째 측정부터 커진다. *)
let measurer_counts_the_same_bytes_as_to_string () =
  let measure =
    Masc.Keeper_context_core.message_measurer ()
  in
  let cases =
    [ "empty body", assistant ""
    ; "plain ascii", assistant "a plain assistant body"
    ; "quotes and backslashes", assistant {|he said "hi\\" and left|}
    ; "control characters", assistant "line\nbreak\ttab\r"
    ; "multibyte", assistant "\xed\x95\x9c\xea\xb5\xad\xec\x96\xb4, emoji \xf0\x9f\x99\x82"
    ; "long tool result", tool_message ~id:"call-long" (String.make 5000 'x')
    ; "short after long", assistant "short"
    ]
  in
  List.iter
    (fun (label, message) ->
       Alcotest.(check int) label (measure_message_bytes message) (measure message))
    cases;
  (* 같은 measurer 로 같은 메시지를 다시 재도 같아야 한다: 버퍼가 쌓이면 깨진다. *)
  let repeated = assistant "measured twice" in
  Alcotest.(check int)
    "a measurer reused on one message"
    (measure repeated)
    (measure repeated)
;;

(* 요청마다 [Complete_common.transmitted_history] 가 메시지 레코드를 전부 새로
   만든다. live 체크포인트처럼 [name] 과 [tool_call_id] 가 없는 메시지로, 새로
   만든 레코드가 앞 요청의 측정을 그대로 쓰는지 본다. *)
let rebuilt_records_reuse_measurements () =
  let envelope_free role text : Types.message =
    { origin = Llm_provider.Types.Conversation;  role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }
  in
  let history =
    List.init 200 (fun i ->
      envelope_free
        (if i mod 2 = 0 then Types.Assistant else Types.Tool)
        (Printf.sprintf "message %d" i))
  in
  let raw_measurements = ref 0 in
  let measure_message_bytes =
    Masc.Keeper_turn_driver_try_provider.For_testing.memoize_message_measurement
      (fun message ->
         incr raw_measurements;
         measure_message_bytes message)
  in
  let request () =
    List.iter
      (fun (message : Types.message) ->
         ignore (measure_message_bytes { message with content = message.content }))
      history
  in
  request ();
  request ();
  request ();
  Alcotest.(check int)
    "three requests encode each message once"
    (List.length history)
    !raw_measurements
;;

(* 캐시 조회는 해시가 같은 항목을 전부 비교한다. [name] 과 [tool_call_id] 가 없는
   메시지는 content 로만 구분되므로, 해시가 content 를 안 읽으면 역할마다 값이
   하나가 되고 조회가 그 역할의 히스토리 전체를 훑는다. 짧은 id 와 긴 본문 모두
   서로 다른 값이 나와야 한다. *)
let measurement_hash_reads_content () =
  let hash = Masc.Keeper_turn_driver_try_provider.For_testing.message_measurement_hash in
  let distinct messages =
    List.sort_uniq Int.compare (List.map hash messages) |> List.length
  in
  let short_texts = List.init 200 (fun i -> assistant (Printf.sprintf "message %d" i)) in
  let tool_results =
    List.init 200 (fun i ->
      tool_message ~id:(Printf.sprintf "call_%08d" i) (String.make 5000 'x'))
    |> List.map (fun (message : Types.message) -> { message with tool_call_id = None })
  in
  Alcotest.(check int) "short texts" 200 (distinct short_texts);
  Alcotest.(check int) "tool results that differ only by id" 200 (distinct tool_results)
;;

(* The production pipeline measures the raw history, rewrites only atoms below
   that cut, then measures the planned list. This fixture makes every atom
   eligible so the memo must reuse every candidate measurement. *)
let projection_reuses_candidate_measurements () =
  let bodies = List.init 20 (fun _ -> String.make 4000 'a') in
  let messages = history_with_tool_bodies bodies in
  let raw_measurements = ref 0 in
  let measured message =
    incr raw_measurements;
    measure_message_bytes message
  in
  let measure_message_bytes =
    Masc.Keeper_turn_driver_try_provider.For_testing
    .memoize_message_measurement measured
  in
  let planned =
    Demotion.plan ~measure_wire_bytes:stored_wire_bytes ~measure_message_bytes ~demote_before:max_int messages
  in
  Alcotest.(check int)
    "fixture creates one candidate per aged tool result"
    20
    (List.length planned.Demotion.pending);
  (match
     Window.project
       ~measure_message_bytes
       ~capacity_bytes:max_int
       ~reserved_bytes:0
       planned.Demotion.messages
   with
  | Error error ->
     Alcotest.fail (Window.budget_error_to_string error)
   | Ok _ -> ());
  let expected_unique_measurements =
    List.length messages + List.length planned.Demotion.pending + 1
    (* The window's synthetic preamble. *)
  in
  Alcotest.(check int)
    "each original, candidate, and preamble is encoded once"
    expected_unique_measurements
    !raw_measurements
;;

(* --- 7. The current turn's results after a size refusal (#28845) -------- *)

(* The alpha incident shape: parallel WebSearch results joined the assistant
   atom that called them, and that one atom (indivisible to the range) was
   refused on its own. Ordinary demotion cannot help — its boundary excludes
   the current turn (RFC-0351 §4) — so the turn was stuck, and a failed turn
   writes no boundary line, so the next turn composed the same range and was
   refused again. After a size refusal the compositions demote every tool
   result the refused request carried, and the same candidate is asked once
   more. *)
module Try_provider = Masc.Keeper_turn_driver_try_provider

let demoted_after_refusal messages =
  Try_provider.Current_turn_demoted
    { refused_atom_count = snd (Window.annotate messages) }
;;

(* The composition carries a range (RFC keeper-context-window-in-tokens
   §10.4), never refuses, and measures the request against nothing;
   [front] is the oldest atom the range starts at and [current_turn_results]
   is what the refusal path decided. *)
let compose ~base_path ~front ~current_turn_results ~turn_end messages =
  let front_digest =
    match Window.atom_opening_digest messages front with
    | Some digest -> digest
    | None -> Alcotest.fail "the front is an atom of the history"
  in
  Try_provider.For_testing.compose_carried_model_input
    ~measure_message_bytes
    ~measure_wire_bytes:stored_wire_bytes
    ~accepted:None ~front:
      (Some
         { Masc.Keeper_carried_front.first_atom = front
         ; front = Model_input_front.At_atom front_digest
         ; source = Masc.Keeper_carried_front.Ledger
         })
    ~history_digest_at:(Window.atom_opening_digest messages)
    ~current_turn_results
    ~base_path
    ~turn_boundary:(Masc.Keeper_carried_front.Turn_boundary { end_atom = turn_end })
    messages
;;

let bytes_of messages =
  List.fold_left (fun acc m -> acc + measure_message_bytes m) 0 messages
;;

(* What the refusal path asks of the refused range: would demoting its tool
   results change it. *)
let demotion_after_refusal ~base_path ~front ~turn_end messages =
  Try_provider.For_testing.current_turn_demotion
    ~refused:
      (compose ~base_path ~front ~current_turn_results:Try_provider.Current_turn_verbatim
         ~turn_end messages)
    ~demoted:
      (compose ~base_path ~front ~current_turn_results:(demoted_after_refusal messages)
         ~turn_end messages)
;;

let newest_bodies = [ 24_000; 31_000; 47_000; 7_000 ]

let oversized_newest_history () =
  (* Earlier atoms carry tiny bodies, so nothing below the turn boundary is
     demotable and every pending entry the composition produces belongs to the
     newest atom. *)
  let earlier = history_with_tool_bodies [ "tick"; "tock" ] in
  let newest =
    assistant "search batch"
    :: List.mapi
         (fun i size ->
            tool_message
              ~id:(Printf.sprintf "search-%d" i)
              (String.make size (Char.chr (Char.code 'a' + i))))
         newest_bodies
  in
  earlier, earlier @ newest, bytes_of newest
;;

let oversized_newest_atom_is_demoted_after_refusal () =
  let earlier, messages, _ = oversized_newest_history () in
  let turn_end =
    Window.first_atom_at_or_after
      messages
      ~message_index:(List.length earlier)
  in
  let base_path = Filename.temp_dir "demote" "" in
  let store = Tool_blob_store.create ~base_path in
  Alcotest.(check (option int)) "the refused range carries demotable results" (Some 3)
    (demotion_after_refusal ~base_path ~front:2 ~turn_end messages);
  (* The range is the newest atom alone, as a walk that evicted every older
     block and a halving that reached one atom leave it. *)
  let composed =
    compose ~base_path ~front:2 ~current_turn_results:(demoted_after_refusal messages)
      ~turn_end messages
  in
  Alcotest.(check int)
    "each of the newest atom's results is demoted"
    (List.length newest_bodies)
    (List.length composed.Try_provider.planned.Demotion.pending);
  Alcotest.(check int)
    "the denominator is still the whole history"
    3
    composed.Try_provider.history_atom_count;
  let outcome =
    Demotion.materialize
      ~store
      ~addresses:(Demotion.create_address_memo ())
      ~pending:composed.Try_provider.planned.Demotion.pending
      composed.Try_provider.projection.Window.messages
  in
  Alcotest.(check int) "a healthy store reverts nothing" 0 outcome.Demotion.reverted;
  let transmitted = markers outcome.Demotion.messages in
  List.iteri
    (fun i size ->
       let body = String.make size (Char.chr (Char.code 'a' + i)) in
       Alcotest.(check bool)
         (Printf.sprintf "body %d left as a reference, not its bytes" i)
         false
         (List.exists (String.equal body) transmitted))
    newest_bodies;
  Alcotest.(check int)
    "the references are readable blob markers"
    (List.length newest_bodies)
    (List.length (List.filter Tool_output.is_marker transmitted))
;;

(* Without a refusal nothing the range carries is demoted, whatever its size
   (RFC-0363 §3.4.1). *)
let an_ordinary_composition_demotes_nothing () =
  let earlier, messages, newest_bytes = oversized_newest_history () in
  let turn_end =
    Window.first_atom_at_or_after
      messages
      ~message_index:(List.length earlier)
  in
  let composed =
    compose ~base_path:(Filename.temp_dir "demote" "") ~front:2
      ~current_turn_results:Try_provider.Current_turn_verbatim ~turn_end messages
  in
  Alcotest.(check int) "nothing is demoted" 0
    (List.length composed.Try_provider.planned.Demotion.pending);
  (* A range that starts mid-history goes out with the window's synthetic
     preamble in front of it, so the request is the newest atom verbatim plus
     that one message — not the atom's bytes alone. *)
  let projected = composed.Try_provider.projection.Window.messages in
  let newest = List.filter (fun m -> not (List.mem m earlier)) messages in
  let preamble = List.filter (fun m -> not (List.mem m newest)) projected in
  Alcotest.(check int) "one preamble rides with the range"
    (List.length newest + 1) (List.length projected);
  Alcotest.(check int) "the newest atom goes whole beside the preamble"
    (newest_bytes + bytes_of preamble) composed.Try_provider.transmitted_bytes
;;

(* A refused atom with nothing demotable in it gives the resend nothing to
   change, and the refusal path is told so before a request is spent. *)
let an_atom_without_demotable_body_demotes_nothing () =
  let newest = [ assistant (String.make 50_000 'x') ] in
  let messages = history_with_tool_bodies [ "tick" ] @ newest in
  let base_path = Filename.temp_dir "demote" "" in
  Alcotest.(check (option int)) "nothing to demote" None
    (demotion_after_refusal ~base_path ~front:1 ~turn_end:1 messages);
  let composed =
    compose ~base_path ~front:1 ~current_turn_results:(demoted_after_refusal messages)
      ~turn_end:1 messages
  in
  Alcotest.(check int) "and a demoting composition plans nothing" 0
    (List.length composed.Try_provider.planned.Demotion.pending);
  Alcotest.(check int)
    "the newest atom is what is transmitted"
    (List.length newest + 1 (* the preamble: the kept head is an assistant *))
    (List.length composed.Try_provider.projection.Window.messages)
;;

(* Without a blob store there is nothing a marker could reference. *)
let demotion_after_refusal_requires_a_blob_store () =
  let _, messages, _ = oversized_newest_history () in
  Alcotest.(check (option int)) "nothing to demote without a store" None
    (demotion_after_refusal ~base_path:"" ~front:2 ~turn_end:2 messages);
  let composed =
    compose ~base_path:"" ~front:2 ~current_turn_results:(demoted_after_refusal messages)
      ~turn_end:2 messages
  in
  Alcotest.(check int) "nothing is planned without a store" 0
    (List.length composed.Try_provider.planned.Demotion.pending)
;;

(* A provider that refuses any request carrying more than [window] bytes,
   driven through the refusal path's sequence the way the Agent Core lane
   drives it: the first request composes the range as it is, a size refusal
   asks whether demoting the refused request's results would change it, and
   the resend composes under that decision. [window] is the fake provider's
   limit, not anything masc measures. *)
type sent =
  { mutable compositions : Try_provider.composed list
  ; mutable demoted_through : int list
  }

let drive ?(gate = fun () -> true) ?(refuse_resend = false) ~base_path ~front ~turn_end
      ~window messages =
  let results = ref Try_provider.Current_turn_verbatim in
  let sent = { compositions = []; demoted_through = [] } in
  let overflow =
    Agent_core.Error.Api
      (Agent_core.Retry.ContextOverflow { message = "prompt is too long"; limit = None })
  in
  let attempt () =
    let composed =
      compose ~base_path ~front ~current_turn_results:!results ~turn_end messages
    in
    sent.compositions <- composed :: sent.compositions;
    let refused_after_demotion = refuse_resend && List.length sent.compositions > 1 in
    if composed.Try_provider.transmitted_bytes > window || refused_after_demotion
    then Error overflow
    else Ok composed
  in
  let outcome =
    Try_provider.current_turn_demotion_sequence
      ~same_run_retry_authorized:gate
      ~demotable:(fun () -> demotion_after_refusal ~base_path ~front ~turn_end messages)
      ~demote:(fun _error ~refused_atom_count ->
        sent.demoted_through <- refused_atom_count :: sent.demoted_through;
        results := Try_provider.Current_turn_demoted { refused_atom_count })
      ~first:attempt
      ~resend:attempt
      ()
  in
  outcome, sent
;;

let current_turn_setup () =
  let earlier, messages, newest_bytes = oversized_newest_history () in
  let turn_end =
    Window.first_atom_at_or_after messages ~message_index:(List.length earlier)
  in
  messages, turn_end, newest_bytes / 2
;;

let a_refused_turn_resends_its_results_as_markers_once () =
  let messages, turn_end, window = current_turn_setup () in
  let base_path = Filename.temp_dir "demote" "" in
  let outcome, sent = drive ~base_path ~front:0 ~turn_end ~window messages in
  Alcotest.(check int) "refused, then resent once" 2 (List.length sent.compositions);
  Alcotest.(check (list int)) "demoted through the refused request's atoms" [ 3 ]
    sent.demoted_through;
  (match List.rev sent.compositions with
   | [ refused; resent ] ->
     Alcotest.(check int) "the refused request carried the current turn verbatim" 0
       (List.length refused.Try_provider.planned.Demotion.pending);
     Alcotest.(check bool) "the refused request was over the window" true
       (refused.Try_provider.transmitted_bytes > window);
     Alcotest.(check int) "the range is not narrowed"
       refused.Try_provider.projection.Window.dropped_atoms
       resent.Try_provider.projection.Window.dropped_atoms;
     (* The earlier turns' bodies are too small for a marker to shorten, so
        every planned demotion is one of this turn's results. *)
     Alcotest.(check int) "every current-turn result goes as a marker"
       (List.length newest_bodies)
       (List.length resent.Try_provider.planned.Demotion.pending);
     Alcotest.(check bool) "the resend fits the window" true
       (resent.Try_provider.transmitted_bytes <= window)
   | _ -> Alcotest.fail "two compositions");
  match outcome with
  | Ok accepted ->
    let transmitted =
      markers
        (Demotion.materialize
           ~store:(Tool_blob_store.create ~base_path)
           ~addresses:(Demotion.create_address_memo ())
           ~pending:accepted.Try_provider.planned.Demotion.pending
           accepted.Try_provider.projection.Window.messages)
          .Demotion.messages
    in
    Alcotest.(check int) "the accepted request names each current-turn body by marker"
      (List.length newest_bodies)
      (List.length (List.filter Tool_output.is_marker transmitted))
  | Error _ -> Alcotest.fail "the demoted resend was accepted"
;;

let a_refused_turn_with_nothing_to_demote_is_not_resent () =
  let newest = [ assistant (String.make 50_000 'x') ] in
  let messages = history_with_tool_bodies [ "tick" ] @ newest in
  let base_path = Filename.temp_dir "demote" "" in
  let outcome, sent = drive ~base_path ~front:0 ~turn_end:1 ~window:25_000 messages in
  Alcotest.(check bool) "the refusal is returned" true (Result.is_error outcome);
  Alcotest.(check int) "asked once" 1 (List.length sent.compositions);
  Alcotest.(check (list int)) "nothing demoted" [] sent.demoted_through
;;

let a_refused_resend_returns_the_refusal () =
  let messages, turn_end, window = current_turn_setup () in
  let base_path = Filename.temp_dir "demote" "" in
  let outcome, sent =
    drive ~refuse_resend:true ~base_path ~front:0 ~turn_end ~window messages
  in
  Alcotest.(check bool) "the resend's refusal is returned" true (Result.is_error outcome);
  Alcotest.(check int) "asked twice, never a third time" 2 (List.length sent.compositions)
;;

let no_resend_after_a_checkpoint_or_another_error () =
  let messages, turn_end, window = current_turn_setup () in
  let base_path = Filename.temp_dir "demote" "" in
  let outcome, sent =
    drive ~gate:(fun () -> false) ~base_path ~front:0 ~turn_end ~window messages
  in
  Alcotest.(check bool) "the refusal is returned" true (Result.is_error outcome);
  Alcotest.(check int) "asked once after a durable checkpoint" 1 (List.length sent.compositions);
  let asked = ref 0 in
  let rate_limited =
    Try_provider.current_turn_demotion_sequence
      ~same_run_retry_authorized:(fun () -> true)
      ~demotable:(fun () -> Some 3)
      ~demote:(fun _ ~refused_atom_count:_ -> Alcotest.fail "a rate limit demoted")
      ~first:(fun () ->
        incr asked;
        Error
          (Agent_core.Error.Api
             (Agent_core.Retry.RateLimited { retry_after = None; message = "slow down" })))
      ~resend:(fun () -> Alcotest.fail "a rate limit was resent")
      ()
  in
  Alcotest.(check bool) "a rate limit is returned" true (Result.is_error rate_limited);
  Alcotest.(check int) "asked once" 1 !asked
;;

let current_batch ~id_prefix ~fill sizes =
  assistant (id_prefix ^ " batch")
  :: List.mapi
       (fun i size ->
          tool_message ~id:(Printf.sprintf "%s-%d" id_prefix i) (String.make size (fill i)))
       sizes
;;

let compose_from_the_oldest_atom ?completed_arguments ?finished_turn_results
      ?(measure_wire_bytes = stored_wire_bytes) ~base_path ~current_turn_results ~turn_boundary
      messages =
  Try_provider.For_testing.compose_carried_model_input
    ?completed_arguments
    ?finished_turn_results
    ~measure_message_bytes
    ~measure_wire_bytes
    ~accepted:None ~front:
      (Some
         { Masc.Keeper_carried_front.first_atom = 0
         ; front = Model_input_front.At_atom (Option.get (Window.atom_opening_digest messages 0))
         ; source = Masc.Keeper_carried_front.Ledger
         })
    ~history_digest_at:(Window.atom_opening_digest messages)
    ~current_turn_results
    ~base_path
    ~turn_boundary
    messages
;;

let letter i = Char.chr (Char.code 'a' + i)

(* A refused request goes again with every result it carried as a marker,
   earlier turns' included and the ones under the finished-turn floor too:
   the resend is the smallest this range can carry, whichever turn boundary
   the history reports. *)
let a_refusal_demotes_every_result_it_carried () =
  let under_the_floor = String.make 1_000 'g' in
  Alcotest.(check bool) "one earlier body is under the finished-turn floor" true
    (String.length under_the_floor < Try_provider.For_testing.aged_result_min_bytes);
  let earlier_bodies =
    [ String.make 20_000 'e'; String.make 21_000 'f'; under_the_floor ]
  in
  let earlier = history_with_tool_bodies earlier_bodies in
  let messages = earlier @ current_batch ~id_prefix:"search" ~fill:letter newest_bodies in
  let turn_start =
    Window.first_atom_at_or_after messages ~message_index:(List.length earlier)
  in
  let base_path = Filename.temp_dir "demote" "" in
  let compose_with turn_boundary =
    compose_from_the_oldest_atom ~base_path
      ~current_turn_results:(demoted_after_refusal messages) ~turn_boundary messages
  in
  let composed =
    compose_with (Masc.Keeper_carried_front.Turn_boundary { end_atom = turn_start })
  in
  Alcotest.(check int) "the range still opens on the earlier turns" 0
    composed.Try_provider.projection.Window.dropped_atoms;
  Alcotest.(check int) "the demotion reaches the refused request's end"
    (snd (Window.annotate messages)) composed.Try_provider.demote_before;
  Alcotest.(check int) "every result of the refused request is planned"
    (List.length earlier_bodies + List.length newest_bodies)
    (List.length composed.Try_provider.planned.Demotion.pending);
  let carried = markers composed.Try_provider.projection.Window.messages in
  List.iter
    (fun body ->
       Alcotest.(check bool) "an earlier-turn body leaves" false
         (List.exists (String.equal body) carried))
    earlier_bodies;
  List.iteri
    (fun i size ->
       Alcotest.(check bool)
         (Printf.sprintf "current-turn body %d leaves" i)
         false
         (List.exists (String.equal (String.make size (letter i))) carried))
    newest_bodies;
  let unknown =
    compose_with (Masc.Keeper_carried_front.Turn_boundary_unknown { reason = "unreadable" })
  in
  Alcotest.(check int) "an unknown boundary plans the same demotions"
    (List.length composed.Try_provider.planned.Demotion.pending)
    (List.length unknown.Try_provider.planned.Demotion.pending)
;;

(* RFC-0363 §6 test 1 across a turn boundary: the next turn's first request
   carries every message the last one sent, unchanged, ahead of the new atoms.
   The bodies are large enough that a marker would shorten each of them, so a
   boundary that demoted completed turns would rewrite them here. This is the
   default path, [Finished_turns_verbatim]; what a Keeper that asks for the
   results of ended turns as markers sends instead is
   [a_finished_turn_result_changes_once_and_its_marker_stays]. *)
let a_sent_result_stays_as_sent_when_the_turn_boundary_moves () =
  let earlier = history_with_tool_bodies [ String.make 20_000 'e'; String.make 21_000 'f' ] in
  let this_turn = earlier @ current_batch ~id_prefix:"search" ~fill:letter newest_bodies in
  let next_turn =
    this_turn @ current_batch ~id_prefix:"next" ~fill:(fun _ -> 'n') [ 9_000 ]
  in
  let base_path = Filename.temp_dir "demote" "" in
  let compose_at messages ~completed_before =
    compose_from_the_oldest_atom ~base_path
      ~current_turn_results:Try_provider.Current_turn_verbatim
      ~turn_boundary:(Masc.Keeper_carried_front.Turn_boundary { end_atom = completed_before })
      messages
  in
  let last =
    compose_at this_turn
      ~completed_before:(Window.first_atom_at_or_after this_turn ~message_index:(List.length earlier))
  in
  let next =
    compose_at next_turn
      ~completed_before:(Window.first_atom_at_or_after next_turn ~message_index:(List.length this_turn))
  in
  Alcotest.(check int) "the last request demoted nothing" 0
    (List.length last.Try_provider.planned.Demotion.pending);
  Alcotest.(check int) "the next request demotes nothing" 0
    (List.length next.Try_provider.planned.Demotion.pending);
  let sent = last.Try_provider.projection.Window.messages in
  let carried = next.Try_provider.projection.Window.messages in
  Alcotest.(check bool) "the next request opens with exactly what the last one sent" true
    (List.filteri (fun index _ -> index < List.length sent) carried = sent);
  Alcotest.(check int) "and carries the new atom after it"
    (List.length sent + 2) (List.length carried)
;;

(* --- Results of turns that ended go as markers (RFC-tool-results-age-out-of-context) --- *)

let as_markers = Try_provider.Finished_turns_as_markers

let finished_turns_through end_atom = Masc.Keeper_carried_front.Turn_boundary { end_atom }

(* A result whose long [content] goes out on Gemini and whose [Text] blocks
   are each shorter than a marker. Anthropic sends only the blocks, so a
   marker in [content] would change nothing it sends: nothing is chosen, and
   a size refusal on Anthropic has nothing to resend. Under the stored JSON,
   which counts both, the same result would have asked for a resend that
   carries the same blocks. *)
let a_body_the_lane_does_not_send_asks_for_no_resend () =
  let anthropic =
    match List.find_opt (fun (lane, _, _) -> String.equal lane "anthropic") structured_lanes with
    | Some (_, measure, _) -> measure
    | None -> Alcotest.fail "the anthropic lane is listed"
  in
  let short = String.make 200 't' in
  let messages =
    structured_cycle ~id:"long" ~content:(String.make 9_000 'q') [ Types.Text short; Types.Text short ]
    @ [ assistant "this turn" ]
  in
  let base_path = Filename.temp_dir "demote" "" in
  let refused_atom_count = snd (Window.annotate messages) in
  let compose ~measure_wire_bytes current_turn_results =
    compose_from_the_oldest_atom ~measure_wire_bytes ~base_path ~current_turn_results
      ~turn_boundary:(finished_turns_through 0) messages
  in
  let resend measure_wire_bytes =
    Try_provider.For_testing.current_turn_demotion
      ~refused:(compose ~measure_wire_bytes Try_provider.Current_turn_verbatim)
      ~demoted:
        (compose ~measure_wire_bytes (Try_provider.Current_turn_demoted { refused_atom_count }))
  in
  Alcotest.(check (option int)) "anthropic: no resend" None (resend anthropic);
  Alcotest.(check (option int)) "the stored JSON would resend" (Some refused_atom_count)
    (resend stored_wire_bytes)
;;

(* The composition's messages with their markers written to a store under
   [base_path], the way one provider attempt sends them. *)
let materialized ~base_path (composed : Try_provider.composed) =
  let outcome =
    Demotion.materialize
      ~store:(Tool_blob_store.create ~base_path)
      ~addresses:(Demotion.create_address_memo ())
      ~pending:composed.Try_provider.planned.Demotion.pending
      composed.Try_provider.projection.Window.messages
  in
  Alcotest.(check int) "a healthy store reverts nothing" 0 outcome.Demotion.reverted;
  outcome.Demotion.messages
;;

let without_preamble messages =
  List.filter (fun message -> not (Window.is_synthetic_preamble message)) messages
;;

let call_with_input ~id input : Types.message =
  { origin = Llm_provider.Types.Conversation;  role = Types.Assistant
  ; content = [ Types.ToolUse { id; name = "read_file"; input } ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let take count list = List.filteri (fun index _ -> index < count) list

(* The longest run of messages the two requests share from the start. *)
let rec shared_prefix first second =
  match first, second with
  | a :: rest_a, b :: rest_b when a = b -> 1 + shared_prefix rest_a rest_b
  | _ -> 0
;;

(* A result of a turn that ended leaves as a marker the blob store reads back
   in full, this turn's results stay as they are, and no argument is
   touched, whatever its size. The ended turns' arguments are bound the way
   a size refusal's resend binds them; this composition still leaves them. *)
let finished_turn_results_leave_as_markers () =
  let big_input = `Assoc [ "command", `String (String.make 4_000 'h') ] in
  let earlier_bodies = [ String.make 20_000 'e'; String.make 21_000 'f' ] in
  let earlier =
    List.concat
      (List.mapi
         (fun i body ->
            [ call_with_input ~id:(Printf.sprintf "old-%d" i) big_input
            ; tool_message ~id:(Printf.sprintf "old-%d" i) body
            ])
         earlier_bodies)
  in
  let messages = earlier @ current_batch ~id_prefix:"search" ~fill:letter newest_bodies in
  let turn_start =
    Window.first_atom_at_or_after messages ~message_index:(List.length earlier)
  in
  let base_path = Filename.temp_dir "demote" "" in
  let completed_arguments =
    bind_arguments ~completed_before:turn_start ~seed:messages messages
  in
  let composed =
    compose_from_the_oldest_atom ~completed_arguments ~finished_turn_results:as_markers
      ~base_path ~current_turn_results:Try_provider.Current_turn_verbatim
      ~turn_boundary:(finished_turns_through turn_start) messages
  in
  Alcotest.(check int) "the demotion stops at the turn boundary" turn_start
    composed.Try_provider.demote_before;
  Alcotest.(check int) "each result of an ended turn is planned"
    (List.length earlier_bodies)
    (List.length composed.Try_provider.planned.Demotion.pending);
  let sent = materialized ~base_path composed in
  let carried = markers sent in
  List.iter
    (fun body ->
       Alcotest.(check bool) "an ended turn's body leaves" false
         (List.exists (String.equal body) carried);
       let reference =
         match
           List.find_map
             (fun content ->
                match Tool_output.decode_from_agent_core content with
                | Tool_output.Decoded reference
                  when reference.Tool_output.bytes = String.length body -> Some reference
                | Tool_output.Decoded _ | Tool_output.Not_marker
                | Tool_output.Invalid_marker _ -> None)
             carried
         with
         | Some reference -> reference
         | None -> Alcotest.fail "no marker names this body"
       in
       match Tool_blob_store.fetch (Tool_blob_store.create ~base_path)
               ~sha256:reference.Tool_output.sha256 with
       | Ok (Some bytes) -> Alcotest.(check string) "the marker reads back the exact body" body bytes
       | Ok None | Error _ -> Alcotest.fail "the marker's blob is not stored")
    earlier_bodies;
  List.iteri
    (fun i size ->
       Alcotest.(check bool)
         (Printf.sprintf "this turn's body %d stays in the prompt" i)
         true
         (List.exists (String.equal (String.make size (letter i))) carried))
    newest_bodies;
  Alcotest.(check bool) "every argument is exactly as it was" true
    (List.for_all
       (fun (message : Types.message) ->
          List.for_all
            (function
              | Types.ToolUse { input; _ } -> input = big_input
              | Types.Text _ | Types.ToolResult _ | Types.Thinking _
              | Types.ReasoningDetails _ | Types.RedactedThinking _ | Types.Image _
              | Types.Document _ | Types.Audio _ -> true)
            message.Types.content)
       sent);
  (* Control: the same bound arguments are demoted by the resend that answers
     a size refusal, so the check above would fail if this composition used
     them. *)
  let refused =
    compose_from_the_oldest_atom ~completed_arguments ~base_path
      ~current_turn_results:(demoted_after_refusal messages)
      ~turn_boundary:(finished_turns_through turn_start) messages
  in
  Alcotest.(check bool) "a size refusal's resend does demote these arguments" true
    (List.exists
       (fun input -> input <> big_input)
       (argument_inputs refused.Try_provider.projection.Window.messages))
;;

(* A result goes as a marker from [aged_result_min_bytes] on; a smaller one
   stays readable. *)
let results_below_the_floor_stay_in_the_prompt () =
  let floor = Try_provider.For_testing.aged_result_min_bytes in
  let bodies =
    [ String.make (floor - 1) 'a'; String.make floor 'b'; String.make (floor + 1) 'c' ]
  in
  let earlier = history_with_tool_bodies bodies in
  let messages = earlier @ [ assistant "this turn" ] in
  let turn_start =
    Window.first_atom_at_or_after messages ~message_index:(List.length earlier)
  in
  let base_path = Filename.temp_dir "demote" "" in
  let composed =
    compose_from_the_oldest_atom ~finished_turn_results:as_markers ~base_path
      ~current_turn_results:Try_provider.Current_turn_verbatim
      ~turn_boundary:(finished_turns_through turn_start) messages
  in
  Alcotest.(check int) "the floor and the sizes above it are planned" 2
    (List.length composed.Try_provider.planned.Demotion.pending);
  let carried = markers (materialized ~base_path composed) in
  Alcotest.(check bool) "one byte under the floor stays" true
    (List.exists (String.equal (List.nth bodies 0)) carried);
  Alcotest.(check bool) "the floor itself leaves" false
    (List.exists (String.equal (List.nth bodies 1)) carried);
  Alcotest.(check bool) "one byte over the floor leaves" false
    (List.exists (String.equal (List.nth bodies 2)) carried)
;;

(* The floor checks the whole result, as it checks a string result: a result
   whose text is split over small blocks is as large as their sum. *)
let structured_bodies_below_the_floor_stay_in_the_prompt () =
  let floor = Try_provider.For_testing.aged_result_min_bytes in
  let under = String.make (floor - 1) 'u' in
  let at = String.make floor 'v' in
  let first_half = String.make (floor / 2) 'h' and second_half = String.make (floor / 2) 'i' in
  let result ~id body = structured_result ~id ~content:body [ Types.Text body ] in
  let earlier =
    [ assistant "call 0"; result ~id:"under" under; assistant "call 1"; result ~id:"at" at
    ; assistant "call 2"
    ; structured_result ~id:"split" ~content:"" [ Types.Text first_half; Types.Text second_half ]
    ]
  in
  let messages = earlier @ [ assistant "this turn" ] in
  let turn_start =
    Window.first_atom_at_or_after messages ~message_index:(List.length earlier)
  in
  let base_path = Filename.temp_dir "demote" "" in
  let composed =
    compose_from_the_oldest_atom ~finished_turn_results:as_markers ~base_path
      ~current_turn_results:Try_provider.Current_turn_verbatim
      ~turn_boundary:(finished_turns_through turn_start) messages
  in
  Alcotest.(check int) "both bodies at the floor and both halves of the split result are planned" 4
    (List.length composed.Try_provider.planned.Demotion.pending);
  let carried = List.concat_map result_texts (materialized ~base_path composed) in
  Alcotest.(check int) "one byte under the floor, both bodies stay" 2
    (List.length (List.filter (String.equal under) carried));
  Alcotest.(check bool) "at the floor, neither body stays" false
    (List.exists (String.equal at) carried);
  Alcotest.(check bool) "two halves that reach the floor together leave as markers" false
    (List.exists (fun text -> String.equal text first_half || String.equal text second_half) carried)
;;

(* The stuck shape of msx-retro-mania on 2026-11-06: every result of the
   refused turn was an MCP result with blocks, so the refusal found nothing
   to demote and the same request was refused again. *)
let a_refusal_demotes_structured_results () =
  let earlier = history_with_tool_bodies [ "tick"; "tock" ] in
  let newest =
    assistant "screens"
    :: List.init 4 (fun i ->
      let body = String.make 9_000 (letter i) in
      structured_result ~id:(Printf.sprintf "shot-%d" i) ~content:body
        [ Types.Text body; screenshot () ])
  in
  let messages = earlier @ newest in
  let turn_end =
    Window.first_atom_at_or_after messages ~message_index:(List.length earlier)
  in
  Alcotest.(check (option int)) "the refused range has results to demote" (Some 3)
    (demotion_after_refusal ~base_path:(Filename.temp_dir "demote" "") ~front:2 ~turn_end
       messages)
;;

(* The cache property the rule is priced on. A result is rewritten once, on
   the first request after its turn ended, and goes as the same marker on
   every later request: the next turn's request opens with what the last one
   sent up to the first result that just aged, and a request later in the
   same turn opens with the whole of the one before it. *)
let a_finished_turn_result_changes_once_and_its_marker_stays () =
  let old_turn = history_with_tool_bodies [ String.make 20_000 'e'; String.make 21_000 'f' ] in
  let turn_a = current_batch ~id_prefix:"a" ~fill:letter [ 9_000; 11_000 ] in
  let turn_b = current_batch ~id_prefix:"b" ~fill:(fun _ -> 'n') [ 9_000 ] in
  let later_in_b = current_batch ~id_prefix:"c" ~fill:(fun _ -> 'm') [ 5_000 ] in
  let base_path = Filename.temp_dir "demote" "" in
  let request messages ~finished_prefix =
    let composed =
      compose_from_the_oldest_atom ~finished_turn_results:as_markers ~base_path
        ~current_turn_results:Try_provider.Current_turn_verbatim
        ~turn_boundary:
          (finished_turns_through
             (Window.first_atom_at_or_after messages ~message_index:(List.length finished_prefix)))
        messages
    in
    composed, without_preamble (materialized ~base_path composed)
  in
  let in_a, sent_in_a = request (old_turn @ turn_a) ~finished_prefix:old_turn in
  let in_b, sent_in_b =
    request (old_turn @ turn_a @ turn_b) ~finished_prefix:(old_turn @ turn_a)
  in
  let _, sent_later_in_b =
    request (old_turn @ turn_a @ turn_b @ later_in_b) ~finished_prefix:(old_turn @ turn_a)
  in
  Alcotest.(check int) "turn A's request rewrites the old turn's two results" 2
    (List.length in_a.Try_provider.planned.Demotion.pending);
  Alcotest.(check int) "turn B's request adds turn A's two" 4
    (List.length in_b.Try_provider.planned.Demotion.pending);
  Alcotest.(check bool) "the old turn's markers are the same bytes in turn B" true
    (take (List.length old_turn) sent_in_b = take (List.length old_turn) sent_in_a);
  (* The old turn's four messages, then turn A's call: all unchanged. The
     first message to differ is turn A's first result. *)
  Alcotest.(check int) "turn B's request first differs at turn A's first result"
    (List.length old_turn + 1)
    (shared_prefix sent_in_a sent_in_b);
  Alcotest.(check bool) "a later request of the same turn opens with the one before it" true
    (take (List.length sent_in_b) sent_later_in_b = sent_in_b)
;;

(* Nothing is known about which turns ended, so nothing is demoted; a Keeper
   with no blob store has nothing a marker could name; and the setting is off
   unless the caller asks. *)
let finished_turns_stay_verbatim_unless_they_can_be_read_back () =
  let earlier = history_with_tool_bodies [ String.make 20_000 'e' ] in
  let messages = earlier @ [ assistant "this turn" ] in
  let turn_start =
    Window.first_atom_at_or_after messages ~message_index:(List.length earlier)
  in
  let compose_with ?finished_turn_results ~base_path turn_boundary =
    compose_from_the_oldest_atom ?finished_turn_results ~base_path
      ~current_turn_results:Try_provider.Current_turn_verbatim ~turn_boundary messages
  in
  let planned (composed : Try_provider.composed) =
    List.length composed.Try_provider.planned.Demotion.pending
  in
  let base_path = Filename.temp_dir "demote" "" in
  let unknown =
    compose_with ~finished_turn_results:as_markers ~base_path
      (Masc.Keeper_carried_front.Turn_boundary_unknown { reason = "unreadable" })
  in
  Alcotest.(check int) "an unknown turn boundary plans nothing" 0 (planned unknown);
  Alcotest.(check int) "and applies no boundary" 0 unknown.Try_provider.demote_before;
  let no_store =
    compose_with ~finished_turn_results:as_markers ~base_path:""
      (finished_turns_through turn_start)
  in
  Alcotest.(check int) "no store plans nothing" 0 (planned no_store);
  Alcotest.(check int) "and applies no boundary" 0 no_store.Try_provider.demote_before;
  let not_asked = compose_with ~base_path (finished_turns_through turn_start) in
  Alcotest.(check int) "a caller that does not ask gets every result as sent" 0
    (planned not_asked);
  Alcotest.(check int) "with no boundary applied" 0 not_asked.Try_provider.demote_before;
  let asked = compose_with ~finished_turn_results:as_markers ~base_path (finished_turns_through turn_start) in
  Alcotest.(check int) "asked, with a known boundary and a store, it plans the result" 1
    (planned asked)
;;

(* The driver asks for markers only for a Keeper that can read them back. *)
let only_a_keeper_with_a_reader_asks_for_markers () =
  let asks reader_available =
    Try_provider.finished_turn_results_for ~reader_available = as_markers
  in
  Alcotest.(check bool) "with a reader" true (asks true);
  Alcotest.(check bool) "without a reader" false (asks false)
;;

(* A turn boundary at the end of the history names the newest atom as ended.
   That atom is what the request has to answer, so it keeps its results. *)
let the_newest_atom_keeps_its_results () =
  let bodies = [ String.make 20_000 'e'; String.make 21_000 'f' ] in
  let messages = history_with_tool_bodies bodies in
  let atom_count = snd (Window.annotate messages) in
  let base_path = Filename.temp_dir "demote" "" in
  let composed =
    compose_from_the_oldest_atom ~finished_turn_results:as_markers ~base_path
      ~current_turn_results:Try_provider.Current_turn_verbatim
      ~turn_boundary:(finished_turns_through atom_count) messages
  in
  Alcotest.(check int) "the boundary stops before the newest atom" (atom_count - 1)
    composed.Try_provider.demote_before;
  Alcotest.(check int) "only the older result is planned" 1
    (List.length composed.Try_provider.planned.Demotion.pending);
  Alcotest.(check bool) "the newest result is in the prompt as it is" true
    (List.exists (String.equal (List.nth bodies 1))
       (markers composed.Try_provider.projection.Window.messages))
;;

(* The resend that answers a size refusal demotes every result of the refused
   request whatever the setting: it is the smallest the range can carry. *)
let a_refusal_resend_ignores_the_finished_turn_setting () =
  let earlier = history_with_tool_bodies [ String.make 20_000 'e'; "tiny" ] in
  let messages = earlier @ current_batch ~id_prefix:"search" ~fill:letter newest_bodies in
  let turn_start =
    Window.first_atom_at_or_after messages ~message_index:(List.length earlier)
  in
  let base_path = Filename.temp_dir "demote" "" in
  let resend ?finished_turn_results () =
    compose_from_the_oldest_atom ?finished_turn_results ~base_path
      ~current_turn_results:(demoted_after_refusal messages)
      ~turn_boundary:(finished_turns_through turn_start) messages
  in
  let plain = resend () and asked = resend ~finished_turn_results:as_markers () in
  Alcotest.(check int) "the same boundary" plain.Try_provider.demote_before
    asked.Try_provider.demote_before;
  Alcotest.(check int) "the same demotions"
    (List.length plain.Try_provider.planned.Demotion.pending)
    (List.length asked.Try_provider.planned.Demotion.pending);
  Alcotest.(check int) "the same bytes" plain.Try_provider.transmitted_bytes
    asked.Try_provider.transmitted_bytes
;;

(* A request that carried the ended turns as markers is not itself a reason
   to resend: only a result still verbatim in it is. *)
let a_request_with_only_markers_has_nothing_left_to_demote () =
  let earlier = history_with_tool_bodies [ String.make 20_000 'e' ] in
  let messages = earlier @ [ assistant "this turn" ] in
  let turn_start =
    Window.first_atom_at_or_after messages ~message_index:(List.length earlier)
  in
  let base_path = Filename.temp_dir "demote" "" in
  let compose_under results =
    compose_from_the_oldest_atom ~finished_turn_results:as_markers ~base_path
      ~current_turn_results:results
      ~turn_boundary:(finished_turns_through turn_start) messages
  in
  Alcotest.(check (option int)) "the ended turn's result is already a marker" None
    (Try_provider.For_testing.current_turn_demotion
       ~refused:(compose_under Try_provider.Current_turn_verbatim)
       ~demoted:(compose_under (demoted_after_refusal messages)))
;;

(* The floor is a rule of [plan]: results below it keep their bodies, results
   at it and above are substituted exactly as without a floor. *)
let plan_keeps_results_below_the_floor () =
  let bodies = [ 1_500; 2_047; 2_048; 4_000; 9_000 ] in
  let messages =
    history_with_tool_bodies (List.map (fun size -> String.make size 'x') bodies)
  in
  let changed ?min_result_bytes () =
    let planned =
      Demotion.plan ~measure_wire_bytes:stored_wire_bytes ?min_result_bytes ~measure_message_bytes ~demote_before:max_int messages
    in
    List.map2 (fun before after -> before <> after) messages planned.Demotion.messages
  in
  let results_only flags =
    List.filteri (fun index _ -> index mod 2 = 1) flags
  in
  let with_floor = results_only (changed ~min_result_bytes:2_048 ()) in
  let without_floor = results_only (changed ()) in
  Alcotest.(check (list bool)) "below the floor nothing is substituted"
    [ false; false; true; true; true ] with_floor;
  (* Without a floor the two small results are substituted as well: the floor
     alone keeps them in the prompt. *)
  Alcotest.(check (list bool)) "without a floor every result is substituted"
    [ true; true; true; true; true ] without_floor
;;

(* Demotion can shrink an atom only down to its non-demotable residue. The
   demoted view goes out and the provider judges it. *)
let still_oversized_after_demotion_is_transmitted_demoted () =
  let earlier = history_with_tool_bodies [ "tick" ] in
  let residue = assistant (String.make 50_000 'x') in
  let newest =
    residue
    :: [ tool_message ~id:"big-0" (String.make 4_000 'a')
       ; tool_message ~id:"big-1" (String.make 4_000 'b')
       ]
  in
  let messages = earlier @ newest in
  let composed =
    compose ~base_path:(Filename.temp_dir "demote" "") ~front:1
      ~current_turn_results:(demoted_after_refusal messages) ~turn_end:1 messages
  in
  Alcotest.(check int) "both results were demoted" 2
    (List.length composed.Try_provider.planned.Demotion.pending);
  Alcotest.(check bool) "the demoted view is smaller than the raw atom" true
    (composed.Try_provider.transmitted_bytes < bytes_of newest)
;;

(* A front measured at an atom this history does not have names no atom of
   it: the composition starts over without it and says which seed it dropped
   and why. *)
let a_front_the_history_shrank_under_starts_over () =
  let _, messages, _ = oversized_newest_history () in
  let composed =
    Try_provider.For_testing.compose_carried_model_input
      ~measure_message_bytes
      ~measure_wire_bytes:stored_wire_bytes
      ~accepted:None ~front:
        (Some
           { Masc.Keeper_carried_front.first_atom = 3_100
           ; front = Model_input_front.At_atom (String.make 64 'f')
           ; source = Masc.Keeper_carried_front.Ledger
           })
      ~history_digest_at:(Window.atom_opening_digest messages)
      ~current_turn_results:Try_provider.Current_turn_verbatim
      ~base_path:""
      ~turn_boundary:(Masc.Keeper_carried_front.Turn_boundary { end_atom = 0 })
      messages
  in
  Alcotest.(check bool) "everything goes, from the turn start at atom 0" true
    (composed.Try_provider.origin = Masc.Keeper_carried_front.Turn_start { end_atom = 0 });
  Alcotest.(check int) "nothing dropped" 0 composed.Try_provider.projection.Window.dropped_atoms;
  Alcotest.(check bool) "the dropped seed is on record, with the missing atom as its reason" true
    (match composed.Try_provider.outlived_seed with
     | Some (_, Masc.Keeper_carried_front.Front_atom_missing) -> true
     | Some (_, Masc.Keeper_carried_front.Front_message_differs) | None -> false)
;;

(* The history has an atom at the front, but it opens with another message
   than the one the front was measured on: atoms before it were removed. The
   composition starts over and records that reason, not the missing-atom one. *)
let a_front_that_opens_with_another_message_starts_over () =
  let _, messages, _ = oversized_newest_history () in
  let composed =
    Try_provider.For_testing.compose_carried_model_input
      ~measure_message_bytes
      ~measure_wire_bytes:stored_wire_bytes
      ~accepted:None ~front:
        (Some
           { Masc.Keeper_carried_front.first_atom = 1
           ; front = Model_input_front.At_atom (String.make 64 'f')
           ; source = Masc.Keeper_carried_front.Ledger
           })
      ~history_digest_at:(Window.atom_opening_digest messages)
      ~current_turn_results:Try_provider.Current_turn_verbatim
      ~base_path:""
      ~turn_boundary:(Masc.Keeper_carried_front.Turn_boundary { end_atom = 0 })
      messages
  in
  Alcotest.(check bool) "atom 1 exists" true
    (Option.is_some (Window.atom_opening_digest messages 1));
  Alcotest.(check bool) "everything goes, from the turn start at atom 0" true
    (composed.Try_provider.origin = Masc.Keeper_carried_front.Turn_start { end_atom = 0 });
  Alcotest.(check int) "nothing dropped" 0 composed.Try_provider.projection.Window.dropped_atoms;
  Alcotest.(check bool) "the dropped seed is on record, with the other message as its reason" true
    (match composed.Try_provider.outlived_seed with
     | Some (_, Masc.Keeper_carried_front.Front_message_differs) -> true
     | Some (_, Masc.Keeper_carried_front.Front_atom_missing) | None -> false)
;;

let () =
  Alcotest.run
    "keeper_model_input_demotion"
    [ ( "bound"
      , [ Alcotest.test_case
            "demotion actually fires (suite is not vacuous)"
            `Quick
            demotion_actually_happens
        ; Alcotest.test_case "short aged result uses exact preview" `Quick short_aged_result_uses_exact_preview
        ; Alcotest.test_case "placeholder bounds the real marker" `Quick bound_is_sound
        ; Alcotest.test_case
            "this turn's results survive the boundary"
            `Quick
            this_turns_results_survive_the_boundary
        ; Alcotest.test_case
            "a turn that produced nothing demotes everything before it"
            `Quick
            a_turn_that_produced_nothing_demotes_everything_before_it
        ; Alcotest.test_case
            "a split atom at the boundary never gets demoted half"
            `Quick
            a_split_atom_at_the_boundary_never_gets_demoted_half
        ] )
    ; ( "exclusions"
      , [ Alcotest.test_case
            "invalid markers are not demoted"
            `Quick
            invalid_markers_are_not_demoted
        ; Alcotest.test_case
            "existing markers are not demoted again"
            `Quick
            stored_results_are_not_demoted_again
        ; Alcotest.test_case
            "each marker stores its own body"
            `Quick
            each_marker_stores_its_own_body
        ; Alcotest.test_case
            "raw-cut-retained atoms keep their bodies"
            `Quick
            raw_cut_retained_atoms_are_verbatim
        ] )
    ; ( "structured_results"
      , [ Alcotest.test_case "content and each Text block are demoted" `Quick
            structured_result_demotes_each_text_body
        ; Alcotest.test_case "a Text block shorter than its marker stays" `Quick
            a_text_block_shorter_than_its_marker_stays
        ; Alcotest.test_case "no provider wire carries a demoted body" `Quick
            structured_bodies_leave_every_provider_wire
        ; Alcotest.test_case "a short Korean block stays on lanes that escape twice" `Quick
            a_short_korean_block_stays_on_lanes_that_escape_twice
        ; Alcotest.test_case "a body the lane does not send asks for no resend" `Quick
            a_body_the_lane_does_not_send_asks_for_no_resend
        ; Alcotest.test_case "markers inside the blocks are left as they are" `Quick
            structured_markers_are_left_as_they_are
        ; Alcotest.test_case "a failed Text write keeps the written content" `Quick
            a_failed_text_write_keeps_the_written_content
        ; Alcotest.test_case "a failed content write keeps the written Text block" `Quick
            a_failed_content_write_keeps_the_written_text
        ; Alcotest.test_case "each body is stored and replayed" `Quick
            structured_bodies_are_stored_and_replayed
        ; Alcotest.test_case "the finished-turn floor counts the whole result" `Quick
            structured_bodies_below_the_floor_stay_in_the_prompt
        ; Alcotest.test_case "a refusal demotes structured results" `Quick
            a_refusal_demotes_structured_results
        ] )
    ; ( "stability"
      , [ Alcotest.test_case
            "plan honours a monotonic boundary"
            `Quick
            plan_honours_a_monotonic_boundary
        ; Alcotest.test_case
            "projection reuses candidate measurements"
            `Quick
            projection_reuses_candidate_measurements
         ] )
    ; ( "current_turn_after_refusal"
      , [ Alcotest.test_case
            "oversized newest atom is demoted after a refusal"
            `Quick
            oversized_newest_atom_is_demoted_after_refusal
        ; Alcotest.test_case
            "a refused turn resends its results as markers once"
            `Quick
            a_refused_turn_resends_its_results_as_markers_once
        ; Alcotest.test_case
            "a refusal demotes every result it carried"
            `Quick
            a_refusal_demotes_every_result_it_carried
        ; Alcotest.test_case
            "a sent result stays as sent when the turn boundary moves"
            `Quick
            a_sent_result_stays_as_sent_when_the_turn_boundary_moves
        ; Alcotest.test_case
            "a refused turn with nothing to demote is not resent"
            `Quick
            a_refused_turn_with_nothing_to_demote_is_not_resent
        ; Alcotest.test_case
            "the resend is refused too and the refusal stands"
            `Quick
            a_refused_resend_returns_the_refusal
        ; Alcotest.test_case
            "no resend after a durable checkpoint or a non-size error"
            `Quick
            no_resend_after_a_checkpoint_or_another_error
        ; Alcotest.test_case
            "an ordinary composition demotes nothing"
            `Quick
            an_ordinary_composition_demotes_nothing
        ; Alcotest.test_case
            "an atom without a demotable body demotes nothing"
            `Quick
            an_atom_without_demotable_body_demotes_nothing
        ; Alcotest.test_case
            "demotion after a refusal requires a blob store"
            `Quick
            demotion_after_refusal_requires_a_blob_store
        ; Alcotest.test_case
            "still oversized after demotion is transmitted demoted"
            `Quick
            still_oversized_after_demotion_is_transmitted_demoted
        ; Alcotest.test_case
            "a front the history shrank under starts over"
            `Quick
            a_front_the_history_shrank_under_starts_over
        ; Alcotest.test_case
            "a front that opens with another message starts over"
            `Quick
            a_front_that_opens_with_another_message_starts_over
        ] )
    ; ( "finished_turn_results"
      , [ Alcotest.test_case
            "results of ended turns leave as markers the store reads back"
            `Quick
            finished_turn_results_leave_as_markers
        ; Alcotest.test_case
            "results below the floor stay in the prompt"
            `Quick
            results_below_the_floor_stay_in_the_prompt
        ; Alcotest.test_case
            "a result changes once and its marker stays"
            `Quick
            a_finished_turn_result_changes_once_and_its_marker_stays
        ; Alcotest.test_case
            "ended turns stay verbatim unless they can be read back"
            `Quick
            finished_turns_stay_verbatim_unless_they_can_be_read_back
        ; Alcotest.test_case
            "only a Keeper with a reader asks for markers"
            `Quick
            only_a_keeper_with_a_reader_asks_for_markers
        ; Alcotest.test_case
            "the newest atom keeps its results"
            `Quick
            the_newest_atom_keeps_its_results
        ; Alcotest.test_case
            "a refusal resend ignores the setting"
            `Quick
            a_refusal_resend_ignores_the_finished_turn_setting
        ; Alcotest.test_case
            "a request with only markers has nothing left to demote"
            `Quick
            a_request_with_only_markers_has_nothing_left_to_demote
        ; Alcotest.test_case
            "plan keeps results below the floor"
            `Quick
            plan_keeps_results_below_the_floor
        ] )
    ; ( "measurement"
      , [ Alcotest.test_case
            "the measurer counts the same bytes as to_string"
            `Quick
            measurer_counts_the_same_bytes_as_to_string
        ; Alcotest.test_case
            "rebuilt records reuse earlier measurements"
            `Quick
            rebuilt_records_reuse_measurements
        ; Alcotest.test_case
            "the measurement hash reads content"
            `Quick
            measurement_hash_reads_content
        ] )
    ; ( "completed_arguments"
      , [ Alcotest.test_case "completed arguments restore through the existing paged reader" `Quick
            completed_arguments_restore_through_reader
        ; Alcotest.test_case "recovery and result resend cannot enlarge the frozen seed" `Quick
            argument_seed_never_expands_after_recovery
        ; Alcotest.test_case "complete cycle must precede completed boundary" `Quick
            arguments_require_the_complete_cycle_before_boundary
        ; Alcotest.test_case "rewritten seed is rejected" `Quick argument_binding_rejects_rewritten_seed
        ; Alcotest.test_case "media projection binds actual request occurrences" `Quick
            media_projection_binds_actual_argument_positions
        ; Alcotest.test_case "window cut and write failure retain exact source occurrences" `Quick
            argument_cut_and_failed_store_preserve_occurrences
        ; Alcotest.test_case "OpenAI Anthropic and Gemini actual wire bounds" `Quick
            arguments_obey_each_provider_wire_bound
        ; Alcotest.test_case "signed ToolUse retains its own exact arguments" `Quick
            signed_call_keeps_its_own_arguments
        ; Alcotest.test_case "signed prefix protects earlier occurrences and demotes later identical records" `Quick
            signed_prefix_protects_only_earlier_argument_occurrences
        ; Alcotest.test_case "signed prefix reproduces actual previously demoted arguments" `Quick
            signed_prefix_can_reproduce_already_demoted_arguments
        ; Alcotest.test_case "signed prefix follows empty-Assistant projection and Tool-User merge" `Quick
            signed_prefix_tracks_replay_projection_and_tool_user_merge
        ; Alcotest.test_case "signed prefix is revalidated after real write failure and later recovery" `Quick
            signed_prefix_revalidates_after_a_failed_store_write
        ; Alcotest.test_case "signed prefix comparisons replay the first mixed storage outcome" `Quick
            signed_prefix_replays_the_first_mixed_storage_outcome
        ] )
    ; ( "materialize"
      , [ Alcotest.test_case "reused IDs retain distinct exact payloads" `Quick
            repeated_ids_keep_distinct_payloads
        ; Alcotest.test_case "cut stores only the retained repeated-ID payload" `Quick
            cut_repeated_id_stores_only_retained_payload
        ; Alcotest.test_case "memo revalidates rewritten source" `Quick
            memo_revalidates_rewritten_source
        ; Alcotest.test_case "unplanned identical marker causes no write" `Quick
            unplanned_marker_does_not_bind_by_text
        ; Alcotest.test_case "write failures restore exact original blocks" `Quick
            failed_write_restores_each_original_block
        ; Alcotest.test_case
            "each body is addressed once per attempt, off this domain"
            `Quick
            materialize_addresses_each_body_once_per_attempt
        ] )
    ]
;;
