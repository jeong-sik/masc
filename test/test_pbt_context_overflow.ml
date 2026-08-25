(** Property-based tests for typed context overflow propagation. *)

module UT = Masc.Keeper_unified_turn
module KC = Masc.Keeper_context_core

(* ── Generators ──────────────────────────────────────────── *)

let gen_positive_int =
  QCheck.Gen.int_range 1 1_000_000

let gen_context_overflow_error =
  QCheck.Gen.(
    map
      (fun limit ->
      Agent_core.Error.Api
        (ContextOverflow { message = "exceeded"; limit }))
      (option gen_positive_int))

(* ── Properties ──────────────────────────────────────────── *)

let prop_overflow_preserves_provider_limit =
  QCheck.Test.make ~count:200
    ~name:"overflow classification preserves the provider-declared optional limit"
    (QCheck.make gen_context_overflow_error)
    (fun err ->
      let expected_limit =
        match err with
        | Agent_core.Error.Api (ContextOverflow { limit; _ }) -> limit
        | _ -> assert false
      in
      match
        Masc.Keeper_unified_turn_execution.For_testing
        .declared_lane_failure_of_error err
      with
      | Masc.Keeper_unified_turn_execution.For_testing
        .Provider_context_overflow { limit_tokens } ->
          Option.equal Int.equal expected_limit limit_tokens
      | Masc.Keeper_unified_turn_execution.For_testing
        .Declared_runtime_lane_exhausted -> false)

let user_text text : Agent_core.Types.message =
  { role = Agent_core.Types.User
  ; content = [ Agent_core.Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let text_blocks (messages : Agent_core.Types.message list) =
  List.concat_map
    (fun (msg : Agent_core.Types.message) ->
       List.filter_map
         (function
           | Agent_core.Types.Text text -> Some text
           | Agent_core.Types.Thinking _
           | Agent_core.Types.ReasoningDetails _
           | Agent_core.Types.RedactedThinking _
           | Agent_core.Types.ToolUse _
           | Agent_core.Types.ToolResult _
           | Agent_core.Types.Image _
           | Agent_core.Types.Document _
           | Agent_core.Types.Audio _ -> None)
         msg.content)
    messages

let text_contains needle texts =
  List.exists (fun text -> Astring.String.is_infix ~affix:needle text) texts

let test_checkpoint_patch_updates_visible_text_and_clears_working_context () =
  let assistant : Agent_core.Types.message =
    { role = Agent_core.Types.Assistant
    ; content =
        [ Agent_core.Types.Text "old visible reply"
        ; Agent_core.Types.Thinking
            { signature = Some "sig"; content = "typed reasoning block" }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let context =
    KC.create ~eio:false ~system_prompt:"system"
    |> fun ctx -> KC.append_many ctx [ user_text "question"; assistant ]
  in
  let checkpoint = KC.checkpoint_of_context context in
  let checkpoint =
    { checkpoint with
      Agent_core.Checkpoint.working_context =
        Some (`Assoc [ "runtime_payload", `String "stale" ])
    }
  in
  let patched =
    KC.patch_checkpoint_last_assistant
      checkpoint
      ~session_id:"unified-session"
      ~response_text:"final visible reply"
  in
  Alcotest.(check string)
    "session id"
    "unified-session"
    patched.Agent_core.Checkpoint.session_id;
  Alcotest.(check bool)
    "working context is cleared after finalization"
    true
    (Option.is_none patched.Agent_core.Checkpoint.working_context);
  let texts = text_blocks patched.Agent_core.Checkpoint.messages in
  Alcotest.(check bool)
    "final visible reply replaces prior assistant text"
    true
    (text_contains "final visible reply" texts);
  Alcotest.(check bool)
    "prior assistant text removed"
    false
    (text_contains "old visible reply" texts);
  let thinking_preserved =
    (* The param annotation is load-bearing: [message] and [api_response] both
       declare a [content] field in Agent_core.Types, and an unannotated
       [message.Agent_core.Types.content] projection resolves to whichever
       record OCaml saw last — which flipped to [api_response] under the
       AGENT_CORE 0.209 pin and broke this test's compile. *)
    patched.Agent_core.Checkpoint.messages
    |> List.exists (fun (message : Agent_core.Types.message) ->
      List.exists
        (function
          | Agent_core.Types.Thinking { content; _ } ->
            String.equal content "typed reasoning block"
          | _ -> false)
        message.Agent_core.Types.content)
  in
  Alcotest.(check bool) "typed non-text block preserved" true thinking_preserved

(* ── Gospel-style specification (documentation) ────────── *)
(*
   @gospel — formal specification (Ortac runtime not available on 5.4)

   val is_context_overflow : Error.t -> bool
   (*@ b = is_context_overflow err
       ensures b = match err with
         | Api (ContextOverflow _) -> true
         | _ -> false *)

   MASC owns keeper context maintenance. AGENT_CORE reports provider overflow as a
   typed error and does not invent a missing provider limit.
*)

(* ── Runner ──────────────────────────────────────────────── *)

let () =
  let qcheck_tests =
    List.map QCheck_alcotest.to_alcotest [
      prop_overflow_preserves_provider_limit;
    ]
  in
  Alcotest.run "pbt_context_overflow" [
    ("properties", qcheck_tests);
    ("typed contracts", [
      Alcotest.test_case
        "checkpoint patch keeps typed blocks and visible reply"
        `Quick
        test_checkpoint_patch_updates_visible_text_and_clears_working_context;
    ]);
  ]
