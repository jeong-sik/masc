(* keeper_music_render reads its arguments into a request, runs masc-alphatex
   on it, and stores every file it writes as the Keeper's attachment.

   A shell script stands in for masc-alphatex. It records the command line
   and the source it was given, copies fixture files to the paths named after
   each export flag, and ends as the case asks. So the test pins the command
   line, the result and the failure classes without Node or alphaTab. *)

open Alcotest
module MR = Masc.Keeper_music_render

(* Headers the attachment store sniffs by their magic bytes. *)
let tiny_png =
  String.concat ""
    [ "\x89PNG\r\n\x1a\n"; "\x00\x00\x00\x0d"; "IHDR"; "\x00\x00\x00\x02"
    ; "\x00\x00\x00\x01"; "\x08\x06\x00\x00\x00"; "\x72\xb6\x0d\x24"
    ]

let tiny_midi = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60"
let tiny_wav = "RIFF\x24\x00\x00\x00WAVEfmt "

let request json = MR.request_of_args (Yojson.Safe.from_string json)

let output_names json =
  match request json with
  | Ok (request : MR.request) -> List.map MR.output_name request.outputs
  | Error reason -> fail reason

let test_arguments () =
  check (list string) "score and midi by default" [ "score"; "midi" ]
    (output_names {|{"source":":4 3.6"}|});
  check (list string) "listed in score, midi, audio order" [ "score"; "midi"; "audio" ]
    (output_names {|{"source":":4 3.6","outputs":["audio","midi","score"]}|});
  let refused label json = check bool label true (Result.is_error (request json)) in
  refused "no source" {|{}|};
  refused "a blank source" {|{"source":"  \n"}|};
  refused "a source that is not a string" {|{"source":3}|};
  refused "an empty outputs list" {|{"source":"x","outputs":[]}|};
  refused "an unknown output" {|{"source":"x","outputs":["pdf"]}|};
  refused "a repeated output" {|{"source":"x","outputs":["midi","midi"]}|};
  refused "an output that is not a string" {|{"source":"x","outputs":[1]}|};
  refused "outputs that is not an array" {|{"source":"x","outputs":"score"}|};
  refused "arguments that are not an object" {|[]|};
  let source_of_length n = MR.request_of_args (`Assoc [ ("source", `String (String.make n 'a')) ]) in
  check bool "a source at the limit" true (Result.is_ok (source_of_length MR.source_max_bytes));
  check bool "a source over the limit" true
    (Result.is_error (source_of_length (MR.source_max_bytes + 1)))

type ending =
  | Summary
  | Source_error
  | Crash

let write_file ?(perm = 0o644) path contents =
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] perm path
    (fun channel -> output_string channel contents)

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* The stand-in records into [dir] and copies the fixtures [dir] holds. *)
let fake_alphatex ~dir ending =
  let quoted name = Filename.quote (Filename.concat dir name) in
  let tail =
    match ending with
    | Summary ->
      {|printf '%s\n' '{"engine":"alphaTab","version":"test","title":"Riff","tracks":1,"bars":2}'|}
    | Source_error -> "echo 'alphaTex: Error AT202(1,8)->(1,9): Unexpected token' >&2; exit 65"
    | Crash -> "echo 'node crashed' >&2; exit 1"
  in
  let script = Filename.concat dir "masc-alphatex" in
  write_file ~perm:0o755 script
    (String.concat "\n"
       [ "#!/bin/sh"
       ; "printf '%s\\n' \"$@\" > " ^ quoted "argv"
       ; "cat \"$1\" > " ^ quoted "source"
       ; "shift"
       ; "while [ $# -gt 0 ]; do"
       ; "  case \"$1\" in"
       ; "    --render) fixture=" ^ quoted "score.png" ^ " ;;"
       ; "    --export-midi) fixture=" ^ quoted "score.mid" ^ " ;;"
       ; "    --audio) fixture=" ^ quoted "score.wav" ^ " ;;"
       ; "  esac"
       ; "  if [ -f \"$fixture\" ]; then cp \"$fixture\" \"$2\"; fi"
       ; "  shift 2"
       ; "done"
       ; tail
       ; ""
       ]);
  script

let with_render_env f =
  let base_path = Filename.temp_dir "music-render-base-" "" in
  let fixtures = Filename.temp_dir "music-render-fixtures-" "" in
  Eio_main.run @@ fun env ->
  Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env) ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect
    ~finally:(fun () ->
      Process_eio.reset_for_testing ();
      Fs_compat.remove_tree base_path;
      Fs_compat.remove_tree fixtures)
    (fun () -> f ~base_path ~fixtures)

let run_with ~base_path ~fixtures ending json =
  let executable = fake_alphatex ~dir:fixtures ending in
  match request json with
  | Ok request -> MR.For_testing.run ~executable ~base_path ~keeper_name:"alice" request
  | Error reason -> fail reason

let failure_of (result : Masc.Keeper_tool_execution.t) =
  match result.disposition with
  | Tool_result.Failed class_ -> Some (class_, result.failure_effect_disposition)
  | Tool_result.Completed () | Tool_result.Deferred () -> None

let test_rendered_files_are_stored () =
  with_render_env @@ fun ~base_path ~fixtures ->
  write_file (Filename.concat fixtures "score.png") tiny_png;
  write_file (Filename.concat fixtures "score.mid") tiny_midi;
  write_file (Filename.concat fixtures "score.wav") tiny_wav;
  let source = "\\title \"Riff\"\n.\n:4 3.6 5.6 7.6 5.6\n" in
  let result =
    run_with ~base_path ~fixtures Summary
      (Yojson.Safe.to_string
         (`Assoc [ ("source", `String source); ("outputs", `List [ `String "audio"; `String "score"; `String "midi" ]) ]))
  in
  (match failure_of result with
   | None -> ()
   | Some _ -> failf "the render failed: %s" result.raw_output);
  check string "masc-alphatex read the source as given" source
    (read_file (Filename.concat fixtures "source"));
  (match String.split_on_char '\n' (String.trim (read_file (Filename.concat fixtures "argv"))) with
   | _source_path :: flags_and_paths ->
     check (list string) "one flag per output, in score, midi, audio order"
       [ "--render"; "score.png"; "--export-midi"; "score.mid"; "--audio"; "score.wav" ]
       (List.mapi (fun index arg -> if index mod 2 = 0 then arg else Filename.basename arg)
          flags_and_paths)
   | [] -> fail "masc-alphatex was given no arguments");
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string result.raw_output in
  check string "title" "Riff" (json |> member "title" |> to_string);
  check int "bars" 2 (json |> member "bars" |> to_int);
  let store = Attachment_store.create ~base_path in
  let files = json |> member "files" |> to_list in
  check (list string) "each output stored, in order" [ "score"; "midi"; "audio" ]
    (List.map (fun file -> file |> member "output" |> to_string) files);
  List.iter2
    (fun file (mime, bytes) ->
       let id = file |> member "attachment_id" |> to_string in
       match Attachment_store.get_meta store ~id with
       | Ok (Some (meta : Attachment_store.meta)) ->
         check string "media type" mime meta.mime_type;
         check int "bytes" (String.length bytes) meta.bytes;
         check bool "alice's ephemeral file" true
           (meta.retention = Attachment_store.Ephemeral { keeper = "alice" })
       | Ok None -> failf "%s is not in the attachment store" id
       | Error error -> fail (Attachment_store.get_error_to_string error))
    files
    [ ("image/png", tiny_png); ("audio/midi", tiny_midi); ("audio/wav", tiny_wav) ]

let test_failures_are_classified () =
  with_render_env @@ fun ~base_path ~fixtures ->
  write_file (Filename.concat fixtures "score.png") tiny_png;
  let source = {|{"source":":4 3.6 }}}","outputs":["score"]}|} in
  (match failure_of (run_with ~base_path ~fixtures Source_error source) with
   | Some (Tool_result.Policy_rejection, Tool_result.Proven_pre_effect) -> ()
   | Some _ | None -> fail "alphaTex that does not parse is a Policy_rejection before any effect");
  (match failure_of (run_with ~base_path ~fixtures Crash source) with
   | Some (Tool_result.Runtime_failure, Tool_result.Proven_pre_effect) -> ()
   | Some _ | None -> fail "a crashed render is a Runtime_failure before any effect");
  (* Exit 0 without the MIDI file: nothing to send, so the call fails. *)
  match
    failure_of
      (run_with ~base_path ~fixtures Summary {|{"source":":4 3.6","outputs":["score","midi"]}|})
  with
  | Some (Tool_result.Runtime_failure, _) -> ()
  | Some _ | None -> fail "a missing output file fails the call"

(* A sparse file: the size the store would see, without writing the bytes. *)
let write_sized path ~header bytes =
  write_file path header;
  Unix.truncate path bytes

let contains ~sub text =
  let sub_length = String.length sub in
  let rec from index =
    index + sub_length <= String.length text
    && (String.equal (String.sub text index sub_length) sub || from (index + 1))
  in
  from 0

let stored_for_alice ~base_path =
  match Attachment_store.list_ephemeral (Attachment_store.create ~base_path) ~keeper:"alice" with
  | Ok metas -> List.length metas
  | Error detail -> fail detail

(* Without the size check the store takes the PNG, then refuses the WAV or
   evicts the PNG for it: a Runtime_failure with a file left behind. *)
let test_files_too_large_to_store_are_refused_before_storing () =
  with_render_env @@ fun ~base_path ~fixtures ->
  write_file (Filename.concat fixtures "score.png") tiny_png;
  let refused label ~wav_bytes ~names =
    write_sized (Filename.concat fixtures "score.wav") ~header:tiny_wav wav_bytes;
    let result =
      run_with ~base_path ~fixtures Summary {|{"source":":4 3.6","outputs":["score","audio"]}|}
    in
    (match failure_of result with
     | Some (Tool_result.Policy_rejection, Tool_result.Proven_pre_effect) -> ()
     | Some _ | None ->
       failf "%s: not a Policy_rejection before any effect: %s" label result.raw_output);
    check bool (label ^ ": the error says " ^ names) true (contains ~sub:names result.raw_output);
    check int (label ^ ": nothing stored") 0 (stored_for_alice ~base_path)
  in
  refused "one file over the limit" ~wav_bytes:(Attachment_store.max_bytes () + 1)
    ~names:"the audio file is";
  let wav_bytes =
    Attachment_store.default_ephemeral_max_bytes - String.length tiny_png + 1
  in
  check bool "each file of the next case fits one attachment" true
    (wav_bytes <= Attachment_store.max_bytes ());
  refused "files over the budget together" ~wav_bytes ~names:"the files total"

let test_absent_executable_is_a_missing_dependency () =
  let saved = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" (Filename.get_temp_dir_name ());
  let result =
    Fun.protect
      ~finally:(fun () -> Option.iter (Unix.putenv "PATH") saved)
      (fun () ->
         MR.handle ~base_path:(Filename.get_temp_dir_name ()) ~keeper_name:"alice"
           ~args:(Yojson.Safe.from_string {|{"source":":4 3.6"}|}))
  in
  match failure_of result with
  | Some (Tool_result.Dependency_unavailable, Tool_result.Proven_pre_effect) -> ()
  | Some _ | None -> fail "masc-alphatex off PATH is Dependency_unavailable"

let () =
  run "keeper_music_render"
    [ ("arguments", [ test_case "read and refused" `Quick test_arguments ])
    ; ( "render"
      , [ test_case "rendered files are stored" `Quick test_rendered_files_are_stored
        ; test_case "failures are classified" `Quick test_failures_are_classified
        ; test_case "files too large to store" `Quick
            test_files_too_large_to_store_are_refused_before_storing
        ; test_case "absent executable" `Quick test_absent_executable_is_a_missing_dependency
        ] )
    ]
