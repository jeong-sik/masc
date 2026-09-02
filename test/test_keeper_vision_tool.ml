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
module Vi = Masc.Keeper_vision_ingest
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
  let json = `Assoc [ "name", `String name ] in
match Masc_test_deps.meta_of_json_fixture json with
| Ok meta -> meta
| Error e -> failwith e

let substring_index s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then None
    else if String.sub s i n_len = needle then Some i
    else loop (i + 1)
  in
  if n_len = 0 then Some 0 else loop 0

let artifact_handle_of_placeholder text =
  let marker = "artifact:" in
  match substring_index text marker with
  | None -> failwith ("missing artifact marker: " ^ text)
  | Some marker_pos ->
    let start = marker_pos + String.length marker in
    let rec stop i =
      if i >= String.length text || text.[i] = ' ' || text.[i] = ']'
      then i
      else stop (i + 1)
    in
    String.sub text start (stop start - start)

let ok_response text : Agent_core.Types.api_response =
  let text_json =
    Yojson.Safe.to_string (`Assoc [ "text", `String text ])
  in
  { id = "vision-test"
  ; model = "vision-test-model"
  ; stop_reason = Agent_core.Types.EndTurn
  ; content = [ Agent_core.Types.Text text_json ]
  ; usage = None
  ; telemetry = None
  }

let text_response text : Agent_core.Types.api_response =
  { id = "vision-test"
  ; model = "vision-test-model"
  ; stop_reason = Agent_core.Types.EndTurn
  ; content = [ Agent_core.Types.Text text ]
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
    ?tools:_
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

(* Only MaxTokens -> true. Exhaustive over all 12 agent-core variants so a new one
   forces a decision rather than silently bucketing to false. *)
let test_truncated_of_stop_reason () =
  assert (Vt.truncated_of_stop_reason Agent_core.Types.MaxTokens = true);
  List.iter
    (fun r -> assert (Vt.truncated_of_stop_reason r = false))
    [ Agent_core.Types.EndTurn
    ; Agent_core.Types.StopToolUse
    ; Agent_core.Types.StopSequence
    ; Agent_core.Types.Refusal
    ; Agent_core.Types.ContentFilter
    ; Agent_core.Types.RepetitionTruncation
    ; Agent_core.Types.PauseTurn
    ; Agent_core.Types.Compaction
    ; Agent_core.Types.ContextWindowExceeded
    ; Agent_core.Types.UnmatchedToolCalls
    ; Agent_core.Types.Unknown "some_novel_reason"
    ]

(* One User message [text query; image]; image data is base64 of the raw bytes
   (NOT the raw bytes), media_type preserved, source_type "base64". The JSON
   response contract is explicit prompt prose because the provider request has
   [response_format = Off]. *)
let test_message_of_request () =
  let bytes = "\x89PNG\r\n\x1a\n\x00raw\xffbytes" in
  match
    Va.make_request ~query:"what color?" ~image_media_type:"image/png"
      ~image_bytes:bytes
  with
  | Error e -> failwith e
  | Ok req ->
    let msg = Vt.message_of_request req in
    assert (msg.Agent_core.Types.role = Agent_core.Types.User);
    (match msg.Agent_core.Types.content with
     | [ Agent_core.Types.Text q; Agent_core.Types.Image img ] ->
       assert (String_util.contains_substring q "what color?");
       assert (String_util.contains_substring q "Return only a JSON object");
       assert (String_util.contains_substring q "field named text");
       assert (String.equal img.media_type "image/png");
       assert (
         String.equal
           (Agent_core.Types.media_source_kind_to_string img.source_type)
           "base64");
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
  let configured =
    Vt.provider_for_vision { base with max_tokens = Some 4096 }
  in
  assert (configured.max_tokens = Some 4096);
  let fallback =
    Vt.provider_for_vision { base with max_tokens = None }
  in
  assert (fallback.max_tokens = Some (Vt.vision_default_max_tokens ()));
  (match configured.response_format with
   | Agent_core.Types.Off -> ()
   | Agent_core.Types.JsonMode
   | Agent_core.Types.JsonSchema _ -> failwith "vision provider must not request a wire format")

(* The 2026-08 fix: vision must NOT force enable_thinking=false. The
   media_failover fleet is entirely /v1 "none" thinking-control lanes —
   reasoning-capable models with no wire field to disable thinking — where a
   disable request is fail-closed by the agent_core guard (Disable_not_encodable),
   which broke every image analysis. Leaving enable_thinking=None lets the guard
   admit the call (complete_common: None -> admitted); the reply is still kept
   clean by preserve_thinking=false + clear_thinking=true, which strip any
   reasoning the model emits without requesting an impossible disable. *)
let test_provider_for_vision_leaves_thinking_uncontrolled () =
  let base =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"vision-model"
      ~base_url:"http://example.invalid"
      ()
  in
  let configured = Vt.provider_for_vision base in
  assert (configured.enable_thinking = None);
  assert (configured.preserve_thinking = Some false);
  assert (configured.clear_thinking = Some true);
  assert (configured.thinking_budget = None)

let test_max_image_bytes_reads_env_config () =
  with_env "MASC_KEEPER_VISION_MAX_IMAGE_BYTES" "128" (fun () ->
    assert (Vt.max_image_bytes () = 128))

let assert_float_eq label expected actual =
  if abs_float (expected -. actual) > 0.000001
  then
    failwith
      (Printf.sprintf "%s: expected %f, got %f" label expected actual)
;;

let test_vision_env_knobs_are_bounded () =
  with_env "MASC_KEEPER_VISION_MAX_IMAGE_BYTES" "999999999" (fun () ->
    assert (Vt.max_image_bytes () = 10 * 1024 * 1024));
  with_env "MASC_KEEPER_VISION_MAX_OUTPUT_TOKENS" "999999999" (fun () ->
    assert (Vt.vision_default_max_tokens () = 128 * 1024));
  with_env "MASC_KEEPER_VISION_MAX_OUTPUT_TOKENS" "1" (fun () ->
    assert (Vt.vision_default_max_tokens () = 4096));
  with_env "MASC_KEEPER_VISION_CANDIDATE_BACKOFF_BASE_SEC" "999" (fun () ->
    assert_float_eq
      "base backoff ceiling"
      5.0
      (Env_config_keeper.KeeperVision.candidate_backoff_base_sec ()));
  with_env "MASC_KEEPER_VISION_CANDIDATE_BACKOFF_MAX_SEC" "999" (fun () ->
    assert_float_eq
      "max backoff ceiling"
      30.0
      (Env_config_keeper.KeeperVision.candidate_backoff_max_sec ()));
  with_env "MASC_KEEPER_VISION_CANDIDATE_BACKOFF_BASE_SEC" "2.0" (fun () ->
    with_env "MASC_KEEPER_VISION_CANDIDATE_BACKOFF_MAX_SEC" "1.0" (fun () ->
      assert_float_eq
        "max backoff is at least base"
        2.0
        (Env_config_keeper.KeeperVision.candidate_backoff_max_sec ())))

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

let test_oversize_image_is_runtime_failure_before_provider_call () =
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
    assert (String.equal (assoc_string "failure_class" json) "runtime_failure"))

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let no_image_runtime_toml =
  {|
[runtime]
default = "p0.text"
media_failover = ["p0.text"]

[providers.p0]
protocol = "openai-compatible-http"
endpoint = "https://p0.example/v1"

[models.text]
api-name = "text"
max-context = 4096

[models.text.capabilities]
supports-image-input = false
supports-multimodal-inputs = false

[p0.text]
|}

let init_runtime_or_fail path =
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error msg -> failwith ("Runtime.init_default failed: " ^ msg)
;;

let reset_runtime_to_no_image_fixture () =
  let path = Filename.temp_file "masc-vision-runtime-reset-" ".toml" in
  write_file path no_image_runtime_toml;
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () -> init_runtime_or_fail path)
;;

let runtime_config_stack = ref []

let with_temp_runtime_toml content f =
  let path = Filename.temp_file "masc-vision-runtime-" ".toml" in
  write_file path content;
  let previous_stack = !runtime_config_stack in
  runtime_config_stack := path :: previous_stack;
  Fun.protect
    ~finally:(fun () ->
      Fun.protect
        ~finally:(fun () ->
          try Sys.remove path with
          | _ -> ())
        (fun () ->
          runtime_config_stack := previous_stack;
          match previous_stack with
          | previous_path :: _ -> init_runtime_or_fail previous_path
          | [] -> reset_runtime_to_no_image_fixture ()))
    (fun () ->
      init_runtime_or_fail path;
      f ())

let vision_failover_runtime_toml =
  {|
[runtime]
default = "p1.vision-a"
media_failover = ["p1.vision-a", "p2.vision-b"]

[providers.p1]
protocol = "ollama-http"
endpoint = "https://p1.example/v1"

[providers.p2]
protocol = "ollama-http"
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
max-request-body-bytes = 65536

[p2.vision-b]
max-request-body-bytes = 65536
|}

let single_vision_runtime_toml =
  {|
[runtime]
default = "p3.vision-c"
media_failover = ["p3.vision-c"]

[providers.p3]
protocol = "ollama-http"
endpoint = "https://p3.example/v1"

[models.vision-c]
api-name = "vision-c"
max-context = 4096
temperature = 1.0

[models.vision-c.capabilities]
supports-image-input = true
supports-multimodal-inputs = true

[p3.vision-c]
max-request-body-bytes = 65536
|}

(* Vision falls back to every image-capable runtime after explicit
   media_failover ordering. The uncapped fallback is therefore genuinely
   reachable even though neither [runtime].default nor media_failover names it. *)
let uncapped_vision_fallback_runtime_toml =
  {|
[runtime]
default = "p0.text"
media_failover = ["p0.text"]

[providers.p0]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1/v1"

[providers.p4]
protocol = "ollama-http"
endpoint = "http://127.0.0.1:2/v1"

[models.text]
api-name = "text"
max-context = 4096

[models.text.capabilities]
supports-image-input = false
supports-multimodal-inputs = false

[models.vision-a]
api-name = "vision-a"
max-context = 4096

[models.vision-a.capabilities]
supports-image-input = true
supports-multimodal-inputs = true

[p0.text]
max-request-body-bytes = 65536

[p4.vision-a]
|}

let test_provider_for_vision_uses_runtime_temperature () =
  with_temp_runtime_toml single_vision_runtime_toml (fun () ->
    match Vt.first_vision_runtime_id () with
    | Error msg -> failwith ("expected configured vision runtime: " ^ msg)
    | Ok runtime_id ->
      (match Runtime.get_runtime_by_id runtime_id with
       | None -> failwith "selected vision runtime should resolve"
       | Some runtime ->
         (match runtime.Runtime.execution with
          | Runtime_execution.Codex_app_server _
          | Runtime_execution.Claude_code _
          | Runtime_execution.Antigravity_cli _ ->
            failwith "selected vision runtime should be agent_core"
          | Runtime_execution.Agent_core provider_config ->
            let configured = Vt.provider_for_vision provider_config in
            assert (configured.temperature = Some 1.0))))

let test_uncapped_vision_fallback_rejects_before_provider_call () =
  with_temp_runtime_toml uncapped_vision_fallback_runtime_toml (fun () ->
    let provider_calls = ref 0 in
    let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
      incr provider_calls;
      Ok (ok_response "provider call must not happen")
    in
    let outcome =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          Vt.run_vision
            ~complete
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~net:(Eio.Stdenv.net env)
            ~query:"describe"
            ~media_type:"image/png"
            ~bytes:"\x89PNG\r\n\x1a\nraw"
            ()))
    in
    assert (!provider_calls = 0);
    match outcome with
    | Vt.Vo_provider { failure_class = Tool_result.Runtime_failure; _ } -> ()
    | _ -> failwith "uncapped vision fallback must fail before provider dispatch")

let image_capable_vision_runtime_toml =
  {|
[runtime]
default = "local.vision"
media_failover = ["local.vision"]

[providers.local]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.vision]
api-name = "vision"
max-context = 4096

[models.vision.capabilities]
supports-image-input = true
supports-multimodal-inputs = true

[local.vision]
|}

let test_temp_runtime_toml_restores_runtime_cache () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    let before = Runtime.get_runtime_ids () in
    with_temp_runtime_toml single_vision_runtime_toml (fun () ->
      assert (Runtime.get_runtime_ids () = [ "p3.vision-c" ]));
    assert (Runtime.get_runtime_ids () = before));
  assert (Vt.vision_runtime_ids () = [])

let test_image_capable_vision_runtime_is_admitted_without_schema_capability () =
  with_temp_runtime_toml image_capable_vision_runtime_toml (fun () ->
    assert (Vt.vision_runtime_ids () = [ "local.vision" ]);
    (match Vt.first_vision_runtime_id () with
     | Ok "local.vision" -> ()
     | Ok runtime_id -> failwith ("unexpected vision runtime admitted: " ^ runtime_id)
     | Error msg -> failwith ("image-capable runtime was rejected: " ^ msg)))

let test_invalid_structured_vision_response_is_runtime_failure () =
  with_temp_runtime_toml single_vision_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-invalid-structured-response" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
        Ok (text_response "not-json")
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
      assert
        (String.equal
           (assoc_string "error" json)
           "invalid_structured_response");
      assert (String.equal (assoc_string "failure_class" json) "runtime_failure");
      assert (String_util.contains_substring (assoc_string "detail" json) "JSON parse error")))

let test_run_vision_invalid_structured_response_is_typed () =
  with_temp_runtime_toml single_vision_runtime_toml (fun () ->
    let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
      Ok (text_response "not-json")
    in
    let outcome =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          Vt.run_vision
            ~complete
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~net:(Eio.Stdenv.net env)
            ~query:"describe"
            ~media_type:"image/png"
            ~bytes:"\x89PNG\r\n\x1a\nraw"
            ()))
    in
    match outcome with
    | Vt.Vo_invalid_structured_response detail ->
      assert (String_util.contains_substring detail "JSON parse error")
    | _ -> failwith "expected Vo_invalid_structured_response")

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
      let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ ?tools:_ () =
        incr calls;
        models := config.Llm_provider.Provider_config.model_id :: !models;
        if !calls = 1 then
          Error
            (Llm_provider.Http_client.HttpError
               { code = 500; body = "down"; retry_after_header = None })
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
      assert (List.rev !models = [ "vision-a"; "vision-b" ]);
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

let test_candidate_failover_is_not_cut_off_by_local_deadline () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-deadline-provider-error" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let calls = ref 0 in
      let models = ref [] in
      let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ ?tools:_ () =
        incr calls;
        models := config.Llm_provider.Provider_config.model_id :: !models;
        Error
          (Llm_provider.Http_client.HttpError
             { code = 500; body = "down"; retry_after_header = None })
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
      assert (List.rev !models = [ "vision-a"; "vision-b" ]);
      assert (String.equal (assoc_string "error" json) "provider_error");
      assert (String.equal (assoc_string "failure_class" json) "dependency_unavailable")))

let test_non_retryable_provider_error_stops_without_trying_next_runtime () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-nonretryable-stop" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let calls = ref 0 in
      let models = ref [] in
      let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ ?tools:_ () =
        incr calls;
        models := config.Llm_provider.Provider_config.model_id :: !models;
        Error
          (Llm_provider.Http_client.HttpError
             { code = 401; body = "bad credentials"; retry_after_header = None })
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
      assert (List.rev !models = [ "vision-a" ]);
      assert (String.equal (assoc_string "error" json) "provider_error");
      assert (String.equal (assoc_string "failure_class" json) "runtime_failure")))

let test_accept_rejected_is_policy_rejection_without_failover () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-accept-rejected" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let calls = ref 0 in
      let models = ref [] in
      let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ ?tools:_ () =
        incr calls;
        models := config.Llm_provider.Provider_config.model_id :: !models;
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
      assert (List.rev !models = [ "vision-a" ]);
      assert (String.equal (assoc_string "error" json) "provider_error");
      assert (String.equal (assoc_string "failure_class" json) "policy_rejection")))

let test_eager_eviction_reason_preserves_typed_outcome () =
  let reason = Vi.eager_read_eviction_reason_of_outcome in
  assert (reason (Vt.Vo_ok "text") = None);
  assert (reason Vt.Vo_empty = Some "eager_empty");
  assert (reason Vt.Vo_truncated = Some "eager_truncated");
  assert (reason Vt.Vo_timeout = Some "eager_timeout");
  assert (reason (Vt.Vo_no_runtime "missing") = Some "eager_no_runtime");
  assert (reason (Vt.Vo_invalid_request "bad") = Some "eager_invalid_request");
  assert
    (reason (Vt.Vo_invalid_structured_response "bad json")
     = Some "eager_invalid_structured_response");
  assert
    (reason
       (Vt.Vo_provider { failure_class = Tool_result.Runtime_failure; detail = "boom" })
     = Some "eager_provider_error")

let test_delegate_eager_eviction_stores_image_and_removes_inline_block () =
  with_temp_base (fun _ ->
    let keeper_name = "vision-ingest-delegate" in
    let bytes = "\x89PNG\r\n\x1a\ninline-image" in
    let metric_labels =
      [ "mode", "eager"; "result", "ok"; "reason", "stored_unread" ]
    in
    let before =
      metric_value Keeper_metrics.VisionIngestEvictions ~labels:metric_labels
    in
    let blocks =
      [ Agent_core.Types.Text "before"
      ; Agent_core.Types.Image
          { media_type = "image/png"
          ; data = Base64.encode_string bytes
          ; source_type = Agent_core.Types.Base64
          }
      ; Agent_core.Types.Text "after"
      ]
    in
    match
      Vi.evict_blocks
        ~mode:Vi.Eager
        ~delegate:true
        ~keeper_name
        blocks
    with
    | [ Agent_core.Types.Text "before"
      ; Agent_core.Types.Text placeholder
      ; Agent_core.Types.Text "after"
      ] ->
      assert (String_util.contains_substring placeholder "[image artifact:");
      assert (String_util.contains_substring placeholder "media_type:image/png");
      assert (String_util.contains_substring placeholder "not yet read");
      let handle = artifact_handle_of_placeholder placeholder in
      (match
         Store.load
           ~dir:(Vt.vision_store_dir ~keeper_name)
           (Store.of_string handle)
       with
       | Ok stored -> assert (String.equal stored bytes)
       | Error msg -> failwith msg);
      assert_metric_increment
        "vision_ingest stored_unread"
        before
        (metric_value Keeper_metrics.VisionIngestEvictions ~labels:metric_labels)
    | _ -> failwith "delegate eviction should replace the image with text")

let test_delegate_eviction_rejects_invalid_media_type_before_store () =
  with_temp_base (fun _ ->
    let keeper_name = "vision-ingest-invalid-media" in
    let bytes = "\x89PNG\r\n\x1a\ninline-image" in
    let metric_labels =
      [ "mode", "store_only"; "result", "error"; "reason", "invalid_media_type" ]
    in
    let before =
      metric_value Keeper_metrics.VisionIngestEvictions ~labels:metric_labels
    in
    match
      Vi.evict_blocks
        ~mode:Vi.Store_only
        ~delegate:true
        ~keeper_name
        [ Agent_core.Types.Image
            { media_type = "text/plain"
            ; data = Base64.encode_string bytes
            ; source_type = Agent_core.Types.Base64
            }
        ]
    with
    | [ Agent_core.Types.Text placeholder ] ->
      assert (String_util.contains_substring placeholder "unsupported image media type");
      assert_metric_increment
        "vision_ingest invalid_media_type"
        before
        (metric_value Keeper_metrics.VisionIngestEvictions ~labels:metric_labels)
    | _ -> failwith "invalid media type must surface as a text placeholder")

let test_delegate_eviction_rejects_oversize_before_store () =
  with_env "MASC_KEEPER_VISION_MAX_IMAGE_BYTES" "8" (fun () ->
    with_temp_base (fun _ ->
      let keeper_name = "vision-ingest-oversize" in
      let bytes = "\x89PNG\r\n\x1a\ninline-image" in
      match
        Vi.evict_blocks
          ~mode:Vi.Store_only
          ~delegate:true
          ~keeper_name
          [ Agent_core.Types.Image
              { media_type = "image/png"
              ; data = Base64.encode_string bytes
              ; source_type = Agent_core.Types.Base64
              }
          ]
      with
      | [ Agent_core.Types.Text placeholder ] ->
        assert (String_util.contains_substring placeholder "image too large")
      | _ -> failwith "oversize image must surface as a text placeholder"))

let test_delegate_eviction_bad_base64_surfaces_redacted_text_error () =
  match
    Vi.evict_blocks
      ~mode:Vi.Store_only
      ~delegate:true
      ~keeper_name:"vision-ingest-bad-base64"
      [ Agent_core.Types.Image
          { media_type = "image/png"
          ; data = "not base64"
          ; source_type = Agent_core.Types.Base64
          }
      ]
  with
  | [ Agent_core.Types.Text placeholder ] ->
    assert (String_util.contains_substring placeholder "could not store");
    assert (String_util.contains_substring placeholder "invalid image payload");
    assert (not (String_util.contains_substring placeholder "bad base64"))
  | _ -> failwith "bad base64 must surface as a redacted text placeholder"

let test_delegate_eviction_rejects_non_base64_source_before_store () =
  List.iter
    (fun source_type ->
      let source_name = Agent_core.Types.media_source_kind_to_string source_type in
      let metric_labels =
        [ "mode", "store_only"; "result", "error"; "reason", "invalid_source_type" ]
      in
      let before =
        metric_value Keeper_metrics.VisionIngestEvictions ~labels:metric_labels
      in
      match
        Vi.evict_blocks
          ~mode:Vi.Store_only
          ~delegate:true
          ~keeper_name:("vision-ingest-source-" ^ source_name)
          [ Agent_core.Types.Image
              { media_type = "image/png"
              ; data = "https://example.invalid/image.png"
              ; source_type
              }
          ]
      with
      | [ Agent_core.Types.Text placeholder ] ->
        assert (String_util.contains_substring placeholder "could not store");
        assert (String_util.contains_substring placeholder "unsupported image source");
        assert_metric_increment
          ("vision_ingest invalid_source_type " ^ source_name)
          before
          (metric_value Keeper_metrics.VisionIngestEvictions ~labels:metric_labels)
      | _ -> failwith "non-base64 image source must surface as a text placeholder")
    [ Agent_core.Types.Url; Agent_core.Types.File_id ]

let test_non_delegate_eviction_preserves_inline_image () =
  let bytes = "raw-image" in
  let blocks =
    [ Agent_core.Types.Image
        { media_type = "image/png"
        ; data = Base64.encode_string bytes
        ; source_type = Agent_core.Types.Base64
        }
    ]
  in
  match
    Vi.evict_blocks
      ~mode:Vi.Eager
      ~delegate:false
      ~keeper_name:"vision-ingest-native"
      blocks
  with
  | [ Agent_core.Types.Image img ] ->
    assert (String.equal img.data (Base64.encode_string bytes))
  | _ -> failwith "a runtime that takes images itself should keep the inline block"

let test_delegates_media_follows_lane_capability () =
  with_temp_runtime_toml no_image_runtime_toml (fun () ->
    if not (Vi.delegates_media ~runtime_id:"p0.text")
    then failwith "a lane whose every candidate is text-only must delegate";
    if not (Vi.delegates_media ~runtime_id:"p9.absent")
    then failwith "an id naming no lane must delegate rather than drop");
  with_temp_runtime_toml single_vision_runtime_toml (fun () ->
    if Vi.delegates_media ~runtime_id:"p3.vision-c"
    then
      failwith
        "a candidate that takes images itself must keep them for the RFC-0265 \
         reroute")

let test_evicted_history_has_no_image_modality () =
  with_temp_base (fun _ ->
    let keeper_name = "vision-ingest-modality" in
    let bytes = "\x89PNG\r\n\x1a\nmodality-test" in
    let msg =
      Agent_core.Types.make_message
        ~role:Agent_core.Types.User
        [ Agent_core.Types.Text "look at this"
        ; Agent_core.Types.Image
            { media_type = "image/png"
            ; data = Base64.encode_string bytes
            ; source_type = Agent_core.Types.Base64
            }
        ]
    in
    let modalities ms =
      Runtime_agent.For_testing.required_modalities_of_messages ms
    in
    assert (List.mem "image" (modalities [ msg ]));
    let evicted =
      Vi.evict_message
        ~mode:Vi.Store_only
        ~delegate:true
        ~keeper_name
        msg
    in
    assert (not (List.mem "image" (modalities [ evicted ])));
    let evicted2 =
      Vi.evict_message
        ~mode:Vi.Store_only
        ~delegate:true
        ~keeper_name
        evicted
    in
    assert (evicted2 = evicted))

let truncated_json_response ~stop_reason : Agent_core.Types.api_response =
  (* A reply cut off mid-JSON: the closing quote and brace never arrive, so the
     structured parse fails. This is what a MaxTokens budget cut produces. *)
  { id = "vision-test"
  ; model = "vision-test-model"
  ; stop_reason
  ; content = [ Agent_core.Types.Text {|{"text":"a red circle on a white backg|} ]
  ; usage = None
  ; telemetry = None
  }

let test_vision_output_tokens_default_and_env () =
  (* Reasoning models count thinking as output tokens; a 4096 cap let the
     reasoning phase truncate the answer (2026-08-27 MiniMax M3 live probe).
     The default is now generous (65536, above the ~25000 reasoning-plus-output
     reserve) so reasoning has room for the answer, and operators can retune it
     through the env knob. *)
  assert (Vt.vision_default_max_tokens () = 65536);
  with_env "MASC_KEEPER_VISION_MAX_OUTPUT_TOKENS" "50000" (fun () ->
    assert (Vt.vision_default_max_tokens () = 50000))

let test_truncated_structured_response_reads_as_truncation () =
  (* mid-JSON parse failure + MaxTokens stop = the budget cut the reply short,
     not a malformed model. Report the real cause so the remedy (a larger
     budget) is legible instead of a misleading parser fault. *)
  (match
     Vt.outcome_of_response
       (truncated_json_response ~stop_reason:Agent_core.Types.MaxTokens)
   with
   | Vt.Vo_truncated -> ()
   | _ -> failwith "MaxTokens-cut mid-JSON must classify as Vo_truncated");
  (* The same broken text with a clean stop is a genuine structured failure. *)
  (match
     Vt.outcome_of_response
       (truncated_json_response ~stop_reason:Agent_core.Types.EndTurn)
   with
   | Vt.Vo_invalid_structured_response _ -> ()
   | _ ->
     failwith
       "mid-JSON parse failure with a clean stop must stay \
        Vo_invalid_structured_response");
  (* A well-formed reply is unaffected by the reclassification. *)
  match Vt.outcome_of_response (ok_response "a red circle") with
  | Vt.Vo_ok text -> assert (text = "a red circle")
  | _ -> failwith "valid structured JSON must classify as Vo_ok"

let () =
  test_vision_output_tokens_default_and_env ();
  test_truncated_structured_response_reads_as_truncation ();
  test_truncated_of_stop_reason ();
  test_message_of_request ();
  test_first_vision_runtime_id_total ();
  test_provider_for_vision_preserves_configured_max_tokens ();
  test_provider_for_vision_leaves_thinking_uncontrolled ();
  test_max_image_bytes_reads_env_config ();
  test_vision_env_knobs_are_bounded ();
  test_missing_eio_context_is_runtime_failure ();
  test_invalid_media_type_is_policy_rejection ();
  test_missing_clock_is_runtime_failure_without_provider_call ();
  test_non_string_media_type_is_policy_rejection ();
  test_unknown_magic_bytes_are_policy_rejection ();
  test_oversize_image_is_runtime_failure_before_provider_call ();
  test_temp_runtime_toml_restores_runtime_cache ();
  test_image_capable_vision_runtime_is_admitted_without_schema_capability ();
  test_provider_for_vision_uses_runtime_temperature ();
  test_uncapped_vision_fallback_rejects_before_provider_call ();
  test_invalid_structured_vision_response_is_runtime_failure ();
  test_run_vision_invalid_structured_response_is_typed ();
  test_retryable_provider_error_tries_next_runtime ();
  test_candidate_failover_is_not_cut_off_by_local_deadline ();
  test_non_retryable_provider_error_stops_without_trying_next_runtime ();
  test_accept_rejected_is_policy_rejection_without_failover ();
  test_eager_eviction_reason_preserves_typed_outcome ();
  test_delegate_eager_eviction_stores_image_and_removes_inline_block ();
  test_delegate_eviction_rejects_invalid_media_type_before_store ();
  test_delegate_eviction_rejects_oversize_before_store ();
  test_delegate_eviction_bad_base64_surfaces_redacted_text_error ();
  test_delegate_eviction_rejects_non_base64_source_before_store ();
  test_non_delegate_eviction_preserves_inline_image ();
  test_evicted_history_has_no_image_modality ();
  test_delegates_media_follows_lane_capability ();
  print_endline "test_keeper_vision_tool: all assertions passed"
