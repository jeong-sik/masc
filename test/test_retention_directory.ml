module Directory = Fs_compat.Retention_directory

let fresh () =
  let path = Filename.temp_file "masc-retention-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Unix.realpath path

let write path = Out_channel.with_open_bin path (fun oc -> output_string oc "sentinel")
let check_exists label expected path = Alcotest.(check bool) label expected (Sys.file_exists path)
let bound path f = match Directory.with_root path f with
  | Some result -> result | None -> Alcotest.fail "fixture root disappeared"

let test_regular_mtime_and_special_entries () =
  let root = fresh () and outside = fresh () in
  let old = Filename.concat root "old.jsonl" in
  let recent = Filename.concat root "recent.jsonl" in
  let foreign = Filename.concat outside "foreign.jsonl" in
  List.iter write [old; recent; foreign];
  List.iter (fun path -> Unix.utimes path 1. 1.) [old; foreign];
  Unix.symlink foreign (Filename.concat root "linked.jsonl");
  Unix.mkfifo (Filename.concat root "fifo.jsonl") 0o600;
  let count = bound root (fun directory ->
    Directory.names directory |> List.fold_left (fun count name ->
      if Directory.remove_regular_file ~older_than:2. directory name
      then count + 1 else count) 0) in
  Alcotest.(check int) "only observed old regular file" 1 count;
  check_exists "old removed" false old;
  List.iter (check_exists "non-owned/non-regular or recent entry preserved" true)
    [ recent; foreign; Filename.concat root "linked.jsonl"; Filename.concat root "fifo.jsonl" ]

let test_child_link_is_skipped () =
  let root = fresh () and outside = fresh () in
  let foreign = Filename.concat outside "old.jsonl" in write foreign;
  Unix.symlink outside (Filename.concat root "keeper");
  let count = bound root (fun directory ->
    Directory.descend directory ["keeper"] (fun child ->
      if Directory.remove_regular_file child "old.jsonl" then 1 else 0)) in
  Alcotest.(check int) "linked child never entered" 0 count;
  check_exists "foreign file preserved" true foreign

let test_fractional_mtime_boundary () =
  let root = fresh () in
  let path = Filename.concat root "boundary.jsonl" in
  write path;
  Unix.utimes path 10.75 10.75;
  bound root (fun directory ->
    Alcotest.(check bool) "mtime fractions are not rounded below the cutoff" false
      (Directory.remove_regular_file ~older_than:10.5 directory "boundary.jsonl");
    Alcotest.(check bool) "strictly older fractional timestamp is removed" true
      (Directory.remove_regular_file ~older_than:10.9 directory "boundary.jsonl"))

let test_bound_child_survives_path_swap () =
  let root = fresh () and outside = fresh () in
  let child = Filename.concat root "keeper" in Unix.mkdir child 0o700;
  write (Filename.concat child "old.jsonl");
  let foreign = Filename.concat outside "old.jsonl" in write foreign;
  bound root (fun directory ->
    ignore (Directory.with_child directory "keeper" (fun held ->
      Unix.rename child (Filename.concat root "held-keeper");
      Unix.symlink outside child;
      Alcotest.(check bool) "unlink stays under held child" true
        (Directory.remove_regular_file held "old.jsonl"))));
  check_exists "replacement link target preserved" true foreign;
  check_exists "original owned entry removed" false (Filename.concat root "held-keeper/old.jsonl")

let test_bound_root_survives_ancestor_swap () =
  let parent = fresh () and outside = fresh () in
  let root = Filename.concat parent "runtime" in Unix.mkdir root 0o700;
  let own = Filename.concat root "logs" in Unix.mkdir own 0o700;
  write (Filename.concat own "old.jsonl");
  Unix.mkdir (Filename.concat outside "logs") 0o700;
  let foreign = Filename.concat outside "logs/old.jsonl" in write foreign;
  bound root (fun held ->
    Unix.rename root (Filename.concat parent "held-runtime");
    Unix.symlink outside root;
    Alcotest.(check int) "root spelling no longer authorizes descent" 1
      (Directory.descend held ["logs"] (fun directory ->
        if Directory.remove_regular_file directory "old.jsonl" then 1 else 0)));
  check_exists "foreign root untouched" true foreign

let test_root_and_ancestor_links_refused () =
  let root = fresh () and outside = fresh () in
  let link = Filename.concat root "linked" in Unix.symlink outside link;
  let refused path =
    match Directory.with_root path (fun _ -> ()) with
    | Some () | None -> Alcotest.fail "linked physical root accepted"
    | exception Unix.Unix_error ((Unix.ENOTDIR | Unix.ELOOP), _, _) -> () in
  refused link;
  Unix.mkdir (Filename.concat outside "child") 0o700;
  refused (Filename.concat link "child")

exception Interrupted

let test_exception_expires_handles () =
  let root = fresh () in
  let escaped = ref None in
  (try bound root (fun directory -> escaped := Some directory; raise Interrupted)
   with Interrupted -> ());
  let directory = Option.get !escaped in
  let fresh_descriptor = Unix.openfile root [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fresh_descriptor) (fun () ->
    Alcotest.check_raises "expired handle cannot operate on a reused descriptor"
      (Invalid_argument "expired retention directory")
      (fun () -> ignore (Directory.names directory : string list)))

let test_missing_and_invalid_components () =
  let root = fresh () in
  Alcotest.(check bool) "missing scope" true
    (Option.is_none (Directory.with_root (Filename.concat root "missing") (fun _ -> ())));
  bound root (fun held ->
    List.iter (fun component ->
      Alcotest.check_raises "no upward or multi-component child"
        (Invalid_argument "retention directory requires one child name")
        (fun () -> ignore (Directory.with_child held component (fun _ -> ()))))
      [".."; "."; "a/b"; ""])

let test_unremovable_file_keeps_later_stores () =
  let root = fresh () in
  let first = Filename.concat root "first" and later = Filename.concat root "later" in
  List.iter (fun path -> Unix.mkdir path 0o700) [first; later];
  let first_file = Filename.concat first "old.jsonl" in
  let later_file = Filename.concat later "old.jsonl" in
  List.iter write [first_file; later_file];
  (* Root can bypass directory modes. In root-run CI only, use the existing
     operation runner to inject the same leaf error. Ordinary users exercise
     the real unlinkat permission failure; the later store always uses real IO. *)
  let inject = ref false in
  let io : Directory.io = { run = (fun f ->
    if !inject then raise (Unix.Unix_error (Unix.EACCES, "retention_unlinkat", "old.jsonl"))
    else f ()) } in
  let prune directory =
    if Directory.remove_regular_file directory "old.jsonl" then 1 else 0 in
  let count = match Directory.with_root ~io root (fun held ->
    List.fold_left (fun count name ->
      count + Directory.descend held [name] (fun directory ->
        if name = "first" then begin
          Unix.chmod first 0o500;
          inject := Unix.geteuid () = 0;
          Fun.protect
            ~finally:(fun () -> inject := false; Unix.chmod first 0o700)
            (fun () -> prune directory)
        end else prune directory)) 0 ["first"; "later"]) with
    | Some count -> count | None -> Alcotest.fail "fixture root disappeared" in
  Alcotest.(check int) "only the later store's removal is counted" 1 count;
  check_exists "rejected leaf retained" true first_file;
  check_exists "later store still pruned" false later_file;
  Alcotest.(check int) "next pass retries the retained leaf" 1 (bound first prune)

let test_inspection_failure_keeps_later_entries () =
  let root = fresh () in
  let later_file = Filename.concat root "old.jsonl" in
  write later_file;
  bound root (fun held ->
    Alcotest.(check bool) "kernel rejects an overlong leaf without aborting pass" false
      (Directory.remove_regular_file held (String.make 65536 'x'));
    Alcotest.(check bool) "later entry uses real descriptor unlink" true
      (Directory.remove_regular_file held "old.jsonl"));
  check_exists "later entry removed" false later_file

let test_directory_failure_still_propagates () =
  let root = fresh () in
  let inject = ref false in
  let failure = Unix.Unix_error (Unix.EACCES, "directory_names", root) in
  let io : Directory.io = { run = (fun f -> if !inject then raise failure else f ()) } in
  match Directory.with_root ~io root (fun held ->
    inject := true;
    Alcotest.check_raises "unreadable inventory does not become an empty pass" failure
      (fun () -> ignore (Directory.names held : string list))) with
  | Some () -> () | None -> Alcotest.fail "fixture root disappeared"

let test_checked_removals_acknowledge_only_actual_effects () =
  let root = fresh () and outside = fresh () in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root; Fs_compat.remove_tree outside)
    (fun () ->
      let marker = Filename.concat outside "marker" in write marker;
      Unix.symlink marker (Filename.concat root "link");
      let child = Filename.concat root "child" in Unix.mkdir child 0o700;
      write (Filename.concat child "blocking-entry");
      bound root (fun held ->
        Alcotest.(check bool) "missing unlink is not counted" false
          (Directory.unlink_entry held "absent");
        Alcotest.(check bool) "link name unlink acknowledged" true
          (Directory.unlink_entry held "link");
        Alcotest.(check bool) "repeated unlink is not counted twice" false
          (Directory.unlink_entry held "link");
        (match Directory.unlink_entry held "child" with
         | true | false -> Alcotest.fail "unlink of a directory was not refused"
         | exception Unix.Unix_error _ -> ());
        (match Directory.remove_empty_child_checked held "child" with
         | true | false -> Alcotest.fail "nonempty rmdir failure was swallowed"
         | exception Unix.Unix_error _ -> ());
        Sys.remove (Filename.concat child "blocking-entry");
        Alcotest.(check bool) "empty directory removal acknowledged" true
          (Directory.remove_empty_child_checked held "child");
        Alcotest.(check bool) "missing directory is not counted twice" false
          (Directory.remove_empty_child_checked held "child"));
      Alcotest.(check string) "link target bytes remain" "sentinel"
        (Fs_compat.load_file marker))

let test_batched_remove_regular_files_chunks_and_errors () =
  let root = fresh () and outside = fresh () in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root; Fs_compat.remove_tree outside)
    (fun () ->
      let old_names =
        List.init 300 (fun i ->
          let name = Printf.sprintf "old-%03d.jsonl" i in
          let path = Filename.concat root name in
          write path;
          Unix.utimes path 1. 1.;
          name)
      in
      let recent_names =
        List.init 5 (fun i ->
          let name = Printf.sprintf "recent-%d.jsonl" i in
          write (Filename.concat root name);
          name)
      in
      let foreign = Filename.concat outside "foreign.jsonl" in
      write foreign;
      Unix.utimes foreign 1. 1.;
      Unix.symlink foreign (Filename.concat root "linked.jsonl");
      Unix.mkfifo (Filename.concat root "fifo.jsonl") 0o600;
      let overlong = String.make 65536 'x' in
      (* Place [overlong] first inside chunk 1 so the test proves a per-leaf
         Unix_error does not abort the remaining removable entries in the same
         chunk or later chunks. *)
      let candidates =
        overlong :: (old_names @ [ "linked.jsonl"; "fifo.jsonl" ] @ recent_names)
      in
      let io_calls = ref 0 in
      let io : Directory.io = { run = (fun f -> incr io_calls; f ()) } in
      let escaped = ref None in
      (match Directory.with_root ~io root (fun held ->
         escaped := Some held;
         io_calls := 0;
         let removed = Directory.remove_regular_files ~older_than:2. held candidates in
         let batch_io_calls = !io_calls in
         Alcotest.(check int) "all 300 old regular files removed despite overlong error" 300 removed;
         Alcotest.(check int) "308 entries run in two 256-entry io batches" 2 batch_io_calls;
         io_calls := 0;
         Alcotest.(check int) "empty candidate list removes nothing" 0
           (Directory.remove_regular_files ~older_than:2. held []);
         Alcotest.(check int) "empty candidate list makes zero io calls" 0 !io_calls;
         let victim = Filename.concat root "victim.jsonl" in
         write victim;
         Unix.utimes victim 1. 1.;
         Alcotest.check_raises "invalid leaf fails before any unlink in batch"
           (Invalid_argument "retention directory requires one child name")
           (fun () ->
              ignore
                (Directory.remove_regular_files ~older_than:2. held [ "victim.jsonl"; "../escape" ]
                 : int));
         check_exists "victim preserved when later leaf is invalid" true victim) with
       | Some () -> ()
       | None -> Alcotest.fail "fixture root disappeared");
      List.iter (fun name -> check_exists name false (Filename.concat root name)) old_names;
      List.iter (fun name -> check_exists name true (Filename.concat root name)) recent_names;
      List.iter (check_exists "special entries and link target preserved" true)
        [ foreign; Filename.concat root "linked.jsonl"; Filename.concat root "fifo.jsonl" ];
      let expired = Option.get !escaped in
      Alcotest.check_raises "expired handle rejected even for empty batch"
        (Invalid_argument "expired retention directory")
        (fun () -> ignore (Directory.remove_regular_files expired [] : int));
      (* An io.run failure on one chunk does not abort later chunks. *)
      let retry_root = fresh () in
      Fun.protect ~finally:(fun () -> Fs_compat.remove_tree retry_root) (fun () ->
        let names =
          List.init 260 (fun i ->
            let name = Printf.sprintf "chunk-%03d.jsonl" i in
            let path = Filename.concat retry_root name in
            write path;
            Unix.utimes path 1. 1.;
            name)
        in
        let fail_first_batch = ref false in
        let io : Directory.io =
          { run =
              (fun f ->
                if !fail_first_batch then (
                  fail_first_batch := false;
                  raise (Unix.Unix_error (Unix.EACCES, "retention_unlinkat", "chunk-000.jsonl")))
                else f ())
          }
        in
        match Directory.with_root ~io retry_root (fun held ->
          fail_first_batch := true;
          let removed = Directory.remove_regular_files ~older_than:2. held names in
          Alcotest.(check int) "second chunk still pruned after first chunk EACCES" 4 removed) with
        | Some () -> ()
        | None -> Alcotest.fail "retry root disappeared"))

let test_batched_remove_empty_children () =
  let root = fresh () and outside = fresh () in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root; Fs_compat.remove_tree outside)
    (fun () ->
      let empty_names =
        List.init 260 (fun i ->
          let name = Printf.sprintf "empty-%03d" i in
          Unix.mkdir (Filename.concat root name) 0o700;
          name)
      in
      let nonempty = Filename.concat root "nonempty" in
      Unix.mkdir nonempty 0o700;
      write (Filename.concat nonempty "keep");
      let target = Filename.concat outside "target" in
      Unix.mkdir target 0o700;
      let linked = Filename.concat root "linked" in
      Unix.symlink target linked;
      let candidates = empty_names @ [ "nonempty"; "linked" ] in
      let io_calls = ref 0 in
      let io : Directory.io = { run = (fun f -> incr io_calls; f ()) } in
      let escaped = ref None in
      (match Directory.with_root ~io root (fun held ->
         escaped := Some held;
         io_calls := 0;
         Directory.remove_empty_children held candidates;
         let batch_io_calls = !io_calls in
         Alcotest.(check int) "262 names run in two 256-entry io batches" 2 batch_io_calls;
         io_calls := 0;
         Directory.remove_empty_children held [];
         Alcotest.(check int) "empty list makes zero io calls" 0 !io_calls;
         let kept_empty = Filename.concat root "kept-empty" in
         Unix.mkdir kept_empty 0o700;
         Alcotest.check_raises "invalid leaf fails before any rmdir in batch"
           (Invalid_argument "retention directory requires one child name")
           (fun () -> Directory.remove_empty_children held [ "kept-empty"; "a/b" ]);
         check_exists "empty dir preserved when later leaf is invalid" true kept_empty) with
       | Some () -> ()
       | None -> Alcotest.fail "fixture root disappeared");
      List.iter (fun name -> check_exists name false (Filename.concat root name)) empty_names;
      List.iter (check_exists "non-empty dir and symlink target preserved" true)
        [ Filename.concat nonempty "keep"; linked; target ];
      let expired = Option.get !escaped in
      Alcotest.check_raises "expired handle rejected even for empty child batch"
        (Invalid_argument "expired retention directory")
        (fun () -> Directory.remove_empty_children expired []))

let () = Alcotest.run "physical retention containment"
  ["owned pruning", [
    Alcotest.test_case "checked removals acknowledge actual effects" `Quick test_checked_removals_acknowledge_only_actual_effects;
    Alcotest.test_case "batched remove_regular_files chunks and isolates errors" `Quick test_batched_remove_regular_files_chunks_and_errors;
    Alcotest.test_case "batched remove_empty_children chunks and preserves links" `Quick test_batched_remove_empty_children;
    Alcotest.test_case "mtime, links and FIFO" `Quick test_regular_mtime_and_special_entries;
    Alcotest.test_case "child link skipped" `Quick test_child_link_is_skipped;
    Alcotest.test_case "fractional mtime retention" `Quick test_fractional_mtime_boundary;
    Alcotest.test_case "bound child path swap" `Quick test_bound_child_survives_path_swap;
    Alcotest.test_case "bound root ancestor swap" `Quick test_bound_root_survives_ancestor_swap;
    Alcotest.test_case "root and ancestor links refused" `Quick test_root_and_ancestor_links_refused;
    Alcotest.test_case "exception expires handles" `Quick test_exception_expires_handles;
    Alcotest.test_case "absence and child validation" `Quick test_missing_and_invalid_components;
    Alcotest.test_case "rejected unlink preserves later stores" `Quick test_unremovable_file_keeps_later_stores;
    Alcotest.test_case "rejected inspection preserves later entries" `Quick test_inspection_failure_keeps_later_entries;
    Alcotest.test_case "directory failure stays explicit" `Quick test_directory_failure_still_propagates ]]
