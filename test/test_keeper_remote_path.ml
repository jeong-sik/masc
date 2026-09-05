open Alcotest
open Masc

let remote_root = "/srv/masc/playground"
let base_path = "/workspace"
let host_file = "/workspace/.masc/playground/keeper-a/src/main.ml"
let remote_file = "/srv/masc/playground/keeper-a/src/main.ml"

let test_host_to_remote () =
  check (result string string) "absolute host path" (Ok remote_file)
    (Keeper_remote_path.host_to_remote ~base_path ~remote_root ~keeper:"keeper-a"
       host_file);
  check (result string string) "relative logical path" (Ok remote_file)
    (Keeper_remote_path.host_to_remote ~base_path ~remote_root ~keeper:"keeper-a"
       "src/main.ml")
;;

let test_remote_to_logical () =
  check string "relative logical path" "src/main.ml"
    (Keeper_remote_path.remote_to_logical ~remote_root ~keeper:"keeper-a"
       remote_file);
  check string "root" "."
    (Keeper_remote_path.remote_to_logical ~remote_root ~keeper:"keeper-a"
       "/srv/masc/playground/keeper-a");
  check string "outside unchanged" "/etc/passwd"
    (Keeper_remote_path.remote_to_logical ~remote_root ~keeper:"keeper-a"
       "/etc/passwd")
;;

let test_jail_and_endpoint_isolation () =
  let outside = "/workspace/.masc/playground/keeper-b/src/main.ml" in
  let outside_result =
    Keeper_remote_path.host_to_remote ~base_path ~remote_root ~keeper:"keeper-a"
      outside
  in
  (match outside_result with
   | Ok path -> failf "outside path translated to %s" path
   | Error error ->
     check bool "named jail error" true
       (String.starts_with ~prefix:"remote_ssh_path_jail_violation:" error));
  check (result string string) "different endpoint root"
    (Ok "/srv/other/playground/keeper-a/src/main.ml")
    (Keeper_remote_path.host_to_remote ~base_path ~remote_root:"/srv/other/playground"
       ~keeper:"keeper-a" host_file)
;;

(* A guest work volume is just another remote root: the translation does
   not know which transport reaches it. *)
let test_guest_volume_root () =
  check (result string string) "host bookkeeping path lands on the volume"
    (Ok "/masc-work/keeper-a/src/main.ml")
    (Keeper_remote_path.host_to_remote ~base_path ~remote_root:"/masc-work"
       ~keeper:"keeper-a" host_file);
  check string "volume path maps back to the logical path" "src/main.ml"
    (Keeper_remote_path.remote_to_logical ~remote_root:"/masc-work"
       ~keeper:"keeper-a" "/masc-work/keeper-a/src/main.ml")
;;

(* The remote namespace must not be resolved against the host filesystem: a
   host symlink (stand-in for the macOS /home firmlink) under the endpoint
   root's prefix must not leak its target into translated paths. *)
let test_host_symlink_does_not_rewrite_remote_paths () =
  let tmp = Filename.temp_file "remote-path" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o700;
  Fun.protect
    ~finally:(fun () ->
      Unix.unlink (Filename.concat tmp "link");
      Unix.rmdir (Filename.concat tmp "target");
      Unix.rmdir tmp)
    (fun () ->
      Unix.mkdir (Filename.concat tmp "target") 0o700;
      Unix.symlink
        (Filename.concat tmp "target")
        (Filename.concat tmp "link");
      let linked_root = Filename.concat tmp "link/playground" in
      check (result string string) "host symlink not substituted"
        (Ok (linked_root ^ "/keeper-a/src/main.ml"))
        (Keeper_remote_path.host_to_remote ~base_path ~remote_root:linked_root
           ~keeper:"keeper-a" host_file);
      check string "remote output maps back through the symlink form"
        "src/main.ml"
        (Keeper_remote_path.remote_to_logical ~remote_root:linked_root
           ~keeper:"keeper-a" (linked_root ^ "/keeper-a/src/main.ml")))
;;

let test_relative_dot_segments () =
  check (result string string) "dot-segment cleanup stays lexical"
    (Ok remote_file)
    (Keeper_remote_path.host_to_remote ~base_path ~remote_root ~keeper:"keeper-a"
       "./src/../src/main.ml");
  check (result string string) "bare dot is the keeper root"
    (Ok "/srv/masc/playground/keeper-a")
    (Keeper_remote_path.host_to_remote ~base_path ~remote_root ~keeper:"keeper-a"
       ".");
  (match
     Keeper_remote_path.host_to_remote ~base_path ~remote_root ~keeper:"keeper-a"
       "src/../../escape"
   with
   | Ok path -> failf "escaping relative path translated to %s" path
   | Error error ->
     check bool "escape is a named jail error" true
       (String.starts_with ~prefix:"remote_ssh_path_jail_violation:" error))
;;

let test_rewrite_output_and_chunk_boundary () =
  let expected = "error: " ^ host_file ^ ":12\n" in
  check string "absolute remote output becomes host logical" expected
    (Keeper_remote_path.rewrite_output ~base_path ~remote_root ~keeper:"keeper-a"
       ("error: " ^ remote_file ^ ":12\n"));
  check string "sibling prefix untouched"
    "/srv/masc/playground/keeper-a-copy/main.ml"
    (Keeper_remote_path.rewrite_output ~base_path ~remote_root ~keeper:"keeper-a"
       "/srv/masc/playground/keeper-a-copy/main.ml");
  let out = Buffer.create 64 in
  let stream =
    Keeper_remote_path.stream ~base_path ~remote_root ~keeper:"keeper-a"
      ~emit:(Buffer.add_string out)
  in
  Keeper_remote_path.rewrite_stream_chunk stream "error: /srv/masc/play";
  Keeper_remote_path.rewrite_stream_chunk stream "ground/keeper-a/src/main.ml";
  Keeper_remote_path.finish_stream stream;
  check string "chunk-boundary rewrite"
    ("error: " ^ host_file)
    (Buffer.contents out)
;;

(* One chunk carries many remote paths; the streamed rewrite must equal the
   whole-string rewrite, and its allocation must stay linear in the chunk.
   The scanner used to re-slice the pending string on every byte, so a chunk
   of n bytes allocated about n^2 / 2 bytes (RFC main-domain-scheduler-latency
   §8.6: 4.5 GB in four minutes from remote lanes). The bound below is words
   allocated per input byte: linear scanning stays under a few dozen, the
   quadratic form needs tens of thousands at this size. *)
let test_large_chunk_allocates_linearly () =
  let line = "at " ^ remote_file ^ ":7 in keeper-a-copy/x.ml, then some prose\n" in
  let chunk = String.concat "" (List.init 2_000 (fun _ -> line)) in
  let expected =
    Keeper_remote_path.rewrite_output ~base_path ~remote_root ~keeper:"keeper-a" chunk
  in
  let out = Buffer.create (String.length chunk) in
  let stream =
    Keeper_remote_path.stream ~base_path ~remote_root ~keeper:"keeper-a"
      ~emit:(Buffer.add_string out)
  in
  let before = Gc.minor_words () in
  Keeper_remote_path.rewrite_stream_chunk stream chunk;
  Keeper_remote_path.finish_stream stream;
  let words = Gc.minor_words () -. before in
  check string "streamed rewrite equals whole-string rewrite" expected (Buffer.contents out);
  let words_per_byte = words /. float_of_int (String.length chunk) in
  check bool
    (Printf.sprintf "allocation is linear: %.1f words per input byte" words_per_byte)
    true
    (words_per_byte < 64.0)
;;

let () =
  run "keeper_remote_path"
    [ ( "mapping"
      , [ test_case "host to remote" `Quick test_host_to_remote
        ; test_case "remote to logical" `Quick test_remote_to_logical
        ; test_case "jail + endpoint isolation" `Quick
            test_jail_and_endpoint_isolation
        ; test_case "guest work volume root" `Quick test_guest_volume_root
        ; test_case "host symlink immunity" `Quick
            test_host_symlink_does_not_rewrite_remote_paths
        ; test_case "relative dot segments" `Quick test_relative_dot_segments
        ; test_case "output rewrite + chunk boundary" `Quick
            test_rewrite_output_and_chunk_boundary
        ; test_case "large chunk allocates linearly" `Quick
            test_large_chunk_allocates_linearly
        ] )
    ]
