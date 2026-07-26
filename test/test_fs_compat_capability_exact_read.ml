open Alcotest

module Public = Fs_compat.Capability_exact_read

module Test_read =
  Fs_compat_test_support.Capability_exact_read_for_testing

module For_testing = Test_read.For_testing

let _public_read_signature
  :  parent:Eio.Fs.dir_ty Eio.Path.t
  -> leaf:string
  -> expected_length:int64
  -> max_length:int64
  -> (Public.observation, Public.failure) result
  =
  Public.read
;;

let fifo_helper_flag = "--capability-exact-read-fifo-helper"
let fatal_callback_helper_flag =
  "--capability-exact-read-fatal-callback-helper"
let fatal_settlement_helper_flag =
  "--capability-exact-read-fatal-settlement-helper"

let rec remove_tree path =
  match Unix.lstat path with
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_DIR ->
       Sys.readdir path
       |> Array.iter (fun leaf ->
         remove_tree (Filename.concat path leaf));
       Unix.rmdir path
     | _ -> Unix.unlink path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let fresh_directory prefix =
  let path = Filename.temp_file prefix ".tmp" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;

let with_directory ~fs prefix fn =
  let root = fresh_directory prefix in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let parent = Eio.Path.(fs / root) in
      fn root parent)
;;

let write_file ?(mode = 0o600) path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents);
  Unix.chmod path mode
;;

let append_file path contents =
  let channel =
    open_out_gen
      [ Open_wronly; Open_append; Open_binary ]
      0
      path
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)
;;

let require_success label
    (result : (Test_read.observation, Test_read.failure) result)
  =
  match result with
  | Ok observation -> observation
  | Error _ -> failf "%s: expected success" label
;;

let require_failure label
    (result : (Test_read.observation, Test_read.failure) result)
  =
  match result with
  | Error failure -> failure
  | Ok _ -> failf "%s: expected failure" label
;;

let check_error label predicate result =
  let failure = require_failure label result in
  check bool label true (predicate failure.error);
  failure
;;

let operation_token = function
  | Test_read.Pin_parent -> "pin_parent"
  | Open_parent_descriptor -> "open_parent_descriptor"
  | Open_leaf -> "open_leaf"
  | Inspect_opened -> "inspect_opened"
  | Allocate -> "allocate"
  | Read_exact -> "read_exact"
  | Inspect_after_read -> "inspect_after_read"
  | Close_leaf -> "close_leaf"
  | Settle_parent_resources -> "settle_parent_resources"
  | Observe_parent_cancellation -> "observe_parent_cancellation"
;;

let warning_token = function
  | Test_read.Close_failed diagnostic ->
    "close:" ^ operation_token diagnostic.operation
  | Settle_resources diagnostic ->
    "settle:" ^ operation_token diagnostic.operation
;;

let check_warnings label expected warnings =
  let actual = List.map warning_token warnings in
  check
    int
    (label ^ " cardinality")
    (List.length expected)
    (List.length actual);
  check
    (list string)
    (label ^ " multiset")
    (List.sort String.compare expected)
    (List.sort String.compare actual)
;;

let test_pre_dispatch_validation ~fs () =
  with_directory ~fs "cap_exact_validate_" @@ fun _root parent ->
  let opened = ref 0 in
  let allocated = ref 0 in
  let hooks =
    For_testing.hooks
      ~before_open:(fun () -> incr opened)
      ~before_allocate:(fun () -> incr allocated)
      ()
  in
  let read ~leaf ~expected_length ~max_length =
    For_testing.read
      ~hooks
      ~parent
      ~leaf
      ~expected_length
      ~max_length
  in
  ignore
    (check_error
       "invalid leaf"
       (function
         | Test_read.Invalid_leaf "../escape" -> true
         | _ -> false)
       (read ~leaf:"../escape" ~expected_length:0L ~max_length:0L));
  ignore
    (check_error
       "negative expected length"
       (function
         | Test_read.Invalid_length_bounds
             { expected_length = -1L; max_length = 0L } ->
           true
         | _ -> false)
       (read ~leaf:"object" ~expected_length:(-1L) ~max_length:0L));
  ignore
    (check_error
       "expected exceeds max"
       (function
         | Test_read.Invalid_length_bounds
             { expected_length = 2L; max_length = 1L } ->
           true
         | _ -> false)
       (read ~leaf:"object" ~expected_length:2L ~max_length:1L));
  let unrepresentable =
    Int64.succ (Int64.of_int Sys.max_string_length)
  in
  ignore
    (check_error
       "representation bound"
       (function
         | Test_read.Length_not_representable observed ->
           Int64.equal observed unrepresentable
         | _ -> false)
       (read
          ~leaf:"object"
          ~expected_length:unrepresentable
          ~max_length:unrepresentable));
  check int "no leaf open dispatched" 0 !opened;
  check int "no allocation dispatched" 0 !allocated
;;

let test_exact_success ~fs () =
  with_directory ~fs "cap_exact_success_" @@ fun root parent ->
  let payload = "exact immutable bytes" in
  write_file (Filename.concat root "object") payload;
  match
    Public.read
      ~parent
      ~leaf:"object"
      ~expected_length:(Int64.of_int (String.length payload))
      ~max_length:1024L
  with
  | Error _ -> fail "exact public read failed"
  | Ok observation ->
    check
      string
      "exact bytes"
      payload
      (Public.observation_bytes observation);
    check
      int64
      "exact length"
      (Int64.of_int (String.length payload))
      (Public.observation_length observation);
    check
      int
      "no settlement warning"
      0
      (List.length
         (Public.observation_settlement_warnings observation))
;;

let test_missing ~fs () =
  with_directory ~fs "cap_exact_missing_" @@ fun _root parent ->
  let failure =
    check_error
      "missing"
      (function
        | Test_read.Missing -> true
        | _ -> false)
      (Test_read.read
         ~parent
         ~leaf:"absent"
         ~expected_length:0L
         ~max_length:0L)
  in
  check_warnings
    "missing has no settlement warning"
    []
    failure.settlement_warnings
;;

let run_fifo_helper root leaf =
  Eio_main.run @@ fun env ->
  let parent = Eio.Path.(Eio.Stdenv.fs env / root) in
  match
    Public.read
      ~parent
      ~leaf
      ~expected_length:0L
      ~max_length:0L
  with
  | Error failure ->
    (match failure.error with
     | Public.Not_regular Unix.S_FIFO -> 0
     | _ -> 2)
  | Ok _ -> 3
;;

let run_fatal_helper ~settlement root leaf =
  Printexc.record_backtrace true;
  let injected_backtrace = ref None in
  let inject_fatal () =
    match raise Sys.Break with
    | exception Sys.Break ->
      let backtrace = Printexc.get_raw_backtrace () in
      injected_backtrace := Some backtrace;
      Printexc.raise_with_backtrace Sys.Break backtrace
    | _ -> Alcotest.fail "fatal injection unexpectedly returned"
  in
  try
    Eio_main.run @@ fun env ->
    let parent = Eio.Path.(Eio.Stdenv.fs env / root) in
    let hooks =
      if settlement
      then For_testing.hooks ~on_settle_resources:inject_fatal ()
      else For_testing.hooks ~after_open_stat:inject_fatal ()
    in
    ignore
      (For_testing.read
         ~hooks
         ~parent
         ~leaf
         ~expected_length:4L
         ~max_length:4L);
    2
  with
  | Sys.Break ->
    let observed = Printexc.get_raw_backtrace () in
    (match !injected_backtrace with
     | None -> 3
     | Some expected ->
       let expected = Printexc.raw_backtrace_to_string expected in
       let observed = Printexc.raw_backtrace_to_string observed in
       if
         not (String.equal expected "")
         && String.equal expected observed
       then 0
       else 4)
  | _ -> 5
;;

let run_helper_if_requested () =
  if Array.length Sys.argv = 4 then
    let flag = Sys.argv.(1) in
    let root = Sys.argv.(2) in
    let leaf = Sys.argv.(3) in
    if String.equal flag fifo_helper_flag then
      exit (run_fifo_helper root leaf)
    else if String.equal flag fatal_callback_helper_flag then
      exit (run_fatal_helper ~settlement:false root leaf)
    else if String.equal flag fatal_settlement_helper_flag then
      exit (run_fatal_helper ~settlement:true root leaf)
;;

let run_self_helper ~clock ~process_mgr ~flag root leaf =
  Eio.Switch.run @@ fun sw ->
  let executable = Unix.realpath Sys.executable_name in
  let child =
    Eio.Process.spawn
      ~sw
      process_mgr
      [ executable; flag; root; leaf ]
  in
  Eio.Time.with_timeout_exn clock 3.0 (fun () ->
    Eio.Process.await child)
;;

let require_helper_success label = function
  | `Exited 0 -> ()
  | `Exited code ->
    failf "%s helper exited with code %d" label code
  | `Signaled signal ->
    failf "%s helper was signaled: %d" label signal
;;

let test_special_files
    ~fs
    ~clock
    ~process_mgr
    ()
  =
  with_directory ~fs "cap_exact_special_" @@ fun root parent ->
  let target = Filename.concat root "target" in
  let symlink = Filename.concat root "symlink" in
  let directory = Filename.concat root "directory" in
  let fifo = Filename.concat root "fifo" in
  write_file target "target";
  Unix.symlink target symlink;
  Unix.mkdir directory 0o700;
  Unix.mkfifo fifo 0o600;
  let symlink_result =
    Eio.Time.with_timeout_exn clock 2.0 (fun () ->
      Test_read.read
        ~parent
        ~leaf:"symlink"
        ~expected_length:6L
        ~max_length:6L)
  in
  ignore
    (check_error
       "symlink is not followed"
       (function
         | Test_read.Symbolic_link -> true
         | _ -> false)
       symlink_result);
  let directory_result =
    Eio.Time.with_timeout_exn clock 2.0 (fun () ->
      Test_read.read
        ~parent
        ~leaf:"directory"
        ~expected_length:0L
        ~max_length:0L)
  in
  ignore
    (check_error
       "directory is rejected"
       (function
         | Test_read.Not_regular Unix.S_DIR -> true
         | _ -> false)
       directory_result);
  run_self_helper
    ~clock
    ~process_mgr
    ~flag:fifo_helper_flag
    root
    "fifo"
  |> require_helper_success "FIFO"
;;

let test_wrong_mode_and_link_count ~fs () =
  with_directory ~fs "cap_exact_metadata_" @@ fun root parent ->
  let wrong_mode = Filename.concat root "wrong-mode" in
  write_file ~mode:0o644 wrong_mode "mode";
  ignore
    (check_error
       "wrong mode"
       (function
         | Test_read.Unsafe_mode 0o644 -> true
         | _ -> false)
       (Test_read.read
          ~parent
          ~leaf:"wrong-mode"
          ~expected_length:4L
          ~max_length:4L));
  let source = Filename.concat root "source" in
  let linked = Filename.concat root "linked" in
  write_file source "link";
  Unix.link source linked;
  ignore
    (check_error
       "multiple hard links"
       (function
         | Test_read.Unsafe_link_count 2 -> true
         | _ -> false)
       (Test_read.read
          ~parent
          ~leaf:"linked"
          ~expected_length:4L
          ~max_length:4L))
;;

let test_length_failures_precede_allocation ~fs () =
  with_directory ~fs "cap_exact_lengths_" @@ fun root parent ->
  write_file (Filename.concat root "object") "four";
  let allocations = ref 0 in
  let hooks =
    For_testing.hooks
      ~before_allocate:(fun () -> incr allocations)
      ()
  in
  let read expected_length max_length =
    For_testing.read
      ~hooks
      ~parent
      ~leaf:"object"
      ~expected_length
      ~max_length
  in
  ignore
    (check_error
       "declared shorter"
       (function
         | Test_read.Length_mismatch
             { expected_length = 3L; observed_length = 4L } ->
           true
         | _ -> false)
       (read 3L 8L));
  ignore
    (check_error
       "declared longer"
       (function
         | Test_read.Length_mismatch
             { expected_length = 5L; observed_length = 4L } ->
           true
         | _ -> false)
       (read 5L 8L));
  ignore
    (check_error
       "observed exceeds max"
       (function
         | Test_read.Length_exceeds_max
             { max_length = 3L; observed_length = 4L } ->
           true
         | _ -> false)
       (read 3L 3L));
  check int "no allocation after stat rejection" 0 !allocations
;;

let test_after_stat_mutations ~fs () =
  with_directory ~fs "cap_exact_mutations_" @@ fun root parent ->
  let shrink = Filename.concat root "shrink" in
  write_file shrink "four";
  let shrink_hooks =
    For_testing.hooks
      ~after_open_stat:(fun () -> Unix.truncate shrink 2)
      ()
  in
  ignore
    (check_error
       "post-stat shrink"
       (function
         | Test_read.Changed_during_read -> true
         | _ -> false)
       (For_testing.read
          ~hooks:shrink_hooks
          ~parent
          ~leaf:"shrink"
          ~expected_length:4L
          ~max_length:4L));
  let grow = Filename.concat root "grow" in
  write_file grow "four";
  let grow_hooks =
    For_testing.hooks
      ~after_open_stat:(fun () -> append_file grow "!")
      ()
  in
  ignore
    (check_error
       "post-stat grow"
       (function
         | Test_read.Changed_during_read -> true
         | _ -> false)
       (For_testing.read
          ~hooks:grow_hooks
          ~parent
          ~leaf:"grow"
          ~expected_length:4L
          ~max_length:4L));
  let target = Filename.concat root "rename-target" in
  let replacement = Filename.concat root "replacement" in
  write_file target "old!";
  write_file replacement "new!";
  let rename_hooks =
    For_testing.hooks
      ~after_open_stat:(fun () -> Unix.rename replacement target)
      ()
  in
  ignore
    (check_error
       "rename-over never adopts replacement bytes"
       (function
         | Test_read.Changed_during_read -> true
         | _ -> false)
       (For_testing.read
          ~hooks:rename_hooks
          ~parent
          ~leaf:"rename-target"
          ~expected_length:4L
          ~max_length:4L))
;;

let test_post_read_metadata_drift ~fs () =
  with_directory ~fs "cap_exact_post_stat_" @@ fun root parent ->
  let chmod_path = Filename.concat root "chmod" in
  write_file chmod_path "four";
  let chmod_hooks =
    For_testing.hooks
      ~after_exact_read:(fun () -> Unix.chmod chmod_path 0o640)
      ()
  in
  ignore
    (check_error
       "post-read mode drift"
       (function
         | Test_read.Changed_during_read -> true
         | _ -> false)
       (For_testing.read
          ~hooks:chmod_hooks
          ~parent
          ~leaf:"chmod"
          ~expected_length:4L
          ~max_length:4L));
  let link_path = Filename.concat root "link-source" in
  let added_link = Filename.concat root "added-link" in
  write_file link_path "four";
  let link_hooks =
    For_testing.hooks
      ~after_exact_read:(fun () -> Unix.link link_path added_link)
      ()
  in
  ignore
    (check_error
       "post-read link-count drift"
       (function
         | Test_read.Changed_during_read -> true
         | _ -> false)
       (For_testing.read
          ~hooks:link_hooks
          ~parent
          ~leaf:"link-source"
          ~expected_length:4L
          ~max_length:4L))
;;

let test_pinned_parent_path_swap ~fs () =
  with_directory ~fs "cap_exact_parent_swap_" @@ fun root _outer ->
  let live_parent = Filename.concat root "objects" in
  let moved_parent = Filename.concat root "objects-pinned" in
  Unix.mkdir live_parent 0o700;
  write_file (Filename.concat live_parent "object") "owned";
  let parent = Eio.Path.(fs / live_parent) in
  let hooks =
    For_testing.hooks
      ~before_open:(fun () ->
        Unix.rename live_parent moved_parent;
        Unix.mkdir live_parent 0o700;
        write_file (Filename.concat live_parent "object") "trap!")
      ()
  in
  let observation =
    require_success
      "pinned parent"
      (For_testing.read
         ~hooks
         ~parent
         ~leaf:"object"
         ~expected_length:5L
         ~max_length:5L)
  in
  check
    string
    "old pinned parent remains authoritative"
    "owned"
    (Test_read.observation_bytes observation)
;;

let test_leaf_close_warnings ~fs () =
  with_directory ~fs "cap_exact_leaf_close_" @@ fun root parent ->
  let success_path = Filename.concat root "success" in
  write_file success_path "okay";
  let success_hooks =
    For_testing.hooks
      ~on_close:(fun () -> raise (Failure "injected leaf close"))
      ()
  in
  let observation =
    require_success
      "success with close warning"
      (For_testing.read
         ~hooks:success_hooks
         ~parent
         ~leaf:"success"
         ~expected_length:4L
         ~max_length:4L)
  in
  check string "successful bytes retained" "okay"
    (Test_read.observation_bytes observation);
  check_warnings
    "successful close warning"
    [ "close:close_leaf" ]
    (Test_read.observation_settlement_warnings observation);
  let failure_path = Filename.concat root "failure" in
  write_file failure_path "four";
  let failure_hooks =
    For_testing.hooks
      ~after_open_stat:(fun () -> Unix.truncate failure_path 2)
      ~on_close:(fun () -> raise (Failure "injected leaf close"))
      ()
  in
  let failure =
    check_error
      "primary read failure retained"
      (function
        | Test_read.Changed_during_read -> true
        | _ -> false)
      (For_testing.read
         ~hooks:failure_hooks
         ~parent
         ~leaf:"failure"
         ~expected_length:4L
         ~max_length:4L)
  in
  check_warnings
    "failure close warning"
    [ "close:close_leaf" ]
    failure.settlement_warnings
;;

let test_hook_failures_preserve_close_warning ~fs () =
  with_directory ~fs "cap_exact_hook_failure_" @@ fun root parent ->
  let generic_path = Filename.concat root "generic" in
  write_file generic_path "four";
  let generic_hooks =
    For_testing.hooks
      ~after_open_stat:(fun () ->
        raise (Failure "injected callback failure"))
      ~on_close:(fun () -> raise (Failure "injected leaf close"))
      ()
  in
  let generic_failure =
    check_error
      "generic hook failure"
      (function
        | Test_read.Io_error
            { operation = Test_read.Inspect_opened; _ } ->
          true
        | _ -> false)
      (For_testing.read
         ~hooks:generic_hooks
         ~parent
         ~leaf:"generic"
         ~expected_length:4L
         ~max_length:4L)
  in
  check_warnings
    "generic hook close warning"
    [ "close:close_leaf" ]
    generic_failure.settlement_warnings;
  let cancelled_path = Filename.concat root "cancelled" in
  write_file cancelled_path "four";
  let cancelled_hooks =
    For_testing.hooks
      ~after_open_stat:(fun () ->
        raise
          (Eio.Cancel.Cancelled
             (Failure "injected callback cancellation")))
      ~on_close:(fun () -> raise (Failure "injected leaf close"))
      ()
  in
  let cancelled_failure =
    check_error
      "explicit hook cancellation"
      (function
        | Test_read.Cancelled
            { operation = Test_read.Inspect_opened; _ } ->
          true
        | _ -> false)
      (For_testing.read
         ~hooks:cancelled_hooks
         ~parent
         ~leaf:"cancelled"
         ~expected_length:4L
         ~max_length:4L)
  in
  check_warnings
    "cancelled hook close warning"
    [ "close:close_leaf" ]
    cancelled_failure.settlement_warnings
;;

let test_pending_cancellation_prevents_dispatch ~fs () =
  with_directory ~fs "cap_exact_pending_cancel_" @@ fun root parent ->
  write_file (Filename.concat root "object") "four";
  let opened = ref 0 in
  let allocated = ref 0 in
  let hooks =
    For_testing.hooks
      ~before_open:(fun () -> incr opened)
      ~before_allocate:(fun () -> incr allocated)
      ()
  in
  let outcome =
    Eio.Cancel.sub @@ fun cancellation ->
    Eio.Cancel.cancel
      cancellation
      (Failure "cancel before exact read");
    match
      For_testing.read
        ~hooks
        ~parent
        ~leaf:"object"
        ~expected_length:4L
        ~max_length:4L
    with
    | _ -> `Returned
    | exception Eio.Cancel.Cancelled _ -> `Cancelled
  in
  check
    string
    "pending cancellation raised"
    "cancelled"
    (match outcome with
     | `Cancelled -> "cancelled"
     | `Returned -> "returned");
  check int "pending cancellation dispatched no open" 0 !opened;
  check int "pending cancellation allocated nothing" 0 !allocated
;;

let test_parent_cancellation_after_dispatch ~fs () =
  with_directory ~fs "cap_exact_cancel_" @@ fun root parent ->
  write_file (Filename.concat root "object") "okay";
  let result =
    Eio.Cancel.sub @@ fun cancellation ->
    let hooks =
      For_testing.hooks
        ~after_open_stat:(fun () ->
          Eio.Cancel.cancel
            cancellation
            (Failure "cancel after leaf dispatch"))
        ~on_close:(fun () -> raise (Failure "injected leaf close"))
        ()
    in
    For_testing.read
      ~hooks
      ~parent
      ~leaf:"object"
      ~expected_length:4L
      ~max_length:4L
  in
  let observation =
    require_success "dispatched cancellation settles" result
  in
  check string "cancelled read bytes retained" "okay"
    (Test_read.observation_bytes observation);
  check_warnings
    "close and parent cancellation warnings"
    [ "close:close_leaf"
    ; "settle:observe_parent_cancellation"
    ]
    (Test_read.observation_settlement_warnings observation)
;;

let settlement_failure () =
  raise (Failure "injected parent resource settlement")
;;

let test_parent_resource_settlement ~fs () =
  with_directory ~fs "cap_exact_parent_settle_" @@ fun root parent ->
  write_file (Filename.concat root "object") "okay";
  let success_hooks =
    For_testing.hooks
      ~on_settle_resources:settlement_failure
      ()
  in
  let observation =
    require_success
      "success survives parent settlement failure"
      (For_testing.read
         ~hooks:success_hooks
         ~parent
         ~leaf:"object"
         ~expected_length:4L
         ~max_length:4L)
  in
  check string "settled success bytes" "okay"
    (Test_read.observation_bytes observation);
  check_warnings
    "success parent settlement warning"
    [ "settle:settle_parent_resources" ]
    (Test_read.observation_settlement_warnings observation);
  let error_hooks =
    For_testing.hooks
      ~on_settle_resources:settlement_failure
      ()
  in
  let failure =
    check_error
      "primary error survives parent settlement failure"
      (function
        | Test_read.Missing -> true
        | _ -> false)
      (For_testing.read
         ~hooks:error_hooks
         ~parent
         ~leaf:"absent"
         ~expected_length:0L
         ~max_length:0L)
  in
  check_warnings
    "error parent settlement warning"
    [ "settle:settle_parent_resources" ]
    failure.settlement_warnings
;;

let test_parent_resource_settlement_cancellation ~fs () =
  with_directory ~fs "cap_exact_parent_settle_cancel_" @@ fun root parent ->
  write_file (Filename.concat root "object") "okay";
  let hooks =
    For_testing.hooks
      ~on_settle_resources:(fun () ->
        raise
          (Eio.Cancel.Cancelled
             (Failure "injected settlement cancellation")))
      ()
  in
  let observation =
    require_success
      "settlement cancellation preserves success"
      (For_testing.read
         ~hooks
         ~parent
         ~leaf:"object"
         ~expected_length:4L
         ~max_length:4L)
  in
  check string "settlement-cancelled bytes" "okay"
    (Test_read.observation_bytes observation);
  check_warnings
    "settlement cancellation warning"
    [ "settle:settle_parent_resources" ]
    (Test_read.observation_settlement_warnings observation)
;;

let test_fatal_backtrace_propagation ~fs ~clock ~process_mgr () =
  with_directory ~fs "cap_exact_fatal_" @@ fun root _parent ->
  write_file (Filename.concat root "object") "four";
  [ "callback", fatal_callback_helper_flag
  ; "settlement", fatal_settlement_helper_flag
  ]
  |> List.iter (fun (label, flag) ->
    run_self_helper
      ~clock
      ~process_mgr
      ~flag
      root
      "object"
    |> require_helper_success ("fatal " ^ label))
;;

let load_workspace_file relative =
  let candidates =
    [ relative
    ; Filename.concat ".." relative
    ]
  in
  let path =
    match List.find_opt Sys.file_exists candidates with
    | Some path -> path
    | None -> failf "source dependency not found: %s" relative
  in
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      really_input_string channel (in_channel_length channel))
;;

let find_substring haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > haystack_length
    then None
    else if
      String.equal
        (String.sub haystack offset needle_length)
        needle
    then Some offset
    else loop (offset + 1)
  in
  if needle_length = 0 then Some 0 else loop 0
;;

let count_substring haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop offset count =
    if offset + needle_length > haystack_length then
      count
    else if
      String.equal
        (String.sub haystack offset needle_length)
        needle
    then
      loop (offset + needle_length) (count + 1)
    else
      loop (offset + 1) count
  in
  if needle_length = 0 then 0 else loop 0 0
;;

let contains haystack needle =
  Option.is_some (find_substring haystack needle)
;;

let exact_read_public_surface source =
  let marker = "module Capability_exact_read : sig" in
  let start =
    match find_substring source marker with
    | Some offset -> offset + String.length marker
    | None -> fail "public exact-read module signature is missing"
  in
  let remainder =
    String.sub source start (String.length source - start)
  in
  let length =
    match find_substring remainder "\nend\n" with
    | Some offset -> offset
    | None -> fail "public exact-read module signature is unterminated"
  in
  String.sub remainder 0 length
;;

let compact_ascii_whitespace source =
  source
  |> String.to_seq
  |> Seq.filter (function
    | ' ' | '\t' | '\r' | '\n' -> false
    | _ -> true)
  |> String.of_seq
;;

let test_static_surface_and_raw_openat () =
  let public_mli =
    load_workspace_file "lib/fs_compat/fs_compat.mli"
    |> exact_read_public_surface
  in
  check bool "test hooks hidden from public module" false
    (contains public_mli "For_testing");
  check bool "raw C primitive hidden from public module" false
    (contains public_mli "openat_nofollow");
  let stub =
    load_workspace_file
      "lib/fs_compat/capability_exact_read_stubs.c"
  in
  check int "one raw openat call" 1
    (count_substring stub "openat(");
  check int "no raw open fallback" 0
    (count_substring stub "open(");
  let call_start =
    match find_substring stub "openat(" with
    | Some offset -> offset
    | None -> fail "raw openat call is missing"
  in
  let call_tail =
    String.sub stub call_start (String.length stub - call_start)
  in
  let call_length =
    match find_substring call_tail ");" with
    | Some offset -> offset + 2
    | None -> fail "raw openat call is unterminated"
  in
  check bool "raw openat expression is bounded" true
    (call_length <= 512);
  let call =
    String.sub call_tail 0 call_length
    |> compact_ascii_whitespace
  in
  check
    string
    "raw openat directly binds exact flags"
    "openat(Int_val(v_dirfd),leaf,O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW|O_NOCTTY);"
    call
;;

(* The flags above only exist if the headers declare them, and on Darwin
   O_NOFOLLOW / O_NOCTTY / O_CLOEXEC sit behind __DARWIN_C_LEVEL: defining
   _POSIX_C_SOURCE alone lowers that level below their declarations and the stub's
   own #error fires. That is a compile break, so no behavioural test can reach it —
   and the symlink case above cannot either, because on glibc _GNU_SOURCE exposes
   everything and the test passes whatever the macros say. CI is Linux, so #25734
   shipped a stub that no macOS checkout could compile and every local test target
   linking fs_compat failed. This asserts the ordering that keeps the flags
   visible: the Darwin level is raised, and it is raised before <fcntl.h>. *)
let test_darwin_feature_level_precedes_fcntl () =
  let stub =
    load_workspace_file "lib/fs_compat/capability_exact_read_stubs.c"
  in
  let offset_of needle =
    match find_substring stub needle with
    | Some offset -> offset
    | None -> failf "capability exact read stub does not contain %S" needle
  in
  let darwin_level = offset_of "_DARWIN_C_SOURCE" in
  let fcntl_include = offset_of "#include <fcntl.h>" in
  check
    bool
    "Darwin feature level is raised before <fcntl.h>"
    true
    (darwin_level < fcntl_include);
  (* Raised under an __APPLE__ guard so other platforms keep their own level. *)
  check
    bool
    "the Darwin level is guarded to Apple"
    true
    (offset_of "defined(__APPLE__)" < darwin_level)
;;

let () =
  run_helper_if_requested ();
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  let process_mgr = Eio.Stdenv.process_mgr env in
  run
    "fs capability exact read"
    [ ( "conformance"
      , [ test_case "validation precedes dispatch" `Quick
            (test_pre_dispatch_validation ~fs)
        ; test_case "exact success" `Quick
            (test_exact_success ~fs)
        ; test_case "missing" `Quick
            (test_missing ~fs)
        ; test_case "symlink directory FIFO" `Quick
            (test_special_files ~fs ~clock ~process_mgr)
        ; test_case "mode and link count" `Quick
            (test_wrong_mode_and_link_count ~fs)
        ; test_case "length failures precede allocation" `Quick
            (test_length_failures_precede_allocation ~fs)
        ; test_case "after-stat mutations" `Quick
            (test_after_stat_mutations ~fs)
        ; test_case "post-read metadata drift" `Quick
            (test_post_read_metadata_drift ~fs)
        ; test_case "pinned parent path swap" `Quick
            (test_pinned_parent_path_swap ~fs)
        ; test_case "leaf close warnings" `Quick
            (test_leaf_close_warnings ~fs)
        ; test_case "hook failures preserve close warning" `Quick
            (test_hook_failures_preserve_close_warning ~fs)
        ; test_case "pending cancellation prevents dispatch" `Quick
            (test_pending_cancellation_prevents_dispatch ~fs)
        ; test_case "parent cancellation after dispatch" `Quick
            (test_parent_cancellation_after_dispatch ~fs)
        ; test_case "parent resource settlement" `Quick
            (test_parent_resource_settlement ~fs)
        ; test_case "parent settlement cancellation" `Quick
            (test_parent_resource_settlement_cancellation ~fs)
        ; test_case "fatal backtrace propagation" `Quick
            (test_fatal_backtrace_propagation
               ~fs
               ~clock
               ~process_mgr)
        ; test_case "static public surface and raw openat" `Quick
            test_static_surface_and_raw_openat
        ; test_case "Darwin feature level precedes fcntl.h" `Quick
            test_darwin_feature_level_precedes_fcntl
        ] )
    ]
;;
