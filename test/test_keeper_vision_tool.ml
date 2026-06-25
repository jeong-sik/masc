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

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

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
  assert (fallback.max_tokens = Some 1024)

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
    let store_dir =
      Filename.concat
        (Config_dir_resolver.keepers_dir ())
        (meta.Masc.Keeper_meta_contract.name ^ ".vision")
    in
    let handle =
      match Store.store ~dir:store_dir bytes with
      | Ok handle -> Store.to_string handle
      | Error msg -> failwith msg
    in
    let raw =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          Vt.handle
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~meta
            ~args:
              (`Assoc
                [ "artifact", `String handle
                ; "query", `String "describe"
                ; "media_type", `String "text/plain"
                ])
            ()))
    in
    let json = json_of_output raw in
    assert (String.equal (assoc_string "error" json) "invalid_media_type");
    assert (String.equal (assoc_string "failure_class" json) "policy_rejection"))

let test_delegate_eager_eviction_stores_image_and_removes_inline_block () =
  with_temp_base (fun _ ->
    let keeper_name = "vision-ingest-delegate" in
    let bytes = "\x89PNG\r\n\x1a\ninline-image" in
    let blocks =
      [ Agent_sdk.Types.Text "before"
      ; Agent_sdk.Types.Image
          { media_type = "image/png"
          ; data = Base64.encode_string bytes
          ; source_type = "base64"
          }
      ; Agent_sdk.Types.Text "after"
      ]
    in
    match
      Vi.evict_blocks
        ~mode:Vi.Eager
        ~policy:Masc.Keeper_types_profile.Mm_delegate
        ~keeper_name
        blocks
    with
    | [ Agent_sdk.Types.Text "before"; Agent_sdk.Types.Text placeholder; Agent_sdk.Types.Text "after" ] ->
      assert (contains_substring placeholder "[image artifact:");
      assert (contains_substring placeholder "not yet read");
      let handle = artifact_handle_of_placeholder placeholder in
      (match
         Store.load
           ~dir:(Vt.vision_store_dir ~keeper_name)
           (Store.of_string handle)
       with
       | Ok stored -> assert (String.equal stored bytes)
       | Error msg -> failwith msg)
    | _ -> failwith "delegate eviction should replace the image with text")

let test_non_delegate_eviction_preserves_inline_image () =
  let bytes = "raw-image" in
  let blocks =
    [ Agent_sdk.Types.Image
        { media_type = "image/png"
        ; data = Base64.encode_string bytes
        ; source_type = "base64"
        }
    ]
  in
  match
    Vi.evict_blocks
      ~mode:Vi.Eager
      ~policy:Masc.Keeper_types_profile.Mm_inherit
      ~keeper_name:"vision-ingest-inherit"
      blocks
  with
  | [ Agent_sdk.Types.Image img ] ->
    assert (String.equal img.data (Base64.encode_string bytes))
  | _ -> failwith "non-delegate policy should preserve image blocks"

let test_delegate_eviction_bad_base64_surfaces_text_error () =
  match
    Vi.evict_blocks
      ~mode:Vi.Store_only
      ~policy:Masc.Keeper_types_profile.Mm_delegate
      ~keeper_name:"vision-ingest-bad-base64"
      [ Agent_sdk.Types.Image
          { media_type = "image/png"; data = "not base64"; source_type = "base64" }
      ]
  with
  | [ Agent_sdk.Types.Text placeholder ] ->
    assert (contains_substring placeholder "could not store");
    assert (contains_substring placeholder "bad base64")
  | _ -> failwith "bad base64 must surface as a text placeholder"

(* RFC §2.3 acceptance #1/#3 + §6 N-of-M proof. After site-2 (Store_only)
   eviction the persisted history carries no "image" modality, so RFC-0265's
   gate admits a text-only runtime and the reroute cannot fire. Revert-red:
   delete the [Image] arm of [evict_block] and the pre/post asserts diverge.
   The modality assertion IS the reroute-non-fire proof — reroute fires iff a
   required modality is not admitted, and a text-only runtime admits []. *)
let test_evicted_history_has_no_image_modality () =
  with_temp_base (fun _ ->
    let keeper_name = "vision-ingest-modality" in
    let bytes = "\x89PNG\r\n\x1a\nmodality-test" in
    let msg =
      Agent_sdk.Types.make_message
        ~role:Agent_sdk.Types.User
        [ Agent_sdk.Types.Text "look at this"
        ; Agent_sdk.Types.Image
            { media_type = "image/png"
            ; data = Base64.encode_string bytes
            ; source_type = "base64"
            }
        ]
    in
    let modalities ms = Runtime_agent.For_testing.required_modalities_of_messages ms in
    (* Pre: the inline image makes "image" a required modality (reroute trigger). *)
    assert (List.mem "image" (modalities [ msg ]));
    let evicted =
      Vi.evict_message
        ~mode:Vi.Store_only
        ~policy:Masc.Keeper_types_profile.Mm_delegate
        ~keeper_name
        msg
    in
    (* Post: no "image" modality -> the persisted history is text-only. *)
    assert (not (List.mem "image" (modalities [ evicted ])));
    (* Idempotent: re-evicting the placeholder message is a structural no-op
       (no double-store, no re-introduced image). *)
    let evicted2 =
      Vi.evict_message
        ~mode:Vi.Store_only
        ~policy:Masc.Keeper_types_profile.Mm_delegate
        ~keeper_name
        evicted
    in
    assert (evicted2 = evicted))

let () =
  test_truncated_of_stop_reason ();
  test_message_of_request ();
  test_first_vision_runtime_id_total ();
  test_provider_for_vision_preserves_configured_max_tokens ();
  test_missing_eio_context_is_runtime_failure ();
  test_invalid_media_type_is_policy_rejection ();
  test_delegate_eager_eviction_stores_image_and_removes_inline_block ();
  test_non_delegate_eviction_preserves_inline_image ();
  test_delegate_eviction_bad_base64_surfaces_text_error ();
  test_evicted_history_has_no_image_modality ();
  print_endline "test_keeper_vision_tool: all assertions passed"
