(* task-2187 (H5) review P2: stored media readings had no retention. The sweep
   in lib/keeper/keeper_media_reading_maintenance.mli keeps a reading while a
   durable record still carries its attachment and deletes it only after two
   complete sweeps found it unreferenced. *)

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

let record_name letter = Printf.sprintf "audio-%s-audio_wav.json" (String.make 64 letter)

let store_record ~dir ?probe letter =
  let fields =
    ("status", `String "read")
    :: (match probe with
        | Some probe -> [ "source_probe", `String probe ]
        | None -> [])
  in
  write ~dir ~rel:(record_name letter) (Yojson.Safe.to_string (`Assoc fields))
;;

let mention ~masc_dir ~rel probe =
  write ~dir:masc_dir ~rel (Printf.sprintf {|{"data":"QUJD%sQUJD"}|} probe)
;;

let sweep ~masc_dir ~dir = Sweep.run ~masc_dir ~dir |> Result.map_error Sweep.error_to_string
let exists ~dir letter = Sys.file_exists (Filename.concat dir (record_name letter))
let probe_a = String.make 64 'P'
let probe_b = String.make 64 'Q'

let report_of = function
  | Ok (report : Sweep.report) -> report
  | Error detail -> fail detail
;;

let test_unreferenced_reading_is_deleted_on_the_second_sweep () =
  let masc_dir = fresh_dir () in
  let dir = fresh_dir () in
  store_record ~dir ~probe:probe_a 'a';
  store_record ~dir ~probe:probe_b 'b';
  mention ~masc_dir ~rel:"keepers/k/checkpoint.json" probe_a;
  let first = report_of (sweep ~masc_dir ~dir) in
  check int "one live reading" 1 first.live;
  check int "one candidate recorded" 1 first.candidates_recorded;
  check int "the first sweep deletes nothing" 0 first.deleted;
  check bool "the candidate is still there after one sweep" true (exists ~dir 'b');
  let second = report_of (sweep ~masc_dir ~dir) in
  check int "the second sweep deletes the candidate" 1 second.deleted;
  check bool "the unreferenced reading is gone" false (exists ~dir 'b');
  check bool "the referenced reading is kept" true (exists ~dir 'a')
;;

let test_reading_referenced_again_is_kept () =
  let masc_dir = fresh_dir () in
  let dir = fresh_dir () in
  store_record ~dir ~probe:probe_a 'a';
  let _ = report_of (sweep ~masc_dir ~dir) in
  mention ~masc_dir ~rel:"keeper_chat/k/turn.jsonl" probe_a;
  let second = report_of (sweep ~masc_dir ~dir) in
  check int "nothing deleted" 0 second.deleted;
  check bool "a reading referenced again before the second sweep is kept" true
    (exists ~dir 'a')
;;

let test_record_without_probe_is_a_candidate () =
  let masc_dir = fresh_dir () in
  let dir = fresh_dir () in
  store_record ~dir 'c';
  write ~dir ~rel:(record_name 'd') "not json";
  let first = report_of (sweep ~masc_dir ~dir) in
  check int "both records count as unprobed" 2 first.unprobed;
  check int "both are candidates" 2 first.candidates_recorded;
  let second = report_of (sweep ~masc_dir ~dir) in
  check int "both are deleted on the second sweep" 2 second.deleted
;;

let test_symlink_stops_the_sweep () =
  let masc_dir = fresh_dir () in
  let dir = fresh_dir () in
  store_record ~dir ~probe:probe_b 'b';
  let _ = report_of (sweep ~masc_dir ~dir) in
  let target = Filename.concat (fresh_dir ()) "elsewhere.json" in
  write ~dir:(Filename.dirname target) ~rel:(Filename.basename target) "{}";
  Unix.symlink target (Filename.concat dir (record_name 'e'));
  write ~dir ~rel:"notes.txt" "not a record";
  (match sweep ~masc_dir ~dir with
   | Ok _ -> fail "a symlinked record must stop the sweep"
   | Error _ -> ());
  check bool "the earlier candidate survives the stopped sweep" true (exists ~dir 'b');
  check bool "a non-record entry is left alone" true
    (Sys.file_exists (Filename.concat dir "notes.txt"))
;;

(* End to end: a reading written by the projection is kept while the durable
   checkpoint still carries the attachment's base64, and removed after two
   sweeps once nothing does. *)
let test_projected_reading_follows_its_attachment () =
  let base_path = fresh_dir () in
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  let payload = String.init 400 (fun index -> Char.chr (Char.code 'A' + (index mod 26))) in
  let data = Base64.encode_string payload in
  let block =
    Agent_core.Types.audio_block
      ~media_type:"audio/wav"
      ~data
      ~source_type:Agent_core.Types.Base64
      ()
  in
  let _ =
    Reading.project_blocks
      ~base_path
      ~keeper_name:"sweep-keeper"
      ~needs_projection:(fun _ -> true)
      ~deadline:(Monotonic_deadline.after ~seconds:30.)
      ~read:(fun ~deadline:_ ~kind:_ ~media_type:_ ~bytes:_ -> Ok "the reading")
      [ block ]
  in
  let checkpoint = "keepers/sweep-keeper/checkpoint.json" in
  write ~dir:masc_dir ~rel:checkpoint (Printf.sprintf {|{"type":"audio","data":"%s"}|} data);
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
  let _ = report_of (sweep ~masc_dir ~dir) in
  let kept = report_of (sweep ~masc_dir ~dir) in
  check int "the reading is live while the checkpoint carries the attachment" 1 kept.live;
  check int "nothing deleted" 0 kept.deleted;
  Sys.remove (Filename.concat masc_dir checkpoint);
  let _ = report_of (sweep ~masc_dir ~dir) in
  let gone = report_of (sweep ~masc_dir ~dir) in
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
            "record without probe is a candidate"
            `Quick
            test_record_without_probe_is_a_candidate
        ; test_case "symlink stops the sweep" `Quick test_symlink_stops_the_sweep
        ; test_case
            "projected reading follows its attachment"
            `Quick
            test_projected_reading_follows_its_attachment
        ] )
    ]
;;
