(* Keeper_vision_tool pure-core tests — RFC-keeper-vision-delegation-tool §2.6.

   Locks the two contract-critical pure pieces:
   - stop_reason -> truncated mapping (the 2026-06-25 gemma4 finding: MaxTokens
     means the reply truncated, distinct from an empty/refusal reply);
   - the one-shot message build (image bytes MUST be base64-encoded for the wire
     serializer, which emits data:<media_type>;base64,<data>).

   The I/O orchestration (handle: load + runtime select + provider sub-call) is
   exercised by the env-gated live smoke, not here — it needs global Runtime
   state, an Eio net, and a populated store dir. The early no-Eio branches are
   covered below. *)

module Vt = Masc.Keeper_vision_tool
module Va = Multimodal.Vision_analyze
module Store = Multimodal.Vision_artifact_store

external unsetenv : string -> unit = "masc_test_unsetenv"

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> unsetenv key)
    (fun () ->
      Unix.putenv key value;
      f ())

let json_of_output raw =
  try Yojson.Safe.from_string raw with
  | Yojson.Json_error msg -> failwith ("invalid json output: " ^ msg ^ ": " ^ raw)

let assoc_string key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) -> s
     | Some other ->
       failwith
         (Printf.sprintf
            "field %s was not a string: %s"
            key
            (Yojson.Safe.to_string other))
     | None -> failwith ("missing field: " ^ key))
  | other -> failwith ("expected object: " ^ Yojson.Safe.to_string other)

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String (name ^ "-agent")
      ; "trace_id", `String (name ^ "-trace")
      ; "goal", `String "vision tool test"
      ; "allowed_paths", `List [ `String "*" ]
      ; "sandbox_profile", `String "none"
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> failwith e

let ok_response text : Agent_sdk.Types.api_response =
  { id = "vision-test"
  ; model = "vision-test-model"
  ; stop_reason = Agent_sdk.Types.EndTurn
  ; content = [ Agent_sdk.Types.Text text ]
  ; usage = None
  ; telemetry = None
  }

let with_temp_base f =
  let path = Filename.temp_file "masc-vision-tool-test-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  Unix.putenv "MASC_BASE_PATH" path;
  Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      unsetenv "MASC_BASE_PATH";
      Config_dir_resolver.reset ();
      let rec rm p =
        match Unix.lstat p with
        | { Unix.st_kind = Unix.S_DIR; _ } ->
          Array.iter
            (fun name -> rm (Filename.concat p name))
            (Sys.readdir p);
          Unix.rmdir p
        | _ -> Unix.unlink p
        | exception Unix.Unix_error _ -> ()
      in
      rm path)
    (fun () -> f path)

let store_image meta bytes =
  let store_dir =
    Vt.vision_store_dir ~keeper_name:meta.Masc.Keeper_meta_contract.name
  in
  match Store.store ~dir:store_dir bytes with
  | Ok handle -> Store.to_string handle
  | Error msg -> failwith msg

let artifact_args ?media_type artifact =
  let fields =
    [ "artifact", `String artifact; "query", `String "describe" ]
    @
    match media_type with
    | None -> []
    | Some value -> [ "media_type", value ]
  in
  `Assoc fields

let complete_should_not_run
    ~sw:_
    ~net:_
    ?clock:_
    ~config:_
    ~messages:_
    () =
  failwith "vision provider complete should not run"

let metric_value metric ~labels =
  Masc.Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string metric)
    ~labels
    ()
;;

let assert_metric_increment label before after =
  let delta = after -. before in
  if abs_float (delta -. 1.0) > 0.0001
  then
    failwith
      (Printf.sprintf
         "expected metric %s to increment by 1.0, before=%f after=%f"
         label
         before
         after)
;;

(* Only MaxTokens -> true. Exhaustive over all 9 SDK variants so a new one forces
   a decision rather than silently bucketing to false. *)
let test_truncated_of_stop_reason () =
  assert (Vt.truncated_of_stop_reason Agent_sdk.Types.MaxTokens = true);
  List.iter
    (fun r -> assert (Vt.truncated_of_stop_reason r = false))
    [ Agent_sdk.Types.EndTurn
    ; Agent_sdk.Types.StopToolUse
    ; Agent_sdk.Types.StopSequence
    ; Agent_sdk.Types.Refusal
    ; Agent_sdk.Types.PauseTurn
    ; Agent_sdk.Types.Compaction
    ; Agent_sdk.Types.ContextWindowExceeded
    ; Agent_sdk.Types.Unknown "content_filter"
    ]

(* One User message [text query; image]; image data is base64 of the raw bytes
   (NOT the raw bytes), media_type preserved, source_type "base64". *)
let test_message_of_request () =
  let bytes = "\x89PNG\r\n\x1a\n\x00raw\xffbytes" in
  match
    Va.make_request ~query:"what color?" ~image_media_type:"image/png"
      ~image_bytes:bytes
  with
  | Error e -> failwith e
  | Ok req ->
    let msg = Vt.message_of_request req in
    assert (msg.Agent_sdk.Types.role = Agent_sdk.Types.User);
    (match msg.Agent_sdk.Types.content with
     | [ Agent_sdk.Types.Text q; Agent_sdk.Types.Image img ] ->
       assert (String.equal q "what color?");
       assert (String.equal img.media_type "image/png");
       assert (String.equal img.source_type "base64");
       assert (String.equal img.data (Base64.encode_string bytes));
       assert (not (String.equal img.data bytes))
     | _ -> assert false)

(* first_vision_runtime_id returns a typed result either way (no exception). With
   no runtime cache loaded in this unit context it is Error; the value is what
   matters (never raises). *)
let test_first_vision_runtime_id_total () =
  match Vt.first_vision_runtime_id () with
  | Ok _ | Error _ -> ()

let test_provider_for_vision_preserves_configured_max_tokens () =
  let base =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"vision-model"
      ~base_url:"http://example.invalid"
      ()
  in
  let configured = Vt.provider_for_vision { base with max_tokens = Some 4096 } in
  assert (configured.max_tokens = Some 4096);
  let fallback = Vt.provider_for_vision { base with max_tokens = None } in
  assert (fallback.max_tokens = Some Vt.vision_default_max_tokens)

let test_max_image_bytes_reads_env_config () =
  with_env "MASC_KEEPER_VISION_MAX_IMAGE_BYTES" "128" (fun () ->
    assert (Vt.max_image_bytes () = 128))

let test_missing_eio_context_is_runtime_failure () =
  let raw =
    Vt.handle
      ~meta:(make_meta "vision-missing-eio")
      ~args:
        (`Assoc
          [ "artifact", `String (String.make 64 'a')
          ; "query", `String "describe"
          ])
      ()
  in
  let json = json_of_output raw in
  assert (String.equal (assoc_string "error" json) "eio_context_unavailable");
  assert (String.equal (assoc_string "failure_class" json) "runtime_failure")

let test_invalid_media_type_is_policy_rejection () =
  with_temp_base (fun _ ->
    let meta = make_meta "vision-media-type" in
    let bytes = "\x89PNG\r\n\x1a\nraw" in
    let handle = store_image meta bytes in
    let metric_labels =
      [ "result", "error"; "reason", "invalid_media_type" ]
    in
    let before =
      metric_value Keeper_metrics.VisionAnalyze ~labels:metric_labels
    in
    let raw =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          Vt.handle
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~net:(Eio.Stdenv.net env)
            ~meta
            ~args:(artifact_args ~media_type:(`String "text/plain") handle)
            ()))
    in
    let json = json_of_output raw in
    assert (String.equal (assoc_string "error" json) "invalid_media_type");
    assert (String.equal (assoc_string "failure_class" json) "policy_rejection");
    assert_metric_increment
      "vision_analyze invalid_media_type"
      before
      (metric_value Keeper_metrics.VisionAnalyze ~labels:metric_labels))

let test_missing_clock_is_runtime_failure_without_provider_call () =
  with_temp_base (fun _ ->
    let meta = make_meta "vision-missing-clock" in
    let raw =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          Vt.handle
            ~complete:complete_should_not_run
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~meta
            ~args:(artifact_args (String.make 64 'a'))
            ()))
    in
    let json = json_of_output raw in
    assert (String.equal (assoc_string "error" json) "eio_context_unavailable");
    assert (String.equal (assoc_string "failure_class" json) "runtime_failure"))

let test_invalid_timeout_is_runtime_failure_without_provider_call () =
  with_temp_base (fun _ ->
    let meta = make_meta "vision-invalid-timeout" in
    let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
    let raw =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          Vt.handle
            ~complete:complete_should_not_run
            ~timeout_sec:0.0
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~net:(Eio.Stdenv.net env)
            ~meta
            ~args:(artifact_args handle)
            ()))
    in
    let json = json_of_output raw in
    assert (String.equal (assoc_string "error" json) "invalid_timeout");
    assert (String.equal (assoc_string "failure_class" json) "runtime_failure"))

let test_non_string_media_type_is_policy_rejection () =
  with_temp_base (fun _ ->
    let meta = make_meta "vision-media-type-non-string" in
    let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
    let raw =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          Vt.handle
            ~complete:complete_should_not_run
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~net:(Eio.Stdenv.net env)
            ~meta
            ~args:(artifact_args ~media_type:(`Int 123) handle)
            ()))
    in
    let json = json_of_output raw in
    assert (String.equal (assoc_string "error" json) "invalid_media_type");
    assert (String.equal (assoc_string "failure_class" json) "policy_rejection"))

let test_unknown_magic_bytes_are_policy_rejection () =
  with_temp_base (fun _ ->
    let meta = make_meta "vision-unknown-magic" in
    let handle = store_image meta "definitely not an image" in
    let raw =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          Vt.handle
            ~complete:complete_should_not_run
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~net:(Eio.Stdenv.net env)
            ~meta
            ~args:(artifact_args handle)
            ()))
    in
    let json = json_of_output raw in
    assert (String.equal (assoc_string "error" json) "invalid_media_type");
    assert (String.equal (assoc_string "failure_class" json) "policy_rejection"))

let test_oversize_image_is_policy_rejection_before_provider_call () =
  with_temp_base (fun _ ->
    let meta = make_meta "vision-oversize" in
    let handle = store_image meta (String.make (Vt.max_image_bytes () + 1) '\000') in
    let raw =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          Vt.handle
            ~complete:complete_should_not_run
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~net:(Eio.Stdenv.net env)
            ~meta
            ~args:(artifact_args handle)
            ()))
    in
    let json = json_of_output raw in
    assert (String.equal (assoc_string "error" json) "image_too_large");
    assert (String.equal (assoc_string "failure_class" json) "policy_rejection"))

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let with_temp_runtime_toml content f =
  let path = Filename.temp_file "masc-vision-runtime-" ".toml" in
  write_file path content;
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      try Sys.remove path with
      | _ -> ())
    (fun () ->
      match Runtime.init_default ~config_path:path with
      | Ok () -> f ()
      | Error msg -> failwith ("Runtime.init_default failed: " ^ msg))

let vision_failover_runtime_toml =
  {|
[runtime]
default = "p1.vision-a"
media_failover = ["p1.vision-a", "p2.vision-b"]

[providers.p1]
protocol = "openai-compatible-http"
endpoint = "https://p1.example/v1"

[providers.p2]
protocol = "openai-compatible-http"
endpoint = "https://p2.example/v1"

[models.vision-a]
api-name = "vision-a"
max-context = 4096

[models.vision-a.capabilities]
supports-image-input = true
supports-multimodal-inputs = true

[models.vision-b]
api-name = "vision-b"
max-context = 4096

[models.vision-b.capabilities]
supports-image-input = true
supports-multimodal-inputs = true

[p1.vision-a]

[p2.vision-b]
|}

let single_vision_runtime_toml =
  {|
[runtime]
default = "p3.vision-c"
media_failover = ["p3.vision-c"]

[providers.p3]
protocol = "openai-compatible-http"
endpoint = "https://p3.example/v1"

[models.vision-c]
api-name = "vision-c"
max-context = 4096

[models.vision-c.capabilities]
supports-image-input = true
supports-multimodal-inputs = true

[p3.vision-c]
|}

let test_temp_runtime_toml_restores_runtime_cache () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    let before = Runtime.get_runtime_ids () in
    with_temp_runtime_toml single_vision_runtime_toml (fun () ->
      assert (Runtime.get_runtime_ids () = [ "p3.vision-c" ]));
    assert (Runtime.get_runtime_ids () = before))

let test_retryable_provider_error_tries_next_runtime () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-failover" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let transient_labels =
        [ "runtime_id", "p1.vision-a"
        ; "result", "error"
        ; "reason", "transient_provider_error"
        ]
      in
      let ok_labels =
        [ "runtime_id", "p2.vision-b"
        ; "result", "ok"
        ; "reason", "provider_response"
        ]
      in
      let before_transient =
        metric_value Keeper_metrics.VisionCandidateAttempts
          ~labels:transient_labels
      in
      let before_ok =
        metric_value Keeper_metrics.VisionCandidateAttempts ~labels:ok_labels
      in
      let calls = ref 0 in
      let models = ref [] in
      let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ () =
        incr calls;
        models := !models @ [ config.Llm_provider.Provider_config.model_id ];
        if !calls = 1 then
          Error (Llm_provider.Http_client.HttpError { code = 500; body = "down" })
        else Ok (ok_response "second runtime answered")
      in
      let raw =
        Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
            Vt.handle
              ~complete
              ~sw
              ~clock:(Eio.Stdenv.clock env)
              ~net:(Eio.Stdenv.net env)
              ~meta
              ~args:(artifact_args handle)
              ()))
      in
      let json = json_of_output raw in
      assert (!calls = 2);
      assert (!models = [ "vision-a"; "vision-b" ]);
      assert (String.equal (assoc_string "text" json) "second runtime answered");
      assert_metric_increment
        "vision_candidate transient_provider_error"
        before_transient
        (metric_value Keeper_metrics.VisionCandidateAttempts
           ~labels:transient_labels);
      assert_metric_increment
        "vision_candidate provider_response"
        before_ok
        (metric_value Keeper_metrics.VisionCandidateAttempts ~labels:ok_labels)))

let test_deadline_exhaustion_preserves_provider_error () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-deadline-provider-error" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let calls = ref 0 in
      let models = ref [] in
      let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ () =
        incr calls;
        models := !models @ [ config.Llm_provider.Provider_config.model_id ];
        Error (Llm_provider.Http_client.HttpError { code = 500; body = "down" })
      in
      let raw =
        Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
            Vt.handle
              ~complete
              ~timeout_sec:0.001
              ~sw
              ~clock:(Eio.Stdenv.clock env)
              ~net:(Eio.Stdenv.net env)
              ~meta
              ~args:(artifact_args handle)
              ()))
      in
      let json = json_of_output raw in
      assert (!calls = 1);
      assert (!models = [ "vision-a" ]);
      assert (String.equal (assoc_string "error" json) "provider_error");
      assert (String.equal (assoc_string "failure_class" json) "transient_error")))

let test_non_retryable_provider_error_stops_without_trying_next_runtime () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-nonretryable-stop" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let calls = ref 0 in
      let models = ref [] in
      let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ () =
        incr calls;
        models := !models @ [ config.Llm_provider.Provider_config.model_id ];
        Error
          (Llm_provider.Http_client.HttpError
             { code = 401; body = "bad credentials" })
      in
      let raw =
        Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
            Vt.handle
              ~complete
              ~sw
              ~clock:(Eio.Stdenv.clock env)
              ~net:(Eio.Stdenv.net env)
              ~meta
              ~args:(artifact_args handle)
              ()))
      in
      let json = json_of_output raw in
      assert (!calls = 1);
      assert (!models = [ "vision-a" ]);
      assert (String.equal (assoc_string "error" json) "provider_error");
      assert (String.equal (assoc_string "failure_class" json) "runtime_failure")))

let test_accept_rejected_is_policy_rejection_without_failover () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-accept-rejected" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let calls = ref 0 in
      let models = ref [] in
      let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ () =
        incr calls;
        models := !models @ [ config.Llm_provider.Provider_config.model_id ];
        Error
          (Llm_provider.Http_client.AcceptRejected
             { reason = "provider rejected the image" })
      in
      let raw =
        Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
            Vt.handle
              ~complete
              ~sw
              ~clock:(Eio.Stdenv.clock env)
              ~net:(Eio.Stdenv.net env)
              ~meta
              ~args:(artifact_args handle)
              ()))
      in
      let json = json_of_output raw in
      assert (!calls = 1);
      assert (!models = [ "vision-a" ]);
      assert (String.equal (assoc_string "error" json) "provider_error");
      assert (String.equal (assoc_string "failure_class" json) "policy_rejection")))

let () =
  test_truncated_of_stop_reason ();
  test_message_of_request ();
  test_first_vision_runtime_id_total ();
  test_provider_for_vision_preserves_configured_max_tokens ();
  test_max_image_bytes_reads_env_config ();
  test_missing_eio_context_is_runtime_failure ();
  test_invalid_media_type_is_policy_rejection ();
  test_missing_clock_is_runtime_failure_without_provider_call ();
  test_invalid_timeout_is_runtime_failure_without_provider_call ();
  test_non_string_media_type_is_policy_rejection ();
  test_unknown_magic_bytes_are_policy_rejection ();
  test_oversize_image_is_policy_rejection_before_provider_call ();
  test_temp_runtime_toml_restores_runtime_cache ();
  test_retryable_provider_error_tries_next_runtime ();
  test_deadline_exhaustion_preserves_provider_error ();
  test_non_retryable_provider_error_stops_without_trying_next_runtime ();
  test_accept_rejected_is_policy_rejection_without_failover ();
  print_endline "test_keeper_vision_tool: all assertions passed"
