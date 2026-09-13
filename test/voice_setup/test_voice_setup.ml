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
voice-setup-fixture = "CwhRBWXzGAHq8TQ4Fs17"

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

(* The standalone JSON beside the temporary runtime.toml. Absent unless a test
   writes it, which is the state every other case runs in. *)
let standalone path = Filename.concat (Filename.dirname path) "voice_config.json"

let revision path =
  match Voice_setup.observe ~runtime_config_path:path ~standalone_path:(standalone path) with
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
  Voice_setup.apply ~runtime_config_path:path ~standalone_path:(standalone path)
    ~expected_revision:(revision path) changes

let test_observe_reads_the_section () =
  with_config fixture (fun path ->
    match Voice_setup.observe ~runtime_config_path:path ~standalone_path:(standalone path) with
    | Error error -> Alcotest.fail (Voice_setup.error_message error)
    | Ok (_, None) -> Alcotest.fail "the fixture has a [voice] section"
    | Ok (_, Some (Voice_setup.Standalone_json _, _)) ->
      Alcotest.fail "no standalone file was written"
    | Ok (revision, Some (Voice_setup.Runtime_toml, config)) ->
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
    match Voice_setup.observe ~runtime_config_path:path ~standalone_path:(standalone path) with
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
        ~standalone_path:(standalone path)
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
      (List.assoc_opt "voice-setup-fixture" (voices (read path))))

(* Moving an endpoint from a hosted provider to a local one has to drop
   api_key_env, or it sends an Authorization header the local server never
   asked for and gets a 401 instead of service. *)
(* send_on_stop is written as a bare boolean, in the section the voice config
   defines it in. It was reachable only by hand-editing runtime.toml: the TUI
   read a [tui] key nothing published, while the one on the wire was read by
   nothing (#35670). A configuring surface writes this one. *)
let test_send_on_stop_is_written_as_a_boolean () =
  with_config fixture (fun path ->
    (match apply path [ Voice_setup.Set_send_on_stop true ] with
     | Ok _revision -> ()
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    let reads contents =
      match Voice_config.parse_runtime_toml_text contents with
      | Ok (Some config) ->
        Option.map (fun stt -> stt.Voice_config.send_on_stop) config.Voice_config.stt
      | Ok None | Error _ -> None
    in
    Alcotest.(check (option bool)) "on" (Some true) (reads (read path));
    (* Bare true, not "true": a reader that expects a boolean refuses the
       quoted form, and the whole [voice] section then fails to load. *)
    Alcotest.(check bool) "written unquoted" true
      (Astring.String.is_infix ~affix:"send_on_stop = true" (read path));
    (match apply path [ Voice_setup.Set_send_on_stop false ] with
     | Ok _revision -> ()
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    Alcotest.(check (option bool)) "and off again" (Some false) (reads (read path)))

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
        ~standalone_path:(standalone path)
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

(* Where a voice chosen for say is written depends on who owns the section's
   default, not on whether a section exists.

   The distinction is load-bearing: an endpoint voice outranks
   [voice.tts.agent_voices], so one written where it is not needed retires
   every per-keeper voice at that endpoint without saying so. Measured
   2026-09-13 -- running the same `voice-local-setup --voice Yuna` twice on a
   fresh workspace put the voice on the endpoint the second time, because a
   section existed by then (the first run's), and a keeper mapped to Eddy then
   spoke in Yuna. *)
let tts_section_of toml =
  match Voice_config.parse_runtime_toml_text toml with
  | Ok (Some { Voice_config.tts = Some tts; _ }) -> tts
  | Ok _ -> Alcotest.fail "the fixture must carry a [voice.tts] section"
  | Error message -> Alcotest.failf "the fixture must parse: %s" message

let say_only_section =
  {|[[voice.tts.endpoints]]
id = "macos-say"
kind = "macos_say"
enabled = true

[voice.tts]
default_voice = "Yuna"
|}

let say_beside_another_provider =
  {|[[voice.tts.endpoints]]
id = "eleven"
kind = "elevenlabs_direct"
api_key_env = "ELEVENLABS_API_KEY"
enabled = true

[[voice.tts.endpoints]]
id = "macos-say"
kind = "macos_say"
enabled = true

[voice.tts]
default_model = "eleven_multilingual_v2"
default_voice = "SAz9YHcvj6GT2YYXdXww"
|}

let test_a_local_voice_goes_where_its_default_is_not_someone_elses () =
  let placed section =
    Voice_setup.voice_placement section = Voice_setup.On_the_section
  in
  Alcotest.(check bool) "no section yet: the section default" true (placed None);
  Alcotest.(check bool)
    "a section only say is in -- including one an earlier run wrote: the section default"
    true
    (placed (Some (tts_section_of say_only_section)));
  Alcotest.(check bool)
    "a section another provider shares: on the endpoint"
    false
    (placed (Some (tts_section_of say_beside_another_provider)))
;;

(* The loader reads the standalone JSON when runtime.toml has no [voice]
   section. The observation parsed only the TOML, so a workspace whose voice
   worked from that file observed as not configured, and a client listed no
   endpoints for it. *)
let standalone_json =
  {|{"tts": {"default_model": "eleven_multilingual_v2", "default_voice": "Yuna",
     "endpoints": [{"id": "from-json", "kind": "elevenlabs_direct",
                    "api_key_env": "ELEVENLABS_API_KEY"}]}}|}

let test_observe_reports_the_standalone_source_in_effect () =
  with_config runtime_base (fun path ->
    Out_channel.with_open_bin (standalone path) (fun out -> output_string out standalone_json);
    match Voice_setup.observe ~runtime_config_path:path ~standalone_path:(standalone path) with
    | Error error -> Alcotest.fail (Voice_setup.error_message error)
    | Ok (_, None) -> Alcotest.fail "the standalone file configures voice"
    | Ok (_, Some (Voice_setup.Runtime_toml, _)) ->
      Alcotest.fail "runtime.toml has no [voice] section"
    | Ok (_, Some (Voice_setup.Standalone_json source, config)) ->
      Alcotest.(check string) "named by the path it was read from" (standalone path) source;
      Alcotest.(check (list string)) "with the endpoints that file declares" [ "from-json" ]
        (match config.Voice_config.tts with
         | None -> []
         | Some tts ->
           List.map (fun (e : Voice_config.endpoint) -> e.Voice_config.id)
             tts.Voice_config.endpoints))

(* runtime.toml's section wins when both exist, so the file beside it is not
   what is in effect and is not reported. *)
let test_a_toml_section_is_in_effect_over_the_standalone_file () =
  with_config fixture (fun path ->
    Out_channel.with_open_bin (standalone path) (fun out -> output_string out standalone_json);
    match Voice_setup.observe ~runtime_config_path:path ~standalone_path:(standalone path) with
    | Ok (_, Some (Voice_setup.Runtime_toml, _)) -> ()
    | Ok (_, Some (Voice_setup.Standalone_json _, _)) ->
      Alcotest.fail "the [voice] section is what the loader reads"
    | Ok (_, None) -> Alcotest.fail "voice is configured"
    | Error error -> Alcotest.fail (Voice_setup.error_message error))

(* The first [voice] section written into runtime.toml becomes what the loader
   reads, and every setting the standalone file carried stops applying. Refused
   by the writer itself, so the route and the local command agree. *)
let test_a_write_over_the_standalone_source_is_refused () =
  with_config runtime_base (fun path ->
    Out_channel.with_open_bin (standalone path) (fun out -> output_string out standalone_json);
    let added =
      endpoint ~id:"mlx-audio" ~kind:Voice_config.Openai_compat
        ~base_url:"http://127.0.0.1:8000/v1" ()
    in
    let changes =
      [ Voice_setup.Put_endpoint (Voice_setup.Tts, added)
      ; Voice_setup.Set_default_model (Voice_setup.Tts, "model")
      ; Voice_setup.Set_tts_default_voice "voice"
      ]
    in
    let refused what = function
      | Error (Voice_setup.Standalone_source_active source) ->
        Alcotest.(check string) (what ^ " names the file in effect") (standalone path) source
      | Ok _ -> Alcotest.failf "%s must not accept a section over the standalone file" what
      | Error error -> Alcotest.fail (Voice_setup.error_message error)
    in
    refused "preview"
      (Voice_setup.preview ~runtime_config_path:path ~standalone_path:(standalone path)
         ~expected_revision:(revision path) changes);
    refused "apply" (apply path changes);
    Alcotest.(check string) "runtime.toml is untouched" runtime_base (read path);
    Alcotest.(check string) "and so is the standalone file" standalone_json
      (read (standalone path)))

let () =
  Alcotest.run
    "voice_setup"
    [ ( "observe"
      , [ Alcotest.test_case "reads the section" `Quick test_observe_reads_the_section
        ; Alcotest.test_case "a file without a voice section is None" `Quick
            test_a_file_without_a_voice_section_observes_as_none
        ; Alcotest.test_case "the standalone source in effect is reported" `Quick
            test_observe_reports_the_standalone_source_in_effect
        ; Alcotest.test_case "a toml section is in effect over the standalone file" `Quick
            test_a_toml_section_is_in_effect_over_the_standalone_file
        ; Alcotest.test_case "a write over the standalone source is refused" `Quick
            test_a_write_over_the_standalone_source_is_refused
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
        ; Alcotest.test_case "a local voice goes where its default is not someone else's"
            `Quick test_a_local_voice_goes_where_its_default_is_not_someone_elses
        ; Alcotest.test_case "send_on_stop is written as a boolean" `Quick
            test_send_on_stop_is_written_as_a_boolean
        ; Alcotest.test_case "a field left None is dropped" `Quick
            test_a_field_left_none_is_dropped_from_the_endpoint
        ; Alcotest.test_case "an endpoint is removed" `Quick test_an_endpoint_is_removed
        ] )
    ]
