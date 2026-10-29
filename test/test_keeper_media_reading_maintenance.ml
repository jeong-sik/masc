(* task-2187 (H5) review P2: stored media readings had no retention. The sweep
   in lib/keeper/keeper_media_reading_maintenance.mli keeps a reading while a
   durable consumer still holds its attachment's Stored reference and deletes
   it only after two complete sweeps found it unreferenced. *)

open Alcotest
module Reading = Masc.Keeper_media_reading
module Sweep = Masc.Keeper_media_reading_maintenance

let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    Sys.mkdir dir 0o755)
;;

let fresh_dir () =
  let base = Filename.temp_file "masc-media-reading-maintenance-test-" "" in
  Sys.remove base;
  mkdir_p base;
  base
;;

let write ~dir ~rel content =
  let path = Filename.concat dir rel in
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel content)
;;

let attachment raw = Agent_core.History.stored_of_raw raw
let record_name (stored : Agent_core.History.stored) =
  Printf.sprintf "audio-%s-audio_wav.json" stored.sha256

let store_record ~dir stored =
  write ~dir ~rel:(record_name stored)
    (Yojson.Safe.to_string (`Assoc [ "status", `String "read" ]))
;;

(* A durable consumer that holds [stored] as history media. *)
let hold ~base_path ~rel stored =
  let block =
    Agent_core.Types.audio_block ~media_type:"audio/wav" ~source:(Agent_core.Types.Stored stored)
  in
  write ~dir:(Common.masc_dir_from_base_path ~base_path) ~rel
    (Yojson.Safe.to_string (Agent_core.History.content_block_to_json block))
;;

(* One pass: one scan of the durable consumers, then the keeper directory. *)
let sweep ~base_path ~dir =
  match
    Tool_blob_maintenance.live_references
      ~board_posts_file:Masc_board_handlers.Board_paths.posts_file ~base_path
  with
  | Error error -> Error (Tool_blob_maintenance.error_to_string error)
  | Ok live -> Sweep.run ~live ~dir |> Result.map_error Sweep.error_to_string
;;

let exists ~dir stored = Sys.file_exists (Filename.concat dir (record_name stored))
let attachment_a = attachment "first attachment"
let attachment_b = attachment "second attachment"

let report_of = function
  | Ok (report : Sweep.report) -> report
  | Error detail -> fail detail
;;

let test_unreferenced_reading_is_deleted_on_the_second_sweep () =
  let base_path = fresh_dir () in
  let dir = fresh_dir () in
  store_record ~dir attachment_a;
  store_record ~dir attachment_b;
  hold ~base_path ~rel:"keepers/k/checkpoint.json" attachment_a;
  let first = report_of (sweep ~base_path ~dir) in
  check int "one live reading" 1 first.live;
  check int "one candidate recorded" 1 first.candidates_recorded;
  check int "the first sweep deletes nothing" 0 first.deleted;
  check bool "the candidate is still there after one sweep" true (exists ~dir attachment_b);
  let second = report_of (sweep ~base_path ~dir) in
  check int "the second sweep deletes the candidate" 1 second.deleted;
  check bool "the unreferenced reading is gone" false (exists ~dir attachment_b);
  check bool "the referenced reading is kept" true (exists ~dir attachment_a)
;;

let test_reading_referenced_again_is_kept () =
  let base_path = fresh_dir () in
  let dir = fresh_dir () in
  store_record ~dir attachment_a;
  let _ = report_of (sweep ~base_path ~dir) in
  hold ~base_path ~rel:"keeper_chat/k/turn.jsonl" attachment_a;
  let second = report_of (sweep ~base_path ~dir) in
  check int "nothing deleted" 0 second.deleted;
  check bool "a reading referenced again before the second sweep is kept" true
    (exists ~dir attachment_a)
;;

(* The live set keeps history media apart from tool artifacts: a tool output
   of the same bytes is not the attachment the reading was made from. *)
let test_a_tool_artifact_of_the_same_bytes_does_not_keep_a_reading () =
  let base_path = fresh_dir () in
  let dir = fresh_dir () in
  let raw = "bytes a tool also returned" in
  let stored = attachment raw in
  store_record ~dir stored;
  let artifact =
    Tool_blob_store.put_durable (Tool_blob_store.create ~base_path) ~bytes:raw ~mime:"audio/wav"
  in
  write ~dir:(Common.masc_dir_from_base_path ~base_path) ~rel:"tool_calls/k/call.json"
    (Yojson.Safe.to_string
       (`Assoc [ "artifact", Tool_output.normalized_artifact_ref_to_json artifact ]));
  check string "the artifact names the same digest" stored.sha256 artifact.Tool_output.sha256;
  let first = report_of (sweep ~base_path ~dir) in
  check int "the reading is not live" 0 first.live;
  let second = report_of (sweep ~base_path ~dir) in
  check int "the reading is deleted on the second sweep" 1 second.deleted
;;

let test_symlink_stops_the_sweep () =
  let base_path = fresh_dir () in
  let dir = fresh_dir () in
  store_record ~dir attachment_b;
  let _ = report_of (sweep ~base_path ~dir) in
  let target = Filename.concat (fresh_dir ()) "elsewhere.json" in
  write ~dir:(Filename.dirname target) ~rel:(Filename.basename target) "{}";
  Unix.symlink target (Filename.concat dir (record_name attachment_a));
  write ~dir ~rel:"notes.txt" "not a record";
  (match sweep ~base_path ~dir with
   | Ok _ -> fail "a symlinked record must stop the sweep"
   | Error _ -> ());
  check bool "the earlier candidate survives the stopped sweep" true (exists ~dir attachment_b);
  check bool "a non-record entry is left alone" true
    (Sys.file_exists (Filename.concat dir "notes.txt"))
;;

(* End to end: a reading written by the projection is kept while the durable
   checkpoint still holds the attachment's reference, and removed after two
   sweeps once nothing does. *)
let test_projected_reading_follows_its_attachment () =
  let base_path = fresh_dir () in
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  let payload = String.init 400 (fun index -> Char.chr (Char.code 'A' + (index mod 26))) in
  let media_store = Agent_core.History.Memory_store.create () in
  let stored =
    match media_store.put ~media_type:"audio/wav" ~raw:payload with
    | Ok stored -> stored
    | Error error -> fail (Agent_core.Error.to_string (Agent_core.Error.Media error))
  in
  let block =
    Agent_core.Types.audio_block
      ~media_type:"audio/wav"
      ~source:(Agent_core.Types.Stored stored)
  in
  let _ =
    Reading.project_blocks ~media_store
      ~base_path
      ~keeper_name:"sweep-keeper"
      ~needs_projection:(fun _ -> true)
      ~deadline:(Monotonic_deadline.after ~seconds:30.)
      ~read:(fun ~deadline:_ ~kind:_ ~media_type:_ ~bytes:_ -> Ok "the reading")
      [ block ]
  in
  let checkpoint = "keepers/sweep-keeper/checkpoint.json" in
  hold ~base_path ~rel:checkpoint stored;
  let dir =
    match Sweep.keeper_dirs ~masc_dir with
    | Ok [ dir ] -> dir
    | Ok dirs -> failf "expected one keeper directory, got %d" (List.length dirs)
    | Error error -> fail (Sweep.error_to_string error)
  in
  let records () =
    Array.to_list (Sys.readdir dir) |> List.filter Sweep.is_record_name
  in
  check int "the projection wrote one record the sweep recognises" 1 (List.length (records ()));
  let _ = report_of (sweep ~base_path ~dir) in
  let kept = report_of (sweep ~base_path ~dir) in
  check int "the reading is live while the checkpoint holds the attachment" 1 kept.live;
  check int "nothing deleted" 0 kept.deleted;
  Sys.remove (Filename.concat masc_dir checkpoint);
  let _ = report_of (sweep ~base_path ~dir) in
  let gone = report_of (sweep ~base_path ~dir) in
  check int "the reading is deleted after two sweeps without the attachment" 1 gone.deleted;
  check int "no record left" 0 (List.length (records ()))
;;

let () =
  run
    "keeper_media_reading_maintenance"
    [ ( "sweep"
      , [ test_case
            "unreferenced reading is deleted on the second sweep"
            `Quick
            test_unreferenced_reading_is_deleted_on_the_second_sweep
        ; test_case
            "reading referenced again is kept"
            `Quick
            test_reading_referenced_again_is_kept
        ; test_case
            "a tool artifact of the same bytes does not keep a reading"
            `Quick
            test_a_tool_artifact_of_the_same_bytes_does_not_keep_a_reading
        ; test_case "symlink stops the sweep" `Quick test_symlink_stops_the_sweep
        ; test_case
            "projected reading follows its attachment"
            `Quick
            test_projected_reading_follows_its_attachment
        ] )
    ]
;;
