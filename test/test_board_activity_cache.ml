(** Tests for the mtime-gated board-activity projection in [Reputation].

    [count_board_activity_in_dir] backs contributor-quality on the board
    dashboard, where it is queried once per unique post author per render. The
    projection parses board_posts.jsonl and board_comments.jsonl once and reuses
    the result until a source file's mtime changes. These tests pin both the
    counting semantics (identical to filtering each file by author) and the
    invalidation behaviour. mtimes are set explicitly with [Unix.utimes] so the
    gate is exercised deterministically rather than depending on wall-clock
    resolution. *)

open Alcotest
open Masc

let with_temp_dir f =
  let dir = Filename.temp_file "board_activity_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir with _ -> [||])
      |> Array.iter (fun n -> try Sys.remove (Filename.concat dir n) with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f dir)

let write_lines path lines ~mtime =
  let oc = open_out path in
  List.iter
    (fun l ->
      output_string oc l;
      output_char oc '\n')
    lines;
  close_out oc;
  Unix.utimes path mtime mtime

let post author = Printf.sprintf {|{"author":%S,"content":"x"}|} author
let comment author = Printf.sprintf {|{"author":%S,"content":"y"}|} author
let posts_path dir = Filename.concat dir "board_posts.jsonl"
let comments_path dir = Filename.concat dir "board_comments.jsonl"

let count dir author =
  Reputation.count_board_activity_in_dir ~board_dir:dir ~agent_name:author

let test_counts_authored () =
  with_temp_dir (fun dir ->
      write_lines (posts_path dir)
        [ post "alice"; post "bob"; post "alice" ]
        ~mtime:1000.0;
      write_lines (comments_path dir)
        [ comment "alice"; comment "carol" ]
        ~mtime:1000.0;
      check (pair int int) "alice = (2 posts, 1 comment)" (2, 1) (count dir "alice");
      check (pair int int) "bob = (1 post, 0 comments)" (1, 0) (count dir "bob");
      check (pair int int) "carol = (0 posts, 1 comment)" (0, 1) (count dir "carol"))

let test_unknown_author_zero () =
  with_temp_dir (fun dir ->
      write_lines (posts_path dir) [ post "alice" ] ~mtime:1000.0;
      write_lines (comments_path dir) [] ~mtime:1000.0;
      check (pair int int) "unknown author -> (0,0)" (0, 0) (count dir "nobody"))

let test_missing_files_zero () =
  with_temp_dir (fun dir ->
      (* No JSONL files exist: load is tolerant and the projection is empty. *)
      check (pair int int) "missing files -> (0,0)" (0, 0) (count dir "alice"))

let test_mtime_invalidation () =
  with_temp_dir (fun dir ->
      write_lines (posts_path dir) [ post "alice" ] ~mtime:1000.0;
      write_lines (comments_path dir) [] ~mtime:1000.0;
      check (pair int int) "before append" (1, 0) (count dir "alice");
      (* Append a second post and advance the mtime: a later query must observe
         the new row rather than the cached projection. *)
      write_lines (posts_path dir)
        [ post "alice"; post "alice" ]
        ~mtime:2000.0;
      check (pair int int) "after append + mtime bump" (2, 0) (count dir "alice"))

(* Regression guard for coarse-mtime filesystems: an append within the same
   wall-clock second leaves the mtime unchanged but grows the file size. The
   projection must still observe the new row, so the cache gate keys on size as
   well as mtime. Here the mtime is held fixed at 1000.0 across both writes. *)
let test_same_second_append_refreshes () =
  with_temp_dir (fun dir ->
      write_lines (posts_path dir) [ post "alice" ] ~mtime:1000.0;
      write_lines (comments_path dir) [] ~mtime:1000.0;
      check (pair int int) "before append" (1, 0) (count dir "alice");
      write_lines (posts_path dir)
        [ post "alice"; post "alice" ]
        ~mtime:1000.0 (* same mtime, larger file *);
      check (pair int int) "same-second append observed via size gate" (2, 0)
        (count dir "alice"))

let () =
  run "board_activity_cache"
    [
      ( "projection",
        [
          test_case "counts authored posts and comments" `Quick test_counts_authored;
          test_case "unknown author yields zero" `Quick test_unknown_author_zero;
          test_case "missing files yield zero" `Quick test_missing_files_zero;
          test_case "mtime change refreshes projection" `Quick test_mtime_invalidation;
          test_case "same-second append refreshes via size gate" `Quick
            test_same_second_append_refreshes;
        ] );
    ]
