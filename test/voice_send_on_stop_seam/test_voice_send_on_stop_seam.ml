(* send_on_stop is written by the voice setup writer and read by the TUI at
   boot. Those are different libraries, and for a while they named different
   keys: the TUI read [tui].voice_send_on_stop, which no surface published,
   while [voice.stt].send_on_stop was published by GET /api/v1/voice/config
   and by the voice setup route and read by nothing (#35670).

   Both sides had tests. Both passed. Nothing crossed the seam, so nobody
   noticed that turning the documented setting on did nothing. This suite is
   that crossing: write it the way a configuring surface does, read it the way
   the TUI does, in one process. *)

(* A whole runtime.toml, because the writer validates the whole file before it
   commits: a voice edit on a file whose [runtime] section is broken is
   refused, and that refusal is the writer working. *)
let fixture =
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

# a note above the section, which the writer has to keep
[voice.stt]
default_model = "scribe_v1"

[[voice.stt.endpoints]]
id = "eleven"
kind = "elevenlabs_direct"
api_key_env = "ELEVENLABS_API_KEY"
|}

(* [<base>/.masc/config/runtime.toml] -- the layout both sides resolve to. *)
let with_workspace f =
  let base = Filename.temp_file "masc_seam" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let masc = Filename.concat base ".masc" in
  let config = Filename.concat masc "config" in
  Unix.mkdir masc 0o700;
  Unix.mkdir config 0o700;
  let path = Filename.concat config "runtime.toml" in
  Fun.protect
    ~finally:(fun () ->
      let remove target = try Sys.remove target with Sys_error _ -> () in
      let remove_dir target = try Unix.rmdir target with Unix.Unix_error _ -> () in
      remove path;
      remove_dir config;
      remove_dir masc;
      remove_dir base)
    (fun () ->
      let out = open_out path in
      output_string out fixture;
      close_out out;
      f ~base ~path)

let write ~path changes =
  match Voice_setup.observe ~runtime_config_path:path with
  | Error error -> Alcotest.fail (Voice_setup.error_message error)
  | Ok (revision, _) ->
    (match Voice_setup.apply ~runtime_config_path:path ~expected_revision:revision changes with
     | Error error -> Alcotest.fail (Voice_setup.error_message error)
     | Ok _revision -> ())

let test_what_the_writer_sets_is_what_the_tui_reads () =
  with_workspace (fun ~base ~path ->
    Alcotest.(check (option bool))
      "off before anything is written"
      (Some false)
      (Masc_tui_config.load ~base_path:base).Masc_tui_config.send_on_stop;
    write ~path [ Voice_setup.Set_send_on_stop true ];
    Alcotest.(check (option bool))
      "on, read by the side that acts on it"
      (Some true)
      (Masc_tui_config.load ~base_path:base).Masc_tui_config.send_on_stop;
    write ~path [ Voice_setup.Set_send_on_stop false ];
    Alcotest.(check (option bool))
      "and off again"
      (Some false)
      (Masc_tui_config.load ~base_path:base).Masc_tui_config.send_on_stop)

(* The comment above the section survives the write. The file is an operator's
   to keep: the whole reason the voice writer edits lines instead of
   regenerating the section. *)
let test_the_note_above_the_section_survives () =
  with_workspace (fun ~base:_ ~path ->
    write ~path [ Voice_setup.Set_send_on_stop true ];
    let channel = open_in path in
    let contents = really_input_string channel (in_channel_length channel) in
    close_in channel;
    Alcotest.(check bool)
      "the note is still there"
      true
      (String.length contents > 0
       && Option.is_some
            (List.find_opt
               (fun line -> String.equal line "# a note above the section, which the writer has to keep")
               (String.split_on_char '\n' contents))))

let () =
  Alcotest.run
    "voice_send_on_stop_seam"
    [ ( "the writer and the reader agree"
      , [ Alcotest.test_case "what the writer sets is what the TUI reads" `Quick
            test_what_the_writer_sets_is_what_the_tui_reads
        ; Alcotest.test_case "the note above the section survives" `Quick
            test_the_note_above_the_section_survives
        ] )
    ]
