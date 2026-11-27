open Alcotest
open Masc

let sample_png =
  (* Minimal valid 2x1 PNG header + trailer (real magic bytes & IHDR dims). *)
  String.concat ""
    [ "\x89PNG\r\n\x1a\n"
    ; "\x00\x00\x00\x0d"
    ; "IHDR"
    ; "\x00\x00\x00\x02"
    ; "\x00\x00\x00\x01"
    ; "\x08\x06\x00\x00\x00"
    ; "\x72\xb6\x0d\x24"
    ; "sk-ant-api03-BINARYPAYLOADMUSTNOTBEREDACTED0000"
    ]

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun entry -> rm (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  Fun.protect ~finally:(fun () -> rm dir) (fun () -> f dir)

let parse_and_materialize_all toml =
  match Runtime_toml.parse_string toml with
  | Error errs ->
    let msg =
      List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errs
      |> String.concat "; "
    in
    failf "runtime.toml parse failed: %s" msg
  | Ok cfg ->
    let runtimes, dropped = Runtime_instance.partition_bindings cfg cfg.bindings in
    if dropped <> [] then
      failf "unexpected dropped bindings: %s"
        (List.map (fun (id, r) -> id ^ ":" ^ Runtime_config_error.string_of_drop_reason r) dropped
         |> String.concat ", ");
    cfg, runtimes

let find_runtime runtimes id =
  match List.find_opt (fun (rt : Runtime_instance.t) -> String.equal rt.id id) runtimes with
  | Some rt -> rt
  | None -> failf "missing materialized runtime %s" id

let json_member key json = Yojson.Safe.Util.member key json
let json_string key json = json_member key json |> Yojson.Safe.Util.to_string
let json_int key json = json_member key json |> Yojson.Safe.Util.to_int

(* 1. Unified Capability Authority + Hard Cut of media_failover *)

let test_unified_capability_derivation_and_acp_probe () =
  with_temp_dir "vision-cap-" @@ fun dir ->
  let agy_cred = Filename.concat dir "agy-oauth.json" in
  let oc = open_out_bin agy_cred in
  output_string oc "{}";
  close_out oc;
  let toml =
    Printf.sprintf
      {|
[runtime]
default = "openai.gpt4o"

[runtime.media]
vision_reader = "openai.gpt4o"
image_generator = "openai.img"

[providers.openai]
protocol = "openai-compatible-http"
endpoint = "https://api.openai.com/v1"

[providers.claude]
protocol = "claude-code"
command = "claude"
is-non-interactive = true

[providers.codex]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true

[providers.agy_legacy]
protocol = "antigravity-cli"
command = "agy"
is-non-interactive = true
timeout-s = 30.0
[providers.agy_legacy.credentials]
type = "file"
path = %S

[providers.agy_acp]
protocol = "acp"
driver = "antigravity"
command = "/fake/bin/agy-probe-test"
is-non-interactive = true

[providers.acp_forced_off]
protocol = "acp"
driver = "kimi_code"
command = "/fake/bin/kimi-probe-test"
is-non-interactive = true

[models.gpt4o]
api-name = "gpt-4o"
max-context = 128000
[models.gpt4o.capabilities]
supports-image-input = true

[models.text_only]
api-name = "text-only"
max-context = 32000
[models.text_only.capabilities]
supports-image-input = false

[models.img]
api-name = "gpt-image-1"
max-context = 32000
[models.img.capabilities]
supports-image-output = true

[models.cli_default]
api-name = "default"
max-context = 200000

[models.cli_no_vision]
api-name = "default"
max-context = 200000
[models.cli_no_vision.capabilities]
supports-image-input = false

[openai.gpt4o]
[openai.text_only]
[openai.img]
[claude.cli_default]
[codex.cli_default]
[agy_legacy.cli_default]
[agy_acp.cli_default]
[acp_forced_off.cli_no_vision]
|}
      agy_cred
  in
  let cfg, runtimes = parse_and_materialize_all toml in
  check (option string) "media.vision_reader parsed" (Some "openai.gpt4o")
    cfg.media.vision_reader;
  check (option string) "media.image_generator parsed" (Some "openai.img")
    cfg.media.image_generator;

  let rt_vision = find_runtime runtimes "openai.gpt4o" in
  let rt_text = find_runtime runtimes "openai.text_only" in
  let rt_img = find_runtime runtimes "openai.img" in
  let rt_claude = find_runtime runtimes "claude.cli_default" in
  let rt_codex = find_runtime runtimes "codex.cli_default" in
  let rt_agy_legacy = find_runtime runtimes "agy_legacy.cli_default" in
  let rt_agy_acp = find_runtime runtimes "agy_acp.cli_default" in
  let rt_acp_forced_off = find_runtime runtimes "acp_forced_off.cli_no_vision" in

  check bool "HTTP vision runtime accepts image input" true
    (Runtime_agent.runtime_accepts_image_input ~runtime:rt_vision);
  check bool "HTTP text-only runtime rejects image input" false
    (Runtime_agent.runtime_accepts_image_input ~runtime:rt_text);
  check bool "HTTP image-output override activates image output" true
    (Runtime_agent.runtime_supports_image_output ~runtime:rt_img);
  check bool "Claude Code natively accepts image input" true
    (Runtime_agent.runtime_accepts_image_input ~runtime:rt_claude);
  check bool "Codex natively accepts image input" true
    (Runtime_agent.runtime_accepts_image_input ~runtime:rt_codex);
  check bool "Codex advertises in-turn image generation output" true
    (Runtime_agent.runtime_supports_image_output ~runtime:rt_codex);
  check bool "Antigravity CLI is strictly No_vision_input" false
    (Runtime_agent.runtime_accepts_image_input ~runtime:rt_agy_legacy);
  check bool "Antigravity CLI is strictly No_image_output" false
    (Runtime_agent.runtime_supports_image_output ~runtime:rt_agy_legacy);

  (* Live ACP promptCapabilities.image probe refines effective_media_capabilities *)
  let parsed_caps_true =
    Runtime_acp_client.For_testing.parse_capabilities
      (`Assoc
         [ "agentCapabilities",
           `Assoc [ "promptCapabilities", `Assoc [ "image", `Bool true ] ]
         ])
  in
  let parsed_caps_false =
    Runtime_acp_client.For_testing.parse_capabilities
      (`Assoc
         [ "agentCapabilities",
           `Assoc [ "promptCapabilities", `Assoc [ "image", `Bool false ] ]
         ])
  in
  check bool "ACP parse_capabilities reads image=true" true parsed_caps_true.image_prompt;
  check bool "ACP parse_capabilities reads image=false" false parsed_caps_false.image_prompt;

  Runtime_acp_client.record_observed_image_prompt
    ~driver:Runtime_acp_client.Antigravity ~cli_path:"/fake/bin/agy-probe-test" false;
  check (option bool) "observed ACP image_prompt false" (Some false)
    (Runtime_acp_client.observed_image_prompt
       ~driver:Runtime_acp_client.Antigravity ~cli_path:"/fake/bin/agy-probe-test");
  check bool "ACP probe=false turns effective vision input off" false
    (Runtime_agent.runtime_accepts_image_input ~runtime:rt_agy_acp);

  Runtime_acp_client.record_observed_image_prompt
    ~driver:Runtime_acp_client.Antigravity ~cli_path:"/fake/bin/agy-probe-test" true;
  check bool "ACP probe=true enables effective vision input" true
    (Runtime_agent.runtime_accepts_image_input ~runtime:rt_agy_acp);

  (* Explicit TOML supports-image-input = false cannot be overridden by live ACP probe *)
  Runtime_acp_client.record_observed_image_prompt
    ~driver:Runtime_acp_client.Kimi_code ~cli_path:"/fake/bin/kimi-probe-test" true;
  check bool "explicit TOML supports-image-input=false wins over live probe" false
    (Runtime_agent.runtime_accepts_image_input ~runtime:rt_acp_forced_off)

let test_media_failover_hard_cut_refused () =
  let bad_toml =
    {|
[runtime]
default = "p.m"
media_failover = ["p.m"]
[providers.p]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1/v1"
[models.m]
api-name = "m"
max-context = 4096
[p.m]
|}
  in
  match Runtime_toml.parse_string bad_toml with
  | Ok _ -> fail "media_failover must be hard-cut refused"
  | Error errs ->
    let msg = List.map (fun (e : Runtime_toml.parse_error) -> e.message) errs |> String.concat "\n" in
    check bool "error explains removal and points to [runtime.media]" true
      (String_util.contains_substring msg "media_failover was removed"
       && String_util.contains_substring msg "[runtime.media]")

(* 2. Natural Vision Routing, Tool Gating & Non-Eviction *)

let test_natural_vision_routing_and_tool_gating () =
  let desc_of name =
    match Keeper_tool_descriptor.descriptors_for_internal name with
    | d :: _ -> d
    | [] -> failf "missing descriptor %s" name
  in
  let read_img = desc_of "keeper_image_read" in
  let analyze_img = desc_of "keeper_analyze_image" in
  let gen_img = desc_of "keeper_generate_image" in

  (* Vision-capable runtime: keeper_image_read admitted, keeper_analyze_image hidden *)
  check bool "keeper_image_read admitted on vision runtime" true
    (Keeper_tools_agent_core.descriptor_admitted Image_input_admitted read_img);
  check bool "keeper_analyze_image hidden on vision runtime" false
    (Keeper_tools_agent_core.descriptor_admitted Image_input_admitted analyze_img);

  (* Text-only runtime: keeper_image_read hidden, keeper_analyze_image admitted *)
  check bool "keeper_image_read hidden on text-only runtime" false
    (Keeper_tools_agent_core.descriptor_admitted Image_input_unavailable read_img);
  check bool "keeper_analyze_image admitted on text-only runtime" true
    (Keeper_tools_agent_core.descriptor_admitted Image_input_unavailable analyze_img);

  (* Image generation gated independently on generator availability *)
  check bool "keeper_generate_image admitted when generator exists" true
    (Keeper_tools_agent_core.descriptor_admitted
       ~image_generation_admitted:true Image_input_unavailable gen_img);
  check bool "keeper_generate_image hidden when no generator exists" false
    (Keeper_tools_agent_core.descriptor_admitted
       ~image_generation_admitted:false Image_input_admitted gen_img);

  (* PreToolUse admission hook enforces both directions *)
  let check_hook ~accepts_image_input ~tool_name ~expect_skip =
    let dummy_tool =
      Agent_core.Tool.create ~name:tool_name ~description:"fixture" ~parameters:[]
        (fun _ -> Ok { Agent_core.Types.content = ""; content_blocks = None; _meta = None })
    in
    let invocation =
      Agent_core.Tool_contract.Invocation.create
        ~tool_use_id:"tu-1"
        ~turn:1
        ~schedule:
          { planned_index = 0
          ; batch_index = 0
          ; batch_size = 1
          ; execution_mode = Agent_core.Tool_contract.Serial
          }
        ~completion:(Agent_core.Tool.completion dummy_tool)
    in
    let ev =
      Agent_core.Hooks.PreToolUse
        { invocation
        ; tool_name
        ; input = `Assoc []
        ; usage = None
        }
    in
    match Keeper_image_read.admission_hook ~accepts_image_input ev with
    | Agent_core.Hooks.Continue ->
      if expect_skip then failf "%s should have been blocked when accepts=%b" tool_name accepts_image_input
    | Agent_core.Hooks.Block _ ->
      if not expect_skip then failf "%s should have been admitted when accepts=%b" tool_name accepts_image_input
    | _ -> fail "unexpected hook decision"
  in
  check_hook ~accepts_image_input:true ~tool_name:"keeper_image_read" ~expect_skip:false;
  check_hook ~accepts_image_input:true ~tool_name:"keeper_analyze_image" ~expect_skip:true;
  check_hook ~accepts_image_input:false ~tool_name:"keeper_image_read" ~expect_skip:true;
  check_hook ~accepts_image_input:false ~tool_name:"keeper_analyze_image" ~expect_skip:false

let test_checkpoint_preserves_images_without_eviction () =
  Eio_main.run @@ fun _ ->
  with_temp_dir "vision-no-evict-" @@ fun base_dir ->
  let media_store = Agent_core.History.Memory_store.create () in
  let stored =
    match media_store.put ~media_type:"image/png" ~raw:sample_png with
    | Ok s -> s
    | Error err -> fail (Agent_core.Error.to_string (Agent_core.Error.Media err))
  in
  let session = Keeper_context_core.create_session ~session_id:"trace-no-evict" ~base_dir in
  let ctx = Keeper_context_core.create ~eio:false ~system_prompt:"system" in
  let user_msg : Agent_core.Types.message =
    { (Agent_core.Types.user_msg "") with
      content =
        [ Agent_core.Types.Text "inspect screenshot"
        ; Agent_core.Types.image_block ~media_type:"image/png"
            ~source:(Agent_core.Types.Stored stored)
        ]
    }
  in
  let ctx = Keeper_context_core.append ctx user_msg in
  let saved =
    match
      Keeper_context_core.save_agent_core_checkpoint
        ~base_path:base_dir
        ~runtime_id:"nonexistent.text_only"
        ~keeper_name:"alpha"
        ~session
        ~agent_name:"alpha"
        ~ctx
    with
    | Ok cp -> cp
    | Error err ->
      fail (Keeper_context_core.checkpoint_write_error_to_string ~persistence_error_to_string:Fun.id err)
  in
  let has_image (msgs : Agent_core.Types.message list) =
    List.exists
      (fun (m : Agent_core.Types.message) ->
         List.exists (function Agent_core.Types.Image _ -> true | _ -> false) m.content)
      msgs
  in
  check bool "saved checkpoint retains canonical Image block (no destructive eviction)"
    true (has_image saved.messages);
  let _, loaded =
    Keeper_context_core.load_context_from_checkpoint ~trace_id:"trace-no-evict" ~base_dir
  in
  match loaded with
  | None -> fail "expected saved checkpoint to reload"
  | Some reloaded_ctx ->
    check bool "reloaded working_context still holds the canonical Image block"
      true (has_image (Keeper_context_core.messages_of_context reloaded_ctx))

(* 3. Unified Bidirectional Image Generation *)

let test_generate_image_validation_and_ssrf_guard () =
  (match Keeper_generate_image.parse_args (`Assoc [ "prompt", `String "a red lighthouse" ]) with
   | Ok (req, None) -> check string "prompt parsed" "a red lighthouse" req.prompt
   | Ok (_, Some _) -> fail "unexpected runtime_id"
   | Error err -> fail err);
  check bool "empty prompt rejected" true
    (Result.is_error (Keeper_generate_image.parse_args (`Assoc [ "prompt", `String "   " ])));
  check bool "count=5 rejected" true
    (Result.is_error
       (Keeper_generate_image.parse_args
          (`Assoc [ "prompt", `String "ok"; "count", `Int 5 ])));
  check bool "unknown format rejected" true
    (Result.is_error
       (Keeper_generate_image.parse_args
          (`Assoc [ "prompt", `String "ok"; "output_format", `String "bmp" ])));
  check bool "unknown field rejected" true
    (Result.is_error
       (Keeper_generate_image.parse_args
          (`Assoc [ "prompt", `String "ok"; "rogue", `Bool true ])));

  check bool "public HTTPS download URL allowed" true
    (Result.is_ok (Keeper_generate_image.validate_remote_download_url "https://cdn.example.com/out.png"));
  (* Regression: public hostnames starting with "fd" or "fc" must NOT be
     false-positively blocked as IPv6 ULA literals. *)
  check bool "public hostname starting with fd allowed" true
    (Result.is_ok (Keeper_generate_image.validate_remote_download_url "https://fd.example.com/out.png"));
  check bool "public hostname starting with fc allowed" true
    (Result.is_ok (Keeper_generate_image.validate_remote_download_url "https://fc-assets.example.com/out.png"));
  List.iter
    (fun url ->
       check bool ("SSRF blocked: " ^ url) true
         (Result.is_error (Keeper_generate_image.validate_remote_download_url url)))
    [ "http://cdn.example.com/out.png"
    ; "file:///etc/passwd"
    ; "https://user:pass@cdn.example.com/out.png"
    ; "https://127.0.0.1/img.png"
    ; "https://localhost/img.png"
    ; "https://localhost./img.png"
    ; "https://169.254.169.254/latest/meta-data"
    ; "https://10.0.0.5/internal.png"
    ; "https://192.168.1.10/img.png"
    ; "https://100.64.0.1/cgnat.png"
    ; "https://[fd00::1]/ula.png"
    ; "https://[fc00::1]/ula.png"
    ; "https://[::ffff:127.0.0.1]/mapped-loopback.png"
    ]

let test_generate_image_candidates_and_execution () =
  let toml =
    {|
[runtime]
default = "openai.chat"

[providers.openai]
protocol = "openai-compatible-http"
endpoint = "https://api.openai.com/v1"
[providers.openai.credentials]
type = "inline"
value = "fixture-openai-key"

[providers.gemini]
protocol = "gemini-http"
endpoint = "https://generativelanguage.googleapis.com/v1beta"
[providers.gemini.credentials]
type = "inline"
value = "fixture-gemini-key"

[models.chat]
api-name = "gpt-4o"
max-context = 128000
[models.chat.capabilities]
supports-image-input = true

[models.flash]
api-name = "gemini-2.5-flash"
max-context = 1000000
[models.flash.capabilities]
supports-image-input = true

[openai.chat]
[gemini.flash]
|}
  in
  let _, runtimes = parse_and_materialize_all toml in
  let rt_openai = find_runtime runtimes "openai.chat" in
  let targets =
    Runtime_agent.image_generator_candidates_of
      ~runtimes
      ~media:Runtime_schema.empty_media_overrides
      ~active_runtime:rt_openai
      ()
  in
  check bool "auto-derives sibling image endpoints from OpenAI & Gemini credentials" true
    (List.length targets >= 2);
  let labels = List.map Runtime_agent.image_generator_target_label targets in
  check bool "sibling OpenAI image model derived" true
    (List.exists (fun l -> String_util.contains_substring l "gpt-image-1") labels);

  (* Execute end-to-end against mocked endpoint + mocked in-turn + empty candidates *)
  with_temp_dir "gen-image-" @@ fun base_dir ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let meta =
    match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String "painter" ]) with
    | Ok m -> m
    | Error err -> fail err
  in
  let endpoint_target =
    Runtime_agent.Runtime_images_endpoint
      { runtime = rt_openai
      ; dialect = Llm_provider.Capabilities.Openai_images_v1
      }
  in
  let generate_endpoint ~sw:_ ~net:_ ~clock:_ ~config:_ ~dialect:_ _req =
    Ok
      { Llm_provider.Image_gen.images =
          [ { Llm_provider.Image_gen.mime_type = Some "image/png"
            ; data_bytes = Some sample_png
            ; remote_url = None
            ; revised_prompt = Some "a crisp red lighthouse"
            }
          ]
      ; ignored_options = []
      }
  in
  let exec =
    Keeper_generate_image.handle_with_outcome
      ~base_path:base_dir
      ~candidates:[ endpoint_target ]
      ~generate_endpoint
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~net:(Eio.Stdenv.net env)
      ~meta
      ~args:(`Assoc [ "prompt", `String "draw a lighthouse" ])
      ()
  in
  check bool "endpoint image generation succeeded" true
    (match exec.disposition with Tool_result.Completed _ -> true | _ -> false);
  let body = Yojson.Safe.from_string exec.raw_output in
  check bool "wire JSON reports ok=true" true
    (json_member "ok" body = `Bool true);
  let att_id = json_string "attachment_id" body in
  check bool "attachment_id is canonical att_<64hex>" true
    (Result.is_ok (Attachment_store.parse_id att_id));
  check string "url matches Attachment_store.url_of_id"
    (Attachment_store.url_of_id att_id) (json_string "url" body);
  let store = Attachment_store.create ~base_path:base_dir in
  (match Attachment_store.get_meta store ~id:att_id with
   | Ok (Some m) ->
     check string "persisted origin is model_generated" "model_generated"
       (Attachment_store.origin_to_string m.origin);
     check string "persisted retention is durable" "durable"
       (Attachment_store.retention_to_wire_string m.retention);
     check (option string) "generated filename has single extension dot"
       (Some "generated-1.png") m.filename;
     check (option int) "PNG width extracted" (Some 2) m.width;
     check (option int) "PNG height extracted" (Some 1) m.height
   | Ok None -> fail "generated attachment metadata missing"
   | Error err -> fail (Attachment_store.get_error_to_string err));
  (match exec.content_blocks with
   | Some blocks ->
     check bool "returns native Image content block alongside metadata" true
       (List.exists (function Llm_provider.Types.Image _ -> true | _ -> false) blocks)
   | None -> fail "expected native Image content_blocks");

  (* In-turn image generation path *)
  let in_turn_target =
    Runtime_agent.Runtime_in_turn
      { runtime = rt_openai
      ; contract = Llm_provider.Capabilities.In_turn_openai_chat_modalities
      }
  in
  let complete_in_turn ~sw:_ ~net:_ ~clock:_ ~config:_ ~messages:_ ?tools:_ () =
    Ok
      { Agent_core.Types.id = "gen-resp-1"
      ; model = "gpt-image-in-turn"
      ; unreadable_tool_uses = []
      ; stop_reason = Agent_core.Types.EndTurn
      ; content =
          [ Llm_provider.Types.Image
              { media_type = "image/png"
              ; source = Llm_provider.Types.Base64 (Base64.encode_string sample_png)
              }
          ]
      ; usage = None
      ; telemetry = None
      }
  in
  let exec_in_turn =
    Keeper_generate_image.handle_with_outcome
      ~base_path:base_dir
      ~candidates:[ in_turn_target ]
      ~complete_in_turn
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~net:(Eio.Stdenv.net env)
      ~meta
      ~args:(`Assoc [ "prompt", `String "in-turn sketch" ])
      ()
  in
  check bool "in-turn image generation succeeded" true
    (match exec_in_turn.disposition with Tool_result.Completed _ -> true | _ -> false);

  (* Empty candidates returns typed error *)
  let exec_empty =
    Keeper_generate_image.handle_with_outcome
      ~base_path:base_dir
      ~candidates:[]
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~net:(Eio.Stdenv.net env)
      ~meta
      ~args:(`Assoc [ "prompt", `String "no generator" ])
      ()
  in
  check bool "no candidates fails with typed failure" true
    (match exec_empty.disposition with Tool_result.Failed _ -> true | _ -> false);
  check bool "failure explains missing image generator" true
    (String_util.contains_substring exec_empty.raw_output "No image-generation")

(* 4. Official-Client Image Output Decoding (Codex + ACP) *)

let test_codex_and_acp_image_output_decoders () =
  let b64 = Base64.encode_string sample_png in
  let codex_data_uri_item =
    `Assoc
      [ "type", `String "imageGeneration"
      ; "id", `String "ig-1"
      ; "result", `String ("data:image/png;base64," ^ b64)
      ; "revisedPrompt", `String "sunset over ocean"
      ]
  in
  (match Runtime_codex_app_server.decode_image_generation_item_for_tests codex_data_uri_item with
   | Some out ->
     check string "codex item_id" "ig-1" out.item_id;
     check string "codex mime_type" "image/png" out.mime_type;
     check string "codex raw bytes decoded" sample_png out.data_bytes;
     check (option string) "codex revised_prompt" (Some "sunset over ocean") out.revised_prompt
   | None -> fail "expected Codex data-URI imageGeneration item to decode");

  let codex_raw_b64_item =
    `Assoc
      [ "type", `String "imageGeneration"
      ; "id", `String "ig-2"
      ; "result", `String b64
      ]
  in
  (match Runtime_codex_app_server.decode_image_generation_item_for_tests codex_raw_b64_item with
   | Some out ->
     check string "codex raw base64 sniffed as image/png" "image/png" out.mime_type;
     check string "codex raw bytes exact" sample_png out.data_bytes
   | None -> fail "expected Codex raw base64 imageGeneration item to decode");

  check bool "non-imageGeneration Codex item returns None" true
    (Option.is_none
       (Runtime_codex_app_server.decode_image_generation_item_for_tests
          (`Assoc [ "type", `String "agentMessage"; "text", `String "hi" ])));

  let acp_update =
    `Assoc
      [ "sessionUpdate", `String "agent_message_chunk"
      ; "content",
        `Assoc
          [ "type", `String "image"
          ; "mimeType", `String "image/png"
          ; "data", `String b64
          ]
      ]
  in
  match
    Runtime_acp_client.For_testing.parse_session_update
      ~driver:Runtime_acp_client.Antigravity acp_update
  with
  | Some (Runtime_acp_client.Media_output { mime_type; data_bytes }) ->
    check string "ACP image chunk mime_type" "image/png" mime_type;
    check string "ACP image chunk decoded bytes" sample_png data_bytes
  | _ -> fail "expected ACP agent_message_chunk image to decode to Media_output"

(* 5. Upload-First Chat Ingress, KEEPER_ATTACHMENT AG-UI Projection, Non-Mangling Store & History Attachments *)

let test_upload_first_ingress_agui_and_history_attachments () =
  with_temp_dir "att-plumbing-" @@ fun base_dir ->
  let store = Attachment_store.create ~base_path:base_dir in
  let uploaded =
    match
      Attachment_store.put
        ~declared_mime:"image/png"
        ~filename:"diagram.png"
        ~origin:Attachment_store.User_upload
        ~created_by:"user"
        ~retention:Attachment_store.Durable
        store
        ~bytes:sample_png
    with
    | Ok m -> m
    | Error err -> fail (Attachment_store.put_error_to_string err)
  in

  (* 5a. Upload-first request with ZERO base64 using type:"attachment" *)
  let req_body =
    Printf.sprintf
      {|{"request_id":"req-upload-first","name":"alpha","message":"explain this","user_blocks":[{"type":"attachment","attachment_id":%S}]}|}
      uploaded.id
  in
  let media_store = Agent_core.History.Memory_store.create () in
  let parsed =
    match
      Server_routes_http_keeper_stream.parse_keeper_chat_stream_request
        ~base_path:base_dir ~media_store req_body
    with
    | Ok p -> p
    | Error err -> fail ("upload-first parse failed: " ^ err)
  in
  check int "hydrated attachment list has 1 entry" 1 (List.length parsed.attachments);
  (match parsed.attachments with
   | [ att ] ->
     check string "hydrated attachment id" uploaded.id att.id;
     check string "hydrated attachment mime" "image/png" att.mime_type;
     check (option int) "hydrated attachment width" (Some 2) att.width
   | _ -> fail "expected 1 hydrated attachment");

  (* 5b. KEEPER_ATTACHMENT AG-UI projection for BOTH Agent_core_media_delta AND Image_block *)
  let url = Attachment_store.url_of_id uploaded.id in
  let media_delta_ev =
    Keeper_chat_events.Agent_core_media_delta
      { index = 0
      ; media_type = "image/png"
      ; source_type = Agent_core.Types.Base64_kind
      ; media_ref = url
      ; response = { response_generation = 0; response_scope = 0 }
      }
  in
  let _, projected_delta =
    Server_keeper_chat_agui_projection.project
      ~base_path:base_dir ~timestamp:1700000000.0 ~redact_text:Fun.id
      Server_keeper_chat_agui_projection.initial media_delta_ev
  in
  (match projected_delta with
   | Some ev ->
     check (option string) "Agent_core_media_delta projects to KEEPER_ATTACHMENT"
       (Some "KEEPER_ATTACHMENT") ev.custom_name;
     let payload = Option.get ev.custom_value in
     check string "KEEPER_ATTACHMENT attachment_id" uploaded.id (json_string "attachment_id" payload);
     check string "KEEPER_ATTACHMENT url" url (json_string "url" payload);
     check string "KEEPER_ATTACHMENT kind" "image" (json_string "kind" payload);
     check int "KEEPER_ATTACHMENT width" 2 (json_int "width" payload)
   | None -> fail "expected Agent_core_media_delta to project to KEEPER_ATTACHMENT");

  let img_block_ev =
    Keeper_chat_events.Image_block
      { url
      ; caption = Some "diagram"
      }
  in
  let _, projected_img =
    Server_keeper_chat_agui_projection.project
      ~base_path:base_dir ~timestamp:1700000001.0 ~redact_text:Fun.id
      Server_keeper_chat_agui_projection.initial img_block_ev
  in
  (match projected_img with
   | Some ev ->
     check (option string) "Image_block no longer dropped; projects to KEEPER_ATTACHMENT"
       (Some "KEEPER_ATTACHMENT") ev.custom_name;
     let payload = Option.get ev.custom_value in
     check string "Image_block attachment_id" uploaded.id (json_string "attachment_id" payload)
   | None -> fail "Image_block must not be dropped by AG-UI projection");

  (* 5b-ii. Live Attachment_emitted events for BOTH user uploads and tool outputs
     (and journal round-trip + replay parity + tool_result_attachment_ids filtering). *)
  let gen_png = sample_png ^ "generated-tool-output" in
  let generated =
    match
      Attachment_store.put
        ~filename:"generated-1.png"
        ~origin:Attachment_store.Model_generated
        ~created_by:"alpha"
        ~retention:Attachment_store.Durable
        store
        ~bytes:gen_png
    with
    | Ok m -> m
    | Error err -> fail (Attachment_store.put_error_to_string err)
  in
  let user_att_ev =
    Keeper_chat_events.Attachment_emitted
      { attachment_id = uploaded.id
      ; role = Keeper_chat_events.Attachment_user
      ; tool_call_id = None
      ; caption = None
      }
  in
  let tool_att_ev =
    Keeper_chat_events.Attachment_emitted
      { attachment_id = generated.id
      ; role = Keeper_chat_events.Attachment_tool
      ; tool_call_id = Some "tc-gen-1"
      ; caption = None
      }
  in
  let _, projected_user_att =
    Server_keeper_chat_agui_projection.project
      ~base_path:base_dir ~timestamp:1700000002.0 ~redact_text:Fun.id
      Server_keeper_chat_agui_projection.initial user_att_ev
  in
  (match projected_user_att with
   | Some ev ->
     check (option string) "user Attachment_emitted projects to KEEPER_ATTACHMENT"
       (Some "KEEPER_ATTACHMENT") ev.custom_name;
     let payload = Option.get ev.custom_value in
     check string "user attachment_id" uploaded.id (json_string "attachment_id" payload);
     check string "user role" "user" (json_string "role" payload);
     check string "user origin" "user_upload" (json_string "origin" payload);
     check bool "user tool_call_id is null" true (json_member "tool_call_id" payload = `Null)
   | None -> fail "expected user Attachment_emitted to project to KEEPER_ATTACHMENT");
  let _, projected_tool_att =
    Server_keeper_chat_agui_projection.project
      ~base_path:base_dir ~timestamp:1700000003.0 ~redact_text:Fun.id
      Server_keeper_chat_agui_projection.initial tool_att_ev
  in
  (match projected_tool_att with
   | Some ev ->
     check (option string) "tool Attachment_emitted projects to KEEPER_ATTACHMENT"
       (Some "KEEPER_ATTACHMENT") ev.custom_name;
     let payload = Option.get ev.custom_value in
     check string "tool attachment_id" generated.id (json_string "attachment_id" payload);
     check string "tool role" "tool" (json_string "role" payload);
     check string "tool origin" "model_generated" (json_string "origin" payload);
     check string "tool_call_id preserved" "tc-gen-1" (json_string "tool_call_id" payload);
     check string "generated filename preserved" "generated-1.png" (json_string "filename" payload);
     check int "generated width preserved" 2 (json_int "width" payload)
   | None -> fail "expected tool Attachment_emitted to project to KEEPER_ATTACHMENT");
  (* Journal round-trip & replay with ~base_path reproduces KEEPER_ATTACHMENT *)
  let roundtrip_ev ev =
    let encoded = Keeper_chat_event_log.keeper_chat_event_to_json ev in
    match Keeper_chat_event_log.keeper_chat_event_of_json encoded with
    | Ok decoded -> decoded
    | Error detail -> failf "Attachment_emitted journal decode failed: %s" detail
  in
  let replayed =
    Server_keeper_chat_replay.replay
      ~base_path:base_dir
      ~redact_text:Fun.id
      ~since_seq:Keeper_chat_event_log.Whole_turn
      [ { seq = 1; ts = 1700000002.0; event = roundtrip_ev user_att_ev }
      ; { seq = 2; ts = 1700000003.0; event = roundtrip_ev tool_att_ev }
      ]
  in
  check int "replay emits both KEEPER_ATTACHMENT events" 2 (List.length replayed);
  (* End-to-end tool_result_attachment_ids reads committed tool-call log,
     keeps Model_generated and skips User_upload *)
  let dated_store_root =
    Workspace.dated_store_root (Workspace.default_config base_dir)
  in
  Keeper_tool_call_log.init ~base_path:base_dir ();
  let exec_id = Ids.Execution_id.of_string "exec-gen-img-1" in
  Keeper_tool_call_log.log_call
    ~keeper_name:"alpha"
    ~tool_name:"keeper_generate_image"
    ~input:(`Assoc [ "prompt", `String "lighthouse" ])
    ~output_text:
      (Yojson.Safe.to_string
         (`Assoc
            [ "ok", `Bool true
            ; "attachment_id", `String generated.id
            ; "source_upload", `String uploaded.id
            ]))
    ~wire_outcome:Tool_result.Ok
    ~duration_ms:10.0
    ~model:"fixture"
    ~execution_id:exec_id
    ~physical_execution_id:exec_id
    ~tool_use_id:"tc-gen-1"
    ~on_committed:(fun () -> ())
    ();
  let emitted_tool_ids =
    Server_routes_http_keeper_stream.For_testing.tool_result_attachment_ids
      ~base_path:base_dir
      ~dated_store_root
      ~keeper_name:"alpha"
      ~execution_id:exec_id
  in
  check (list string) "tool_result_attachment_ids emits generated attachment and skips user upload"
    [ generated.id ] emitted_tool_ids;

  (* 5c. Chat store non-mangling of binary PNG containing sk-ant-... pattern + history attachments[] synthesis *)
  Keeper_chat_store.append_turn
    ~base_dir
    ~keeper_name:"alpha"
    ~user_content:"check this image"
    ~user_attachments:
      [ { Keeper_chat_store.id = "raw-upload"
        ; att_type = "image"
        ; name = "diagram.png"
        ; size = String.length sample_png
        ; mime_type = "image/png"
        ; data = Base64.encode_string sample_png
        ; width = None
        ; height = None
        }
      ]
    ~tool_calls:
      [ { Keeper_chat_store.call_id = "tc-1"
        ; execution_id = None
        ; call_name = "keeper_generate_image"
        ; args = Printf.sprintf {|{"attachment_id":%S}|} uploaded.id
        }
      ]
    ~assistant_content:"Here is your image."
    ~blocks:
      [ Keeper_chat_blocks.Image { src = url; cap = Some "generated"; mime_type = Some "image/png" } ]
    ();

  (* Verify binary bytes were NEVER mangled by secret redaction regexes *)
  (match Attachment_store.get_bytes_by_sha256 store ~sha256:uploaded.sha256 with
   | Ok (Some stored_bytes) ->
     check string "binary PNG bytes with sk-ant-... untouched by text redaction"
       sample_png stored_bytes
   | _ -> fail "stored PNG missing");

  let rows = Keeper_chat_store.load ~base_dir ~keeper_name:"alpha" in
  let projected_rows =
    List.map
      (Keeper_chat_projection.message_to_json
         ~base_dir ~trace_lookup_available:false ~trace_block:None)
      rows
  in
  let has_att_id row =
    match json_member "attachments" row with
    | `List items ->
      List.exists (fun item -> json_member "attachment_id" item = `String uploaded.id) items
    | _ -> false
  in
  let row_of_role role =
    List.find (fun r -> json_member "role" r = `String role) projected_rows
  in
  check bool "user history row exposes canonical AttachmentRef" true
    (has_att_id (row_of_role "user"));
  check bool "tool history row synthesizes attachments[] from att_<64hex>" true
    (has_att_id (row_of_role "tool"));
  check bool "assistant history row synthesizes attachments[] from Image block" true
    (has_att_id (row_of_role "assistant"))

(* 6. Board Post & Comment attachment_ids + Dashboard AttachmentRef Projection *)

let test_board_attachments_roundtrip_and_dashboard_projection () =
  with_temp_dir "board-att-" @@ fun base_dir ->
  let store = Attachment_store.create ~base_path:base_dir in
  let uploaded =
    match
      Attachment_store.put
        ~declared_mime:"image/png"
        ~filename:"board-shot.png"
        ~origin:Attachment_store.User_upload
        ~created_by:"alice"
        ~retention:Attachment_store.Durable
        store
        ~bytes:sample_png
    with
    | Ok m -> m
    | Error err -> fail (Attachment_store.put_error_to_string err)
  in
  let post_id = Board.Post_id.of_string "p-att-test-1" |> Result.get_ok in
  let author = Board.Agent_id.of_string "alice" |> Result.get_ok in
  let make_post attachment_ids : Board.post =
    { id = post_id
    ; author
    ; title = "Visual report"
    ; body = "See attached screenshot"
    ; post_kind = Board.Human_post
    ; meta_json = None
    ; visibility = Board.Internal
    ; audience = None
    ; created_at = 1700000000.0
    ; content_updated_at = 1700000000.0
    ; updated_at = 1700000000.0
    ; expires_at = 0.0
    ; votes_up = 1
    ; votes_down = 0
    ; reply_count = 0
    ; pinned = false
    ; hearth = None
    ; thread_id = None
    ; origin = None
    ; closed = None
    ; attachment_ids
    }
  in
  (* Empty attachment_ids omitted on wire and round-trips to [] *)
  let empty_json = Board.post_to_yojson (make_post []) in
  check bool "empty attachment_ids omitted from post JSON" true
    (json_member "attachment_ids" empty_json = `Null);
  (match Board.post_of_yojson empty_json with
   | Some p -> check (list string) "empty attachment_ids decodes to []" [] p.attachment_ids
   | None -> fail "post_of_yojson returned None for empty attachment_ids");

  (* Non-empty attachment_ids round-trips and projects AttachmentRef[] on dashboard *)
  let post_with_att = make_post [ uploaded.id ] in
  let wire_json = Board.post_to_yojson post_with_att in
  (match Board.post_of_yojson wire_json with
   | Some p ->
     check (list string) "post attachment_ids round-trip" [ uploaded.id ] p.attachment_ids
   | None -> fail "post_of_yojson returned None for non-empty attachment_ids");

  let dash_post =
    Server_utils.board_post_dashboard_json ~base_path:base_dir ~author_karma:10 post_with_att
  in
  (match json_member "attachments" dash_post with
   | `List [ att ] ->
     check string "dashboard post attachment_id" uploaded.id (json_string "attachment_id" att);
     check string "dashboard post attachment url"
       (Attachment_store.url_of_id uploaded.id) (json_string "url" att);
     check int "dashboard post attachment width" 2 (json_int "width" att)
   | other -> failf "expected 1 dashboard post attachment, got %s" (Yojson.Safe.to_string other));

  let comment : Board.comment =
    { id = Board.Comment_id.generate ()
    ; post_id
    ; parent_id = None
    ; author
    ; content = "Follow-up image"
    ; audience = None
    ; created_at = 1700000010.0
    ; expires_at = 0.0
    ; votes_up = 0
    ; votes_down = 0
    ; attachment_ids = [ uploaded.id ]
    }
  in
  (match Board.comment_of_yojson (Board.comment_to_yojson comment) with
   | Some c ->
     check (list string) "comment attachment_ids round-trip" [ uploaded.id ] c.attachment_ids
   | None -> fail "comment_of_yojson returned None");
  let dash_comment =
    Server_utils.board_comment_dashboard_json ~base_path:base_dir comment
  in
  match json_member "attachments" dash_comment with
  | `List [ att ] ->
    check string "dashboard comment attachment_id" uploaded.id (json_string "attachment_id" att)
  | other -> failf "expected 1 dashboard comment attachment, got %s" (Yojson.Safe.to_string other)

(* 7. Review-Fix Regressions: Catalog Capability Floor, Strict Vision Pin,
   Multi-Keeper Ephemeral Pin Isolation, ACP Tool-Update Media Filtering,
   Generate-Image Failover/Partial/Options/Write-Policy, Codex/URI Hardening *)

let test_catalog_false_not_overridden_by_acp_probe () =
  let toml =
    {|
[runtime]
default = "acp_text.text_model"

[providers.acp_text]
protocol = "acp"
driver = "kimi_code"
command = "/fake/bin/acp-catalog-false-probe"
is-non-interactive = true

[models.text_model]
api-name = "glm-5"
max-context = 128000

[acp_text.text_model]
|}
  in
  let _, runtimes = parse_and_materialize_all toml in
  let rt = find_runtime runtimes "acp_text.text_model" in
  let catalog_caps =
    Llm_provider.Capabilities.for_model_id "glm-5"
  in
  check (option bool) "catalog declares glm-5 non-vision" (Some false)
    (Option.map (fun (c : Llm_provider.Capabilities.capabilities) -> c.supports_image_input) catalog_caps);
  Runtime_acp_client.record_observed_image_prompt
    ~driver:Runtime_acp_client.Kimi_code
    ~cli_path:"/fake/bin/acp-catalog-false-probe"
    true;
  check bool "live ACP probe=true must NOT override catalog supports_image_input=false"
    false (Runtime_agent.runtime_accepts_image_input ~runtime:rt)

let test_vision_reader_strict_pin_and_exact_uri_host_derivation () =
  let toml =
    {|
[runtime]
default = "proxy_openai.chat"

[providers.proxy_openai]
protocol = "openai-compatible-http"
endpoint = "https://my-openai-proxy.internal/v1"
[providers.proxy_openai.credentials]
type = "inline"
value = "fixture-proxy-key"

[providers.xyz_ai]
protocol = "openai-compatible-http"
endpoint = "https://xyz.ai/v1"
[providers.xyz_ai.credentials]
type = "inline"
value = "fixture-xyz-key"

[providers.real_zai]
protocol = "openai-compatible-http"
endpoint = "https://api.z.ai/api/paas/v4"
[providers.real_zai.credentials]
type = "inline"
value = "fixture-zai-key"

[models.chat]
api-name = "gpt-4o"
max-context = 128000
[models.chat.capabilities]
supports-image-input = true

[proxy_openai.chat]
[xyz_ai.chat]
[real_zai.chat]
|}
  in
  let _, runtimes = parse_and_materialize_all toml in
  let ids = List.map (fun (rt : Runtime_instance.t) -> rt.id) in
  (* Strict pin: explicit vision_reader returns ONLY that runtime *)
  let pinned =
    Runtime_agent.vision_reader_candidates_of
      ~runtimes
      ~media:{ Runtime_schema.vision_reader = Some "real_zai.chat"; image_generator = None }
      ()
  in
  check (list string) "explicit vision_reader strictly pins to one runtime"
    [ "real_zai.chat" ] (ids pinned);
  (* Exact URI host derivation: xyz.ai and my-openai-proxy.internal must NOT derive siblings *)
  let targets =
    Runtime_agent.image_generator_candidates_of
      ~runtimes
      ~media:Runtime_schema.empty_media_overrides
      ()
  in
  let labels = List.map Runtime_agent.image_generator_target_label targets in
  check bool "api.z.ai derives glm-image sibling" true
    (List.exists (fun l -> String_util.contains_substring l "glm-image") labels);
  check bool "my-openai-proxy.internal does NOT derive OpenAI sibling" false
    (List.exists (fun l -> String_util.contains_substring l "proxy_openai") labels);
  check bool "xyz.ai does NOT derive Z.AI sibling" false
    (List.exists (fun l -> String_util.contains_substring l "xyz_ai") labels)

let test_multi_keeper_identical_ephemeral_capture_isolation () =
  with_temp_dir "multi-keeper-ephem-" @@ fun base_dir ->
  let png_shared = sample_png ^ "shared-frame-bytes" in
  let png_other = sample_png ^ "keeper-a-newer-frame" in
  let handle_a =
    match Keeper_vision_tool.store_frame ~base_path:base_dir ~keeper_name:"keeper-a" png_shared with
    | Ok h -> h
    | Error err -> fail err
  in
  let handle_b =
    match Keeper_vision_tool.store_frame ~base_path:base_dir ~keeper_name:"keeper-b" png_shared with
    | Ok h -> h
    | Error err -> fail err
  in
  let sha = Multimodal.Vision_artifact_store.to_string handle_a in
  check string "identical frame bytes share content-addressed handle"
    sha (Multimodal.Vision_artifact_store.to_string handle_b);
  let store = Attachment_store.create ~base_path:base_dir in
  (* Evict keeper-a's ephemeral pin by capping keeper-a at 1 entry with a newer frame *)
  (match
     Attachment_store.put
       ~ephemeral_max_entries:1
       ~origin:Attachment_store.Tool_capture
       ~created_by:"keeper-a"
       ~retention:(Attachment_store.Ephemeral { keeper = "keeper-a" })
       store
       ~bytes:png_other
   with
   | Ok _ -> ()
   | Error err -> fail (Attachment_store.put_error_to_string err));
  check bool "keeper-a pin evicted" false
    (Attachment_store.has_ephemeral_pin store ~keeper:"keeper-a" ~sha256:sha);
  check bool "keeper-b pin still held" true
    (Attachment_store.has_ephemeral_pin store ~keeper:"keeper-b" ~sha256:sha);
  let dir_a = Keeper_vision_tool.vision_store_dir ~base_path:base_dir ~keeper_name:"keeper-a" () in
  let dir_b = Keeper_vision_tool.vision_store_dir ~base_path:base_dir ~keeper_name:"keeper-b" () in
  let dir_c = Keeper_vision_tool.vision_store_dir ~base_path:base_dir ~keeper_name:"keeper-c" () in
  (match Keeper_vision_tool.load_artifact ~dir:dir_b handle_b with
   | Ok loaded -> check string "keeper-b reads shared ephemeral frame after keeper-a eviction" png_shared loaded
   | Error _ -> fail "keeper-b must still read its pinned ephemeral capture");
  check bool "keeper-a denied after its own pin eviction" true
    (Result.is_error (Keeper_vision_tool.load_artifact ~dir:dir_a handle_a));
  check bool "unpinned keeper-c denied" true
    (Result.is_error (Keeper_vision_tool.load_artifact ~dir:dir_c handle_b))

let test_acp_tool_call_update_media_filtering_and_dedup () =
  let b64 = Base64.encode_string sample_png in
  let image_block =
    `Assoc [ "type", `String "image"; "mimeType", `String "image/png"; "data", `String b64 ]
  in
  (* 1. MCP tool (keeper_image_read) echoing ImageContent must NOT emit media_outputs *)
  let mcp_read_update =
    `Assoc
      [ "sessionUpdate", `String "tool_call_update"
      ; "toolCallId", `String "tc-read-1"
      ; "title", `String "keeper_image_read"
      ; "kind", `String "read"
      ; "status", `String "completed"
      ; "content", `List [ image_block ]
      ]
  in
  (match
     Runtime_acp_client.For_testing.parse_session_update
       ~driver:Runtime_acp_client.Antigravity mcp_read_update
   with
   | Some (Runtime_acp_client.Tool_call_updated { media_outputs; _ }) ->
     check int "MCP keeper_image_read tool_call_update emits 0 media_outputs"
       0 (List.length media_outputs)
   | _ -> fail "expected Tool_call_updated for MCP read");

  (* 2. Native generate_image carrying both content and rawOutput emits exactly 1 deduped image *)
  let gen_update =
    `Assoc
      [ "sessionUpdate", `String "tool_call_update"
      ; "toolCallId", `String "tc-gen-1"
      ; "title", `String "generate_image"
      ; "kind", `String "other"
      ; "status", `String "completed"
      ; "content", `List [ image_block ]
      ; "rawOutput", `Assoc [ "content", `List [ image_block ] ]
      ]
  in
  let parsed_media =
    match
      Runtime_acp_client.For_testing.parse_session_update
        ~driver:Runtime_acp_client.Antigravity gen_update
    with
    | Some (Runtime_acp_client.Tool_call_updated { media_outputs; _ }) ->
      check int "native generate_image deduplicates content + rawOutput to 1 image"
        1 (List.length media_outputs);
      media_outputs
    | _ -> fail "expected Tool_call_updated for generate_image"
  in
  (* 3. Stream projection deduplicates repeated Tool_call_updated frames for the same tool_call_id *)
  let emitted_media = ref 0 in
  let on_acp_event, _, _, _, _ =
    Keeper_acp_runtime.For_testing.project_stream_for_testing
      ~on_event:(function
        | Agent_core.Types.ContentBlockDelta { delta = Agent_core.Types.MediaDelta _; _ } ->
          incr emitted_media
        | _ -> ())
      ~driver:Runtime_acp_client.Antigravity
      ~mcp_server_name:"masc"
      ~model:"fixture"
      ~session_id:"sess-media-dedupe"
      ~turn_count:1
      ~native_posture:Runtime_native_tools.Native_read
      ~allowed_tool_names:[]
      ()
  in
  let ev =
    Runtime_acp_client.Tool_call_updated
      { tool_call_id = "tc-gen-1"
      ; title = Some "generate_image"
      ; kind = None
      ; status = None
      ; raw_input = None
      ; raw_output = None
      ; identity = Some (Runtime_acp_client.Native_tool { name = Some "generate_image"; kind = None; locations = [] })
      ; media_outputs = parsed_media
      }
  in
  on_acp_event ev;
  on_acp_event ev;
  check int "repeated identical Tool_call_updated media emits exactly 1 MediaDelta"
    1 !emitted_media

let test_generate_image_failover_partial_options_and_write_policy () =
  (* Write policy & catalog authority *)
  (match Keeper_tool_descriptor.find_id "keeper.vision.generate_image" with
   | Some desc ->
     check (option bool) "keeper_generate_image is NOT read-only (fences retries)"
       (Some false) (Keeper_tool_descriptor.readonly_static_hint desc)
   | None -> fail "keeper_generate_image descriptor missing");
  let cat = Tool_catalog.metadata "keeper_generate_image" in
  check bool "Tool_catalog grants keeper_generate_image write permission (CanBroadcast)"
    true (cat.required_permission = Masc_domain.CanBroadcast);
  check bool "Tool_catalog does not mark keeper_generate_image read-only"
    true (cat.readonly <> Some true);

  let toml =
    {|
[runtime]
default = "p1.img"

[providers.p1]
protocol = "openai-compatible-http"
endpoint = "https://api.openai.com/v1"
[providers.p1.credentials]
type = "inline"
value = "fixture-key-1"

[providers.p2]
protocol = "openai-compatible-http"
endpoint = "https://api.openai.com/v1"
[providers.p2.credentials]
type = "inline"
value = "fixture-key-2"

[models.img]
api-name = "gpt-image-1"
max-context = 32000
[models.img.capabilities]
supports-image-output = true

[p1.img]
[p2.img]
|}
  in
  let _, runtimes = parse_and_materialize_all toml in
  let rt1 = find_runtime runtimes "p1.img" in
  let rt2 = find_runtime runtimes "p2.img" in
  let t1 =
    Runtime_agent.Runtime_images_endpoint
      { runtime = rt1; dialect = Llm_provider.Capabilities.Openai_images_v1 }
  in
  let t2 =
    Runtime_agent.Runtime_images_endpoint
      { runtime = rt2; dialect = Llm_provider.Capabilities.Openai_images_v1 }
  in
  let meta =
    match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String "painter" ]) with
    | Ok m -> m
    | Error err -> fail err
  in
  with_temp_dir "gen-review-" @@ fun base_dir ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let run ?fetch_remote_url ~generate_endpoint ~args () =
    Keeper_generate_image.handle_with_outcome
      ~base_path:base_dir
      ~candidates:[ t1; t2 ]
      ~generate_endpoint
      ?fetch_remote_url
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~net:(Eio.Stdenv.net env)
      ~meta
      ~args
      ()
  in
  (* 1. Pre-dispatch 429 fails over from t1 to t2 and succeeds + reports ignored_options *)
  let calls = ref 0 in
  let exec_429 =
    run
      ~generate_endpoint:(fun ~sw:_ ~net:_ ~clock:_ ~config:_ ~dialect:_ _req ->
        incr calls;
        if !calls = 1
        then
          Error
            (Llm_provider.Http_client.HttpError
               { code = 429
               ; body = Llm_provider.Http_client.Received "rate limited"
               ; retry_after_header = None
               })
        else
          Ok
            { Llm_provider.Image_gen.images =
                [ { Llm_provider.Image_gen.mime_type = None
                  ; data_bytes = Some sample_png
                  ; remote_url = None
                  ; revised_prompt = None
                  }
                ]
            ; ignored_options = [ "aspect_ratio" ]
            })
      ~args:(`Assoc [ "prompt", `String "sun"; "aspect_ratio", `String "16:9" ])
      ()
  in
  check int "429 failed over to second candidate" 2 !calls;
  check bool "429 failover succeeded" true
    (match exec_429.disposition with Tool_result.Completed _ -> true | _ -> false);
  let body_429 = Yojson.Safe.from_string exec_429.raw_output in
  check bool "ignored_options surfaced in result JSON" true
    (json_member "ignored_options" body_429 = `List [ `String "aspect_ratio" ]);

  (* 2. Terminal 400 does NOT fail over and preserves bounded refusal body *)
  let calls_400 = ref 0 in
  let exec_400 =
    run
      ~generate_endpoint:(fun ~sw:_ ~net:_ ~clock:_ ~config:_ ~dialect:_ _req ->
        incr calls_400;
        Error
          (Llm_provider.Http_client.HttpError
             { code = 400
             ; body = Llm_provider.Http_client.Received "safety_system: prompt rejected"
             ; retry_after_header = None
             }))
      ~args:(`Assoc [ "prompt", `String "blocked" ])
      ()
  in
  check int "HTTP 400 must NOT fail over to second candidate" 1 !calls_400;
  check bool "HTTP 400 returns Failed" true
    (match exec_400.disposition with Tool_result.Failed _ -> true | _ -> false);
  check bool "HTTP 400 preserves provider refusal body" true
    (String_util.contains_substring exec_400.raw_output "safety_system: prompt rejected");

  (* 3. Timeout and Response_body_too_large do NOT fail over *)
  let calls_to = ref 0 in
  let exec_to =
    run
      ~generate_endpoint:(fun ~sw:_ ~net:_ ~clock:_ ~config:_ ~dialect:_ _req ->
        incr calls_to;
        Error
          (Llm_provider.Http_client.TimeoutError
             { message = "deadline exceeded"; phase = Llm_provider.Http_client.Wall_clock }))
      ~args:(`Assoc [ "prompt", `String "slow" ])
      ()
  in
  check int "TimeoutError must NOT fail over" 1 !calls_to;
  check bool "TimeoutError returns Failed" true
    (match exec_to.disposition with Tool_result.Failed _ -> true | _ -> false);

  let calls_big = ref 0 in
  let exec_big =
    run
      ~generate_endpoint:(fun ~sw:_ ~net:_ ~clock:_ ~config:_ ~dialect:_ _req ->
        incr calls_big;
        Error
          (Llm_provider.Http_client.ProviderFailure
             { kind = Llm_provider.Http_client.Response_body_too_large { limit_bytes = 1024 }
             ; message = "too large"
             }))
      ~args:(`Assoc [ "prompt", `String "huge" ])
      ()
  in
  check int "Response_body_too_large must NOT fail over" 1 !calls_big;
  check bool "Response_body_too_large returns Failed" true
    (match exec_big.disposition with Tool_result.Failed _ -> true | _ -> false);

  (* 4. Unsupported negative_prompt fails closed before calling provider *)
  let calls_neg = ref 0 in
  let exec_neg =
    run
      ~generate_endpoint:(fun ~sw:_ ~net:_ ~clock:_ ~config:_ ~dialect:_ _req ->
        incr calls_neg;
        Error (Llm_provider.Http_client.AcceptRejected { reason = "should not reach" }))
      ~args:(`Assoc [ "prompt", `String "cat"; "negative_prompt", `String "blurry" ])
      ()
  in
  check int "unsupported negative_prompt rejected before HTTP call" 0 !calls_neg;
  check bool "negative_prompt returns Policy_rejection failure" true
    (match exec_neg.disposition with
     | Tool_result.Failed Tool_result.Policy_rejection -> true
     | _ -> false);

  (* 5. Partial persistence + mismatched MIME retry + remote URL download *)
  let exec_partial =
    run
      ~fetch_remote_url:(fun ~net:_ ~clock:_ ~max_bytes:_ url ->
        if String.equal url "https://cdn.example.com/ok.png"
        then Ok sample_png
        else Error "remote download HTTP 404")
      ~generate_endpoint:(fun ~sw:_ ~net:_ ~clock:_ ~config:_ ~dialect:_ _req ->
        Ok
          { Llm_provider.Image_gen.images =
              [ { Llm_provider.Image_gen.mime_type = Some "image/jpeg" (* mismatched on PNG bytes *)
                ; data_bytes = None
                ; remote_url = Some "https://cdn.example.com/ok.png"
                ; revised_prompt = Some "clean sky"
                }
              ; { Llm_provider.Image_gen.mime_type = None
                ; data_bytes = None
                ; remote_url = Some "https://cdn.example.com/missing.png"
                ; revised_prompt = None
                }
              ]
          ; ignored_options = []
          })
      ~args:(`Assoc [ "prompt", `String "two skies"; "count", `Int 2 ])
      ()
  in
  check bool "partial persistence succeeds without orphaning first image" true
    (match exec_partial.disposition with Tool_result.Completed _ -> true | _ -> false);
  let body_partial = Yojson.Safe.from_string exec_partial.raw_output in
  check int "partial result count = 1" 1 (json_int "count" body_partial);
  check bool "partial flag is true" true (json_member "partial" body_partial = `Bool true);
  (match json_member "errors" body_partial with
   | `List [ `String err ] ->
     check bool "partial error identifies image #2" true
       (String_util.contains_substring err "image #2")
   | other -> failf "expected 1 partial error, got %s" (Yojson.Safe.to_string other))

let test_codex_wrapped_base64_and_synthetic_id () =
  let b64 = Base64.encode_string sample_png in
  let mid = String.length b64 / 2 in
  let wrapped_b64 =
    String.sub b64 0 mid ^ "\r\n  " ^ String.sub b64 mid (String.length b64 - mid)
  in
  let item =
    `Assoc
      [ "type", `String "imageGeneration"
      ; "result", `String wrapped_b64
      ]
  in
  match Runtime_codex_app_server.decode_image_generation_item_for_tests item with
  | Some out ->
    check string "missing Codex id gets deterministic indexed synthetic id"
      "image_generation_0" out.item_id;
    check string "whitespace-wrapped base64 decoded cleanly" sample_png out.data_bytes
  | None -> fail "expected wrapped-base64 Codex imageGeneration item to decode"

let () =
  run "vision_attachments_overhaul"
    [ ( "capabilities"
      , [ test_case "unified capability derivation and live ACP probe" `Quick
            test_unified_capability_derivation_and_acp_probe
        ; test_case "media_failover hard-cut refused" `Quick
            test_media_failover_hard_cut_refused
        ; test_case "catalog supports_image_input=false never overridden by ACP probe" `Quick
            test_catalog_false_not_overridden_by_acp_probe
        ; test_case "strict vision_reader pin and exact URI host sibling derivation" `Quick
            test_vision_reader_strict_pin_and_exact_uri_host_derivation
        ] )
    ; ( "vision_routing"
      , [ test_case "natural vision routing and PreToolUse tool gating" `Quick
            test_natural_vision_routing_and_tool_gating
        ; test_case "checkpoint preserves canonical images without eviction" `Quick
            test_checkpoint_preserves_images_without_eviction
        ; test_case "multi-keeper identical ephemeral capture isolation" `Quick
            test_multi_keeper_identical_ephemeral_capture_isolation
        ] )
    ; ( "image_generation"
      , [ test_case "parse_args validation and SSRF URL guard" `Quick
            test_generate_image_validation_and_ssrf_guard
        ; test_case "candidate discovery and mocked endpoint/in-turn execution" `Quick
            test_generate_image_candidates_and_execution
        ; test_case "failover classification, partial persistence, options, and write policy" `Quick
            test_generate_image_failover_partial_options_and_write_policy
        ] )
    ; ( "official_clients"
      , [ test_case "Codex imageGeneration and ACP image chunk decoding" `Quick
            test_codex_and_acp_image_output_decoders
        ; test_case "ACP tool_call_update media filtering and deduplication" `Quick
            test_acp_tool_call_update_media_filtering_and_dedup
        ; test_case "Codex whitespace-wrapped base64 and indexed synthetic id" `Quick
            test_codex_wrapped_base64_and_synthetic_id
        ] )
    ; ( "attachments"
      , [ test_case "upload-first ingress, KEEPER_ATTACHMENT AG-UI, non-mangling store & history"
            `Quick test_upload_first_ingress_agui_and_history_attachments
        ; test_case "Board post/comment attachment_ids and dashboard AttachmentRef projection"
            `Quick test_board_attachments_roundtrip_and_dashboard_projection
        ] )
    ]
