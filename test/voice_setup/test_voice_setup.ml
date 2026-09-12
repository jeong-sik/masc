(* Voice_setup writes the [voice] section of a live runtime.toml. What these
   tests fix is that a bad edit does not reach the file: nothing reads [voice]
   at boot, so a section that does not load stays quiet until the first speak,
   and once did so for six days. *)

(* Every commit validates the whole file, not the section being edited, so a
   voice-only write still needs a runtime.toml that loads: without
   [runtime].default the commit is refused with "[runtime].default is required".
   That is worth knowing at the wizard's edge -- an operator whose [runtime] is
   already broken cannot fix voice until that is fixed. The provider rows are
   the shape test_runtime_setup_credentials uses, where a named [providers]
   entry keeps the capability gate satisfied. *)
let runtime_base =
  {|[providers."deepseek"]
display-name = "Fixture HTTP (deepseek)"
protocol = "openai-compatible-http"
endpoint = "https://fixture.invalid/v1"
[providers."deepseek".credentials]
type = "inline"
value = "previous-fixture-key"
[models.chat]
api-name = "deepseek-v4-pro"
["deepseek".chat]
[runtime]
default = "deepseek.chat"
|}

let fixture =
  runtime_base
  ^ {|
[voice.tts]
default_model = "eleven_multilingual_v2"
default_voice = "SAz9YHcvj6GT2YYXdXww"

[voice.tts.agent_voices]
sangsu = "CwhRBWXzGAHq8TQ4Fs17"

# 2026-09-03: local whisper first. Measured 0.85 s on a real utterance.
# Leaving api_key_env out is what keeps the Authorization header absent.

[[voice.tts.endpoints]]
id = "elevenlabs-direct"
kind = "elevenlabs_direct"
api_key_env = "ELEVENLABS_API_KEY"
enabled = true
timeout_seconds = 35.0

[voice.stt]
default_model = "scribe_v2"

[[voice.stt.endpoints]]
id = "whisper-local"
kind = "openai_compat"
base_url = "http://127.0.0.1:2022/v1"
enabled = true
timeout_seconds = 60.0
|}

let with_config contents f =
  let home = Filename.temp_file "voice-setup" "" in
  Unix.unlink home;
  Unix.mkdir home 0o700;
  let path = Filename.concat home "runtime.toml" in
  Out_channel.with_open_bin path (fun out -> output_string out contents);
  let rec cleanup target =
    match Unix.lstat target with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> cleanup (Filename.concat target name)) (Sys.readdir target);
      Unix.rmdir target
    | _ -> Unix.unlink target
  in
  Fun.protect ~finally:(fun () -> cleanup home) (fun () -> f path)

let read path = In_channel.with_open_bin path In_channel.input_all

let revision path =
  match Voice_setup.observe ~runtime_config_path:path with
  | Ok (revision, _) -> revision
  | Error error -> Alcotest.fail (Voice_setup.error_message error)

let comments contents =
  String.split_on_char '\n' contents
  |> List.filter (fun line ->
       let trimmed = String.trim line in
       String.length trimmed > 0 && Char.equal trimmed.[0] '#')

let endpoint ?base_url ?api_key_env ?timeout_seconds ~id ~kind () : Voice_config.endpoint =
  { Voice_config.id
  ; kind
  ; base_url
  ; mcp_url = None
  ; health_url = None
  ; api_key_env
  ; enabled = true
  ; timeout_seconds
  ; default_voice = None
  ; command = None
  }

let apply path changes =
  Voice_setup.apply ~runtime_config_path:path ~expected_revision:(revision path) changes

let test_observe_reads_the_section () =
  with_config fixture (fun path ->
    match Voice_setup.observe ~runtime_config_path:path with
    | Error error -> Alcotest.fail (Voice_setup.error_message error)
    | Ok (_, None) -> Alcotest.fail "the fixture has a [voice] section"
    | Ok (revision, Some config) ->
      Alcotest.(check bool) "a revision is reported" true (String.length revision > 0);
      (match config.Voice_config.tts with
       | None -> Alcotest.fail "the fixture configures tts"
       | Some tts ->
         Alcotest.(check (option string))
           "the model the file names"
           (Some "eleven_multilingual_v2")
           tts.Voice_config.default_model))

let test_a_file_without_a_voice_section_observes_as_none () =
  with_config runtime_base (fun path ->
    match Voice_setup.observe ~runtime_config_path:path with
    | Ok (_, None) -> ()
    | Ok (_, Some _) -> Alcotest.fail "there is no [voice] section to find"
    | Error error -> Alcotest.fail (Voice_setup.error_message error))

let test_an_endpoint_is_added_and_the_notes_survive () =
  with_config fixture (fun path ->
    let added =
      endpoint
        ~id:"mlx-audio"
        ~kind:Voice_config.Openai_compat
        ~base_url:"http://127.0.0.1:8000/v1"
        ~timeout_seconds:60.0
        ()
    in
    (match apply path [ Voice_setup.Put_endpoint (Voice_setup.Tts, added) ] with
     | Ok _revision -> ()
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    let written = read path in
    Alcotest.(check (list string))
      "the operator's notes are still there, in order"
      (comments fixture)
      (comments written);
    match Voice_config.parse_runtime_toml_text written with
    | Error message -> Alcotest.fail message
    | Ok None -> Alcotest.fail "the section did not survive the write"
    | Ok (Some config) ->
      let ids =
        match config.Voice_config.tts with
        | None -> []
        | Some tts ->
          List.map (fun (e : Voice_config.endpoint) -> e.Voice_config.id) tts.Voice_config.endpoints
      in
      Alcotest.(check (list string))
        "both endpoints load back"
        [ "elevenlabs-direct"; "mlx-audio" ]
        ids)

(* The check that matters: an edit the loader refuses must not reach the file.
   A blank default_model is refused by name, because a blank one would reach a
   provider as model_id "". *)
let test_an_edit_the_loader_refuses_is_not_written () =
  with_config fixture (fun path ->
    match apply path [ Voice_setup.Set_default_model (Voice_setup.Tts, "") ] with
    | Ok _revision -> Alcotest.fail "a blank default_model must not be accepted"
    | Error (Voice_setup.Voice_section_invalid message) ->
      Alcotest.(check bool)
        "the refusal names the key"
        true
        (let needle = "default_model" in
         let rec found index =
           index + String.length needle <= String.length message
           && (String.equal (String.sub message index (String.length needle)) needle
               || found (index + 1))
         in
         found 0);
      Alcotest.(check string) "the file is untouched" fixture (read path)
    | Error error -> Alcotest.fail (Voice_setup.error_message error))

let test_a_stale_revision_writes_nothing () =
  with_config fixture (fun path ->
    let stale = revision path in
    (* Someone else writes between the observation and the apply. *)
    let concurrent = fixture ^ "\n# another session was here\n" in
    Out_channel.with_open_bin path (fun out -> output_string out concurrent);
    match
      Voice_setup.apply
        ~runtime_config_path:path
        ~expected_revision:stale
        [ Voice_setup.Set_tts_default_voice "Sarah" ]
    with
    | Error Voice_setup.Configuration_changed ->
      Alcotest.(check string) "the concurrent write is preserved" concurrent (read path)
    | Ok _revision -> Alcotest.fail "a stale revision must be refused"
    | Error error -> Alcotest.fail (Voice_setup.error_message error))

(* A first endpoint and the default_model its section requires have to land
   together: applied one at a time, the first half is refused. *)
let test_changes_that_depend_on_each_other_land_together () =
  with_config runtime_base (fun path ->
    let added =
      endpoint
        ~id:"whisper-local"
        ~kind:Voice_config.Openai_compat
        ~base_url:"http://127.0.0.1:2022/v1"
        ()
    in
    (match apply path [ Voice_setup.Put_endpoint (Voice_setup.Stt, added) ] with
     | Error (Voice_setup.Voice_section_invalid _) -> ()
     | Ok _revision -> Alcotest.fail "an stt section with no default_model must be refused"
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    Alcotest.(check string) "nothing was written by the refused half" runtime_base (read path);
    match
      apply
        path
        [ Voice_setup.Set_default_model (Voice_setup.Stt, "scribe_v2")
        ; Voice_setup.Put_endpoint (Voice_setup.Stt, added)
        ]
    with
    | Error error -> Alcotest.fail (Voice_setup.error_message error)
    | Ok _revision ->
      (match Voice_config.parse_runtime_toml_text (read path) with
       | Ok (Some config) ->
         (match config.Voice_config.stt with
          | Some stt ->
            Alcotest.(check int) "the endpoint is there" 1 (List.length stt.Voice_config.endpoints)
          | None -> Alcotest.fail "the stt section should exist")
       | Ok None -> Alcotest.fail "the section should exist"
       | Error message -> Alcotest.fail message))

let test_an_agent_voice_is_set_and_cleared () =
  with_config fixture (fun path ->
    (match apply path [ Voice_setup.Set_agent_voice ("codex", Some "JBFqnCBsd6RMkjVDRZzb") ] with
     | Ok _revision -> ()
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    let voices contents =
      match Voice_config.parse_runtime_toml_text contents with
      | Ok (Some config) ->
        (match config.Voice_config.tts with
         | Some tts -> tts.Voice_config.agent_voices
         | None -> [])
      | Ok None | Error _ -> []
    in
    Alcotest.(check (option string))
      "the mapping is written"
      (Some "JBFqnCBsd6RMkjVDRZzb")
      (List.assoc_opt "codex" (voices (read path)));
    (match apply path [ Voice_setup.Set_agent_voice ("codex", None) ] with
     | Ok _revision -> ()
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    Alcotest.(check (option string))
      "and cleared again"
      None
      (List.assoc_opt "codex" (voices (read path)));
    Alcotest.(check (option string))
      "the agent that was already mapped is left alone"
      (Some "CwhRBWXzGAHq8TQ4Fs17")
      (List.assoc_opt "sangsu" (voices (read path))))

(* Moving an endpoint from a hosted provider to a local one has to drop
   api_key_env, or it sends an Authorization header the local server never
   asked for and gets a 401 instead of service. *)
let test_a_field_left_none_is_dropped_from_the_endpoint () =
  with_config fixture (fun path ->
    let local =
      endpoint
        ~id:"elevenlabs-direct"
        ~kind:Voice_config.Openai_compat
        ~base_url:"http://127.0.0.1:8000/v1"
        ()
    in
    (match apply path [ Voice_setup.Put_endpoint (Voice_setup.Tts, local) ] with
     | Ok _revision -> ()
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    match Voice_config.parse_runtime_toml_text (read path) with
    | Ok (Some config) ->
      (match config.Voice_config.tts with
       | Some { Voice_config.endpoints = [ written ]; _ } ->
         Alcotest.(check (option string))
           "the credential reference is gone"
           None
           written.Voice_config.api_key_env;
         Alcotest.(check (option string))
           "the local address replaced it"
           (Some "http://127.0.0.1:8000/v1")
           written.Voice_config.base_url
       | Some _ | None -> Alcotest.fail "expected exactly one tts endpoint")
    | Ok None -> Alcotest.fail "the section should exist"
    | Error message -> Alcotest.fail message)

let test_preview_does_not_write () =
  with_config fixture (fun path ->
    match
      Voice_setup.preview
        ~runtime_config_path:path
        ~expected_revision:(revision path)
        [ Voice_setup.Set_tts_default_voice "Sarah" ]
    with
    | Error error -> Alcotest.fail (Voice_setup.error_message error)
    | Ok proposed ->
      Alcotest.(check string) "the file on disk is unchanged" fixture (read path);
      Alcotest.(check bool)
        "the proposal carries the new value"
        true
        (List.exists
           (String.equal {|default_voice = "Sarah"|})
           (String.split_on_char '\n' proposed)))

let test_an_endpoint_is_removed () =
  with_config fixture (fun path ->
    let local =
      endpoint
        ~id:"mlx-audio"
        ~kind:Voice_config.Openai_compat
        ~base_url:"http://127.0.0.1:8000/v1"
        ()
    in
    (match apply path [ Voice_setup.Put_endpoint (Voice_setup.Tts, local) ] with
     | Ok _revision -> ()
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    (match apply path [ Voice_setup.Remove_endpoint (Voice_setup.Tts, "elevenlabs-direct") ] with
     | Ok _revision -> ()
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    match Voice_config.parse_runtime_toml_text (read path) with
    | Ok (Some config) ->
      (match config.Voice_config.tts with
       | Some tts ->
         Alcotest.(check (list string))
           "only the endpoint that was not removed remains"
           [ "mlx-audio" ]
           (List.map
              (fun (e : Voice_config.endpoint) -> e.Voice_config.id)
              tts.Voice_config.endpoints)
       | None -> Alcotest.fail "the tts section should still exist")
    | Ok None -> Alcotest.fail "the section should exist"
    | Error message -> Alcotest.fail message)

(* A section that exists must carry an endpoints array, so emptying one leaves a
   file the loader refuses. The refusal is the right answer -- a tts section with
   nowhere to send a sentence is not a configuration -- and it costs nothing,
   because the writer checks before it writes. Removing the section itself is a
   change this module does not offer yet. *)
let test_removing_the_last_endpoint_is_refused () =
  with_config fixture (fun path ->
    match apply path [ Voice_setup.Remove_endpoint (Voice_setup.Stt, "whisper-local") ] with
    | Error (Voice_setup.Voice_section_invalid _) ->
      Alcotest.(check string) "the file is untouched" fixture (read path)
    | Ok _revision -> Alcotest.fail "an stt section with no endpoints must be refused"
    | Error error -> Alcotest.fail (Voice_setup.error_message error))

let test_provider_voices_do_not_replace_the_existing_section_voice () =
  with_config runtime_base (fun path ->
    let say =
      { (endpoint ~id:"speaker" ~kind:Voice_config.Macos_say ()) with
        Voice_config.default_voice = Some "Yuna" }
    in
    let eleven =
      { (endpoint ~id:"hosted" ~kind:Voice_config.Elevenlabs_direct ()) with
        Voice_config.default_voice = Some "provider-specific-id" }
    in
    let commit changes =
      match apply path changes with
      | Ok _revision -> ()
      | Error error -> Alcotest.fail (Voice_setup.error_message error)
    in
    commit [ Voice_setup.Put_endpoint (Voice_setup.Tts, say) ];
    commit
      [ Voice_setup.Set_default_model (Voice_setup.Tts, "hosted-model")
      ; Voice_setup.Put_endpoint (Voice_setup.Tts, eleven) ];
    match Voice_config.parse_runtime_toml_text (read path) with
    | Ok (Some { Voice_config.tts = Some tts; _ }) ->
      Alcotest.(check string) "the initial fallback remains unchanged" "Yuna" tts.default_voice;
      Alcotest.(check (list (option string))) "each endpoint keeps its vocabulary"
        [ Some "Yuna"; Some "provider-specific-id" ]
        (List.map (fun (endpoint : Voice_config.endpoint) -> endpoint.default_voice) tts.endpoints)
    | Ok _ -> Alcotest.fail "the speaking section should exist"
    | Error message -> Alcotest.fail message)

let test_a_dotted_keeper_voice_can_be_written_replaced_and_removed () =
  with_config fixture (fun path ->
    let set voice =
      match apply path [ Voice_setup.Set_agent_voice ("team.alpha", voice) ] with
      | Ok _revision -> ()
      | Error error -> Alcotest.fail (Voice_setup.error_message error)
    in
    let voices () =
      match Voice_config.parse_runtime_toml_text (read path) with
      | Ok (Some { Voice_config.tts = Some tts; _ }) -> tts.agent_voices
      | Ok _ -> Alcotest.fail "the speaking section should exist"
      | Error message -> Alcotest.fail message
    in
    set (Some "one");
    Alcotest.(check (option string)) "the raw dotted keeper name was written"
      (Some "one") (List.assoc_opt "team.alpha" (voices ()));
    set (Some "two");
    Alcotest.(check (option string)) "the literal keeper key was replaced"
      (Some "two") (List.assoc_opt "team.alpha" (voices ()));
    set None;
    Alcotest.(check (option string)) "the literal keeper key was removed"
      None (List.assoc_opt "team.alpha" (voices ())))

let () =
  Alcotest.run
    "voice_setup"
    [ ( "observe"
      , [ Alcotest.test_case "reads the section" `Quick test_observe_reads_the_section
        ; Alcotest.test_case "a file without a voice section is None" `Quick
            test_a_file_without_a_voice_section_observes_as_none
        ] )
    ; ( "refusals write nothing"
      , [ Alcotest.test_case "an edit the loader refuses is not written" `Quick
            test_an_edit_the_loader_refuses_is_not_written
        ; Alcotest.test_case "a stale revision writes nothing" `Quick
            test_a_stale_revision_writes_nothing
        ; Alcotest.test_case "removing the last endpoint is refused" `Quick
            test_removing_the_last_endpoint_is_refused
        ; Alcotest.test_case "preview does not write" `Quick test_preview_does_not_write
        ] )
    ; ( "changes"
      , [ Alcotest.test_case "an endpoint is added and the notes survive" `Quick
            test_an_endpoint_is_added_and_the_notes_survive
        ; Alcotest.test_case "dependent changes land together" `Quick
            test_changes_that_depend_on_each_other_land_together
        ; Alcotest.test_case "an agent voice is set and cleared" `Quick
            test_an_agent_voice_is_set_and_cleared
        ; Alcotest.test_case "provider voices preserve the section fallback" `Quick
            test_provider_voices_do_not_replace_the_existing_section_voice
        ; Alcotest.test_case "dotted keeper voice can be replaced and removed" `Quick
            test_a_dotted_keeper_voice_can_be_written_replaced_and_removed
        ; Alcotest.test_case "a field left None is dropped" `Quick
            test_a_field_left_none_is_dropped_from_the_endpoint
        ; Alcotest.test_case "an endpoint is removed" `Quick test_an_endpoint_is_removed
        ] )
    ]
