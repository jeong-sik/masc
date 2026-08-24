open Alcotest

module Head = Fs_compat.Capability_head

let with_tmp_dir prefix f =
  let path = Filename.temp_file prefix ".tmp" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
;;

let with_parent ~fs directory f =
  Eio.Path.with_open_dir Eio.Path.(fs / directory) f
;;

let directory_entries directory =
  Sys.readdir directory |> Array.to_list |> List.sort String.compare
;;

(* [Error _] told a reader nothing: 18 of this suite's 19 cases can fail and
   every one of them printed the same sentence. The variant is closed, so the
   arm can name which one arrived. *)
let error_name : Head.error -> string = function
  | Invalid_leaf detail -> Printf.sprintf "Invalid_leaf %S" detail
  | Invalid_row detail -> Printf.sprintf "Invalid_row %S" detail
  | Busy -> "Busy"
  | Conflict _ -> "Conflict"
  | Corrupt_lock detail -> Printf.sprintf "Corrupt_lock %S" detail
  | Corrupt_head detail -> Printf.sprintf "Corrupt_head %S" detail
  | Unsupported detail -> Printf.sprintf "Unsupported %S" detail
  | Io_error _ -> "Io_error"
;;

let require_read label = function
  | Ok snapshot -> snapshot
  | Error ({ Head.error; _ } : Head.failure) ->
      failf "%s: HEAD read failed with %s" label (error_name error)
;;

let require_publication label = function
  | Ok publication -> publication
  | Error _ -> failf "%s: HEAD publication failed" label
;;

let require_conflict label = function
  | Error
      ({ error = Head.Conflict current
       ; target_effect = Head.Unchanged
       ; _
       } : Head.failure) ->
    current
  | Error _ -> failf "%s: expected an unchanged typed conflict" label
  | Ok _ -> failf "%s: stale or foreign cursor unexpectedly published" label
;;

let require_busy label = function
  | Error
      ({ error = Head.Busy
       ; target_effect = Head.Unchanged
       ; _
       } : Head.failure) ->
    ()
  | Error _ -> failf "%s: expected an unchanged typed busy result" label
  | Ok _ -> failf "%s: contending publication unexpectedly succeeded" label
;;

let require_invalid_row label = function
  | Error
      ({ error = Head.Invalid_row _
       ; target_effect = Head.Unchanged
       ; _
       } : Head.failure) ->
    ()
  | Error _ -> failf "%s: expected an unchanged typed invalid-row failure" label
  | Ok _ -> failf "%s: invalid row unexpectedly published" label
;;

let require_invalid_leaf ~expected label = function
  | Error
      ({ error = Head.Invalid_leaf observed
       ; target_effect = Head.Unchanged
       ; _
       } : Head.failure) ->
    check string (label ^ " rejected leaf") expected observed
  | Error _ -> failf "%s: expected an unchanged typed invalid-leaf failure" label
  | Ok _ -> failf "%s: reserved leaf unexpectedly dispatched" label
;;

let require_unchanged_io_error ~operation label = function
  | Error
      ({ error =
           Head.Io_error
             ({ operation = observed_operation; _ } : Head.diagnostic)
       ; target_effect = Head.Unchanged
       ; _
       } : Head.failure)
    when observed_operation = operation ->
    ()
  | Error _ -> failf "%s: expected the exact unchanged typed IO failure" label
  | Ok _ -> failf "%s: entropy exhaustion unexpectedly succeeded" label
;;

let require_unchanged_failure label = function
  | Error ({ target_effect = Head.Unchanged; _ } : Head.failure) -> ()
  | Error _ -> failf "%s: failure crossed the publication boundary" label
  | Ok _ -> failf "%s: injected pre-publication failure unexpectedly succeeded" label
;;

let require_indeterminate_failure label = function
  | Error
      ({ target_effect = Head.Publication_indeterminate evidence; _ } : Head.failure) ->
    evidence
  | Error _ -> failf "%s: expected publication-indeterminate evidence" label
  | Ok _ -> failf "%s: injected post-rename failure unexpectedly returned success" label
;;

let require_published_failure label = function
  | Error ({ target_effect = Head.Published evidence; _ } : Head.failure) -> evidence
  | Error _ -> failf "%s: expected typed published evidence" label
  | Ok _ -> failf "%s: injected post-verification failure unexpectedly returned success" label
;;

let read ~secure_random ~parent ~leaf label =
  Head.read ~secure_random ~parent ~leaf |> require_read label
;;

let publish ~secure_random ~parent ~leaf ~expected ~row label =
  Head.compare_and_swap
    ~secure_random
    ~parent
    ~leaf
    ~expected:(Head.snapshot_cursor expected)
    ~row
  |> require_publication label
;;

let publish_for_testing
      hooks
      ~secure_random
      ~parent
      ~leaf
      ~expected
      ~row
  =
  Head.For_testing.compare_and_swap
    hooks
    ~secure_random
    ~parent
    ~leaf
    ~expected:(Head.snapshot_cursor expected)
    ~row
;;

let check_row label expected snapshot =
  check (option string) label expected (Head.snapshot_row snapshot)
;;

let check_publication_evidence label row (evidence : Head.publication_evidence) =
  ignore evidence.Head.expected_cursor;
  ignore evidence.Head.published_cursor;
  check int64
    (label ^ " intended byte length")
    (Int64.of_int (String.length row + 1))
    evidence.Head.intended_length;
  check int
    (label ^ " SHA-256 hex length")
    64
    (String.length evidence.Head.intended_sha256)
;;

let raise_with_captured_backtrace captured exn =
  try raise exn with
  | raised ->
    let raw_backtrace = Printexc.get_raw_backtrace () in
    captured := Some raw_backtrace;
    Printexc.raise_with_backtrace raised raw_backtrace
;;

let fatal_kind = function
  | Out_of_memory -> "Out_of_memory"
  | Stack_overflow -> "Stack_overflow"
  | Sys.Break -> "Sys.Break"
  | exn -> Printexc.to_string exn
;;

let require_original_fatal_backtrace ~label ~expected ~captured run =
  Printexc.record_backtrace true;
  let outcome =
    try
      ignore (run ());
      `Returned
    with
    | exn -> `Raised (exn, Printexc.get_raw_backtrace ())
  in
  match outcome, !captured with
  | `Raised (observed, observed_backtrace), Some original_backtrace ->
    check string
      (label ^ " preserves fatal kind")
      (fatal_kind expected)
      (fatal_kind observed);
    check string
      (label ^ " preserves original raw backtrace")
      (Printexc.raw_backtrace_to_string original_backtrace)
      (Printexc.raw_backtrace_to_string observed_backtrace)
  | `Raised (_, _), None ->
    failf "%s: fatal source did not capture its raw backtrace" label
  | `Returned, _ ->
    failf "%s: fatal exception was flattened into a typed result" label
;;

let cross_process_holder_arg = "--capability-head-cross-process-holder"
let cross_process_timeout_seconds = 10.0

let () =
  if
    Array.length Sys.argv = 5
    && String.equal Sys.argv.(1) cross_process_holder_arg
  then (
    let directory = Sys.argv.(2) in
    let leaf = Sys.argv.(3) in
    let row = Sys.argv.(4) in
    let exit_code =
      try
        Eio_main.run @@ fun env ->
        let fs = Eio.Stdenv.fs env in
        let secure_random = Eio.Stdenv.secure_random env in
        with_parent ~fs directory @@ fun parent ->
        match Head.read ~secure_random ~parent ~leaf with
        | Error _ -> 2
        | Ok expected ->
          let hooks =
            Head.For_testing.hooks
              ~after_lock_acquired:(fun () ->
                output_char stdout 'R';
                flush stdout;
                if input_char stdin <> 'X'
                then failwith "invalid cross-process release signal")
              ()
          in
          (match
             Head.For_testing.compare_and_swap
               hooks
               ~secure_random
               ~parent
               ~leaf
               ~expected:(Head.snapshot_cursor expected)
               ~row
           with
           | Ok _ -> 0
           | Error _ -> 3)
      with
      | _ -> 4
    in
    exit exit_code)
;;

let test_absent_publish_and_reopen ~fs ~secure_random () =
  with_tmp_dir "masc_capability_head_reopen_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory (fun parent ->
    let absent = read ~secure_random ~parent ~leaf "initial absent read" in
    check_row "fresh HEAD is absent" None absent;
    publish
      ~secure_random
      ~parent
      ~leaf
      ~expected:absent
      ~row:"manifest-v1"
      "initial publication"
    |> Head.publication_evidence
    |> check_publication_evidence "initial publication" "manifest-v1");
  with_parent ~fs directory (fun reopened_parent ->
    let reopened =
      read ~secure_random ~parent:reopened_parent ~leaf "reopened read"
    in
    check_row "reopened HEAD observes first row" (Some "manifest-v1") reopened;
    ignore
      (publish
         ~secure_random
         ~parent:reopened_parent
         ~leaf
         ~expected:reopened
         ~row:"manifest-v2"
         "publication after reopen"));
  with_parent ~fs directory (fun final_parent ->
    read ~secure_random ~parent:final_parent ~leaf "final reopened read"
    |> check_row "second publication remains authoritative" (Some "manifest-v2"))
;;

let test_stale_cursor_conflicts_without_mutation ~fs ~secure_random () =
  with_tmp_dir "masc_capability_head_stale_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  let absent = read ~secure_random ~parent ~leaf "stale fixture read" in
  ignore
    (publish
       ~secure_random
       ~parent
       ~leaf
       ~expected:absent
       ~row:"winner"
       "winner publication");
  let current =
    Head.compare_and_swap
      ~secure_random
      ~parent
      ~leaf
      ~expected:(Head.snapshot_cursor absent)
      ~row:"stale-overwrite"
    |> require_conflict "stale publication"
  in
  check_row "conflict carries current authority" (Some "winner") current;
  read ~secure_random ~parent ~leaf "read after stale conflict"
  |> check_row "stale attempt leaves authority unchanged" (Some "winner")
;;

let test_cross_root_absent_cursor_conflicts ~fs ~secure_random () =
  with_tmp_dir "masc_capability_head_cursor_a_" @@ fun directory_a ->
  with_tmp_dir "masc_capability_head_cursor_b_" @@ fun directory_b ->
  let leaf = "HEAD" in
  with_parent ~fs directory_a @@ fun parent_a ->
  with_parent ~fs directory_b @@ fun parent_b ->
  let foreign = read ~secure_random ~parent:parent_a ~leaf "root A absent read" in
  check_row "root A is absent" None foreign;
  let current =
    Head.compare_and_swap
      ~secure_random
      ~parent:parent_b
      ~leaf
      ~expected:(Head.snapshot_cursor foreign)
      ~row:"must-not-cross-roots"
    |> require_conflict "cross-root publication"
  in
  check_row "foreign cursor conflict reports root B absent" None current;
  read ~secure_random ~parent:parent_b ~leaf "root B after foreign cursor"
  |> check_row "foreign cursor cannot create root B HEAD" None
;;

let test_strict_row_shape_rejection ~fs ~secure_random () =
  with_tmp_dir "masc_capability_head_row_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  List.iter
    (fun (label, row) ->
       let absent = read ~secure_random ~parent ~leaf (label ^ " pre-read") in
       check_row (label ^ " keeps HEAD absent before CAS") None absent;
       Head.compare_and_swap
         ~secure_random
         ~parent
         ~leaf
         ~expected:(Head.snapshot_cursor absent)
         ~row
       |> require_invalid_row label;
       read ~secure_random ~parent ~leaf (label ^ " post-read")
       |> check_row (label ^ " leaves HEAD absent") None)
    [ "empty row", ""
    ; "LF-only row", "\n"
    ; "LF-terminated row", "row\n"
    ; "CRLF row", "row\r\n"
    ; "embedded LF row", "left\nright"
    ; "oversized row", String.make (Head.max_row_bytes + 1) 'x'
    ];
  let absent = read ~secure_random ~parent ~leaf "valid row pre-read" in
  ignore
    (publish
       ~secure_random
       ~parent
       ~leaf
       ~expected:absent
       ~row:"valid-row"
       "valid row after rejections");
  read ~secure_random ~parent ~leaf "valid row post-read"
  |> check_row "invalid attempts do not poison later publication" (Some "valid-row")
;;

let test_reserved_namespace_is_rejected_before_dispatch ~fs () =
  with_tmp_dir "masc_capability_head_reserved_leaf_" @@ fun directory ->
  with_parent ~fs directory @@ fun parent ->
  List.iter
    (fun (label, leaf) ->
       Head.read
         ~secure_random:(Eio.Flow.string_source "")
         ~parent
         ~leaf
       |> require_invalid_leaf ~expected:leaf label;
       check (list string)
         (label ^ " creates neither target nor stable lock")
         []
         (directory_entries directory))
    [ "lowercase reserved capability HEAD namespace", ".masc-capability-head-forbidden"
    ; "uppercase reserved capability HEAD namespace", ".MASC-CAPABILITY-HEAD-FORBIDDEN"
    ; "mixed-case reserved capability HEAD namespace", ".MaSc-CaPaBiLiTy-HeAd-forbidden"
    ]
;;

let test_first_read_entropy_eof_is_unchanged_and_recoverable
      ~fs
      ~secure_random
      ()
  =
  with_tmp_dir "masc_capability_head_lock_entropy_" @@ fun directory ->
  let leaf = "HEAD" in
  let target = Filename.concat directory leaf in
  with_parent ~fs directory @@ fun parent ->
  Head.read
    ~secure_random:(Eio.Flow.string_source (String.make 31 'x'))
    ~parent
    ~leaf
  |> require_unchanged_io_error
       ~operation:Head.Initialize_lock_marker
       "finite lock-marker entropy";
  check bool "lock-marker entropy EOF leaves HEAD absent" false (Sys.file_exists target);
  Head.read ~secure_random ~parent ~leaf
  |> require_read "fresh entropy after lock-marker EOF"
  |> check_row "fresh entropy recovers an absent HEAD" None
;;

let test_stage_entropy_eof_is_unchanged ~fs ~secure_random () =
  with_tmp_dir "masc_capability_head_stage_entropy_" @@ fun directory ->
  let leaf = "HEAD" in
  let target = Filename.concat directory leaf in
  with_parent ~fs directory @@ fun parent ->
  let absent = read ~secure_random ~parent ~leaf "initialized lock read" in
  Head.compare_and_swap
    ~secure_random:(Eio.Flow.string_source "")
    ~parent
    ~leaf
    ~expected:(Head.snapshot_cursor absent)
    ~row:"must-not-stage"
  |> require_unchanged_io_error
       ~operation:Head.Create_stage
       "empty stage entropy";
  check bool "stage entropy EOF leaves HEAD absent" false (Sys.file_exists target);
  Head.read ~secure_random ~parent ~leaf
  |> require_read "exact read after stage entropy EOF"
  |> check_row "stage entropy EOF leaves authority unchanged" None
;;

let test_same_directory_contention_is_busy ~fs ~secure_random () =
  with_tmp_dir "masc_capability_head_contention_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent_a ->
  with_parent ~fs directory @@ fun parent_b ->
  let candidate_a = read ~secure_random ~parent:parent_a ~leaf "handle A read" in
  let candidate_b = read ~secure_random ~parent:parent_b ~leaf "handle B read" in
  Eio.Switch.run @@ fun sw ->
  let lock_acquired, resolve_lock_acquired = Eio.Promise.create () in
  let release_lock, resolve_release_lock = Eio.Promise.create () in
  let result_a, resolve_result_a = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let hooks =
      Head.For_testing.hooks
        ~after_lock_acquired:(fun () ->
          Eio.Promise.resolve resolve_lock_acquired ();
          Eio.Promise.await release_lock)
        ()
    in
    publish_for_testing
      hooks
      ~secure_random
      ~parent:parent_a
      ~leaf
      ~expected:candidate_a
      ~row:"handle-a-wins"
    |> Eio.Promise.resolve resolve_result_a);
  Eio.Promise.await lock_acquired;
  Head.compare_and_swap
    ~secure_random
    ~parent:parent_b
    ~leaf
    ~expected:(Head.snapshot_cursor candidate_b)
    ~row:"handle-b-must-not-enter"
  |> require_busy "second same-directory writer";
  Eio.Promise.resolve resolve_release_lock ();
  Eio.Promise.await result_a
  |> require_publication "first same-directory writer"
  |> ignore;
  read ~secure_random ~parent:parent_b ~leaf "contention final read"
  |> check_row "lock owner is the only publisher" (Some "handle-a-wins")
;;

let test_different_roots_do_not_false_share ~fs ~secure_random () =
  with_tmp_dir "masc_capability_head_root_a_" @@ fun directory_a ->
  with_tmp_dir "masc_capability_head_root_b_" @@ fun directory_b ->
  let leaf = "HEAD" in
  with_parent ~fs directory_a @@ fun parent_a ->
  with_parent ~fs directory_b @@ fun parent_b ->
  let candidate_a = read ~secure_random ~parent:parent_a ~leaf "root A read" in
  let candidate_b = read ~secure_random ~parent:parent_b ~leaf "root B read" in
  Eio.Switch.run @@ fun sw ->
  let lock_acquired, resolve_lock_acquired = Eio.Promise.create () in
  let release_lock, resolve_release_lock = Eio.Promise.create () in
  let result_a, resolve_result_a = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let hooks =
      Head.For_testing.hooks
        ~after_lock_acquired:(fun () ->
          Eio.Promise.resolve resolve_lock_acquired ();
          Eio.Promise.await release_lock)
        ()
    in
    publish_for_testing
      hooks
      ~secure_random
      ~parent:parent_a
      ~leaf
      ~expected:candidate_a
      ~row:"root-a"
    |> Eio.Promise.resolve resolve_result_a);
  Eio.Promise.await lock_acquired;
  ignore
    (publish
       ~secure_random
       ~parent:parent_b
       ~leaf
       ~expected:candidate_b
       ~row:"root-b"
       "root B while root A is locked");
  Eio.Promise.resolve resolve_release_lock ();
  Eio.Promise.await result_a |> require_publication "root A writer" |> ignore;
  read ~secure_random ~parent:parent_a ~leaf "root A final read"
  |> check_row "root A retains its authority" (Some "root-a");
  read ~secure_random ~parent:parent_b ~leaf "root B final read"
  |> check_row "root B progressed independently" (Some "root-b")
;;

let test_cross_process_lock_then_stale_cursor
      ~fs
      ~secure_random
      ~process_mgr
      ~clock
      ()
  =
  with_tmp_dir "masc_capability_head_cross_process_" @@ fun directory ->
  let leaf = "HEAD" in
  let child_row = "cross-process-winner" in
  with_parent ~fs directory @@ fun parent ->
  Eio.Time.with_timeout_exn clock cross_process_timeout_seconds (fun () ->
    let original = read ~secure_random ~parent ~leaf "cross-process initial read" in
    Eio.Switch.run @@ fun sw ->
    let child_stdin, parent_stdin = Eio.Process.pipe ~sw process_mgr in
    let parent_stdout, child_stdout = Eio.Process.pipe ~sw process_mgr in
    let child =
      Eio.Process.spawn
        ~sw
        process_mgr
        ~stdin:child_stdin
        ~stdout:child_stdout
        ~executable:Sys.executable_name
        [ Sys.executable_name
        ; cross_process_holder_arg
        ; directory
        ; leaf
        ; child_row
        ]
    in
    Eio.Flow.close child_stdin;
    Eio.Flow.close child_stdout;
    let ready = Cstruct.create 1 in
    Eio.Flow.read_exact parent_stdout ready;
    check string
      "separate process owns the stable lock"
      "R"
      (Cstruct.to_string ready);
    Head.compare_and_swap
      ~secure_random
      ~parent
      ~leaf
      ~expected:(Head.snapshot_cursor original)
      ~row:"contender-must-not-publish"
    |> require_busy "cross-process contender";
    Eio.Flow.copy_string "X" parent_stdin;
    Eio.Flow.close parent_stdin;
    Eio.Process.await_exn child;
    Eio.Flow.close parent_stdout;
    let current =
      Head.compare_and_swap
        ~secure_random
        ~parent
        ~leaf
        ~expected:(Head.snapshot_cursor original)
        ~row:"stale-cursor-must-not-publish"
      |> require_conflict "cursor after cross-process publication"
    in
    check_row
      "released child publication invalidates the original cursor"
      (Some child_row)
      current;
    read ~secure_random ~parent ~leaf "cross-process final read"
    |> check_row
         "cross-process winner remains the exact HEAD authority"
         (Some child_row))
;;

let test_parent_cancellation_after_dispatch_returns_publication
      ~fs
      ~secure_random
      ()
  =
  with_tmp_dir "masc_capability_head_parent_cancel_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  let absent = read ~secure_random ~parent ~leaf "parent cancellation fixture read" in
  let receipts = ref [] in
  let cancel_was_issued = Atomic.make false in
  Eio.Switch.run (fun sw ->
    let sub_context, resolve_sub_context = Eio.Promise.create () in
    let lock_acquired, resolve_lock_acquired = Eio.Promise.create () in
    let release_lock, resolve_release_lock = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      let context = Eio.Promise.await sub_context in
      Eio.Promise.await lock_acquired;
      Eio.Cancel.cancel
        context
        (Failure "caller cancellation after HEAD dispatch");
      Atomic.set cancel_was_issued true;
      Eio.Promise.resolve resolve_release_lock ());
    (try
       Eio.Cancel.sub (fun context ->
         Eio.Promise.resolve resolve_sub_context context;
         let hooks =
           Head.For_testing.hooks
             ~after_lock_acquired:(fun () ->
               Eio.Promise.resolve resolve_lock_acquired ();
               Eio.Promise.await release_lock)
             ()
         in
         let receipt =
           publish_for_testing
             hooks
             ~secure_random
             ~parent
             ~leaf
             ~expected:absent
             ~row:"published-after-parent-cancel"
         in
         receipts := receipt :: !receipts)
     with
     | Eio.Cancel.Cancelled _ -> ()));
  check bool
    "outer sibling issued real parent cancellation"
    true
    (Atomic.get cancel_was_issued);
  (match !receipts with
   | [ Ok publication ] ->
     Head.publication_evidence publication
     |> check_publication_evidence
          "parent cancellation publication"
          "published-after-parent-cancel"
   | [ Error _ ] ->
     fail "protected CAS returned a failure after parent cancellation"
   | [] ->
     fail "parent cancellation escaped before CAS returned a receipt"
   | _ :: _ :: _ ->
     fail "parent cancellation produced more than one CAS receipt");
  read ~secure_random ~parent ~leaf "parent cancellation final read"
  |> check_row
       "successful receipt matches published HEAD"
       (Some "published-after-parent-cancel")
;;

let test_before_rename_failure_and_cancellation_are_unchanged
      ~fs
      ~secure_random
      ()
  =
  with_tmp_dir "masc_capability_head_before_rename_" @@ fun directory ->
  with_parent ~fs directory @@ fun parent ->
  let exception_leaf = "HEAD-exception" in
  let exception_label = "before-rename exception" in
  let absent = read ~secure_random ~parent ~leaf:exception_leaf (exception_label ^ " read") in
  let hooks = Head.For_testing.hooks ~before_rename:(fun () -> raise Exit) () in
  publish_for_testing
    hooks
    ~secure_random
    ~parent
    ~leaf:exception_leaf
    ~expected:absent
    ~row:"must-not-publish"
  |> require_unchanged_failure exception_label;
  read ~secure_random ~parent ~leaf:exception_leaf (exception_label ^ " final read")
  |> check_row (exception_label ^ " keeps HEAD absent") None;
  let cancellation_leaf = "HEAD-cancellation" in
  let cancellation_label = "before-rename injected Cancelled exception" in
  let absent =
    read ~secure_random ~parent ~leaf:cancellation_leaf (cancellation_label ^ " read")
  in
  let hooks =
    Head.For_testing.hooks
      ~before_rename:(fun () ->
        raise
          (Eio.Cancel.Cancelled
             (Failure "injected before-rename cancellation")))
      ()
  in
  (match
     publish_for_testing
       hooks
       ~secure_random
       ~parent
       ~leaf:cancellation_leaf
       ~expected:absent
       ~row:"must-not-publish"
   with
   | exception Eio.Cancel.Cancelled _ -> ()
   | _ -> Alcotest.fail "pre-publication cancellation was swallowed");
  read ~secure_random ~parent ~leaf:cancellation_leaf (cancellation_label ^ " final read")
  |> check_row (cancellation_label ^ " keeps HEAD absent") None
;;

let test_after_rename_failure_is_indeterminate ~fs ~secure_random () =
  with_tmp_dir "masc_capability_head_after_rename_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  let absent = read ~secure_random ~parent ~leaf "after-rename fixture read" in
  let hooks =
    Head.For_testing.hooks ~after_rename:(fun () -> raise Exit) ()
  in
  let evidence =
    publish_for_testing
      hooks
      ~secure_random
      ~parent
      ~leaf
      ~expected:absent
      ~row:"renamed-row"
    |> require_indeterminate_failure "after-rename exception"
  in
  check int64
    "indeterminate evidence retains intended length"
    (Int64.of_int (String.length "renamed-row" + 1))
    evidence.Head.intended_length;
  check int
    "indeterminate evidence retains intended SHA-256"
    64
    (String.length evidence.Head.intended_sha256)
;;

let test_after_parent_sync_failure_is_indeterminate_but_visible
      ~fs
      ~secure_random
      ()
  =
  with_tmp_dir "masc_capability_head_after_parent_sync_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  let absent = read ~secure_random ~parent ~leaf "parent-sync fixture read" in
  let hooks =
    Head.For_testing.hooks ~after_parent_sync:(fun () -> raise Exit) ()
  in
  let evidence =
    publish_for_testing
      hooks
      ~secure_random
      ~parent
      ~leaf
      ~expected:absent
      ~row:"parent-synced-row"
    |> require_indeterminate_failure "after-parent-sync exception"
  in
  check int64
    "parent-sync indeterminate evidence retains intended length"
    (Int64.of_int (String.length "parent-synced-row" + 1))
    evidence.Head.intended_length;
  check int
    "parent-sync indeterminate evidence retains intended SHA-256"
    64
    (String.length evidence.Head.intended_sha256);
  read ~secure_random ~parent ~leaf "after-parent-sync exact read"
  |> check_row
       "exact read observes the parent-synced row"
       (Some "parent-synced-row")
;;

let test_after_verified_failure_reports_published ~fs ~secure_random () =
  with_tmp_dir "masc_capability_head_after_verified_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  let absent = read ~secure_random ~parent ~leaf "after-verified fixture read" in
  let hooks =
    Head.For_testing.hooks ~after_verified:(fun () -> raise Exit) ()
  in
  publish_for_testing
    hooks
    ~secure_random
    ~parent
    ~leaf
    ~expected:absent
    ~row:"published-row"
  |> require_published_failure "after-verified exception"
  |> check_publication_evidence "after-verified exception" "published-row";
  read ~secure_random ~parent ~leaf "after-verified final read"
  |> check_row "published effect matches durable authority" (Some "published-row")
;;

let test_resource_settlement_warning_preserves_success ~fs ~secure_random () =
  with_tmp_dir "masc_capability_head_settlement_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  let absent = read ~secure_random ~parent ~leaf "settlement fixture read" in
  let hooks =
    Head.For_testing.hooks
      ~on_resource_settlement:(fun () -> raise Exit)
      ()
  in
  let publication =
    publish_for_testing
      hooks
      ~secure_random
      ~parent
      ~leaf
      ~expected:absent
      ~row:"settled-row"
    |> require_publication "resource settlement"
  in
  (match Head.publication_settlement_warnings publication with
   | [ Head.Resource_settlement_failed
         ({ operation = Head.Settle_resources; _ } : Head.diagnostic) ] ->
     ()
   | [] -> fail "resource-settlement failure was silently dropped"
   | _ ->
     fail
       "resource settlement did not produce exactly one typed Settle_resources warning");
  Head.publication_evidence publication
  |> check_publication_evidence "resource settlement" "settled-row";
  read ~secure_random ~parent ~leaf "resource settlement final read"
  |> check_row "settlement warning does not hide publication" (Some "settled-row")
;;

let test_pre_publication_fatal_preserves_backtrace_and_disk
      ~fs
      ~secure_random
      ()
  =
  with_tmp_dir "masc_capability_head_pre_fatal_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  let absent = read ~secure_random ~parent ~leaf "pre-publication fatal fixture" in
  let captured = ref None in
  let hooks =
    Head.For_testing.hooks
      ~before_rename:(fun () ->
        raise_with_captured_backtrace captured Sys.Break)
      ()
  in
  require_original_fatal_backtrace
    ~label:"pre-publication Sys.Break"
    ~expected:Sys.Break
    ~captured
    (fun () ->
      publish_for_testing
        hooks
        ~secure_random
        ~parent
        ~leaf
        ~expected:absent
        ~row:"must-not-publish");
  read ~secure_random ~parent ~leaf "pre-publication fatal final read"
  |> check_row "pre-publication fatal leaves HEAD absent" None;
  check bool
    "pre-publication fatal cleans its private stage"
    false
    (directory_entries directory
     |> List.exists (String.starts_with ~prefix:".masc-capability-head-stage-"))
;;

let test_post_rename_fatal_preserves_backtrace_and_disk
      ~fs
      ~secure_random
      ()
  =
  with_tmp_dir "masc_capability_head_post_fatal_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  let absent = read ~secure_random ~parent ~leaf "post-rename fatal fixture" in
  let captured = ref None in
  let hooks =
    Head.For_testing.hooks
      ~after_rename:(fun () ->
        raise_with_captured_backtrace captured Out_of_memory)
      ()
  in
  require_original_fatal_backtrace
    ~label:"post-rename Out_of_memory"
    ~expected:Out_of_memory
    ~captured
    (fun () ->
      publish_for_testing
        hooks
        ~secure_random
        ~parent
        ~leaf
        ~expected:absent
        ~row:"renamed-before-fatal");
  read ~secure_random ~parent ~leaf "post-rename fatal final read"
  |> check_row
       "post-rename fatal does not erase the visible HEAD effect"
       (Some "renamed-before-fatal")
;;

let test_settlement_fatal_preserves_backtrace_and_disk
      ~fs
      ~secure_random
      ()
  =
  with_tmp_dir "masc_capability_head_settlement_fatal_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  let absent = read ~secure_random ~parent ~leaf "settlement fatal fixture" in
  let captured = ref None in
  let hooks =
    Head.For_testing.hooks
      ~on_resource_settlement:(fun () ->
        raise_with_captured_backtrace captured Stack_overflow)
      ()
  in
  require_original_fatal_backtrace
    ~label:"settlement Stack_overflow"
    ~expected:Stack_overflow
    ~captured
    (fun () ->
      publish_for_testing
        hooks
        ~secure_random
        ~parent
        ~leaf
        ~expected:absent
        ~row:"durable-before-settlement-fatal");
  read ~secure_random ~parent ~leaf "settlement fatal final read"
  |> check_row
       "settlement fatal does not erase the durable HEAD effect"
       (Some "durable-before-settlement-fatal")
;;

let () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let secure_random = Eio.Stdenv.secure_random env in
  let process_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  run
    "fs_compat capability HEAD"
    [ ( "authority"
      , [ test_case "absent publish and reopen" `Quick
            (test_absent_publish_and_reopen ~fs ~secure_random)
        ; test_case "stale cursor conflicts without mutation" `Quick
            (test_stale_cursor_conflicts_without_mutation ~fs ~secure_random)
        ; test_case "cross-root absent cursor conflicts" `Quick
            (test_cross_root_absent_cursor_conflicts ~fs ~secure_random)
        ; test_case "strict one-row shape" `Quick
            (test_strict_row_shape_rejection ~fs ~secure_random)
        ; test_case "reserved namespace rejected before dispatch" `Quick
            (test_reserved_namespace_is_rejected_before_dispatch ~fs)
        ; test_case "lock entropy EOF is unchanged and recoverable" `Quick
            (test_first_read_entropy_eof_is_unchanged_and_recoverable
               ~fs
               ~secure_random)
        ; test_case "stage entropy EOF is unchanged" `Quick
            (test_stage_entropy_eof_is_unchanged ~fs ~secure_random)
        ] )
    ; ( "concurrency"
      , [ test_case "same-directory contention is busy" `Quick
            (test_same_directory_contention_is_busy ~fs ~secure_random)
        ; test_case "different roots do not false-share" `Quick
            (test_different_roots_do_not_false_share ~fs ~secure_random)
        ; test_case "cross-process lock and stale cursor" `Quick
            (test_cross_process_lock_then_stale_cursor
               ~fs
               ~secure_random
               ~process_mgr
               ~clock)
        ; test_case "parent cancellation after dispatch publishes once" `Quick
            (test_parent_cancellation_after_dispatch_returns_publication
               ~fs
               ~secure_random)
        ] )
    ; ( "publication-boundary"
      , [ test_case "before rename stays unchanged" `Quick
            (test_before_rename_failure_and_cancellation_are_unchanged
               ~fs
               ~secure_random)
        ; test_case "after rename is indeterminate" `Quick
            (test_after_rename_failure_is_indeterminate ~fs ~secure_random)
        ; test_case "after parent sync is indeterminate but visible" `Quick
            (test_after_parent_sync_failure_is_indeterminate_but_visible
               ~fs
               ~secure_random)
        ; test_case "after verified is published" `Quick
            (test_after_verified_failure_reports_published ~fs ~secure_random)
        ; test_case "settlement warning preserves success" `Quick
            (test_resource_settlement_warning_preserves_success
               ~fs
               ~secure_random)
        ; test_case "pre-publication fatal preserves backtrace and disk" `Quick
            (test_pre_publication_fatal_preserves_backtrace_and_disk
               ~fs
               ~secure_random)
        ; test_case "post-rename fatal preserves backtrace and disk" `Quick
            (test_post_rename_fatal_preserves_backtrace_and_disk
               ~fs
               ~secure_random)
        ; test_case "settlement fatal preserves backtrace and disk" `Quick
            (test_settlement_fatal_preserves_backtrace_and_disk
               ~fs
               ~secure_random)
        ] )
    ]
;;
