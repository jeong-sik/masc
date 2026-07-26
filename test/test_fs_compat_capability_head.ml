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

let require_read label = function
  | Ok snapshot -> snapshot
  | Error _ -> failf "%s: HEAD read failed" label
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

let read ~parent ~leaf label =
  Head.read ~parent ~leaf |> require_read label
;;

let publish ~parent ~leaf ~expected ~row label =
  Head.compare_and_swap
    ~parent
    ~leaf
    ~expected:(Head.snapshot_cursor expected)
    ~row
  |> require_publication label
;;

let check_row label expected snapshot =
  check (option string) label expected (Head.snapshot_row snapshot)
;;

let test_absent_publish_and_reopen ~fs () =
  with_tmp_dir "masc_capability_head_reopen_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory (fun parent ->
    let absent = read ~parent ~leaf "initial absent read" in
    check_row "fresh HEAD is absent" None absent;
    let publication =
      publish
        ~parent
        ~leaf
        ~expected:absent
        ~row:"manifest-v1"
        "initial publication"
    in
    ignore (Head.publication_cursor publication));
  with_parent ~fs directory (fun reopened_parent ->
    let reopened = read ~parent:reopened_parent ~leaf "reopened read" in
    check_row "reopened HEAD observes first row" (Some "manifest-v1") reopened;
    ignore
      (publish
         ~parent:reopened_parent
         ~leaf
         ~expected:reopened
         ~row:"manifest-v2"
         "publication after reopen"));
  with_parent ~fs directory (fun final_parent ->
    read ~parent:final_parent ~leaf "final reopened read"
    |> check_row "second publication remains authoritative" (Some "manifest-v2"))
;;

let test_stale_cursor_conflicts_without_mutation ~fs () =
  with_tmp_dir "masc_capability_head_stale_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  let absent = read ~parent ~leaf "stale fixture read" in
  ignore
    (publish
       ~parent
       ~leaf
       ~expected:absent
       ~row:"winner"
       "winner publication");
  let current =
    Head.compare_and_swap
      ~parent
      ~leaf
      ~expected:(Head.snapshot_cursor absent)
      ~row:"stale-overwrite"
    |> require_conflict "stale publication"
  in
  check_row "conflict carries current authority" (Some "winner") current;
  read ~parent ~leaf "read after stale conflict"
  |> check_row "stale attempt leaves authority unchanged" (Some "winner")
;;

let test_cross_root_absent_cursor_conflicts ~fs () =
  with_tmp_dir "masc_capability_head_cursor_a_" @@ fun directory_a ->
  with_tmp_dir "masc_capability_head_cursor_b_" @@ fun directory_b ->
  let leaf = "HEAD" in
  with_parent ~fs directory_a @@ fun parent_a ->
  with_parent ~fs directory_b @@ fun parent_b ->
  let foreign = read ~parent:parent_a ~leaf "root A absent read" in
  check_row "root A is absent" None foreign;
  let current =
    Head.compare_and_swap
      ~parent:parent_b
      ~leaf
      ~expected:(Head.snapshot_cursor foreign)
      ~row:"must-not-cross-roots"
    |> require_conflict "cross-root publication"
  in
  check_row "foreign cursor conflict reports root B absent" None current;
  read ~parent:parent_b ~leaf "root B after foreign cursor"
  |> check_row "foreign cursor cannot create root B HEAD" None
;;

let test_strict_row_shape_rejection ~fs () =
  with_tmp_dir "masc_capability_head_row_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent ->
  List.iter
    (fun (label, row) ->
       let absent = read ~parent ~leaf (label ^ " pre-read") in
       check_row (label ^ " keeps HEAD absent before CAS") None absent;
       Head.compare_and_swap
         ~parent
         ~leaf
         ~expected:(Head.snapshot_cursor absent)
         ~row
       |> require_invalid_row label;
       read ~parent ~leaf (label ^ " post-read")
       |> check_row (label ^ " leaves HEAD absent") None)
    [ "empty row", ""
    ; "LF-only row", "\n"
    ; "LF-terminated row", "row\n"
    ; "CRLF row", "row\r\n"
    ; "embedded LF row", "left\nright"
    ];
  let absent = read ~parent ~leaf "valid row pre-read" in
  ignore
    (publish
       ~parent
       ~leaf
       ~expected:absent
       ~row:"valid-row"
       "valid row after rejections");
  read ~parent ~leaf "valid row post-read"
  |> check_row "invalid attempts do not poison later publication" (Some "valid-row")
;;

let test_independent_same_directory_handles_have_one_winner ~fs () =
  with_tmp_dir "masc_capability_head_handles_" @@ fun directory ->
  let leaf = "HEAD" in
  with_parent ~fs directory @@ fun parent_a ->
  with_parent ~fs directory @@ fun parent_b ->
  let candidate_a = read ~parent:parent_a ~leaf "handle A absent read" in
  let candidate_b = read ~parent:parent_b ~leaf "handle B absent read" in
  check_row "handle A observes absent HEAD" None candidate_a;
  check_row "handle B observes the same absent generation" None candidate_b;
  ignore
    (publish
       ~parent:parent_a
       ~leaf
       ~expected:candidate_a
       ~row:"handle-a-wins"
       "handle A publication");
  let current =
    Head.compare_and_swap
      ~parent:parent_b
      ~leaf
      ~expected:(Head.snapshot_cursor candidate_b)
      ~row:"handle-b-must-lose"
    |> require_conflict "handle B publication"
  in
  check_row "losing handle receives winning authority" (Some "handle-a-wins") current;
  read ~parent:parent_b ~leaf "losing handle final read"
  |> check_row "only the first candidate published" (Some "handle-a-wins")
;;

let test_different_roots_do_not_false_share ~fs () =
  with_tmp_dir "masc_capability_head_root_a_" @@ fun directory_a ->
  with_tmp_dir "masc_capability_head_root_b_" @@ fun directory_b ->
  let leaf = "HEAD" in
  with_parent ~fs directory_a @@ fun parent_a ->
  with_parent ~fs directory_b @@ fun parent_b ->
  let absent_a = read ~parent:parent_a ~leaf "root A read" in
  let absent_b = read ~parent:parent_b ~leaf "root B read" in
  ignore
    (publish
       ~parent:parent_a
       ~leaf
       ~expected:absent_a
       ~row:"root-a"
       "root A publication");
  ignore
    (publish
       ~parent:parent_b
       ~leaf
       ~expected:absent_b
       ~row:"root-b"
       "root B publication");
  read ~parent:parent_a ~leaf "root A final read"
  |> check_row "root A retains its own authority" (Some "root-a");
  read ~parent:parent_b ~leaf "root B final read"
  |> check_row "root B retains its own authority" (Some "root-b")
;;

let () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  run
    "fs_compat capability HEAD"
    [ ( "authority"
      , [ test_case "absent publish and reopen" `Quick
            (test_absent_publish_and_reopen ~fs)
        ; test_case "stale cursor conflicts without mutation" `Quick
            (test_stale_cursor_conflicts_without_mutation ~fs)
        ; test_case "cross-root absent cursor conflicts" `Quick
            (test_cross_root_absent_cursor_conflicts ~fs)
        ; test_case "strict one-row shape" `Quick
            (test_strict_row_shape_rejection ~fs)
        ; test_case "independent same-directory handles have one winner" `Quick
            (test_independent_same_directory_handles_have_one_winner ~fs)
        ; test_case "different roots do not false-share" `Quick
            (test_different_roots_do_not_false_share ~fs)
        ] )
    ]
;;
