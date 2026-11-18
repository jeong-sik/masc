(* task-2187 (H5) review P2: stored media readings had no retention. The sweep
   in lib/keeper/keeper_media_reading_maintenance.mli keeps a reading while a
   durable consumer still holds its attachment's Stored reference and deletes
   it only after two complete sweeps found it unreferenced. *)

open Alcotest
module Reading = Masc.Keeper_media_reading
module Sweep = Masc.Keeper_media_reading_maintenance

let declared_reader ~id ~revision =
  match Reading.reader_identity ~id ~revision with
  | Ok identity -> identity
  | Error Reading.Empty_id -> fail "fixture reader id must be nonempty"
  | Error Reading.Empty_revision -> fail "fixture reader revision must be nonempty"

let fixture_identity = declared_reader ~id:"maintenance-fixture" ~revision:"fixture-v1"

let resolve_reader ?(identity = fixture_identity) read ~kind:_ ~media_type:_ =
  Ok (Reading.reader ~identity ~read)

let check_reading label identity text = function
  | Reading.Read (reading : Reading.reading) ->
    check string (label ^ ": reader id") identity.Reading.id reading.reader.id;
    check string (label ^ ": reader revision") identity.revision reading.reader.revision;
    check string (label ^ ": text") text reading.text
  | Reading.Unavailable error -> fail (Reading.failure_to_string error)
  | Reading.Pending _ -> fail (label ^ ": unexpected pending original")

let check_failure label expected = function
  | Reading.Read _ | Reading.Pending _ -> fail (label ^ ": expected a typed failure")
  | Reading.Unavailable actual ->
    check (testable (fun fmt value -> Format.pp_print_string fmt (Reading.failure_to_string value)) (=))
      label expected actual

let pdf_timeout =
  Reading.Pdf_failed
    (Masc.Verification_pdf_inspection.Poppler_budget_spent
       { program = "pdftotext"; budget_sec = 60. })

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
      ~scope:Server_tool_blob_scope.scope ~base_path
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
      ~resolve:(resolve_reader (fun ~bytes:_ -> Ok "the reading"))
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

let with_stored_reading f =
  let base_path = fresh_dir () in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let media_store = Agent_core.History.Memory_store.create () in
    let stored = match media_store.put ~media_type:"application/pdf" ~raw:"stored PDF bytes" with
      | Ok stored -> stored
      | Error error -> fail (Agent_core.Error.to_string (Agent_core.Error.Media error)) in
    f base_path media_store stored)
;;

let project_document projector stored =
  let blocks, _ = Reading.project projector ~needs_projection:(fun _ -> true)
    [ Agent_core.Types.document_block ~media_type:"application/pdf"
        ~source:(Agent_core.Types.Stored stored) ] in
  match blocks with
  | [ Agent_core.Types.Text text ] -> text
  | _ -> fail "history must carry the attachment's reading as text"
;;

let test_raw_and_history_share_one_reading ~raw_first () =
  with_stored_reading @@ fun _base_path media_store stored ->
  let reads = ref 0 in
  let raw = "  exact extracted fact\n" in
  let projector = Reading.projector ~media_store ~keeper_name:"shared-reader"
    ~resolve:(resolve_reader (fun ~bytes:_ -> incr reads; Ok raw)) () in
  let read_raw () = Reading.read_stored projector ~kind:Reading.Document
    ~media_type:"application/pdf" stored in
  let raw_result, history =
    if raw_first then
      let result = read_raw () in result, project_document projector stored
    else
      let history = project_document projector stored in read_raw (), history in
  check_reading "raw consumer receives selected provenance and no history wrapper"
    fixture_identity raw raw_result;
  check bool "history adds its own source attribution" true
    (String_util.contains_substring history "conversation history");
  check bool "history names the same selected reader as the raw result" true
    (String_util.contains_substring history fixture_identity.id
     && String_util.contains_substring history fixture_identity.revision);
  check bool "history preserves exact extracted bytes" true
    (String.ends_with ~suffix:raw history);
  check int "both consumers share one extraction" 1 !reads
;;

let test_raw_disk_cache_needs_no_reader () =
  with_stored_reading @@ fun base_path media_store stored ->
  let raw = "persisted raw reading" in
  let first = Reading.projector ~base_path ~media_store ~keeper_name:"shared-reader"
    ~resolve:(resolve_reader (fun ~bytes:_ -> Ok raw)) () in
  ignore (project_document first stored);
  let reopened = Reading.projector ~base_path ~media_store ~keeper_name:"shared-reader"
    ~resolve:(resolve_reader (fun ~bytes:_ -> fail "stored reading must not extract again")) () in
  check_reading "a new walk reuses the same reader's raw disk record" fixture_identity raw
    (Reading.read_stored reopened ~kind:Reading.Document ~media_type:"application/pdf" stored)
;;

let test_unavailable_raw_result_retries_only_in_a_new_walk () =
  List.iter (fun (answer, reason) ->
    with_stored_reading @@ fun base_path media_store stored ->
    let reads = ref 0 in
    let make read = Reading.projector ~base_path ~media_store ~keeper_name:"shared-reader"
      ~resolve:(resolve_reader read) () in
    let unavailable = make (fun ~bytes:_ ->
      incr reads; answer) in
    check_failure "raw failure retains selected reader and typed reason"
      (Reading.Reader_failed { reader = fixture_identity; reason })
      (Reading.read_stored unavailable ~kind:Reading.Document ~media_type:"application/pdf" stored);
    let history = project_document unavailable stored in
    check bool "history marks the same attachment unavailable" true
      (String_util.contains_substring history "status=unavailable");
    check int "history does not retry the unavailable reading in this walk" 1 !reads;
    let next = make (fun ~bytes:_ ->
      incr reads; Ok "reader recovered") in
    check_reading "unavailable is not a durable successful reading"
      fixture_identity "reader recovered"
      (Reading.read_stored next ~kind:Reading.Document ~media_type:"application/pdf" stored);
    check int "a new walk retries the reader" 2 !reads)
    [ Error pdf_timeout, pdf_timeout; Ok " \n", Reading.Empty_reading ]
;;

let test_later_attachment_is_read_after_earlier_result ~earlier_succeeded () =
  with_stored_reading @@ fun _base_path media_store stored ->
  let another = match media_store.put ~media_type:"application/pdf" ~raw:"later PDF bytes" with
    | Ok stored -> stored
    | Error error -> fail (Agent_core.Error.to_string (Agent_core.Error.Media error)) in
  let gets = ref 0 and reads = ref [] in
  let counted_store = { media_store with Agent_core.History.get = (fun reference ->
    incr gets; media_store.get reference) } in
  let earlier_result = if earlier_succeeded then Ok "earlier reading" else Error pdf_timeout in
  let projector = Reading.projector ~media_store:counted_store ~keeper_name:"shared-reader"
    ~resolve:(resolve_reader (fun ~bytes ->
      reads := bytes :: !reads;
      if String.equal bytes "stored PDF bytes" then earlier_result else Ok "later reading")) () in
  let check_earlier label result =
    if earlier_succeeded then check_reading label fixture_identity "earlier reading" result
    else check_failure label
      (Reading.Reader_failed { reader = fixture_identity; reason = pdf_timeout }) result in
  check_earlier "the first attachment keeps its own reader outcome"
    (Reading.read_stored projector ~kind:Reading.Document ~media_type:"application/pdf" stored);
  ignore (project_document projector stored);
  let later_history = project_document projector another in
  check bool "a later history request reads a newly arrived attachment" true
    (String.ends_with ~suffix:"later reading" later_history);
  check_reading "a retained consumer shares the later attachment's reading"
    fixture_identity "later reading"
    (Reading.read_stored projector ~kind:Reading.Document ~media_type:"application/pdf" another);
  check_earlier "the later result does not replace the first attachment's memo"
    (Reading.read_stored projector ~kind:Reading.Document ~media_type:"application/pdf" stored);
  check (list string) "each distinct original reaches its reader once"
    [ "stored PDF bytes"; "later PDF bytes" ] (List.rev !reads);
  check int "each distinct original is fetched once" 2 !gets
;;

let test_raw_cancellation_propagates_without_memoization () =
  with_stored_reading @@ fun _base_path media_store stored ->
  let reads = ref 0 in
  let cancelled = Eio.Cancel.Cancelled Exit in
  let projector = Reading.projector ~media_store ~keeper_name:"shared-reader"
    ~resolve:(resolve_reader (fun ~bytes:_ ->
      incr reads;
      if !reads = 1 then raise cancelled else Ok "resumed reading")) () in
  (match Reading.read_stored projector ~kind:Reading.Document ~media_type:"application/pdf" stored with
   | Reading.Read _ | Reading.Unavailable _ | Reading.Pending _ -> fail "reader cancellation must propagate"
   | exception (Eio.Cancel.Cancelled _ as observed) ->
     check bool "the original cancellation is preserved" true (observed == cancelled));
  let history = project_document projector stored in
  check bool "cancellation did not become an unavailable memo entry" true
    (String.ends_with ~suffix:"resumed reading" history);
  check int "the reader can resume after an unrecorded exception" 2 !reads
;;

let test_reader_identity_and_revision_own_the_cached_reading () =
  with_stored_reading @@ fun base_path media_store stored ->
  let reads = ref [] in
  let read_as identity text =
    let projector = Reading.projector ~base_path ~media_store ~keeper_name:"selected-reader"
      ~resolve:(resolve_reader ~identity (fun ~bytes ->
        reads := (identity, bytes) :: !reads; Ok text)) () in
    check_reading "each selected declaration owns its reading" identity text
      (Reading.read_stored projector ~kind:Reading.Document ~media_type:"application/pdf" stored)
  in
  let a = declared_reader ~id:"reader-a" ~revision:"1" in
  let b = declared_reader ~id:"reader-b" ~revision:"1" in
  let revised_b = declared_reader ~id:"reader-b" ~revision:"2" in
  read_as a "reader A interpretation";
  read_as b "reader B interpretation";
  read_as revised_b "revised reader B interpretation";
  check int "a new reader or revision must read the original again" 3 (List.length !reads);
  List.iter (fun (_, bytes) ->
    check string "each declaration receives the same original bytes" "stored PDF bytes" bytes) !reads;
  let restarted = Reading.projector ~base_path ~media_store ~keeper_name:"selected-reader"
    ~resolve:(resolve_reader ~identity:revised_b (fun ~bytes:_ ->
      fail "the same declaration must reuse its durable reading")) () in
  check_reading "the selected revision survives a restart" revised_b "revised reader B interpretation"
    (Reading.read_stored restarted ~kind:Reading.Document ~media_type:"application/pdf" stored)
;;

let test_unavailable_resolver_cannot_borrow_a_cached_reading () =
  with_stored_reading @@ fun base_path media_store stored ->
  let available = Reading.projector ~base_path ~media_store ~keeper_name:"selected-reader"
    ~resolve:(resolve_reader (fun ~bytes:_ -> Ok "earlier reader's private interpretation")) () in
  ignore (project_document available stored);
  let resolutions = ref 0 in
  let unavailable = Reading.projector ~base_path ~media_store ~keeper_name:"selected-reader"
    ~resolve:(fun ~kind:_ ~media_type:_ -> incr resolutions; Error Reading.No_matching_reader) () in
  check_failure "missing selection cannot authorize an old success"
    (Reading.Resolution_failed Reading.No_matching_reader)
    (Reading.read_stored unavailable ~kind:Reading.Document ~media_type:"application/pdf" stored);
  let history = project_document unavailable stored in
  check bool "history does not borrow the earlier reading" false
    (String_util.contains_substring history "earlier reader's private interpretation");
  check bool "history keeps the unresolved attachment explicit" true
    (String_util.contains_substring history "status=unavailable");
  check int "all consumers share the walk's unavailable selection" 1 !resolutions
;;

let test_a_walk_keeps_its_selected_reader_snapshot () =
  with_stored_reading @@ fun _base_path media_store stored ->
  let another = match media_store.put ~media_type:"application/pdf" ~raw:"later original" with
    | Ok stored -> stored
    | Error error -> fail (Agent_core.Error.to_string (Agent_core.Error.Media error)) in
  let a = declared_reader ~id:"reader-a" ~revision:"1" in
  let b = declared_reader ~id:"reader-b" ~revision:"1" in
  let selected = ref (Reading.reader ~identity:a ~read:(fun ~bytes -> Ok ("A:" ^ bytes))) in
  let resolutions = ref 0 in
  let resolve ~kind:_ ~media_type:_ = incr resolutions; Ok !selected in
  let walk () = Reading.projector ~media_store ~keeper_name:"selected-reader" ~resolve () in
  let first = walk () in
  check_reading "first attachment selects A" a "A:stored PDF bytes"
    (Reading.read_stored first ~kind:Reading.Document ~media_type:"application/pdf" stored);
  selected := Reading.reader ~identity:b ~read:(fun ~bytes -> Ok ("B:" ^ bytes));
  check_reading "later attachment keeps the same walk's selection" a "A:later original"
    (Reading.read_stored first ~kind:Reading.Document ~media_type:"application/pdf" another);
  check int "the declaration is resolved once in a walk" 1 !resolutions;
  check_reading "the next walk selects B" b "B:stored PDF bytes"
    (Reading.read_stored (walk ()) ~kind:Reading.Document ~media_type:"application/pdf" stored);
  check int "a new walk resolves the declaration again" 2 !resolutions
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
    ; ( "shared_reading"
      , [ test_case "raw read then history share one extraction" `Quick
            (test_raw_and_history_share_one_reading ~raw_first:true)
        ; test_case "history then raw read retain distinct attribution" `Quick
            (test_raw_and_history_share_one_reading ~raw_first:false)
        ; test_case "raw disk reading needs no reader" `Quick
            test_raw_disk_cache_needs_no_reader
        ; test_case "unavailable raw reading retries in the next walk" `Quick
            test_unavailable_raw_result_retries_only_in_a_new_walk
        ; test_case "later attachment is read after an earlier success" `Quick
            (test_later_attachment_is_read_after_earlier_result ~earlier_succeeded:true)
        ; test_case "one attachment timeout does not reject a later attachment" `Quick
            (test_later_attachment_is_read_after_earlier_result ~earlier_succeeded:false)
        ; test_case "raw reader cancellation propagates without memoization" `Quick
            test_raw_cancellation_propagates_without_memoization
        ; test_case "reader identity and revision own cached readings" `Quick
            test_reader_identity_and_revision_own_the_cached_reading
        ; test_case "an unavailable resolver cannot borrow an old reading" `Quick
            test_unavailable_resolver_cannot_borrow_a_cached_reading
        ; test_case "a walk keeps its selected reader snapshot" `Quick
            test_a_walk_keeps_its_selected_reader_snapshot
        ] )
    ]
;;
