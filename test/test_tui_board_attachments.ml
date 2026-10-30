(* Board post attachments decode from [meta.attachments] per entry, with
   explicit failure carried on the entry rather than failing the post
   (spec decision 5). The wire writer is the board post handler
   (lib/board_tool_adapter/board_tool_attachment.ml): a stored entry is
   [{"kind", "url"|"artifact", "name"?}]. These pin the read side: a kind
   this build does not know is carried as [Ak_unknown] and still decodes, a
   broken entry is an [Error] carrying why, and the rest of the entries and
   the post decode normally. *)

open Masc_tui_types

let sha256 = String.make 64 'a'

let url_entry ?name kind url =
  `Assoc
    ([ "kind", `String kind; "url", `String url ]
     @ match name with Some name -> [ "name", `String name ] | None -> [])
;;

let artifact_entry ?name kind digest =
  `Assoc
    ([ ( "kind", `String kind )
     ; ( "artifact"
       , `Assoc
           [ ( "_blob"
             , `Assoc
                 [ "sha256", `String digest
                 ; "bytes", `Int 42
                 ; "mime", `String "application/octet-stream"
                 ; "preview", `String ""
                 ] )
           ] )
     ]
     @ match name with Some name -> [ "name", `String name ] | None -> [])
;;

let post_json ?meta () =
  `Assoc
    ([ "id", `String "p1"
     ; "author", `String "keeper"
     ; "title", `String "t"
     ; "body", `String "b"
     ; "votes", `Int 0
     ; "comment_count", `Int 0
     ; "created_at", `String "2026-10-13"
     ]
     @ match meta with Some meta -> [ "meta", meta ] | None -> [])
;;

let decode = decode_board_attachments

let check_entry name (expected : board_attachment_entry) actual =
  Alcotest.(check bool) name true (expected = actual)
;;

let check_broken name (entry : board_attachment_entry) =
  Alcotest.(check bool) name true (Result.is_error entry)
;;

let attachments entries = post_json ~meta:(`Assoc [ "attachments", entries ]) ()

let test_meta_attachments_decode () =
  match
    decode
      (attachments
         (`List
           [ url_entry "image" "https://example.com/a.png"
           ; artifact_entry ~name:"riff.gp" "score" sha256
           ]))
  with
  | [ image; score ] ->
      check_entry "url entry decodes kind, source, no name"
        (Ok
           { ba_kind = Ak_image
           ; ba_source = As_url "https://example.com/a.png"
           ; ba_name = None
           })
        image;
      check_entry "artifact entry decodes to the digest, the size and the name"
        (Ok
           { ba_kind = Ak_score
           ; ba_source = As_artifact { sha256; bytes = 42 }
           ; ba_name = Some "riff.gp"
           })
        score
  | other ->
      Alcotest.failf "expected two attachments, decoded %d" (List.length other)
;;

let test_unknown_kind_is_carried () =
  match decode (attachments (`List [ url_entry "hologram" "https://example.com/h" ])) with
  | [ entry ] ->
      check_entry "the unknown kind keeps the wire's word and still decodes"
        (Ok
           { ba_kind = Ak_unknown "hologram"
           ; ba_source = As_url "https://example.com/h"
           ; ba_name = None
           })
        entry
  | other ->
      Alcotest.failf "unknown kind not carried: decoded %d entries"
        (List.length other)
;;

let test_malformed_entry_does_not_fail_the_rest () =
  match
    decode
      (attachments
         (`List
           [ artifact_entry "file" sha256
           ; `Assoc [ "kind", `String "image" ] (* source missing *)
           ; `String "not an object"
           ; `Assoc
               [ "kind", `String "audio"
               ; "url", `String "https://example.com/a.mp3"
               ; "name", `Int 42 (* name must be a string *)
               ]
           ; `Assoc
               [ "kind", `String "audio"
               ; "kind", `String "midi" (* which one is it *)
               ; "url", `String "https://example.com/a.mp3"
               ]
           ]))
  with
  | [ fine; missing_source; not_object; bad_name; two_kinds ] ->
      check_entry "the well-formed entry still decodes"
        (Ok
           { ba_kind = Ak_file
           ; ba_source = As_artifact { sha256; bytes = 42 }
           ; ba_name = None
           })
        fine;
      check_broken "missing source is broken, not dropped" missing_source;
      check_broken "non-object entry is broken, not dropped" not_object;
      check_broken "non-string name is broken, not dropped" bad_name;
      check_broken "a kind said twice is broken, not read as the first" two_kinds
  | other ->
      Alcotest.failf "expected five attachments, decoded %d" (List.length other)
;;

let test_no_meta_means_no_attachments () =
  Alcotest.(check int) "no meta" 0 (List.length (decode (post_json ())));
  Alcotest.(check int)
    "meta without attachments" 0
    (List.length (decode (post_json ~meta:(`Assoc [ "source", `String "x" ]) ())))
;;

let test_non_list_attachments_is_one_broken_entry () =
  match decode (attachments (`String "oops")) with
  | [ broken ] -> check_broken "one broken entry stands for the claim" broken
  | other ->
      Alcotest.failf "expected one broken entry, decoded %d" (List.length other)
;;

(* A stored artifact is the handler's wrapper: a digest and an integer size.
   Each of these is some other shape under [artifact], and none of them reads
   as an attachment. The bare [sha256] form is what a client sends, never
   what a post holds. *)
let test_only_the_handlers_wrapper_is_an_artifact () =
  let wrapper fields = `Assoc [ "_blob", `Assoc fields ] in
  let broken label source =
    match decode (attachments (`List [ `Assoc (("kind", `String "file") :: source) ])) with
    | [ entry ] -> check_broken label entry
    | other -> Alcotest.failf "%s: decoded %d entries" label (List.length other)
  in
  broken "a size that is not an integer"
    [ "artifact", wrapper [ "sha256", `String sha256; "bytes", `String "42" ] ];
  broken "no size"
    [ "artifact", wrapper [ "sha256", `String sha256 ] ];
  broken "a digest that is not a sha256"
    [ "artifact", wrapper [ "sha256", `String "abc"; "bytes", `Int 42 ] ];
  broken "a bare digest" [ "sha256", `String sha256 ]
;;

(* The read pane's one-line label. These check that the entry's own data
   reaches the reader -- its name, its size, its kind, the wire's word for a
   kind this build does not know, the reason an entry broke -- and leave the
   wording around that data free to change. *)
module Board_attachments = Masc_tui_board_attachments

let contains ~part whole =
  let part_length = String.length part in
  let rec at index =
    index + part_length <= String.length whole
    && (String.equal (String.sub whole index part_length) part || at (index + 1))
  in
  at 0
;;

let artifact ?name ?(bytes = 42) kind : board_attachment_entry =
  Ok
    { ba_kind = kind
    ; ba_source = As_artifact { sha256; bytes }
    ; ba_name = name
    }
;;

let test_label_carries_the_name_and_the_size () =
  let small = Board_attachments.label (artifact ~name:"riff.gp" ~bytes:42 Ak_score) in
  let large = Board_attachments.label (artifact ~name:"riff.gp" ~bytes:4096 Ak_score) in
  Alcotest.(check bool) "the name is in the label" true
    (contains ~part:"riff.gp" small);
  Alcotest.(check bool) "the size is said" false (String.equal small large)
;;

let test_label_tells_the_kinds_apart () =
  let labels =
    List.map
      (fun kind -> Board_attachments.label (artifact ~name:"a" kind))
      [ Ak_image; Ak_video; Ak_youtube; Ak_external_link
      ; Ak_file; Ak_audio; Ak_score; Ak_midi
      ]
  in
  Alcotest.(check int) "eight kinds, eight labels" 8
    (List.length (List.sort_uniq String.compare labels))
;;

let test_label_names_an_unknown_kind () =
  let unknown = Board_attachments.label (artifact (Ak_unknown "hologram")) in
  Alcotest.(check bool) "the wire's word for the kind is in the label" true
    (contains ~part:"hologram" unknown)
;;

let test_label_says_why_an_entry_broke () =
  let reason = "attachments[3] name must be a string" in
  Alcotest.(check bool) "the reason is in the label" true
    (contains ~part:reason (Board_attachments.label (Error reason)))
;;

(* The write side of the pane: a local file's kind comes from its name --
   the store keeps no media type per file, so the name is the only signal --
   and staged uploads become the [attachments] field of the post payload. The
   field is omitted entirely when nothing was staged, so a plain post's
   payload is exactly what it was before this feature. *)
let check_option name expected actual =
  Alcotest.(check bool) name true (expected = actual)
;;

let check_kinds expected paths =
  List.iter
    (fun path ->
      Alcotest.(check string) path
        (board_upload_kind_to_wire expected)
        (board_upload_kind_to_wire (upload_kind_of_path path)))
    paths
;;

let test_a_name_decides_the_kind () =
  check_kinds Uk_score
    [ "riff.gp"; "riff.gp5"; "riff.gpx"; "lead.musicxml"; "lead.mxl"; "x.atex" ];
  check_kinds Uk_midi [ "groove.mid"; "groove.midi" ];
  check_kinds Uk_image [ "tab.png"; "photo.jpg" ];
  check_kinds Uk_audio [ "mix.mp3"; "mix.wav" ]
;;

(* Extension matching ignores case: exports from tab editors and macOS saves
   routinely carry uppercase extensions. *)
let test_an_uppercase_extension_decides_the_same () =
  check_kinds Uk_score [ "SOLO.GP5" ];
  check_kinds Uk_image [ "Photo.JPG" ]
;;

(* A name that says nothing is a plain file: every path can be attached. *)
let test_an_unknown_name_is_a_plain_file () =
  check_kinds Uk_file [ "notes.zzz9"; "Makefile"; "notes."; ".gp5" ]
;;

let test_attachments_field_omitted_when_empty () =
  Alcotest.(check bool) "no staged uploads, no field" true
    (board_outbound_attachments_field [] = None)
;;

let test_attachments_field_carries_kind_sha256_name () =
  check_option "staged uploads become the attachments array"
    (Some
       ( "attachments"
       , `List
           [ `Assoc
               [ "kind", `String "score"
               ; "sha256", `String sha256
               ; "name", `String "riff.gp5"
               ]
           ; `Assoc
               [ "kind", `String "midi"
               ; "sha256", `String (String.make 64 'b')
               ; "name", `String "take1.mid"
               ]
           ] ))
    (board_outbound_attachments_field
       [ { oa_kind = Uk_score; oa_sha256 = sha256; oa_name = "riff.gp5" }
       ; { oa_kind = Uk_midi
         ; oa_sha256 = String.make 64 'b'
         ; oa_name = "take1.mid"
         }
       ])
;;

(* The send path: each staged file is read and uploaded in staging order and
   becomes one entry of the post, and the first refusal stops the rest --
   the caller sends no post on an [Error]. The upload itself is passed in, so
   these run the sequencing without a server. *)
module Upload = Masc_tui_board_upload

let with_temp_files contents run =
  let paths =
    List.map
      (fun bytes ->
        let path = Filename.temp_file "board-attach" ".bin" in
        Out_channel.with_open_bin path (fun channel ->
          Out_channel.output_string channel bytes);
        path)
      contents
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) paths)
    (fun () -> run paths)
;;

let staged path =
  { sa_path = path; sa_name = Filename.basename path; sa_kind = Uk_file }
;;

let read = Upload.read_file ~max_bytes:Upload.max_attachment_bytes

(* A stand-in upload that records what it was sent and answers each body
   with an address built from the body's first letter. *)
let recording_upload ?(refuse = fun _ -> false) () =
  let sent = ref [] in
  let upload ~bytes =
    sent := bytes :: !sent;
    if refuse bytes then Error "413 too large" else Ok (String.make 64 bytes.[0])
  in
  upload, fun () -> List.rev !sent
;;

let test_staged_files_upload_in_order () =
  with_temp_files [ "a-first"; "b-second" ] (fun paths ->
    let upload, sent = recording_upload () in
    let result = Upload.upload_staged ~read ~upload (List.map staged paths) in
    Alcotest.(check (list string)) "each file's bytes, in staging order"
      [ "a-first"; "b-second" ] (sent ());
    check_option "each address becomes an entry naming its file"
      (Ok
         (List.map2
            (fun path digit ->
              { oa_kind = Uk_file
              ; oa_sha256 = String.make 64 digit
              ; oa_name = Filename.basename path
              })
            paths [ 'a'; 'b' ]))
      result)
;;

let test_a_refused_upload_stops_the_rest () =
  with_temp_files [ "a-first"; "b-second"; "c-third" ] (fun paths ->
    let upload, sent =
      recording_upload ~refuse:(String.equal "b-second") ()
    in
    let result = Upload.upload_staged ~read ~upload (List.map staged paths) in
    Alcotest.(check bool) "the send is refused" true (Result.is_error result);
    Alcotest.(check (list string)) "nothing after the refusal is uploaded"
      [ "a-first"; "b-second" ] (sent ()))
;;

let test_a_file_over_the_limit_is_not_uploaded () =
  with_temp_files [ "four" ] (fun paths ->
    let upload, sent = recording_upload () in
    let result =
      Upload.upload_staged ~read:(Upload.read_file ~max_bytes:3) ~upload
        (List.map staged paths)
    in
    Alcotest.(check bool) "the send is refused" true (Result.is_error result);
    Alcotest.(check (list string)) "no upload was attempted" [] (sent ()))
;;

(* At send time the limit is a bound on what is read, not a size looked up
   first: the read itself stops one byte past it and refuses the file. *)
let test_the_read_stops_at_the_limit () =
  with_temp_files [ "0123456789" ] (fun paths ->
    let path = List.hd paths in
    Alcotest.(check bool) "a file within the limit reads whole" true
      (Upload.read_file ~max_bytes:10 path = Ok "0123456789");
    Alcotest.(check bool) "one byte over is refused" true
      (Result.is_error (Upload.read_file ~max_bytes:9 path)))
;;

let test_what_can_be_attached () =
  let attachable = Upload.attachable ~max_bytes:Upload.max_attachment_bytes in
  with_temp_files [ "x"; "" ] (fun paths ->
    let file = List.nth paths 0 and empty = List.nth paths 1 in
    let link = file ^ ".link" in
    Unix.symlink file link;
    Fun.protect
      ~finally:(fun () -> try Sys.remove link with Sys_error _ -> ())
      (fun () ->
        Alcotest.(check bool) "a regular file" true (Result.is_ok (attachable file));
        Alcotest.(check bool) "a link to that file" true
          (Result.is_error (attachable link));
        Alcotest.(check bool) "a link is not read either" true
          (Result.is_error (Upload.read_file ~max_bytes:10 link));
        Alcotest.(check bool) "an empty file" true
          (Result.is_error (attachable empty));
        Alcotest.(check bool) "a directory" true
          (Result.is_error (attachable (Filename.dirname file)));
        Alcotest.(check bool) "a path that is not there" true
          (Result.is_error (attachable (file ^ ".missing")));
        Alcotest.(check bool) "a device" true
          (Result.is_error (attachable "/dev/null"))))
;;

let test_an_upload_response_must_name_a_digest () =
  check_option "a response naming its address" (Ok sha256)
    (Upload.uploaded_sha256 (`Assoc [ "sha256", `String sha256; "bytes", `Int 4 ]));
  Alcotest.(check bool) "no digest" true
    (Result.is_error (Upload.uploaded_sha256 (`Assoc [ "bytes", `Int 4 ])));
  Alcotest.(check bool) "a digest that is not a sha256" true
    (Result.is_error (Upload.uploaded_sha256 (`Assoc [ "sha256", `String "abc" ])))
;;

(* What a finished send leaves staged. The files that went out with a new
   post are on the board; left staged they would ride the next post too. *)
let state_with staged_files =
  let state = create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  state.board_mode <- Board_compose;
  state.board_compose_attachments <- staged_files;
  Buffer.add_string state.board_draft "title";
  state
;;

let finish state ~reply_to ~sent_attachments result =
  Masc_tui_board_updates.new_post_done state ~reply_to ~sent_draft:"title"
    ~sent_attachments
    ~report:(fun _ _ -> ())
    ~refresh:(fun () -> ())
    ~refresh_detail:(fun _ -> ())
    result
;;

let staged_names state =
  List.map (fun file -> file.sa_name) state.board_compose_attachments
;;

let named name = { sa_path = "/tmp/" ^ name; sa_name = name; sa_kind = Uk_file }

let test_sent_files_leave_the_staged_list () =
  let first = named "first" and second = named "second" in
  let state = state_with [ first; second ] in
  (* [late] was staged while the send was out. *)
  let late = named "late" in
  state.board_compose_attachments <- state.board_compose_attachments @ [ late ];
  finish state ~reply_to:None ~sent_attachments:[ first; second ] (Ok "posted");
  Alcotest.(check (list string)) "only the file staged meanwhile is left"
    [ "late" ] (staged_names state)
;;

let test_a_refused_send_keeps_the_staged_files () =
  let first = named "first" in
  let state = state_with [ first ] in
  finish state ~reply_to:None ~sent_attachments:[ first ] (Error "refused");
  Alcotest.(check (list string)) "the files are still staged" [ "first" ]
    (staged_names state);
  Alcotest.(check bool) "the refusal is recorded" true
    (Option.is_some state.board_post_error)
;;

let test_a_comment_leaves_the_staged_files () =
  let state = state_with [ named "for-the-next-post" ] in
  state.board_compose_reply_to <- Some "p1";
  finish state ~reply_to:(Some "p1") ~sent_attachments:[] (Ok "commented");
  Alcotest.(check (list string)) "a comment carried none of them"
    [ "for-the-next-post" ] (staged_names state)
;;

(* The read pane numbers the attachments 1..9 for the open key; the index
   counts every entry, a broken one included, so the number on screen and
   the key resolve to the same entry. *)
let test_attachment_at_index_picks_the_nth () =
  let entries =
    decode
      (attachments
         (`List
           [ url_entry "audio" "https://example.com/a.mp3"
           ; `String "broken"
           ; artifact_entry ~name:"riff.gp5" "score" sha256
           ]))
  in
  let at nth = Masc_tui_board_attachments.attachment_at_index entries nth in
  (match at 1 with
   | Some (Ok { ba_kind = Ak_audio; _ }) -> ()
   | _ -> Alcotest.fail "index 1 is the audio");
  (match at 2 with
   | Some (Error _) -> ()
   | _ -> Alcotest.fail "index 2 is the broken entry, its reason carried");
  (match at 3 with
   | Some (Ok { ba_kind = Ak_score; _ }) -> ()
   | _ -> Alcotest.fail "index 3 is the score");
  Alcotest.(check bool) "index 0 is nothing" true (Option.is_none (at 0));
  Alcotest.(check bool) "past the end is nothing" true
    (Option.is_none (at 4))
;;

let test_attachment_at_index_empty () =
  Alcotest.(check bool) "an empty list has no nth" true
    (Option.is_none (Masc_tui_board_attachments.attachment_at_index [] 1))
;;

let () =
  Alcotest.run "tui_board_attachments"
    [ ( "decode"
      , [ Alcotest.test_case "meta.attachments decode" `Quick
            test_meta_attachments_decode
        ; Alcotest.test_case "unknown kind is carried" `Quick
            test_unknown_kind_is_carried
        ; Alcotest.test_case "malformed entry does not fail the rest" `Quick
            test_malformed_entry_does_not_fail_the_rest
        ; Alcotest.test_case "no meta means no attachments" `Quick
            test_no_meta_means_no_attachments
        ; Alcotest.test_case "non-list attachments is one broken entry" `Quick
            test_non_list_attachments_is_one_broken_entry
        ; Alcotest.test_case "only the handler's wrapper is an artifact" `Quick
            test_only_the_handlers_wrapper_is_an_artifact
        ; Alcotest.test_case "the nth index picks the nth entry" `Quick
            test_attachment_at_index_picks_the_nth
        ; Alcotest.test_case "an empty list has no nth" `Quick
            test_attachment_at_index_empty
        ] )
    ; ( "label"
      , [ Alcotest.test_case "the name and the size" `Quick
            test_label_carries_the_name_and_the_size
        ; Alcotest.test_case "the kinds are told apart" `Quick
            test_label_tells_the_kinds_apart
        ; Alcotest.test_case "an unknown kind is named" `Quick
            test_label_names_an_unknown_kind
        ; Alcotest.test_case "a broken entry says why" `Quick
            test_label_says_why_an_entry_broke
        ] )
    ; ( "stage"
      , [ Alcotest.test_case "a name decides the kind" `Quick
            test_a_name_decides_the_kind
        ; Alcotest.test_case "an uppercase extension decides the same" `Quick
            test_an_uppercase_extension_decides_the_same
        ; Alcotest.test_case "an unknown name is a plain file" `Quick
            test_an_unknown_name_is_a_plain_file
        ; Alcotest.test_case "what can be attached" `Quick
            test_what_can_be_attached
        ] )
    ; ( "payload"
      , [ Alcotest.test_case "empty omits the field" `Quick
            test_attachments_field_omitted_when_empty
        ; Alcotest.test_case "entries carry kind, sha256, name" `Quick
            test_attachments_field_carries_kind_sha256_name
        ] )
    ; ( "send"
      , [ Alcotest.test_case "staged files upload in order" `Quick
            test_staged_files_upload_in_order
        ; Alcotest.test_case "a refused upload stops the rest" `Quick
            test_a_refused_upload_stops_the_rest
        ; Alcotest.test_case "a file over the limit is not uploaded" `Quick
            test_a_file_over_the_limit_is_not_uploaded
        ; Alcotest.test_case "the read stops at the limit" `Quick
            test_the_read_stops_at_the_limit
        ; Alcotest.test_case "an upload response must name a digest" `Quick
            test_an_upload_response_must_name_a_digest
        ] )
    ; ( "after the send"
      , [ Alcotest.test_case "sent files leave the staged list" `Quick
            test_sent_files_leave_the_staged_list
        ; Alcotest.test_case "a refused send keeps the staged files" `Quick
            test_a_refused_send_keeps_the_staged_files
        ; Alcotest.test_case "a comment leaves the staged files" `Quick
            test_a_comment_leaves_the_staged_files
        ] )
    ]
