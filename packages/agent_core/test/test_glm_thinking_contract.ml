open Llm_provider

let with_catalog f =
  let previous = Llm_provider.Catalog_snapshot.current () in
  let restore () =
    Llm_provider.Catalog_snapshot.publish previous
  in
  let path =
    match List.find_opt Sys.file_exists [ "models.toml"; "../models.toml" ] with
    | Some path -> path
    | None -> Alcotest.fail "repository models.toml is required"
  in
  match Model_catalog.load_file path with
  | Error message -> Alcotest.fail message
  | Ok catalog ->
    (Llm_provider.Catalog_snapshot.publish (Agent_core_test_deps.admit_catalogs ~models:(Some (catalog)) ~providers:(None)));
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
    (* RFC-0488 §3.2: a row that declares no preserve_thinking sends no
       clear_thinking member, so the endpoint's own default applies. *)
    Alcotest.(check string) "undeclared row sends no thinking object"
      "null"
      (body (config provider model) |> field "thinking" |> Yojson.Safe.to_string))
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

let test_nonreasoning_default_omits_thinking model () =
  with_catalog (fun () ->
    List.iter (fun kind ->
      let config = Provider_config.make ~kind ~provider_id:"glm" ~model_id:model
          ~base_url:"https://api.z.ai/api/paas/v4" ~max_tokens:128 () in
      let caps = Backend_openai_request.capabilities_of_config config in
      Alcotest.(check bool) "catalog declares no reasoning" false caps.supports_reasoning;
      let serialized = Result.bind (Complete_common.validate_all config) (fun () ->
        Complete_common.serialize_http_request ~stream:false ~config
          ~messages:[Types.user_msg "Return text."] ~tools:[]) in
      let wire = match serialized with
        | Ok artifact -> Yojson.Safe.from_string artifact.body
        | Error (Http_client.AcceptRejected {reason}) -> Alcotest.fail reason
        | Error _ -> Alcotest.fail "non-reasoning GLM request serialization failed" in
      Alcotest.(check bool) "absent controls do not invent a thinking object" true
        (field "thinking" wire = `Null))
      [Provider_config.Glm; Provider_config.OpenAI_compat])
;;

(* The OpenAI-compatible preflight reads the same request-control artifact as
   the serializer. A row without a toggle wire claims no encoding for an
   explicit enable, so admission follows [supports_reasoning]: inherent
   reasoning is admitted, and an enable on a row without reasoning is refused
   before it reaches the wire (Complete_common [Enable_not_declared]). *)
let test_openai_compat_explicit_enable model expected () =
  with_catalog (fun () ->
    let config =
      Provider_config.make ~kind:OpenAI_compat ~provider_id:"glm" ~model_id:model
        ~base_url:"https://api.z.ai/api/paas/v4" ~request_path:"/chat/completions"
        ~max_tokens:128 ~enable_thinking:true ()
    in
    let caps = Backend_openai_request.capabilities_of_config config in
    Alcotest.(check bool) "row declares no toggle wire" true
      (caps.thinking_control_format = Capabilities.No_thinking_control);
    Alcotest.(check bool) "explicit enable admission follows supports_reasoning" true
      (Complete_common.thinking_control_request_rejection ~caps config = expected))
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
    ; "openai-compatible explicit enable", List.map (fun (model, expected) ->
        Alcotest.test_case model `Quick (test_openai_compat_explicit_enable model expected))
        [ "glm-5.3", None
        ; "glm-5.3-flash", None
        ; "glm-4", Some Complete_common.Enable_not_declared
        ; "glm-4v", Some Complete_common.Enable_not_declared
        ; "glm-4-flash", Some Complete_common.Enable_not_declared
        ]
    ; "non-reasoning defaults", List.map (fun model ->
        Alcotest.test_case model `Quick (test_nonreasoning_default_omits_thinking model))
        ["glm-4"; "glm-4v"; "glm-4-flash"]
    ; "anonymous native", List.map (fun (model, can_disable) ->
        Alcotest.test_case model `Quick (test_native_binding model can_disable))
        [ "glm-5.1", true; "glm-4.6", true; "glm-5.3", false
        ; "glm-5.3-flash", false; "glm-5.4", false; "glm-4.7-unlisted", false
        ; "unlisted-glm-model", false
        ]
    ]
;;
