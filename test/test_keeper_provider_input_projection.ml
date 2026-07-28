module P = Masc.Keeper_provider_input_projection
module T = Agent_sdk.Types

let message role content : T.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }
;;

let text role value = message role [ T.Text value ]

let provider_config () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id:"projection-test"
    ~base_url:"http://127.0.0.1"
    ~request_path:"/v1/chat/completions"
    ~system_prompt:"projection system prompt"
    ()
;;

let inspect config messages =
  match
    Llm_provider.Complete.inspect_serialized_request
      ~stream:true
      ~config
      ~messages
      ()
  with
  | Ok observation -> observation
  | Error error ->
    Alcotest.failf
      "fixture serialization failed: %s"
      (Masc.Provider_http_error.to_message error)
;;

let require_ok = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let check_messages label expected actual =
  Alcotest.(check bool) label true (expected = actual)
;;

let make_project ~canonical ~config observed =
  P.create
    ~canonical_prefix:canonical
    ~provider_config:config
    ~tools:[]
    ~stream:true
    ~base_projection:Fun.id
    ~observe:(fun observation -> observed := Some observation)
    ()
;;

let test_over_limit_preserves_full_input_for_typed_admission () =
  let canonical =
    [ text T.User (String.make 8_000 'o')
    ; text T.Assistant (String.make 8_000 'a')
    ]
  in
  let current_run = [ text T.User "current turn" ] in
  let messages = canonical @ current_run in
  let unbounded = provider_config () in
  let wire = inspect unbounded messages in
  let bounded =
    { unbounded with
      Llm_provider.Provider_config.max_request_body_bytes =
        Some (wire.body_bytes - 1)
    }
  in
  let observed = ref None in
  let projected = make_project ~canonical ~config:bounded observed messages |> require_ok in
  check_messages "over-limit transcript remains lossless" messages projected;
  match !observed with
  | None -> Alcotest.fail "preflight observation missing"
  | Some observation ->
    Alcotest.(check int) "canonical history count" 2
      observation.canonical_history_messages;
    Alcotest.(check int) "current run count" 1 observation.current_run_messages;
    Alcotest.(check int) "exact full body" wire.body_bytes observation.body_bytes;
    Alcotest.(check string) "exact full digest" wire.body_sha256
      observation.body_sha256;
    Alcotest.(check bool) "requires typed admission refusal" false
      observation.fits
;;

let test_within_limit_preserves_full_input () =
  let canonical = [ text T.User "history" ] in
  let current_run = [ text T.User "current turn" ] in
  let messages = canonical @ current_run in
  let unbounded = provider_config () in
  let wire = inspect unbounded messages in
  let bounded =
    { unbounded with
      Llm_provider.Provider_config.max_request_body_bytes = Some wire.body_bytes
    }
  in
  let observed = ref None in
  let projected = make_project ~canonical ~config:bounded observed messages |> require_ok in
  check_messages "within-limit transcript remains exact" messages projected;
  match !observed with
  | None -> Alcotest.fail "preflight observation missing"
  | Some observation ->
    Alcotest.(check bool) "fits exact limit" true observation.fits;
    Alcotest.(check int) "exact limit" wire.body_bytes observation.limit_bytes
;;

let test_prefix_mismatch_fails_closed () =
  let canonical = [ text T.User "canonical" ] in
  let project =
    P.create
      ~canonical_prefix:canonical
      ~provider_config:
        { (provider_config ()) with
          Llm_provider.Provider_config.max_request_body_bytes = Some 1_024
        }
      ~tools:[]
      ~stream:true
      ~base_projection:Fun.id
      ()
  in
  match project [ text T.User "different"; text T.User "current" ] with
  | Error detail ->
    Alcotest.(check bool)
      "typed mismatch detail"
      true
      (String.starts_with
         ~prefix:"keeper provider input projection cannot locate canonical history"
         detail)
  | Ok _ -> Alcotest.fail "prefix mismatch silently projected"
;;

let test_base_projection_must_preserve_message_positions () =
  let canonical = [ text T.User "oldest"; text T.User "newest" ] in
  let current_run = [ text T.User "current" ] in
  let project =
    P.create
      ~canonical_prefix:canonical
      ~provider_config:
        { (provider_config ()) with
          Llm_provider.Provider_config.max_request_body_bytes = Some 1_024
        }
      ~tools:[]
      ~stream:true
      ~base_projection:(function
        | first :: second :: rest -> second :: first :: rest
        | messages -> messages)
      ()
  in
  match project (canonical @ current_run) with
  | Error detail ->
    Alcotest.(check bool)
      "position contract surfaced"
      true
      (String.starts_with
         ~prefix:"keeper provider input base projection changed message order"
         detail)
  | Ok _ -> Alcotest.fail "reordered base projection was accepted"
;;

let test_unbounded_projection_still_preserves_structure () =
  let canonical = [ text T.User "oldest" ] in
  let project =
    P.create
      ~canonical_prefix:canonical
      ~provider_config:(provider_config ())
      ~tools:[]
      ~stream:true
      ~base_projection:(fun _ -> [])
      ()
  in
  match project canonical with
  | Error detail ->
    Alcotest.(check bool)
      "unbounded structural drift surfaced"
      true
      (String.starts_with
         ~prefix:"keeper provider input base projection changed message order"
         detail)
  | Ok _ -> Alcotest.fail "unbounded projection silently removed history"
;;

let test_base_projection_may_not_change_structured_tool_result () =
  let tool_result json =
    message
      T.Tool
      [ T.ToolResult
          { tool_use_id = "call-1"
          ; content = "opaque payload"
          ; outcome = T.Tool_succeeded
          ; json
          ; content_blocks = None
          }
      ]
  in
  let canonical = [ tool_result (Some (`Assoc [ "value", `Int 1 ])) ] in
  let project =
    P.create
      ~canonical_prefix:canonical
      ~provider_config:(provider_config ())
      ~tools:[]
      ~stream:true
      ~base_projection:(fun _ ->
        [ tool_result (Some (`Assoc [ "value", `Int 2 ])) ])
      ()
  in
  match project canonical with
  | Error detail ->
    Alcotest.(check bool)
      "structured payload drift surfaced"
      true
      (String.starts_with
         ~prefix:"keeper provider input base projection changed message order"
         detail)
  | Ok _ -> Alcotest.fail "structured ToolResult drift was accepted"
;;

let () =
  Alcotest.run
    "keeper provider input projection"
    [ ( "preflight"
      , [ Alcotest.test_case
            "over-limit input remains lossless for typed admission"
            `Quick
            test_over_limit_preserves_full_input_for_typed_admission
        ; Alcotest.test_case
            "within-limit input remains lossless"
            `Quick
            test_within_limit_preserves_full_input
        ; Alcotest.test_case
            "prefix mismatch fails closed"
            `Quick
            test_prefix_mismatch_fails_closed
        ; Alcotest.test_case
            "base projection preserves positions"
            `Quick
            test_base_projection_must_preserve_message_positions
        ; Alcotest.test_case
            "unbounded projection still preserves structure"
            `Quick
            test_unbounded_projection_still_preserves_structure
        ; Alcotest.test_case
            "base projection preserves structured ToolResult fields"
            `Quick
            test_base_projection_may_not_change_structured_tool_result
        ] )
    ]
;;
