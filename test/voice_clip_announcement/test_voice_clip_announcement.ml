(* What a keeper's spoken reply is announced as, and whether the route that
   serves it would agree.

   These are two ends of one pairing and they were written apart. The serving
   route resolved a token against every container it knows and answered the
   real type. The announcing side chopped the extension off by hand and said
   the literal "audio/mpeg" for all of them -- so a reply spoken through
   [say], which writes WAVE and is the only thing a fresh mac has, went out
   labelled MP3.

   The dashboard happened not to notice: its [<audio>] element is given a src
   and no type, so the browser reads the container off the response. The cost
   was to every other reader -- the field is persisted on the chat line and
   emitted on the SSE payload, and a device following that stream has only it.

   Both sides had passing tests. Neither crossed the seam. *)

module Chat = Masc.Keeper_chat_store

let audio_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-clip-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir dir 0o700;
  dir

let write path bytes =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel bytes)

let remove_dir dir =
  Array.iter (fun name -> Sys.remove (Filename.concat dir name)) (Sys.readdir dir);
  Sys.rmdir dir

(* The announcement and the serving route have to name the same type for the
   same file. Asserting the literal alone would pass again if only one side
   moved, which is how this started. *)
let announced_and_served ~dir ~token ~extension =
  let audio_file = Filename.concat dir (token ^ extension) in
  write audio_file "not really audio, but it is really on disk";
  let announced =
    Chat.audio_clip_of_synthesized_file
      ~audio_file
      ~message_text:"오늘 음성 설정을 마쳤습니다."
      ~device_id:None
  in
  let served =
    Option.map
      (fun (_path, format) -> Voice_bridge_core.clip_content_type format)
      (Voice_bridge_core.find_clip ~dir ~token)
  in
  announced, served

let test_a_say_reply_is_announced_as_wave () =
  let dir = audio_dir () in
  Fun.protect
    ~finally:(fun () -> remove_dir dir)
    (fun () ->
      let announced, served = announced_and_served ~dir ~token:"9f3c" ~extension:".wav" in
      match announced with
      | None -> Alcotest.fail "a clip that is on disk was announced as no clip"
      | Some clip ->
        Alcotest.(check string)
          "the container say writes"
          "audio/wav"
          clip.Chat.mime;
        Alcotest.(check (option string))
          "and the route serving it agrees"
          (Some clip.Chat.mime)
          served;
        Alcotest.(check string) "the token is the name" "9f3c" clip.Chat.token;
        Alcotest.(check (option string))
          "and the URL is the one the clip route answers"
          (Some "/api/v1/voice/audio/9f3c")
          clip.Chat.audio_url)

let test_an_http_reply_is_announced_as_mp3 () =
  let dir = audio_dir () in
  Fun.protect
    ~finally:(fun () -> remove_dir dir)
    (fun () ->
      let announced, served = announced_and_served ~dir ~token:"a1b2" ~extension:".mp3" in
      match announced with
      | None -> Alcotest.fail "a clip that is on disk was announced as no clip"
      | Some clip ->
        Alcotest.(check string)
          "what the HTTP providers answer with"
          "audio/mpeg"
          clip.Chat.mime;
        Alcotest.(check (option string))
          "and the route serving it agrees"
          (Some clip.Chat.mime)
          served)

(* The reply is still recorded; only the audio is dropped. Announcing a URL
   the clip route answers 404 for would be worse than saying nothing: the
   route resolves a token by trying each container it knows, so a name it
   does not know is not fetchable however it is labelled. *)
let test_a_file_masc_cannot_serve_is_not_announced () =
  let dir = audio_dir () in
  Fun.protect
    ~finally:(fun () -> remove_dir dir)
    (fun () ->
      let audio_file = Filename.concat dir "9f3c.ogg" in
      write audio_file "a container masc does not write";
      Alcotest.(check bool)
        "no clip is announced for it"
        true
        (Chat.audio_clip_of_synthesized_file
           ~audio_file
           ~message_text:"…"
           ~device_id:None
         = None))

(* [Filename.chop_extension] raises [Invalid_argument] on a name with no
   extension, and that is what the old code called. masc's own writer always
   names a container, so this was never reached from the say or HTTP paths --
   but the field is read back out of the synthesis payload, and the MCP kind's
   payload is a tool's answer rather than masc's. An answer is the right
   outcome either way. *)
let test_a_name_with_no_extension_is_answered_not_raised () =
  let dir = audio_dir () in
  Fun.protect
    ~finally:(fun () -> remove_dir dir)
    (fun () ->
      let audio_file = Filename.concat dir "9f3c" in
      write audio_file "no extension at all";
      Alcotest.(check bool)
        "answered, not raised"
        true
        (Chat.audio_clip_of_synthesized_file
           ~audio_file
           ~message_text:"…"
           ~device_id:None
         = None))

let () =
  Random.self_init ();
  Alcotest.run
    "voice clip announcement"
    [ ( "a spoken reply is announced as what it is"
      , [ Alcotest.test_case "a say reply is WAVE" `Quick
            test_a_say_reply_is_announced_as_wave
        ; Alcotest.test_case "an HTTP reply is MP3" `Quick
            test_an_http_reply_is_announced_as_mp3
        ; Alcotest.test_case "a file masc cannot serve is not announced" `Quick
            test_a_file_masc_cannot_serve_is_not_announced
        ; Alcotest.test_case "a name with no extension is answered, not raised" `Quick
            test_a_name_with_no_extension_is_answered_not_raised
        ] )
    ]
