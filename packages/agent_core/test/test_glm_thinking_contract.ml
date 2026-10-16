open Llm_provider

let with_catalog f =
  let previous = Model_catalog.global () in
  let restore () =
    match previous with
    | Some catalog -> Model_catalog.set_global catalog
    | None -> Model_catalog.clear_global ()
  in
  let path =
    match List.find_opt Sys.file_exists [ "models.toml"; "../models.toml" ] with
    | Some path -> path
    | None -> Alcotest.fail "repository models.toml is required"
  in
  match Model_catalog.load_file path with
  | Error message -> Alcotest.fail message
  | Ok catalog ->
    Model_catalog.set_global catalog;
    Fun.protect f ~finally:restore
;;

let config ?enable_thinking ?preserve_thinking provider_id model_id =
  let base_url =
    match provider_id with
    | "glm-coding" -> "https://api.z.ai/api/coding/paas/v4"
    | _ -> "https://api.z.ai/api/paas/v4"
  in
  Provider_config.make ~kind:Glm ~provider_id ~model_id ~base_url
    ~request_path:"/chat/completions" ~max_tokens:128
    ~response_format:Types.JsonMode ?enable_thinking ?preserve_thinking ()
;;

let body config =
  Backend_glm.build_request ~config ~messages:[ Types.user_msg "Return JSON." ] ()
  |> Yojson.Safe.from_string
;;

let field key = Yojson.Safe.Util.member key

let test_hybrid provider model () =
  with_catalog (fun () ->
    let disabled = config ~enable_thinking:false provider model in
    let caps = Backend_openai_request.capabilities_of_config disabled in
    Alcotest.(check bool) "exact binding declares toggle" true
      (caps.thinking_control_format = Capabilities.Thinking_object_only);
    Alcotest.(check bool) "explicit disable admitted" true
      (Option.is_none (Complete_common.thinking_control_request_rejection ~caps disabled));
    let wire = body disabled in
    Alcotest.(check string) "one independent toggle object"
      {|{"type":"disabled"}|} (Yojson.Safe.to_string (field "thinking" wire));
    Alcotest.(check bool) "no guessed enable_thinking field" true
      (field "enable_thinking" wire = `Null);
    Alcotest.(check string) "JSON mode preserved" "json_object"
      (field "response_format" wire |> field "type" |> Yojson.Safe.Util.to_string);
    let enabled = config ~enable_thinking:true ~preserve_thinking:true provider model in
    let on = body enabled |> field "thinking" in
    Alcotest.(check string) "enable reaches request" "enabled"
      (field "type" on |> Yojson.Safe.Util.to_string);
    Alcotest.(check bool) "history preservation remains independent" false
      (field "clear_thinking" on |> Yojson.Safe.Util.to_bool);
    let reset = config ~enable_thinking:true ~preserve_thinking:false provider model in
    Alcotest.(check bool) "explicit history clear still travels" true
      (body reset |> field "thinking" |> field "clear_thinking" |> Yojson.Safe.Util.to_bool);
    Alcotest.(check bool) "unspecified toggle preserves provider default" true
      (body (config provider model) |> field "thinking" = `Null))
;;

let test_no_toggle provider model () =
  with_catalog (fun () ->
    let disabled = config ~enable_thinking:false ~preserve_thinking:true provider model in
    let caps = Backend_openai_request.capabilities_of_config disabled in
    Alcotest.(check bool) "no disable capability fabricated" true
      (caps.thinking_control_format = Capabilities.No_thinking_control);
    Alcotest.(check bool) "preserve does not authorize disable" true
      (Complete_common.thinking_control_request_rejection ~caps disabled
       = Some Complete_common.Disable_not_encodable);
    Alcotest.(check bool) "low-level builder cannot invent disabled wire" true
      (body disabled |> field "thinking" = `Null);
    let enabled = config ~enable_thinking:true ~preserve_thinking:true provider model in
    Alcotest.(check bool) "inherent reasoning still admitted" true
      (Option.is_none (Complete_common.thinking_control_request_rejection ~caps enabled));
    let on = body enabled |> field "thinking" in
    Alcotest.(check string) "preserved inherent reasoning remains expressible" "enabled"
      (field "type" on |> Yojson.Safe.Util.to_string);
    Alcotest.(check bool) "reasoning history retained" false
      (field "clear_thinking" on |> Yojson.Safe.Util.to_bool))
;;

let test_response_separation () =
  let response = Backend_glm.parse_response
      {|{"id":"glm-contract","model":"glm-5.1","choices":[{"finish_reason":"stop","message":{"role":"assistant","reasoning_content":"private reasoning","content":"{\"answer\":42}"}}]}|}
  in
  Alcotest.(check bool) "reasoning and JSON remain distinct" true
    (response.content =
       [ Types.Thinking { content = "private reasoning"; signature = None }
       ; Types.Text "{\"answer\":42}"
       ]);
  Alcotest.(check string) "visible JSON excludes reasoning" "{\"answer\":42}"
    (Types.visible_text_of_response response)
;;

let test_native_binding model can_disable () =
  with_catalog (fun () ->
    let disabled =
      Provider_config.make ~kind:Glm ~model_id:model
        ~base_url:"https://api.z.ai/api/paas/v4" ~enable_thinking:false ()
    in
    let caps = Backend_openai_request.capabilities_of_config disabled in
    Alcotest.(check bool) "anonymous native binding uses exact declaration" can_disable
      (caps.thinking_control_format = Capabilities.Thinking_object_only);
    Alcotest.(check bool) "anonymous native disable admission" can_disable
      (Option.is_none (Complete_common.thinking_control_request_rejection ~caps disabled));
    let expected = if can_disable then `Assoc [ "type", `String "disabled" ] else `Null in
    Alcotest.(check string) "prefix resemblance cannot grant a wire toggle"
      (Yojson.Safe.to_string expected)
      (body disabled |> field "thinking" |> Yojson.Safe.to_string))
;;

let () =
  let bindings models test =
    List.concat_map (fun provider ->
      List.map (fun model -> Alcotest.test_case (provider ^ "." ^ model) `Quick
        (test provider model)) models) [ "glm"; "glm-coding" ]
  in
  Alcotest.run "GLM exact thinking contract"
    [ "documented hybrid", bindings [ "glm-5.2"; "glm-5.1"; "glm-5"; "glm-4.7"; "glm-4.6" ] test_hybrid
    ; "forced and undeclared", bindings [ "glm-5.3"; "glm-5.3-flash"; "unlisted-glm-model" ] test_no_toggle
    ; "anonymous native", List.map (fun (model, can_disable) ->
        Alcotest.test_case model `Quick (test_native_binding model can_disable))
        [ "glm-5.1", true; "glm-4.6", true; "glm-5.3", false
        ; "glm-5.3-flash", false; "glm-5.4", false; "glm-4.7-unlisted", false
        ; "unlisted-glm-model", false
        ]
    ; "response", [ Alcotest.test_case "reasoning does not become JSON" `Quick test_response_separation ]
    ]
;;
