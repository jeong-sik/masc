(** Observational preflight uses real files and the real Keeper consumer. It
    never manufactures a live Board observation, cursor or admission proof. *)

open Masc

module P = Board_core
module D = Keeper_durable_store
module Rows = Masc_board_handlers.Board_votes_json
module Paths = Masc_board_handlers.Board_paths

let () = Mirage_crypto_rng_unix.use_default ()

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_fixture test () =
  let base = Unix.realpath (Filename.temp_dir "board-preflight-" "") in
  Fs_compat.clear_fs ();
  Fun.protect
    ~finally:(fun () -> Fs_compat.clear_fs (); remove_tree base)
    (fun () -> test base)

let in_eio operation =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Fun.protect ~finally:Fs_compat.clear_fs operation)

let read_bytes path = In_channel.with_open_bin path In_channel.input_all
let write_bytes path bytes =
  Out_channel.with_open_bin path (fun channel -> output_string channel bytes)

let workspace base = Common.masc_dir_from_base_path ~base_path:base
let posts_path base = Paths.posts_file ~workspace_masc_dir:(workspace base)
let entries path = Sys.readdir path |> Array.to_list |> List.sort String.compare

let absent path =
  match Unix.lstat path with
  | _ -> false
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true

(* atime is deliberately excluded: a readonly observation may update it. *)
let file_state path =
  let stat = Unix.lstat path in
  stat.Unix.st_dev, stat.Unix.st_ino, stat.Unix.st_nlink,
  stat.Unix.st_perm, stat.Unix.st_size, read_bytes path

let unchanged label before path =
  Alcotest.(check bool) label true (before = file_state path)

let prepare base bytes =
  let dir = workspace base in
  Unix.mkdir dir 0o750;
  let path = posts_path base in
  write_bytes path bytes;
  Unix.chmod path 0o640;
  dir, path

let create store body =
  Board.create_post store ~lookup:Recipient_lookup.none_declared
    ~author:"preflight-writer" ~content:body ~title:"preflight title" ~body
    ~post_kind:Board.Human_post ~ttl_hours:0 ()

(* The fixture wire comes from the actual producer in a different workspace.
   Its stable lock is never removed to simulate an observational fixture. *)
let canonical_row base =
  let seed = Filename.concat base "producer" in
  in_eio (fun () ->
    Fs_compat.mkdir_p seed;
    let module Preparation = Masc_test_deps.Board_test_preparation in
    Preparation.prepare ~base_path:seed ~action:Preparation.Bootstrap;
    let store = Board.create_store ~base_path:seed () in
    (match Rows.load_persisted_posts store with
     | Ok 0 -> ()
     | Ok _ | Error _ -> Alcotest.fail "initialized producer did not load an empty source");
    match create store "actual preflight source" with
    | Ok post -> Board.post_to_yojson post
    | Error failure -> Alcotest.fail (Board.Post_publication_failure.to_string failure))

let wire row = Yojson.Safe.to_string row ^ "\n"

let inspect base = P.inspect_posts_source ~workspace_masc_dir:(workspace base)

let scan base =
  match D.reader D.Id.Board_posts with
  | D.Preflight_only reader -> D.run reader ~base_path:base
  | D.Refuse_boot _ | D.Degrade_typed _ ->
    Alcotest.fail "Board posts lost its observational preflight policy"

let check_report ~rows ~refused = function
  | Ok report ->
    Alcotest.(check int) "Keeper complete physical rows excluding blanks" rows report.D.rows;
    Alcotest.(check int) "Keeper refused complete rows" refused report.D.refused;
    Alcotest.(check bool) "refusal detail agrees with the count"
      (refused > 0) (Option.is_some report.D.first_refusal)
  | Error detail -> Alcotest.fail detail

let check_present ~accepted ~errors = function
  | P.Inspected {
      observation = Observed_present {
        accepted_rows; errors = actual_errors; framing = Complete_rows };
      settlement_diagnostic = None } ->
    Alcotest.(check int) "accepted complete rows" accepted accepted_rows;
    Alcotest.(check int) "refused complete rows" errors (List.length actual_errors)
  | P.Inspected _ -> Alcotest.fail "expected a settled complete present observation"
  | P.Inspection_failed { error; _ } ->
    Alcotest.fail (Fs_compat.Private_jsonl_unique_fold.error_to_string error)

let check_missing = function
  | P.Inspected { observation = Observed_missing; settlement_diagnostic = None } -> ()
  | P.Inspected _ | P.Inspection_failed _ -> Alcotest.fail "expected actual Missing"

let test_absent_nested_root base =
  let missing_parent = Filename.concat base "absent" in
  let nested_base = Filename.concat missing_parent "nested" in
  let before = entries base in
  Alcotest.(check bool) "subject parent starts absent" true (absent missing_parent);
  check_missing (inspect nested_base);
  check_report ~rows:0 ~refused:0 (scan nested_base);
  Alcotest.(check bool) "inspection and Keeper created no subject ancestor"
    true (absent missing_parent);
  Alcotest.(check (list string)) "outer directory entries are unchanged" before (entries base)

let test_missing_and_empty base =
  let dir = workspace base in
  Unix.mkdir dir 0o750;
  let before = Unix.lstat dir in
  check_missing (inspect base);
  check_report ~rows:0 ~refused:0 (scan base);
  Alcotest.(check (list string)) "Missing created no lock or payload" [] (entries dir);
  let after = Unix.lstat dir in
  Alcotest.(check (pair int int)) "existing root identity is unchanged"
    (before.Unix.st_dev, before.Unix.st_ino) (after.Unix.st_dev, after.Unix.st_ino);
  Alcotest.(check int) "existing root permissions are unchanged"
    before.Unix.st_perm after.Unix.st_perm;
  let path = posts_path base in
  write_bytes path "";
  Unix.chmod path 0o640;
  let before = file_state path in
  check_present ~accepted:0 ~errors:0 (inspect base);
  check_report ~rows:0 ~refused:0 (scan base);
  unchanged "empty present payload is unchanged" before path;
  Alcotest.(check (list string)) "empty observation created no sibling"
    [Filename.basename path] (entries dir)

let test_existing_lock_is_untouched base =
  let row = canonical_row base in
  let dir, path = prepare base (wire row) in
  let lock = path ^ ".lock" in
  write_bytes lock "an existing unrelated lock sentinel\000\255";
  Unix.chmod lock 0o640;
  let payload = file_state path and sentinel = file_state lock in
  let before = entries dir in
  check_present ~accepted:1 ~errors:0 (inspect base);
  (* The same inspection shell must also move diagnostics out of its worker. *)
  in_eio (fun () ->
    check_present ~accepted:1 ~errors:0 (inspect base);
    check_report ~rows:1 ~refused:0 (scan base));
  unchanged "payload binding, mode and bytes survive both callers" payload path;
  unchanged "stable sibling was neither opened as authority nor rewritten" sentinel lock;
  Alcotest.(check (list string)) "no stage or other sibling was created" before (entries dir)

let test_partial_and_torn base =
  let row = canonical_row base in
  let complete = "\n" ^ wire row ^ " \t\n{\n{}\n" in
  let dir, path = prepare base complete in
  let before = file_state path and before_entries = entries dir in
  (match inspect base with
   | P.Inspected {
       observation = Observed_present {
         accepted_rows = 1;
         errors = [P.Invalid_posts_json { line = 4; _ }; P.Invalid_posts_row { line = 5 }];
         framing = Complete_rows };
       settlement_diagnostic = None } -> ()
   | P.Inspected _ | P.Inspection_failed _ ->
     Alcotest.fail "blank rows changed physical error lines or row classification");
  check_report ~rows:3 ~refused:2 (scan base);
  unchanged "partial inspection preserves rejected source bytes and mode" before path;
  let tail = "{\"author\":\"bad/unterminated\"" in
  let torn = complete ^ tail in
  write_bytes path torn;
  let before = file_state path in
  let rejections_before, _ = Validation.get_rejection_stats () in
  (match inspect base with
   | P.Inspected {
       observation = Observed_present {
         accepted_rows = 1; errors = [_; _]; framing = Torn_tail { rows_end; end_offset } };
       settlement_diagnostic = None } ->
     Alcotest.(check int) "complete rows end at their real newline"
       (String.length complete) rows_end;
     Alcotest.(check int) "torn end is the real file length" (String.length torn) end_offset
   | P.Inspected _ | P.Inspection_failed _ -> Alcotest.fail "torn framing was lost");
  (match scan base with Error _ -> () | Ok _ -> Alcotest.fail "Keeper accepted a torn source");
  let rejections_after, _ = Validation.get_rejection_stats () in
  Alcotest.(check int) "unterminated fragment was never decoded" 0
    (rejections_after - rejections_before);
  unchanged "torn inspection performs no repair" before path;
  Alcotest.(check (list string)) "partial and torn reads create no siblings"
    before_entries (entries dir)

let set_field row key value =
  match row with
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> Alcotest.fail "producer row is not an object"

let remove_field row key =
  match row with
  | `Assoc fields -> `Assoc (List.remove_assoc key fields)
  | _ -> Alcotest.fail "producer row is not an object"

let rejection_delta label expected operation =
  let before, _ = Validation.get_rejection_stats () in
  let value = operation () in
  let after, _ = Validation.get_rejection_stats () in
  Alcotest.(check int) label expected (after - before);
  value

let origin producer = `Assoc [
  "source", `String "fusion"; "fusion_run_id", `String "preflight-fusion";
  "fusion_producer", producer ]

let test_torn_prefix_diagnostics base =
  let canonical = canonical_row base in
  let rejected = set_field canonical "origin" (origin (`String "bad/producer")) in
  let complete = wire canonical ^ wire rejected in
  let dir, path = prepare base (complete ^ "{") in
  let before = file_state path in
  rejection_delta "torn prefix emits no decoder diagnostic" 0 (fun () ->
    match inspect base with
    | P.Inspected {
        observation = Observed_present {
          accepted_rows = 1; errors = [P.Invalid_posts_row { line = 2 }];
          framing = Torn_tail { rows_end; end_offset } };
        settlement_diagnostic = None } ->
      Alcotest.(check int) "rejected complete row remains in the prefix"
        (String.length complete) rows_end;
      Alcotest.(check int) "torn delimiter remains outside decoding"
        (String.length complete + 1) end_offset
    | P.Inspected _ | P.Inspection_failed _ -> Alcotest.fail "torn prefix classification changed");
  rejection_delta "Keeper torn refusal emits no decoder diagnostic" 0 (fun () ->
    match scan base with Error _ -> () | Ok _ -> Alcotest.fail "Keeper admitted torn diagnostics");
  unchanged "torn diagnostic refusal leaves the source intact" before path;
  write_bytes path complete;
  rejection_delta "complete source emits the rejected row diagnostic once" 1 (fun () ->
    check_present ~accepted:1 ~errors:1 (inspect base));
  rejection_delta "complete Keeper scan emits that diagnostic once" 1 (fun () ->
    check_report ~rows:2 ~refused:1 (scan base));
  Alcotest.(check string) "completed source is not rewritten" complete (read_bytes path);
  Alcotest.(check (list string)) "neither framing creates a sidecar"
    [Filename.basename path] (entries dir)

let test_decoder_and_consumer_agree base =
  let canonical = canonical_row base in
  let transferred = set_field canonical "author" (`String "transferred-owner") in
  let transferred = set_field transferred "origin" (origin (`String "  original-producer  ")) in
  let nested = set_field canonical "audience" (`Assoc [
      "kind", `String "targets";
      "targets", `List [`String "bad/target"; `String "another/target"]]) in
  let nested = set_field nested "closed" (`Assoc [
      "closed_by", `String "bad/closer"; "closed_at", `Float 1.]) in
  let nested = set_field nested "author" (`String "bad/author") in
  let nested = remove_field (set_field nested "post_kind" (`String "unknown")) "body" in
  let bad_kind = set_field (set_field canonical "author" (`String "bad/author"))
      "post_kind" (`String "unknown") in
  let malformed_close = set_field canonical "closed" (`Assoc [
      "closed_by", `String "bad/closer"; "closed_at", `Float 1.; "successor_id", `Int 7]) in
  let bad_producer = set_field canonical "origin" (origin (`String "bad/producer")) in
  let cases = [
    "canonical", canonical, true, 0;
    "transferred producer", transferred, true, 0;
    "nested diagnostics", nested, false, 2;
    "outer author after kind", bad_kind, false, 1;
    "malformed close", malformed_close, false, 0;
    "producer", bad_producer, false, 1;
    "nested producer before missing body", remove_field bad_producer "body", false, 1;
    "unknown field", set_field canonical "unexpected" `Null, false, 0;
    "wrong outer shape", `List [], false, 0 ] in
  List.iteri (fun index (label, row, accepted, diagnostics) ->
    let decoded = rejection_delta (label ^ " public diagnostics") diagnostics
        (fun () -> Board.post_of_yojson row) in
    Alcotest.(check bool) (label ^ " public schema") accepted (Option.is_some decoded);
    (match label, decoded with
     | "transferred producer", Some post ->
       Alcotest.(check string) "mutable author remains independent"
         "transferred-owner" (Board.Agent_id.to_string post.author);
       Alcotest.(check (option string)) "producer is canonicalized"
         (Some "original-producer") (Option.bind post.origin (fun origin -> origin.fusion_producer))
     | _ -> ());
    let subject = Filename.concat base (Printf.sprintf "inspection-%d" index) in
    Unix.mkdir subject 0o750;
    let dir, path = prepare subject (wire row) in
    let before = file_state path in
    let accepted_rows = if accepted then 1 else 0 in
    let refused = if accepted then 0 else 1 in
    rejection_delta (label ^ " inspection diagnostics") diagnostics (fun () ->
      in_eio (fun () ->
        check_present ~accepted:accepted_rows ~errors:refused (inspect subject)));
    rejection_delta (label ^ " Keeper diagnostics") diagnostics (fun () ->
      check_report ~rows:1 ~refused (scan subject));
    unchanged (label ^ " observational bytes") before path;
    Alcotest.(check (list string)) (label ^ " no observation sidecar")
      [Filename.basename path] (entries dir);
    let live = Filename.concat base (Printf.sprintf "live-%d" index) in
    Unix.mkdir live 0o750;
    let _, live_path = prepare live (wire row) in
    in_eio (fun () ->
      let store = Board.create_store ~base_path:live () in
      let result = rejection_delta (label ^ " loader diagnostics") diagnostics
          (fun () -> Rows.load_persisted_posts store) in
      match accepted, result with
      | true, Ok 1 | false, Error _ -> ()
      | _ -> Alcotest.fail (label ^ " live loader schema disagreed"));
    Alcotest.(check string) (label ^ " live loader preserves wire") (wire row) (read_bytes live_path)
  ) cases

let require_binding_refusal = function
  | P.Inspection_failed {
      error = Fs_compat.Private_jsonl_unique_fold.Binding_refused _;
      settlement_diagnostic = None } -> ()
  | P.Inspected _ | P.Inspection_failed _ ->
    Alcotest.fail "an actual alias was not refused at the unique-file boundary"

let test_symlink base =
  let row = canonical_row base in
  let target = Filename.concat base "external.jsonl" in
  write_bytes target (wire row);
  Unix.chmod target 0o640;
  let target_before = file_state target in
  Unix.mkdir (workspace base) 0o750;
  let path = posts_path base in
  Unix.symlink target path;
  let link_before = Unix.lstat path in
  require_binding_refusal (inspect base);
  (match scan base with Error _ -> () | Ok _ -> Alcotest.fail "Keeper followed the symlink");
  let link_after = Unix.lstat path in
  Alcotest.(check (pair int int)) "symlink inode is unchanged"
    (link_before.Unix.st_dev, link_before.Unix.st_ino)
    (link_after.Unix.st_dev, link_after.Unix.st_ino);
  Alcotest.(check string) "symlink target is unchanged" target (Unix.readlink path);
  unchanged "external regular file is untouched" target_before target;
  Alcotest.(check (list string)) "symlink refusal created no sidecar"
    [Filename.basename path] (entries (workspace base))

let test_dangling_symlink base =
  Unix.mkdir (workspace base) 0o750;
  let target = Filename.concat base "absent-target.jsonl" in
  let path = posts_path base in
  Unix.symlink target path;
  require_binding_refusal (inspect base);
  (match scan base with Error _ -> () | Ok _ -> Alcotest.fail "dangling alias became Missing");
  Alcotest.(check bool) "dangling target was not created" true (absent target);
  Alcotest.(check string) "dangling link remains in place" target (Unix.readlink path);
  Alcotest.(check (list string)) "dangling refusal created no sidecar"
    [Filename.basename path] (entries (workspace base))

let test_hardlink base =
  let row = canonical_row base in
  let dir, path = prepare base (wire row) in
  let alias = Filename.concat base "external-hardlink.jsonl" in
  Unix.link path alias;
  let before = file_state path in
  require_binding_refusal (inspect base);
  (match scan base with Error _ -> () | Ok _ -> Alcotest.fail "Keeper accepted multiple links");
  unchanged "hardlink refusal preserves payload and link count" before path;
  unchanged "hardlink refusal preserves the external alias" before alias;
  Unix.unlink alias;
  check_present ~accepted:1 ~errors:0 (inspect base);
  check_report ~rows:1 ~refused:0 (scan base);
  Alcotest.(check (list string)) "refusal and later healthy read create no sibling"
    [Filename.basename path] (entries dir)

let test_inspection_grants_no_live_authority base =
  let row = canonical_row base in
  let dir, path = prepare base (wire row) in
  let before = file_state path in
  in_eio (fun () ->
    let store = Board.create_store ~base_path:base () in
    check_present ~accepted:1 ~errors:0 (inspect base);
    check_report ~rows:1 ~refused:0 (scan base);
    (match store.Board.posts_source with
     | Board.Posts_unobserved -> ()
     | _ -> Alcotest.fail "inspection changed live source admission");
    match create store "unadmitted publication" with
    | Ok _ -> Alcotest.fail "observational preflight granted write authority"
    | Error failure ->
      (match Board.Post_publication_failure.cause failure with
       | Board.Post_publication_failure.Board_error (Board.Io_error _) -> ()
       | _ -> Alcotest.fail "unobserved source was refused for an unrelated cause");
      (match Board.Post_publication_failure.effect_disposition failure with
       | Failure_effect.Proven_pre_effect -> ()
       | _ -> Alcotest.fail "unadmitted create did not prove it preceded effect");
      Alcotest.(check bool) "no committed receipt" true
        (Option.is_none (Board.Post_publication_failure.committed failure)));
  unchanged "unadmitted create leaves observed source intact" before path;
  Alcotest.(check (list string)) "no stable lock or stage was created"
    [Filename.basename path] (entries dir)

let close_io failure captured closes =
  { Fs_compat.before_sync_parent = (fun _ -> Alcotest.fail "readonly inspection attempted parent sync");
    close_fd = (fun descriptor ->
      incr closes;
      Unix.close descriptor;
      try raise failure with exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        captured := Some backtrace;
        Printexc.raise_with_backtrace exception_ backtrace) }

let check_original_backtrace label captured actual =
  let expected = match !captured with
    | Some backtrace -> backtrace
    | None -> Alcotest.fail "close injection never captured its actual raising backtrace" in
  let length = Printexc.raw_backtrace_length expected in
  Alcotest.(check bool) (label ^ " has original raising frames") true (length > 0);
  Alcotest.(check bool) (label ^ " retains all original frames") true
    (Printexc.raw_backtrace_length actual >= length);
  for index = 0 to length - 1 do
    Alcotest.(check bool) (label ^ " retains original frame order") true
      (Printexc.get_raw_backtrace_slot expected index
       = Printexc.get_raw_backtrace_slot actual index)
  done

let test_ordinary_close base =
  let row = canonical_row base in
  let dir, path = prepare base (wire row ^ "{}\n") in
  let before = file_state path in
  let failure = Failure "ordinary preflight close" in
  let captured = ref None and closes = ref 0 in
  let errors_before = P.persist_error_count () in
  (match P.inspect_posts_source_with_io_for_testing
      ~workspace_masc_dir:(workspace base) ~io:(close_io failure captured closes) with
   | P.Inspected {
       observation = Observed_present {
         accepted_rows = 1; errors = [_]; framing = Complete_rows };
       settlement_diagnostic = Some diagnostic } ->
     Alcotest.(check bool) "close operation is explicit" true
       (diagnostic.operation = Fs_compat.Close_transaction_data);
     Alcotest.(check bool) "original close exception is retained" true
       (diagnostic.exception_ == failure);
     check_original_backtrace "ordinary close backtrace" captured diagnostic.backtrace
   | P.Inspected _ | P.Inspection_failed _ ->
     Alcotest.fail "ordinary settlement replaced the actual partial observation");
  Alcotest.(check int) "one actual descriptor close" 1 !closes;
  Alcotest.(check int) "one settlement persist diagnostic" 1
    (P.persist_error_count () - errors_before);
  check_present ~accepted:1 ~errors:1 (inspect base);
  unchanged "close failure performs no write or retry" before path;
  Alcotest.(check (list string)) "close failure created no sidecar"
    [Filename.basename path] (entries dir)

let test_binding_refusal_and_close base =
  let row = canonical_row base in
  let dir, path = prepare base (wire row) in
  let alias = Filename.concat base "refused-hardlink.jsonl" in
  Unix.link path alias;
  let before = file_state path in
  let failure = Failure "cleanup after actual binding refusal" in
  let captured = ref None and closes = ref 0 in
  (match P.inspect_posts_source_with_io_for_testing
      ~workspace_masc_dir:(workspace base) ~io:(close_io failure captured closes) with
   | P.Inspection_failed {
       error = Fs_compat.Private_jsonl_unique_fold.Binding_refused
         (Fs_compat.Ambiguous_transaction_file_identity { link_count = 2; _ });
       settlement_diagnostic = Some diagnostic } ->
     Alcotest.(check bool) "ordinary cleanup preserves its original exception" true
       (diagnostic.exception_ == failure);
     Alcotest.(check bool) "cleanup retains its close operation" true
       (diagnostic.operation = Fs_compat.Close_transaction_data);
     check_original_backtrace "refused source cleanup" captured diagnostic.backtrace
   | P.Inspected _ | P.Inspection_failed _ ->
     Alcotest.fail "cleanup failure replaced the real hardlink refusal");
  Alcotest.(check int) "refused source still closes its descriptor once" 1 !closes;
  unchanged "primary refusal plus cleanup leaves both links intact" before path;
  unchanged "external alias survives refusal plus cleanup" before alias;
  Unix.unlink alias;
  check_present ~accepted:1 ~errors:0 (inspect base);
  Alcotest.(check (list string)) "refused cleanup creates no sidecar"
    [Filename.basename path] (entries dir)

type reserved_close = Timeout | Allocation | Nested_timeout

let test_reserved_close kind base =
  let row = set_field (canonical_row base) "origin" (origin (`String "bad/producer")) in
  let dir, path = prepare base (wire row) in
  let before = file_state path in
  let backtrace = Printexc.get_callstack 16 in
  let failure = match kind with
    | Timeout -> Eio.Time.Timeout
    | Allocation -> Out_of_memory
    | Nested_timeout -> fst (Eio.Exn.combine
        (Failure "ordinary close member", backtrace) (Eio.Time.Timeout, backtrace)) in
  let captured = ref None and closes = ref 0 in
  let errors_before = P.persist_error_count () in
  let rejections_before, _ = Validation.get_rejection_stats () in
  let raised =
    try
      ignore (P.inspect_posts_source_with_io_for_testing
        ~workspace_masc_dir:(workspace base) ~io:(close_io failure captured closes));
      None
    with exception_ -> Some (exception_, Printexc.get_raw_backtrace ()) in
  (match raised with
   | Some (exception_, actual_backtrace) ->
     Alcotest.(check bool) "original reserved exception escapes" true (exception_ == failure);
     check_original_backtrace "reserved close backtrace" captured actual_backtrace
   | None -> Alcotest.fail "reserved descriptor settlement was swallowed");
  let rejections_after, _ = Validation.get_rejection_stats () in
  Alcotest.(check int) "row diagnostic emitted once before reserved propagation"
    1 (rejections_after - rejections_before);
  Alcotest.(check int) "one reserved settlement diagnostic" 1
    (P.persist_error_count () - errors_before);
  Alcotest.(check int) "reserved settlement closes once" 1 !closes;
  rejection_delta "next healthy inspection remains usable" 1 (fun () ->
    check_present ~accepted:0 ~errors:1 (inspect base));
  unchanged "reserved settlement leaves real bytes and binding untouched" before path;
  Alcotest.(check (list string)) "reserved settlement created no sibling"
    [Filename.basename path] (entries dir)

let () =
  Printexc.record_backtrace true;
  let case name test = Alcotest.test_case name `Quick (with_fixture test) in
  Alcotest.run "board_posts_preflight" [
    "noncreating observations", [
      case "absent nested workspace stays absent" test_absent_nested_root;
      case "Missing differs from present empty" test_missing_and_empty;
      case "existing payload and lock remain untouched" test_existing_lock_is_untouched;
      case "partial rows and torn framing reach Keeper" test_partial_and_torn;
      case "torn prefix defers all decoder diagnostics" test_torn_prefix_diagnostics;
      case "public decoder loader inspection and Keeper agree" test_decoder_and_consumer_agree;
      case "inspection grants no live source authority" test_inspection_grants_no_live_authority ];
    "actual unique binding", [
      case "symlink target is refused and preserved" test_symlink;
      case "dangling symlink is refused rather than Missing" test_dangling_symlink;
      case "hardlinks refuse then unique source reads" test_hardlink ];
    "actual descriptor settlement", [
      case "ordinary close preserves partial observation" test_ordinary_close;
      case "ordinary close preserves actual binding refusal" test_binding_refusal_and_close;
      case "timeout close emits before propagating" (test_reserved_close Timeout);
      case "allocation close emits before propagating" (test_reserved_close Allocation);
      case "nested timeout close preserves original exception" (test_reserved_close Nested_timeout) ] ]
