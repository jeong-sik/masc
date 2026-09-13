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
  match Vt.first_vision_runtime_id ~now:(Unix.gettimeofday ()) with
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
  assert (configured.clear_thinking = Some true)

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

let vision_failover_runtime_toml_with_caps ~p1_cap ~p2_cap =
  Printf.sprintf
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
max-request-body-bytes = %d

[p2.vision-b]
max-request-body-bytes = %d
|}
    p1_cap
    p2_cap

let vision_failover_runtime_toml =
  vision_failover_runtime_toml_with_caps ~p1_cap:65536 ~p2_cap:65536

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
(* [p4.vision-a] is the image-capable runtime this case wants reached, and it
   is named in [media_failover] because that is what declares a runtime as an
   image candidate for a keeper that does not route to it. It used to be
   reachable by being declared at all, which is the tail #34823 removed: that
   tail was the set boot does not validate dispatch caps for. The capped
   [p0.text] stays ahead of it, which is the point -- the vision path must not
   inherit that cap. *)
let uncapped_vision_fallback_runtime_toml =
  {|
[runtime]
default = "p0.text"
media_failover = ["p0.text", "p4.vision-a"]

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
    match Vt.first_vision_runtime_id ~now:(Unix.gettimeofday ()) with
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

let test_uncapped_vision_fallback_reaches_provider () =
  with_temp_runtime_toml uncapped_vision_fallback_runtime_toml (fun () ->
    let provider_calls = ref 0 in
    let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ ?tools:_ () =
      assert (config.Llm_provider.Provider_config.max_request_body_bytes = None);
      incr provider_calls;
      Ok (ok_response "uncapped vision reached provider")
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
    assert (!provider_calls = 1);
    match outcome with
    | Vt.Vo_ok { text = "uncapped vision reached provider"; _ } -> ()
    | _ -> failwith "uncapped vision fallback should reach provider")

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
  assert (Vt.vision_runtime_ids ~now:(Unix.gettimeofday ()) = [])

let test_image_capable_vision_runtime_is_admitted_without_schema_capability () =
  with_temp_runtime_toml image_capable_vision_runtime_toml (fun () ->
    assert (Vt.vision_runtime_ids ~now:(Unix.gettimeofday ()) = [ "local.vision" ]);
    (match Vt.first_vision_runtime_id ~now:(Unix.gettimeofday ()) with
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
      let outcome =
        Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
            Vt.handle_with_outcome
              ~complete
              ~sw
              ~clock:(Eio.Stdenv.clock env)
              ~net:(Eio.Stdenv.net env)
              ~meta
              ~args:(artifact_args handle)
              ()))
      in
      assert (outcome.failure_effect_disposition = Tool_result.Proven_pre_effect);
      let raw = outcome.raw_output in
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

let test_explicit_vision_runtime_selection () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-selected" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        let run selected response =
          let calls = ref [] in
          let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ ?tools:_ () =
            calls := config.Llm_provider.Provider_config.model_id :: !calls;
            response
          in
          let args = match artifact_args handle with
            | `Assoc fields -> `Assoc (("runtime_id", selected) :: fields)
            | _ -> failwith "artifact fixture must be an object"
          in
          let raw = Vt.handle ~complete ~sw ~clock:(Eio.Stdenv.clock env)
            ~net:(Eio.Stdenv.net env) ~meta ~args () in
          json_of_output raw, List.rev !calls
        in
        let json, calls = run (`String "p2.vision-b") (Ok (ok_response "selected reader")) in
        assert (calls = ["vision-b"]);
        assert (assoc_string "runtime_id" json = "p2.vision-b");
        assert (assoc_string "text" json = "selected reader");
        let json, calls = run (`String "p2.vision-b")
          (Error (Llm_provider.Http_client.HttpError
            { code = 500; body = "selected unavailable"; retry_after_header = None })) in
        assert (calls = ["vision-b"]);
        assert (assoc_string "error" json = "provider_error");
        List.iter (fun (selected, code) ->
          let json, calls = run selected (Ok (ok_response "must not run")) in
          assert (calls = []);
          assert (assoc_string "error" json = code))
          [`String "missing.vision", "invalid_request";
           `String "", "invalid_args"; `Int 1, "invalid_args"; `Null, "invalid_args"]))))

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
      assert (assoc_string "runtime_id" json = "p2.vision-b");
      assert (assoc_string "requested_model" json = "vision-b");
      assert (assoc_string "response_model" json = "vision-test-model");
      assert_metric_increment
        "vision_candidate transient_provider_error"
        before_transient
        (metric_value Keeper_metrics.VisionCandidateAttempts
           ~labels:transient_labels);
      assert_metric_increment
        "vision_candidate provider_response"
        before_ok
        (metric_value Keeper_metrics.VisionCandidateAttempts ~labels:ok_labels)))

(* 2026-09-12, msx-retro-mania: one candidate answered malformed JSON under
   json_object (unescaped quotes inside the string value) and the walk
   returned that reply as its final verdict -- the terminal composition
   above it killed the whole turn. A broken structured reply is as
   candidate-local as a length stop: which backends break JSON escaping
   differs per model, and the walk exists to move on. *)
let test_invalid_structured_response_tries_next_runtime () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-invalid-json-failover" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let invalid_labels =
        [ "runtime_id", "p1.vision-a"
        ; "result", "error"
        ; "reason", "invalid_structured_output"
        ]
      in
      let ok_labels =
        [ "runtime_id", "p2.vision-b"
        ; "result", "ok"
        ; "reason", "provider_response"
        ]
      in
      let before_invalid =
        metric_value Keeper_metrics.VisionCandidateAttempts
          ~labels:invalid_labels
      in
      let before_ok =
        metric_value Keeper_metrics.VisionCandidateAttempts ~labels:ok_labels
      in
      let calls = ref 0 in
      let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
        incr calls;
        if !calls = 1 then Ok (text_response "not-json")
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
      assert (String.equal (assoc_string "text" json) "second runtime answered");
      assert (assoc_string "runtime_id" json = "p2.vision-b");
      assert_metric_increment
        "vision_candidate invalid_structured_output"
        before_invalid
        (metric_value Keeper_metrics.VisionCandidateAttempts
           ~labels:invalid_labels);
      assert_metric_increment
        "vision_candidate provider_response"
        before_ok
        (metric_value Keeper_metrics.VisionCandidateAttempts
           ~labels:ok_labels)))

(* 2026-09-07: glm-coding.glm-4.6v answered HTTP 400 (max_tokens out of its
   range) and the walk stopped there, never reaching the local runtime behind
   it that takes the same pixels. A 400 is one binding's verdict, so the walk
   must advance -- and without the transient backoff, which is for outages. *)
let test_candidate_policy_error_tries_next_runtime () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-policy-failover" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let policy_labels =
        [ "runtime_id", "p1.vision-a"
        ; "result", "error"
        ; "reason", "candidate_policy_error"
        ]
      in
      let ok_labels =
        [ "runtime_id", "p2.vision-b"
        ; "result", "ok"
        ; "reason", "provider_response"
        ]
      in
      let before_policy =
        metric_value Keeper_metrics.VisionCandidateAttempts ~labels:policy_labels
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
               { code = 400
               ; body = "{\"error\":{\"code\":\"1210\",\"message\":\"max_tokens illegal\"}}"
               ; retry_after_header = None
               })
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
      assert (assoc_string "runtime_id" json = "p2.vision-b");
      assert (assoc_string "requested_model" json = "vision-b");
      assert (assoc_string "response_model" json = "vision-test-model");
      assert_metric_increment
        "vision_candidate candidate_policy_error"
        before_policy
        (metric_value Keeper_metrics.VisionCandidateAttempts ~labels:policy_labels);
      assert_metric_increment
        "vision_candidate provider_response"
        before_ok
        (metric_value Keeper_metrics.VisionCandidateAttempts ~labels:ok_labels)))

(* RFC-0440 §3: a candidate whose account answered a hard quota rejection moves
   behind the live ones; a success on that account clears the observation. *)
let test_vision_candidates_follow_quota_window () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    Runtime_quota_window.reset_for_testing ();
    Fun.protect ~finally:Runtime_quota_window.reset_for_testing (fun () ->
      let now = Unix.gettimeofday () in
      let scope id =
        match Runtime.get_runtime_by_id id with
        | Some rt -> Runtime.quota_scope_of_runtime rt
        | None -> failwith ("missing runtime " ^ id)
      in
      assert (Vt.vision_runtime_ids ~now = [ "p1.vision-a"; "p2.vision-b" ]);
      Runtime_quota_window.note_observed_exhausted ~scope:(scope "p1.vision-a");
      assert (Vt.vision_runtime_ids ~now = [ "p2.vision-b"; "p1.vision-a" ]);
      Runtime_quota_window.note_succeeded ~scope:(scope "p1.vision-a");
      assert (Vt.vision_runtime_ids ~now = [ "p1.vision-a"; "p2.vision-b" ])))

(* RFC-0440 §3: a 402 from the read walk is recorded on that account, the walk
   moves on at once, and the answering account is recorded as live. *)
let test_vision_402_marks_the_account_exhausted_and_moves_on () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      Runtime_quota_window.reset_for_testing ();
      Fun.protect ~finally:Runtime_quota_window.reset_for_testing (fun () ->
        let meta = make_meta "vision-402-failover" in
        let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
        let scope id =
          match Runtime.get_runtime_by_id id with
          | Some rt -> Runtime.quota_scope_of_runtime rt
          | None -> failwith ("missing runtime " ^ id)
        in
        let calls = ref 0 in
        let models = ref [] in
        let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ ?tools:_ () =
          incr calls;
          models := config.Llm_provider.Provider_config.model_id :: !models;
          if !calls = 1 then
            Error
              (Llm_provider.Http_client.HttpError
                 { code = 402
                 ; body = "{\"error\":{\"message\":\"Insufficient Balance\"}}"
                 ; retry_after_header = None
                 })
          else Ok (ok_response "second account answered")
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
        assert (String.equal (assoc_string "text" json) "second account answered");
        let now = Unix.gettimeofday () in
        assert (Runtime_quota_window.is_exhausted ~scope:(scope "p1.vision-a") ~now);
        assert (not (Runtime_quota_window.is_exhausted ~scope:(scope "p2.vision-b") ~now));
        assert (Vt.vision_runtime_ids ~now = [ "p2.vision-b"; "p1.vision-a" ]))))

(* When every candidate answers 400 the walk still ends as a policy rejection
   carrying the last verdict, so a keeper learns the field, not "no runtime". *)
let test_policy_error_on_every_candidate_is_reported () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-policy-exhausted" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let calls = ref 0 in
      let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
        incr calls;
        Error
          (Llm_provider.Http_client.HttpError
             { code = 400; body = "field refused"; retry_after_header = None })
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
      assert (String.equal (assoc_string "error" json) "provider_error");
      assert (String.equal (assoc_string "failure_class" json) "policy_rejection");
      assert (String_util.contains_substring (assoc_string "detail" json) "field refused")))

(* Mixed order: a 400 the walk moved past, then a 500 on the last candidate.
   The outcome is the last candidate's -- what ended the walk -- and the 400
   verdict lives on the candidate counter, not in the tool result. *)
let test_policy_error_then_transient_reports_the_last_candidate () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-policy-then-transient" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let calls = ref 0 in
      let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
        incr calls;
        if !calls = 1 then
          Error
            (Llm_provider.Http_client.HttpError
               { code = 400; body = "field refused"; retry_after_header = None })
        else
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
      assert (String.equal (assoc_string "error" json) "provider_error");
      assert (String.equal (assoc_string "failure_class" json) "dependency_unavailable");
      assert (String_util.contains_substring (assoc_string "detail" json) "down")))

let test_capacity_failover_preserves_image_and_declared_caps () =
  let errors =
    [ Llm_provider.Http_client.request_body_too_large_error
        ~actual_bytes:1_172_224 ~limit_bytes:65_536
    ; Llm_provider.Http_client.ProviderFailure
        { kind = Llm_provider.Http_client.Context_overflow { limit = Some 4096 }
        ; message = "image context exceeds this candidate"
        }
    ; Llm_provider.Http_client.HttpError
        { code = 413; body = "payload refused"; retry_after_header = None }
    ]
  in
  List.iter
    (fun error ->
      with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
        let calls = ref [] in
        let first_messages = ref None in
        let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages ?tools:_ () =
          assert (config.Llm_provider.Provider_config.max_request_body_bytes = Some 65_536);
          calls := config.model_id :: !calls;
          match !first_messages with
          | None ->
            first_messages := Some messages;
            Error error
          | Some original ->
            assert (messages = original);
            assert
              (Runtime_agent.For_testing.required_modalities_of_messages messages
               = [ "image" ]);
            Ok (ok_response "image read on the next runtime")
        in
        let outcome =
          Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
              Vt.run_vision ~complete ~sw
                ~clock:(Eio.Stdenv.clock env) ~net:(Eio.Stdenv.net env)
                ~query:"read the screenshot" ~media_type:"image/png"
                ~bytes:"\x89PNG\r\n\x1a\nraw" ()))
        in
        assert (List.rev !calls = [ "vision-a"; "vision-b" ]);
        (match outcome with
           | Vt.Vo_ok reading ->
             assert (reading.text = "image read on the next runtime");
             assert (reading.runtime_id = "p2.vision-b");
             assert (reading.requested_model = "vision-b");
             assert (reading.response_model = "vision-test-model")
           | _ -> failwith "expected successful fallback reading")))
    errors

let test_capacity_exhaustion_retains_size_failure () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    let calls = ref 0 in
    let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
      incr calls;
      Error
        (Llm_provider.Http_client.HttpError
           { code = 413; body = "payload refused"; retry_after_header = None })
    in
    let outcome =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          Vt.run_vision ~complete ~sw
            ~clock:(Eio.Stdenv.clock env) ~net:(Eio.Stdenv.net env)
            ~query:"read the screenshot" ~media_type:"image/png"
            ~bytes:"\x89PNG\r\n\x1a\nraw" ()))
    in
    assert (!calls = 2);
    match outcome with
    | Vt.Vo_provider { failure_class = Tool_result.Runtime_failure; detail } ->
      assert (String_util.contains_substring detail "413")
    | _ -> failwith "exhausted image capacity must remain a visible runtime failure")

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

(* A 401 is one binding's key being refused; the next candidate carries its
   own key. It used to end the walk after one call. *)
let test_credential_error_tries_next_runtime () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-credential-failover" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let policy_labels =
        [ "runtime_id", "p1.vision-a"
        ; "result", "error"
        ; "reason", "candidate_policy_error"
        ]
      in
      let before_policy =
        metric_value Keeper_metrics.VisionCandidateAttempts ~labels:policy_labels
      in
      let calls = ref 0 in
      let models = ref [] in
      let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ ?tools:_ () =
        incr calls;
        models := config.Llm_provider.Provider_config.model_id :: !models;
        if !calls = 1 then
          Error
            (Llm_provider.Http_client.HttpError
               { code = 401; body = "bad credentials"; retry_after_header = None })
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
      assert (assoc_string "runtime_id" json = "p2.vision-b");
      assert (assoc_string "requested_model" json = "vision-b");
      assert (assoc_string "response_model" json = "vision-test-model");
      assert_metric_increment
        "vision_candidate candidate_policy_error (401)"
        before_policy
        (metric_value Keeper_metrics.VisionCandidateAttempts ~labels:policy_labels)))

module Fit = Masc.Keeper_vision_cap_fit

let tiny_png = "\x89PNG\r\n\x1a\nraw"
let tight_cap = 1024

(* Under the tight cap the tiny image still does not fit: the envelope
   allowance alone is above it, and its header carries no dimensions to
   shrink by, so the walk must move on without a call. *)
let test_cap_fit_sends_a_small_image_as_is () =
  match
    Fit.plan ~cap_bytes:65536 ~image_bytes:(String.length tiny_png) ~query_bytes:5
      ~longest_edge:None ~min_edge:256
  with
  | Fit.Sends_as_is -> ()
  | Fit.Shrink_longest_edge_to _ | Fit.Cannot_fit _ ->
    failwith "an image under the cap is sent unchanged"

let test_cap_fit_cannot_plan_without_dimensions () =
  let image_bytes = String.length tiny_png in
  match
    Fit.plan ~cap_bytes:tight_cap ~image_bytes ~query_bytes:5 ~longest_edge:None
      ~min_edge:256
  with
  | Fit.Cannot_fit { needed_bytes; cap_bytes } ->
    assert (cap_bytes = tight_cap);
    assert (needed_bytes = Fit.needed_bytes ~image_bytes ~query_bytes:5);
    assert (needed_bytes = Fit.base64_length image_bytes + 5 + Fit.envelope_allowance_bytes)
  | Fit.Sends_as_is | Fit.Shrink_longest_edge_to _ ->
    failwith "without dimensions there is no edge to shrink to"

(* The 1568px screenshot of 2026-09-07 (699,071 bytes) against the deepseek
   cap. The predicted size at the planned edge must be under the cap, and
   the edge must sit between the floor and the current edge. *)
let test_cap_fit_shrinks_by_the_byte_ratio () =
  let image_bytes = 699_071 and edge = 1568 and cap_bytes = 262_144 in
  match
    Fit.plan ~cap_bytes ~image_bytes ~query_bytes:20 ~longest_edge:(Some edge)
      ~min_edge:256
  with
  | Fit.Shrink_longest_edge_to fitted ->
    assert (fitted >= 256 && fitted < edge);
    let scale = float_of_int fitted /. float_of_int edge in
    let predicted_image_bytes =
      int_of_float (float_of_int image_bytes *. scale *. scale)
    in
    assert (Fit.needed_bytes ~image_bytes:predicted_image_bytes ~query_bytes:20 <= cap_bytes)
  | Fit.Sends_as_is | Fit.Cannot_fit _ ->
    failwith "an image with known dimensions over the cap is shrunk"

let test_cap_fit_refuses_below_the_edge_floor () =
  match
    Fit.plan ~cap_bytes:8192 ~image_bytes:699_071 ~query_bytes:20
      ~longest_edge:(Some 1568) ~min_edge:256
  with
  | Fit.Cannot_fit _ -> ()
  | Fit.Sends_as_is | Fit.Shrink_longest_edge_to _ ->
    failwith "an edge under the floor is not worth a scaler run"

let test_cap_fit_refuses_an_empty_image_without_dividing () =
  match
    Fit.plan ~cap_bytes:1024 ~image_bytes:0 ~query_bytes:20000
      ~longest_edge:(Some 1568) ~min_edge:256
  with
  | Fit.Cannot_fit _ -> ()
  | Fit.Sends_as_is | Fit.Shrink_longest_edge_to _ ->
    failwith "an empty image has no byte ratio to scale by"

let test_cap_fit_refuses_when_the_cap_leaves_no_room () =
  match
    Fit.plan ~cap_bytes:100 ~image_bytes:699_071 ~query_bytes:20
      ~longest_edge:(Some 1568) ~min_edge:256
  with
  | Fit.Cannot_fit _ -> ()
  | Fit.Sends_as_is | Fit.Shrink_longest_edge_to _ ->
    failwith "a cap under the envelope cannot carry any image"

(* p1's cap is under the envelope; p2's is not. The walk skips p1 without a
   call, counts the skip under p1's id, and p2 answers. *)
let test_image_over_a_candidates_cap_skips_to_the_next_without_a_call () =
  with_temp_runtime_toml
    (vision_failover_runtime_toml_with_caps ~p1_cap:tight_cap ~p2_cap:65536)
    (fun () ->
      with_temp_base (fun _ ->
        let meta = make_meta "vision-cap-skip" in
        let handle = store_image meta tiny_png in
        let skip_labels =
          [ "runtime_id", "p1.vision-a"; "result", "skipped"; "reason", "image_exceeds_cap" ]
        in
        let before_skip =
          metric_value Keeper_metrics.VisionCandidateAttempts ~labels:skip_labels
        in
        let calls = ref 0 in
        let models = ref [] in
        let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ ?tools:_ () =
          incr calls;
          models := config.Llm_provider.Provider_config.model_id :: !models;
          Ok (ok_response "second runtime answered")
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
        assert (!models = [ "vision-b" ]);
        assert (String.equal (assoc_string "text" json) "second runtime answered");
        assert (assoc_string "runtime_id" json = "p2.vision-b");
        assert (assoc_string "requested_model" json = "vision-b");
        assert (assoc_string "response_model" json = "vision-test-model");
        assert_metric_increment
          "vision_candidate skipped image_exceeds_cap"
          before_skip
          (metric_value Keeper_metrics.VisionCandidateAttempts ~labels:skip_labels)))

(* Every cap is under the envelope: no call is made and the walk reports the
   size failure the client would have raised, naming the last cap. *)
let test_image_over_every_cap_is_a_size_failure_without_a_call () =
  with_temp_runtime_toml
    (vision_failover_runtime_toml_with_caps ~p1_cap:tight_cap ~p2_cap:tight_cap)
    (fun () ->
      let calls = ref 0 in
      let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
        incr calls;
        Ok (ok_response "must not be reached")
      in
      let outcome =
        Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
            Vt.run_vision ~complete ~sw
              ~clock:(Eio.Stdenv.clock env) ~net:(Eio.Stdenv.net env)
              ~query:"read the screenshot" ~media_type:"image/png"
              ~bytes:tiny_png ()))
      in
      assert (!calls = 0);
      match outcome with
      | Vt.Vo_provider { failure_class = Tool_result.Runtime_failure; detail } ->
        assert (String_util.contains_substring detail (string_of_int tight_cap))
      | _ -> failwith "an image no candidate can carry is a visible runtime failure")

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
  assert (reason (Vt.outcome_of_response ~runtime_id:"test.vision" ~requested_model:"vision-test" (ok_response "text")) = None);
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
      assert
        (String_util.contains_substring placeholder
           "call keeper_analyze_image to read it");
      let handle = artifact_handle_of_placeholder placeholder in
      (match
         Store.load
           ~dir:(Vt.vision_store_dir ~keeper_name)
           (Store.of_string handle)
       with
       | Ok stored -> assert (String.equal stored bytes)
       | Error msg -> failwith (Store.load_error_to_string msg));
      assert_metric_increment
        "vision_ingest stored_unread"
        before
        (metric_value Keeper_metrics.VisionIngestEvictions ~labels:metric_labels)
    | _ -> failwith "delegate eviction should replace the image with text")

let test_fallback_projection_preserves_artifacts_and_caches_each_mode () =
  with_temp_base (fun _ ->
    let keeper_name = "vision-fallback-projection" in
    let bytes = "\x89PNG\r\n\x1a\noriginal-image" in
    let image =
      Agent_core.Types.Image
        { media_type = "image/png"; data = Base64.encode_string bytes
        ; source_type = Agent_core.Types.Base64 }
    in
    let nested =
      Agent_core.Types.ToolResult
        { tool_use_id = "read-screen"; content = "screenshot"
        ; outcome = Agent_core.Types.Tool_succeeded; json = None
        ; content_blocks = Some [ image ] }
    in
    let original = [ Agent_core.Types.Text "inspect"; image; nested ] in
    let canonical_before = original in
    let project = Vi.fallback_projector ~keeper_name () in
    let labels = [ "mode", "eager"; "result", "ok"; "reason", "stored_unread" ] in
    let before = metric_value Keeper_metrics.VisionIngestEvictions ~labels in
    let projected = project ~mode:Vi.Eager original in
    assert (projected.delegated_images = 2);
    assert (project ~mode:Vi.Eager original = projected);
    assert_metric_increment "repeated and nested image reads cached" before
      (metric_value Keeper_metrics.VisionIngestEvictions ~labels);
    let assert_stored = function
      | Agent_core.Types.Text placeholder ->
        let handle = artifact_handle_of_placeholder placeholder |> Store.of_string in
        (match Store.load ~dir:(Vt.vision_store_dir ~keeper_name) handle with
         | Ok stored -> assert (stored = bytes)
         | Error error -> failwith (Store.load_error_to_string error))
      | _ -> failwith "fallback image must carry its durable artifact"
    in
    (match projected.blocks with
     | [ Agent_core.Types.Text "inspect"; direct
       ; Agent_core.Types.ToolResult
           { content_blocks = Some [ nested ]; content = "screenshot"; _ } ] ->
       assert_stored direct;
       assert (direct = nested)
     | _ -> failwith "fallback must preserve nested tool result structure");
    let labels = [ "mode", "store_only"; "result", "ok"; "reason", "stored" ] in
    let before = metric_value Keeper_metrics.VisionIngestEvictions ~labels in
    let historical = project ~mode:Vi.Store_only [ image; nested ] in
    assert (project ~mode:Vi.Store_only [ image; nested ] = historical);
    assert_metric_increment "historical duplicate image stored once" before
      (metric_value Keeper_metrics.VisionIngestEvictions ~labels);
    (match historical.blocks with
     | direct :: _ -> assert_stored direct
     | [] -> failwith "historical image lost");
    assert (original = canonical_before);
    assert
      (Runtime_agent.For_testing.required_modalities_of_content_blocks original
       = [ "image" ]))

(* The projector is built once per lane walk and carries that walk's spent
   accounts. A projector that dropped them would send the delegation back to
   the runtimes the walk just tried (#34829). One eager read per turn is the
   budget ([max_eager_reads_per_turn]), so the boundary is observed once. *)
let test_fallback_read_receives_the_walks_excluded_runtimes () =
  with_temp_base (fun _ ->
    let keeper_name = "vision-fallback-exclusion" in
    let bytes = "\x89PNG\r\n\x1a\nexclusion-fixture" in
    let image =
      Agent_core.Types.image_block ~media_type:"image/png"
        ~data:(Base64.encode_string bytes) ()
    in
    let seen = ref [] in
    let read ~exclude_runtime_ids ~media_type:_ ~bytes:_ =
      seen := exclude_runtime_ids :: !seen;
      Some (Ok "reading")
    in
    let project =
      Vi.For_testing.fallback_projector
        ~exclude_runtime_ids:[ "glm-coding.glm-5.3"; "deepseek.deepseek-v4-flash" ]
        ~read ~keeper_name ()
    in
    ignore (project ~mode:Vi.Eager [ image ]);
    match !seen with
    | [ ids ] ->
      assert (ids = [ "glm-coding.glm-5.3"; "deepseek.deepseek-v4-flash" ])
    | other ->
      failwith
        (Printf.sprintf "expected one delegated read, got %d" (List.length other)))

let test_fallback_semantic_read_is_cached_after_completion () =
  with_temp_base (fun _ ->
    let keeper_name = "vision-fallback-read" in
    let bytes = "\x89PNG\r\n\x1a\nsemantic-reading-fixture" in
    let image = Agent_core.Types.image_block ~media_type:"image/png"
        ~data:(Base64.encode_string bytes) () in
    let calls = ref 0 in
    let read ~exclude_runtime_ids:_ ~media_type ~bytes:received =
      incr calls;
      assert (media_type = "image/png" && received = bytes);
      Some (Ok "The screenshot says deployment failed, code 413.")
    in
    let project = Vi.For_testing.fallback_projector ~read ~keeper_name () in
    let first = project ~mode:Vi.Eager [ image; image ] in
    assert (!calls = 1 && first.delegated_images = 2);
    assert (project ~mode:Vi.Eager [ image; image ] = first);
    assert (!calls = 1);
    (match first.blocks with
     | [ Agent_core.Types.Text reading; repeated ] ->
       assert (repeated = Agent_core.Types.Text reading);
       assert (String_util.contains_substring reading "deployment failed, code 413");
       let handle = artifact_handle_of_placeholder reading |> Store.of_string in
       (match Store.load ~dir:(Vt.vision_store_dir ~keeper_name) handle with
        | Ok original -> assert (original = bytes)
        | Error detail -> failwith (Store.load_error_to_string detail))
     | _ -> failwith "semantic fallback lost its reading or artifact");
    let history = project ~mode:Vi.Store_only [ image ] in
    assert (!calls = 1);
    (match history.blocks with
     | [ Agent_core.Types.Text reference ] ->
       assert (String_util.contains_substring reference "artifact:");
       assert (not (String_util.contains_substring reference "image read:"))
     | _ -> failwith "checkpoint projection must preserve an unread artifact"))

let test_cancelled_fallback_read_can_retry_without_cached_failure () =
  with_temp_base (fun _ ->
    let keeper_name = "vision-fallback-cancellation" in
    let image = Agent_core.Types.image_block ~media_type:"image/png"
        ~data:(Base64.encode_string "\x89PNG\r\n\x1a\nretry-fixture") () in
    let cancelled = Eio.Cancel.Cancelled (Failure "cancel image reading") in
    let calls = ref 0 in
    let read ~exclude_runtime_ids:_ ~media_type:_ ~bytes:_ =
      incr calls;
      if !calls = 1 then raise cancelled;
      Some (Ok "The retried image contains a green checkmark.")
    in
    let project = Vi.For_testing.fallback_projector ~read ~keeper_name () in
    (try
       ignore (project ~mode:Vi.Eager [ image ]);
       failwith "cancelled reading unexpectedly produced a projection"
     with
     | Eio.Cancel.Cancelled _ as observed -> assert (observed == cancelled));
    let retried = project ~mode:Vi.Eager [ image ] in
    assert (!calls = 2);
    (match retried.blocks with
     | [ Agent_core.Types.Text reading ] ->
       assert (String_util.contains_substring reading "green checkmark")
     | _ -> failwith "retry did not complete the semantic reading");
    assert (project ~mode:Vi.Eager [ image ] = retried);
    assert (!calls = 2))

let test_vision_candidate_cancellation_does_not_failover () =
  with_temp_runtime_toml vision_failover_runtime_toml (fun () ->
    let calls = ref 0 in
    let cancelled = Eio.Cancel.Cancelled (Failure "cancel vision candidate") in
    let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
      incr calls;
      raise cancelled
    in
    (try
       Eio_main.run (fun env ->
         Eio.Switch.run (fun sw ->
           ignore (Vt.run_vision ~complete ~sw ~clock:env#clock ~net:env#net
                     ~query:"inspect" ~media_type:"image/png"
                     ~bytes:"\x89PNG\r\n\x1a\nprovider-cancel" ())));
       failwith "provider cancellation was swallowed"
     with
     | Eio.Cancel.Cancelled _ as observed -> assert (observed == cancelled));
    assert (!calls = 1))

let test_fallback_reference_projection_is_explicitly_unread () =
  let image source_type data =
    Agent_core.Types.Image { source_type; data; media_type = "image/png" }
  in
  let original =
    [ image Agent_core.Types.Url "https://example.invalid/screenshot.png"
    ; image Agent_core.Types.File_id "file-screen-123" ]
  in
  let project = Vi.fallback_projector ~keeper_name:"vision-reference-projection" () in
  let projected = project ~mode:Vi.Eager original in
  assert (projected.delegated_images = 2);
  (match projected.blocks with
   | [ Agent_core.Types.Text url; Agent_core.Types.Text file ] ->
     assert (String_util.contains_substring url "unread image URL:");
     assert (String_util.contains_substring url "https://example.invalid/screenshot.png");
     assert (String_util.contains_substring file "unread image file ID:");
     assert (String_util.contains_substring file "file-screen-123");
     assert (not (String_util.contains_substring url "artifact:"));
     assert (not (String_util.contains_substring file "artifact:"))
   | _ -> failwith "reference fallback must retain an honest unread reference");
  assert (Runtime_agent.For_testing.required_modalities_of_content_blocks original = [ "image" ])

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

(* RFC-0430 / #33682: a URL or Files-API id is a reference, not a payload. The
   serializers put both on the wire natively (#33669), so eviction — which
   exists to trade heavy inline pixels for a local artifact handle — must hand
   the block through unchanged instead of swapping it for a store-failure
   placeholder the reader cannot act on. *)
let test_delegate_eviction_passes_reference_source_through () =
  List.iter
    (fun source_type ->
      let source_name = Agent_core.Types.media_source_kind_to_string source_type in
      let metric_labels =
        [ "mode", "store_only"; "result", "ok"; "reason", "reference_passthrough" ]
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
      | [ Agent_core.Types.Image img ] ->
        assert (String.equal img.data "https://example.invalid/image.png");
        assert (String.equal img.media_type "image/png");
        assert (
          String.equal
            (Agent_core.Types.media_source_kind_to_string img.source_type)
            source_name);
        assert_metric_increment
          ("vision_ingest reference_passthrough " ^ source_name)
          before
          (metric_value Keeper_metrics.VisionIngestEvictions ~labels:metric_labels)
      | _ -> failwith "a reference-carrying image block must pass through unchanged")
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

let test_delegates_media_matches_antigravity_transport () =
  with_temp_base (fun base_path ->
    let oauth_source = Filename.concat base_path "vision-oauth.json" in
    write_file oauth_source "{}";
    let config =
      Printf.sprintf
        {|[runtime]
default = "gravity.vision"
[providers.gravity]
protocol = "antigravity-cli"
command = "antigravity"
is-non-interactive = true
timeout-s = 30.0
[providers.gravity.credentials]
type = "file"
path = %S
[models.vision]
api-name = "vision"
max-context = 4096
[models.vision.capabilities]
supports-image-input = true
supports-multimodal-inputs = true
[gravity.vision]
|}
        oauth_source
    in
    with_temp_runtime_toml config (fun () ->
      assert (Vi.delegates_media ~runtime_id:"gravity.vision");
      let runtime =
        match Runtime.get_runtime_by_id "gravity.vision" with
        | Some runtime -> runtime
        | None -> failwith "Antigravity runtime did not materialize"
      in
      assert
        (not
           (Runtime_agent.caps_admit_required_modalities
              (Runtime_agent.input_capabilities_of_runtime runtime) [ "image" ]))))

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

let vision_output_limit_runtime_toml =
  {|
[runtime]
default = "p1.vision-a"
media_failover = ["p1.vision-a", "p1.vision-a", "p2.vision-b"]
[providers.p1]
protocol = "openai-compatible-http"
endpoint = "https://p1.example/v1"
[providers.p2]
protocol = "openai-compatible-http"
endpoint = "https://p2.example/v1"
[models.vision-a]
api-name = "vision-a"
max-context = 131072
[models.vision-a.capabilities]
max-output-tokens = 32768
supports-image-input = true
supports-multimodal-inputs = true
[models.vision-b]
api-name = "vision-b"
max-context = 131072
[models.vision-b.capabilities]
max-output-tokens = 49152
supports-image-input = true
supports-multimodal-inputs = true
[p1.vision-a]
max-tokens = 65536
max-request-body-bytes = 65536
[p2.vision-b]
max-tokens = 60000
max-request-body-bytes = 65536
|}

let test_max_tokens_failover_preserves_image_and_candidate_wire_limits () =
  let well_formed_cut =
    { (ok_response "partial answer") with stop_reason = Agent_core.Types.MaxTokens }
  in
  List.iter
    (fun cut ->
      with_temp_runtime_toml vision_output_limit_runtime_toml (fun () ->
        let calls = ref [] in
        let first_messages = ref None in
        let limit_labels =
          [ "runtime_id", "p1.vision-a"; "result", "error"; "reason", "output_token_limit" ]
        in
        let before_limit =
          metric_value Keeper_metrics.VisionCandidateAttempts ~labels:limit_labels
        in
        let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages ?tools:_ () =
          let requested, ceiling =
            match config.Llm_provider.Provider_config.model_id with
            | "vision-a" -> 65536, 32768
            | "vision-b" -> 60000, 49152
            | _ -> failwith "unexpected vision candidate"
          in
          assert (config.max_tokens = Some requested);
          let wire =
            Llm_provider.Backend_openai.build_request_assoc ~config ~messages ()
          in
          assert (Yojson.Safe.Util.member "max_tokens" wire = `Int ceiling);
          calls := config.model_id :: !calls;
          match !first_messages with
          | None -> first_messages := Some messages; Ok cut
          | Some original ->
            assert (messages = original);
            assert
              (Runtime_agent.For_testing.required_modalities_of_messages messages
               = [ "image" ]);
            Ok (ok_response "complete screenshot reading")
        in
        let outcome =
          Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
              Vt.run_vision ~complete ~sw ~clock:(Eio.Stdenv.clock env)
                ~net:(Eio.Stdenv.net env) ~query:"read the screenshot"
                ~media_type:"image/png" ~bytes:"\x89PNG\r\n\x1a\nraw" ()))
        in
        assert (List.rev !calls = [ "vision-a"; "vision-b" ]);
        assert_metric_increment "one output limit despite duplicate configured candidate"
          before_limit
          (metric_value Keeper_metrics.VisionCandidateAttempts ~labels:limit_labels);
        (match outcome with
           | Vt.Vo_ok reading ->
             assert (reading.text = "complete screenshot reading");
             assert (reading.runtime_id = "p2.vision-b");
             assert (reading.requested_model = "vision-b");
             assert (reading.response_model = "vision-test-model")
           | _ -> failwith "expected successful fallback reading")))
    [ truncated_json_response ~stop_reason:Agent_core.Types.MaxTokens; well_formed_cut ]

let test_max_tokens_exhaustion_remains_visible_tool_failure () =
  with_temp_runtime_toml vision_output_limit_runtime_toml (fun () ->
    with_temp_base (fun _ ->
      let meta = make_meta "vision-output-exhausted" in
      let handle = store_image meta "\x89PNG\r\n\x1a\nraw" in
      let calls = ref [] in
      let complete ~sw:_ ~net:_ ?clock:_ ~config ~messages:_ ?tools:_ () =
        calls := config.Llm_provider.Provider_config.model_id :: !calls;
        Ok (truncated_json_response ~stop_reason:Agent_core.Types.MaxTokens)
      in
      let raw =
        Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
            Vt.handle ~complete ~sw ~clock:(Eio.Stdenv.clock env)
              ~net:(Eio.Stdenv.net env) ~meta ~args:(artifact_args handle) ()))
      in
      let json = json_of_output raw in
      assert (List.rev !calls = [ "vision-a"; "vision-b" ]);
      assert (assoc_string "error" json = "truncated_extraction");
      assert (assoc_string "failure_class" json = "runtime_failure")))

let test_non_length_response_does_not_trigger_vision_failover () =
  (* A Refusal or ContentFilter stop is the model answering "no"; re-rolling
     the same pixels on the next candidate cannot change that verdict. *)
  List.iter
    (fun stop_reason ->
      with_temp_runtime_toml vision_output_limit_runtime_toml (fun () ->
        let calls = ref 0 in
        let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
          incr calls;
          Ok (truncated_json_response ~stop_reason)
        in
        let outcome =
          Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
              Vt.run_vision ~complete ~sw ~clock:(Eio.Stdenv.clock env)
                ~net:(Eio.Stdenv.net env) ~query:"read the screenshot"
                ~media_type:"image/png" ~bytes:"\x89PNG\r\n\x1a\nraw" ()))
        in
        assert (!calls = 1);
        match outcome with
        | Vt.Vo_invalid_structured_response _ -> ()
        | _ -> failwith "non-length terminal response must retain its original classification"))
    [ Agent_core.Types.Refusal; Agent_core.Types.ContentFilter ]

(* A finished reply (EndTurn) whose JSON broke mid-string is the json_object
   flake, not a verdict: the walk advances, and when every candidate breaks
   the same way the exhausted walk still reports the typed failure. *)
let test_end_turn_broken_json_walks_and_exhaustion_reports_typed_failure () =
  with_temp_runtime_toml vision_output_limit_runtime_toml (fun () ->
    let calls = ref 0 in
    let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
      incr calls;
      Ok (truncated_json_response ~stop_reason:Agent_core.Types.EndTurn)
    in
    let outcome =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          Vt.run_vision ~complete ~sw ~clock:(Eio.Stdenv.clock env)
            ~net:(Eio.Stdenv.net env) ~query:"read the screenshot"
            ~media_type:"image/png" ~bytes:"\x89PNG\r\n\x1a\nraw" ()))
    in
    assert (!calls = 2);
    match outcome with
    | Vt.Vo_invalid_structured_response detail ->
      (* the exhausted walk reports the LAST candidate that answered *)
      assert (String_util.contains_substring detail "p2.vision-b")
    | _ -> failwith "exhausted broken-json walk must report the typed failure")

let test_length_failover_preserves_candidate_http_recovery () =
  List.iter
    (fun code ->
      with_temp_runtime_toml vision_output_limit_runtime_toml (fun () ->
        with_env "MASC_KEEPER_VISION_CANDIDATE_BACKOFF_BASE_SEC" "0" (fun () ->
          let calls = ref 0 in
          let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
            incr calls;
            if !calls = 1 then
              Error (Llm_provider.Http_client.HttpError
                { code; body = "max_tokens request rejected"; retry_after_header = None })
            else Ok (ok_response "candidate HTTP fallback")
          in
          let outcome =
            Eio_main.run (fun env ->
              Eio.Switch.run (fun sw ->
                Vt.run_vision ~complete ~sw ~clock:(Eio.Stdenv.clock env)
                  ~net:(Eio.Stdenv.net env) ~query:"read the screenshot"
                  ~media_type:"image/png" ~bytes:"\x89PNG\r\n\x1a\nraw" ()))
          in
          assert (!calls = 2);
          (match outcome with
           | Vt.Vo_ok reading ->
             assert (reading.text = "candidate HTTP fallback");
             assert (reading.runtime_id = "p2.vision-b");
             assert (reading.requested_model = "vision-b");
             assert (reading.response_model = "vision-test-model")
           | _ -> failwith "expected successful fallback reading"))))
    [ 400; 422; 429 ]

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
     Vt.outcome_of_response ~runtime_id:"test.vision" ~requested_model:"vision-test"
       (truncated_json_response ~stop_reason:Agent_core.Types.MaxTokens)
   with
   | Vt.Vo_truncated -> ()
   | _ -> failwith "MaxTokens-cut mid-JSON must classify as Vo_truncated");
  (* The same broken text with a clean stop is a genuine structured failure. *)
  (match
     Vt.outcome_of_response ~runtime_id:"test.vision" ~requested_model:"vision-test"
       (truncated_json_response ~stop_reason:Agent_core.Types.EndTurn)
   with
   | Vt.Vo_invalid_structured_response _ -> ()
   | _ ->
     failwith
       "mid-JSON parse failure with a clean stop must stay \
        Vo_invalid_structured_response");
  (* A well-formed reply is unaffected by the reclassification. *)
  match Vt.outcome_of_response ~runtime_id:"test.vision" ~requested_model:"vision-test" (ok_response "a red circle") with
  | Vt.Vo_ok reading -> assert (reading.text = "a red circle")
  | _ -> failwith "valid structured JSON must classify as Vo_ok"

let test_browser_screenshot_reaches_vision_reader () =
  with_temp_base (fun base_path ->
    let config = Masc.Workspace.default_config base_path in
    with_temp_runtime_toml single_vision_runtime_toml (fun () ->
      let meta = make_meta "browser-screenshot" in
      let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" in
      let viewport = `Assoc ["documentId", `String "captured-document";
        "width", `Float 800.; "height", `Float 600.;
        "scrollX", `Float 0.; "scrollY", `Float 120.] in
      let verify_pointer_receipt source data =
        let field key = Yojson.Safe.Util.member key data in
        assert (assoc_string "source" data = source);
        assert (field "viewport" = viewport);
        let route = match field "clientId" with `String _ as id -> ["clientId", id] | _ -> [] in
        let request = Masc.Browser_interaction.parse (`Assoc (route @ [
          "lane", field "source"; "tabId", field "tabId";
          "expectedUrl", field "url"; "viewport", field "viewport";
          "action", `String "click_at";
          "point", `Assoc ["x", `Float 0.5; "y", `Float 0.25]])) in
        match request with
        | Ok {action = Browser_lane.Click_at {viewport = observed; _}; _} ->
          assert (observed.document_id = "captured-document");
          assert (observed.scroll_y = 120.)
        | _ -> failwith "persisted screenshot cannot address its observed viewport" in
      let seen_image = ref false in
      let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages ?tools:_ () =
        seen_image := List.exists (fun (message : Agent_core.Types.message) ->
          List.exists (function
            | Agent_core.Types.Image {media_type="image/png";data;source_type=Base64} -> data=encoded
            | _ -> false) message.content) messages;
        Ok (ok_response "stored browser pixels reached vision") in
      Eio_main.run (fun env ->
        Time_compat.set_clock (Eio.Stdenv.clock env);
        Eio.Switch.run (fun sw ->
          Browser_lane.install_automation_executor (Some (function
            | Browser_lane.Page_capture {tab_id=73} -> Browser_lane.Answered
                (`Assoc ["ok",`Bool true;"data",`Assoc [
                  "tabId",`Int 73;"url",`String "https://example.org/form";
                  "title",`String "Form";"mimeType",`String "image/png";"viewport",viewport;"data",`String encoded]])
            | _ -> failwith "unexpected screenshot command"));
          Eio.Switch.on_release sw (fun () -> Browser_lane.install_automation_executor None);
          let result = Masc.Keeper_tool_in_process_runtime.handle_browser_read_with_outcome
            ~config ~meta ~args:(`Assoc ["lane",`String "automation";"mode",`String "screenshot";"tabId",`Int 73]) in
          assert (result.disposition = Tool_result.Completed ());
          let data = match result.data with Some data -> data | None -> failwith "no screenshot metadata" in
          assert (not (String_util.contains_substring result.raw_output encoded));
          verify_pointer_receipt "automation" data;
          let handle = assoc_string "artifact" data in
          let reader = Vt.handle ~complete ~sw ~clock:(Eio.Stdenv.clock env) ~net:(Eio.Stdenv.net env)
            ~meta ~args:(artifact_args handle) () |> json_of_output in
          assert (!seen_image);
          assert (assoc_string "text" reader = "stored browser pixels reached vision");
          let connect suffix browser =
            let raw = "30000000-0000-4000-8000-" ^ suffix in
            let client_id = Result.get_ok (Browser_lane.client_id_of_string raw) in
            let info : Browser_lane.client_info = {client_id;browser;version="fixture";engine_version="155.0.1"} in
            Eio.Switch.on_release sw (fun () ->
              ignore (Browser_lane.disconnect_client ~client_id));
            let initial = Browser_lane.take_command ~client_info:info ~window_sec:0.001 in
            assert (initial = Ok None);
            info in
          let first = connect "000000000001" Browser_lane.Firefox in
          let second = connect "000000000002" Browser_lane.Zen in
          let client_id = Browser_lane.client_id_to_string first.client_id in
          List.iter (fun mode ->
            let pending = Eio.Fiber.fork_promise ~sw (fun () ->
              Masc.Keeper_tool_in_process_runtime.handle_browser_read_with_outcome ~config ~meta
                ~args:(`Assoc ["lane",`String "live";"clientId",`String client_id;
                  "mode",`String mode;"tabId",`Int 73])) in
            assert (Browser_lane.take_command ~client_info:second ~window_sec:0.001 = Ok None);
            let command = match Browser_lane.take_command ~client_info:first ~window_sec:1. with
              | Ok (Some command) -> command | _ -> failwith "selected live client received no command" in
            let data = if mode = "screenshot" then `Assoc ["tabId",`Int 73;
              "url",`String "https://example.org/form";"title",`String "Form";
              "mimeType",`String "image/png";"viewport",viewport;"data",`String encoded]
              else `Assoc ["tabId",`Int 73;"elements",`List []] in
            assert (Browser_lane.deliver_result ~client_id:first.client_id ~id:command.id
              ~payload:(`Assoc ["ok",`Bool true;"data",data]) = Ok ());
            let result = match Eio.Promise.await pending with
              | Ok result -> result | Error exn -> raise exn in
            assert (result.disposition = Tool_result.Completed ());
            let data = match result.data with Some data -> data | None -> failwith "missing client receipt" in
            assert (assoc_string "clientId" data = client_id);
            if mode = "screenshot" then verify_pointer_receipt "live" data) ["elements";"screenshot"]))))

let test_browser_screenshot_requires_keeper_owner () =
  let result = Masc.Tool_misc_browser_lane.handle_read ~tool_name:"masc_browser_read" ~start_time:0.
      (`Assoc ["lane",`String "automation";"mode",`String "screenshot";"tabId",`Int 73]) in
  match result with
  | Tool_result.Failed failure -> assert (failure.message = "screenshot requires an owning Keeper")
  | _ -> failwith "generic caller invented a Keeper screenshot owner"

let test_browser_screenshot_rejects_bad_pixels () =
  with_temp_base (fun _ ->
    List.iter (fun encoded ->
      let result = Masc.Browser_screenshot.persist ~keeper_name:"bad-browser-pixels"
        (`Assoc ["tabId",`Int 73;"url",`String "https://example.org";
          "title",`String "Page";"data",`String encoded]) in
      assert (Result.is_error result)) ["not base64!";Base64.encode_string "not a PNG"])

let test_browser_screenshot_rejects_invalid_client () =
  List.iter (fun client_id ->
    let result = Masc.Browser_screenshot.persist ~keeper_name:"invalid-browser-client"
      (`Assoc ["tabId",`Int 73;"url",`String "https://example.org";
        "title",`String "Page";"data",`String "";"clientId",client_id]) in
    match result with
    | Error ("invalid_client_id" | "invalid screenshot clientId") -> ()
    | _ -> failwith "malformed routing identity must fail before pixel persistence")
    [`String "not-a-client"; `Int 73]

let test_browser_screenshot_rejects_invalid_observation () =
  with_temp_base (fun _ ->
    let pixels = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" in
    List.iter (fun metadata ->
      let result = Masc.Browser_screenshot.persist ~keeper_name:"invalid-observation"
        (`Assoc (metadata @ ["tabId", `Int 73; "url", `String "https://example.org";
          "title", `String "Page"; "data", `String pixels])) in
      assert (Result.is_error result))
      [["source", `String "unknown"];
       ["viewport", `Null];
       ["viewport", `Assoc ["documentId", `String "doc"; "width", `Int 0;
          "height", `Int 600; "scrollX", `Int 0; "scrollY", `Int 0]]])

let test_artifact_failures_are_classified () =
  with_temp_base (fun _ ->
    let meta = make_meta "vision-artifact-errors" in
    let dir = Vt.vision_store_dir ~keeper_name:meta.name in
    let corrupt = store_image meta "original image" in
    Out_channel.with_open_bin (Filename.concat dir corrupt)
      (fun oc -> output_string oc "tampered image");
    let unreadable = String.make 64 'b' in
    Unix.mkdir (Filename.concat dir unreadable) 0o700;
    let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ ?tools:_ () =
      failwith "artifact errors must not invoke a vision provider" in
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      List.iter (fun (artifact, expected_code, expected_class) ->
        let raw = Vt.handle ~complete ~sw ~clock:(Eio.Stdenv.clock env)
          ~net:(Eio.Stdenv.net env) ~meta ~args:(artifact_args artifact) () in
        let json = json_of_output raw in
        assert (assoc_string "error" json = expected_code);
        assert (assoc_string "failure_class" json = expected_class))
        [ "bad-reference", "invalid_artifact", "policy_rejection"
        ; String.make 64 'a', "artifact_not_found", "workflow_rejection"
        ; corrupt, "artifact_load_failed", "runtime_failure"
        ; unreadable, "artifact_load_failed", "runtime_failure" ])))

(* Real PNG bytes through the production sandbox runner and store, with a fake
   Docker transport and provider spy. This proves byte admission/transport, not
   an actual container execution or semantic image understanding. *)
let test_generated_sandbox_image_reaches_vision () =
  with_temp_runtime_toml image_capable_vision_runtime_toml (fun () ->
    with_temp_base (fun base ->
      let meta = { (make_meta "generated-image") with
        sandbox_profile = Keeper_types_profile_sandbox.Docker;
        sandbox_image = Some "alpine:test" } in
      let config = Masc.Workspace.default_config base in
      let root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
      let rec mkdir path =
        if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o755)
      in
      mkdir root;
      let bytes = Base64.decode_exn "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" in
      let source = Filename.concat root "generated.png" in
      write_file source bytes;
      let docker = Filename.concat base "docker" in
      let script = Printf.sprintf
        "#!/bin/sh\ncase \"$1\" in\ninfo|image) printf '[]\\n'; exit 0;;\nrun) ;;\n*) exit 92;;\nesac\nwhile [ \"$#\" -gt 0 ] && [ \"$1\" != 'alpine:test' ]; do shift; done\nshift\n[ \"$1\" = head ] || exit 93\n[ \"$2\" = -c ] || exit 99\n[ \"$4\" = %s ] || exit 94\nexec /usr/bin/head -c \"$3\" %s\n"
        (Filename.quote (Filename.concat (Masc.Keeper_sandbox.container_root meta.name) "generated.png"))
        (Filename.quote source) in
      write_file docker script; Unix.chmod docker 0o755;
      with_env "PATH" (base ^ ":" ^ Sys.getenv "PATH") (fun () ->
      with_env "MASC_TEST_FAKE_DOCKER_PATH" docker (fun () ->
      with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "false" (fun () ->
      Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        let calls = ref 0 in
        let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages ?tools:_ () =
          incr calls;
          let expected = Vt.message_of_request
              { Va.query = "read generated image"; image_media_type = "image/png"; image_bytes = bytes } in
          assert (messages = [expected]);
          Ok (ok_response "generated image read") in
        let invoke args = Masc.Keeper_tool_in_process_runtime.handle_analyze_image_with_outcome
            ~complete ~config ~sw ~clock:(Eio.Stdenv.clock env) ~net:(Eio.Stdenv.net env)
            ~meta ~args () in
        let result = invoke (`Assoc ["path", `String "generated.png"; "query", `String "read generated image"]) in
        assert (result.disposition = Tool_result.Completed ());
        let output = json_of_output result.raw_output in
        let handle = assoc_string "artifact" output in
        assert (assoc_string "text" output = "generated image read");
        assert (Store.load ~dir:(Vt.vision_store_dir ~keeper_name:meta.name) (Store.of_string handle) = Ok bytes);
        let again = invoke (`Assoc ["artifact", `String handle; "query", `String "read generated image"]) in
        assert (again.disposition = Tool_result.Completed ());
        assert (!calls = 2);
        let bad_query = invoke (`Assoc ["path", `String "generated.png"; "query", `Int 7]) in
        assert (assoc_string "error" (json_of_output bad_query.raw_output) = "invalid_args");
        let bad_mime = invoke (`Assoc ["path", `String "generated.png"; "query", `String "read generated image"; "media_type", `String "text/plain"]) in
        assert (assoc_string "error" (json_of_output bad_mime.raw_output) = "invalid_media_type");
        let invalid = invoke (`Assoc ["artifact", `String handle; "path", `String source; "query", `String "read generated image"]) in
        assert (assoc_string "error" (json_of_output invalid.raw_output) = "invalid_args");
        let escaped = invoke (`Assoc ["path", `String "/etc/passwd"; "query", `String "read generated image"]) in
        assert (escaped.disposition <> Tool_result.Completed ());
        assert (!calls = 2);
        Unix.symlink "/etc/passwd" (Filename.concat root "outside.png");
        let symlink = invoke (`Assoc ["path", `String "outside.png"; "query", `String "read generated image"]) in
        assert (symlink.disposition <> Tool_result.Completed ());
        write_file source "not an image";
        let non_image = invoke (`Assoc ["path", `String "generated.png"; "query", `String "read generated image"]) in
        assert (assoc_string "error" (json_of_output non_image.raw_output) = "invalid_media_type");
        with_env "MASC_KEEPER_VISION_MAX_IMAGE_BYTES" "32" (fun () ->
          write_file source bytes;
          let oversized = invoke (`Assoc ["path", `String "generated.png"; "query", `String "read generated image"]) in
          assert (assoc_string "error" (json_of_output oversized.raw_output) = "image_too_large"));
        assert (!calls = 2)
      )))))))

let () =
  test_generated_sandbox_image_reaches_vision ();
  test_artifact_failures_are_classified ();
  test_browser_screenshot_rejects_invalid_client ();
  test_browser_screenshot_rejects_invalid_observation ();
  test_browser_screenshot_requires_keeper_owner ();
  test_browser_screenshot_reaches_vision_reader ();
  test_browser_screenshot_rejects_bad_pixels ();
  test_vision_output_tokens_default_and_env ();
  test_truncated_structured_response_reads_as_truncation ();
  test_max_tokens_failover_preserves_image_and_candidate_wire_limits ();
  test_max_tokens_exhaustion_remains_visible_tool_failure ();
  test_non_length_response_does_not_trigger_vision_failover ();
  test_length_failover_preserves_candidate_http_recovery ();
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
  test_uncapped_vision_fallback_reaches_provider ();
  test_invalid_structured_vision_response_is_runtime_failure ();
  test_run_vision_invalid_structured_response_is_typed ();
  test_explicit_vision_runtime_selection ();
  test_retryable_provider_error_tries_next_runtime ();
  test_invalid_structured_response_tries_next_runtime ();
  test_end_turn_broken_json_walks_and_exhaustion_reports_typed_failure ();
  test_candidate_policy_error_tries_next_runtime ();
  test_policy_error_on_every_candidate_is_reported ();
  test_policy_error_then_transient_reports_the_last_candidate ();
  test_capacity_failover_preserves_image_and_declared_caps ();
  test_capacity_exhaustion_retains_size_failure ();
  test_candidate_failover_is_not_cut_off_by_local_deadline ();
  test_credential_error_tries_next_runtime ();
  test_cap_fit_sends_a_small_image_as_is ();
  test_cap_fit_cannot_plan_without_dimensions ();
  test_cap_fit_shrinks_by_the_byte_ratio ();
  test_cap_fit_refuses_below_the_edge_floor ();
  test_cap_fit_refuses_an_empty_image_without_dividing ();
  test_cap_fit_refuses_when_the_cap_leaves_no_room ();
  test_image_over_a_candidates_cap_skips_to_the_next_without_a_call ();
  test_image_over_every_cap_is_a_size_failure_without_a_call ();
  test_accept_rejected_is_policy_rejection_without_failover ();
  test_eager_eviction_reason_preserves_typed_outcome ();
  test_delegate_eager_eviction_stores_image_and_removes_inline_block ();
  test_fallback_projection_preserves_artifacts_and_caches_each_mode ();
  test_fallback_reference_projection_is_explicitly_unread ();
  test_fallback_semantic_read_is_cached_after_completion ();
  test_fallback_read_receives_the_walks_excluded_runtimes ();
  test_cancelled_fallback_read_can_retry_without_cached_failure ();
  test_vision_candidate_cancellation_does_not_failover ();
  test_delegate_eviction_rejects_invalid_media_type_before_store ();
  test_delegate_eviction_rejects_oversize_before_store ();
  test_delegate_eviction_bad_base64_surfaces_redacted_text_error ();
  test_delegate_eviction_passes_reference_source_through ();
  test_non_delegate_eviction_preserves_inline_image ();
  test_evicted_history_has_no_image_modality ();
  test_delegates_media_follows_lane_capability ();
  test_delegates_media_matches_antigravity_transport ();
  test_vision_candidates_follow_quota_window ();
  test_vision_402_marks_the_account_exhausted_and_moves_on ();
  print_endline "test_keeper_vision_tool: all assertions passed"
