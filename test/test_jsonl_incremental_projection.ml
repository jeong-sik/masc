(** Tests for [Jsonl_incremental_projection]. The [add] fold is instrumented with
    a call counter, so these prove the defining property — a re-read folds only
    newly appended lines, never re-folding consumed ones — rather than merely
    that the result is correct. Partial-line holding and truncation reseed are
    pinned too. *)

open Alcotest
module P = Masc.Jsonl_incremental_projection

let big_tail = 1_000_000

let with_temp_file f =
  let path = Filename.temp_file "incr_proj" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let append path s =
  let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  output_string oc s;
  close_out oc

let rewrite path s =
  let oc = open_out path in
  output_string oc s;
  close_out oc

(* add prepends each line and counts invocations; acc is most-recent-first. *)
let reader cache path counter =
  P.read cache ~key:"k" ~path ~empty:[]
    ~add:(fun acc line ->
      incr counter;
      line :: acc)
    ~initial_tail_bytes:big_tail

let reader_with_key cache ~key path counter =
  P.read cache ~key ~path ~empty:[]
    ~add:(fun acc line ->
      incr counter;
      line :: acc)
    ~initial_tail_bytes:big_tail

let test_seeds_from_tail () =
  with_temp_file (fun path ->
      append path "a\nb\nc\n";
      let cache = P.create () in
      let c = ref 0 in
      let acc = reader cache path c in
      check int "folded every complete line once" 3 !c;
      check (list string) "most-recent-first" [ "c"; "b"; "a" ] acc)

let test_no_change_no_refold () =
  with_temp_file (fun path ->
      append path "a\nb\n";
      let cache = P.create () in
      let c = ref 0 in
      let _ = reader cache path c in
      check int "first read folds 2" 2 !c;
      let acc = reader cache path c in
      check int "unchanged file folds nothing more" 2 !c;
      check (list string) "same accumulator" [ "b"; "a" ] acc)

let test_append_folds_only_new () =
  with_temp_file (fun path ->
      append path "a\nb\n";
      let cache = P.create () in
      let c = ref 0 in
      let _ = reader cache path c in
      append path "c\n";
      let acc = reader cache path c in
      check int "only the appended line is folded" 3 !c;
      check (list string) "accumulated" [ "c"; "b"; "a" ] acc)

let test_same_path_distinct_keys_do_not_share_offsets () =
  with_temp_file (fun path ->
      append path "a\nb\n";
      let cache = P.create () in
      let c_a = ref 0 in
      let c_b = ref 0 in
      let _ = reader_with_key cache ~key:"projection:a" path c_a in
      append path "c\n";
      let b = reader_with_key cache ~key:"projection:b" path c_b in
      check int "first key folded original lines once" 2 !c_a;
      check int "second key cold-read folds all complete lines" 3 !c_b;
      check (list string) "second key has independent accumulator"
        [ "c"; "b"; "a" ] b)

let test_partial_line_held () =
  with_temp_file (fun path ->
      append path "a\n";
      let cache = P.create () in
      let c = ref 0 in
      let _ = reader cache path c in
      check int "1 complete line" 1 !c;
      append path "partial";
      let _ = reader cache path c in
      check int "partial line not folded" 1 !c;
      append path "rest\n";
      let acc = reader cache path c in
      check int "completed line folded once" 2 !c;
      check (list string) "partial+rest joined" [ "partialrest"; "a" ] acc)

let test_truncation_reseeds () =
  with_temp_file (fun path ->
      append path "a\nb\nc\n";
      let cache = P.create () in
      let c = ref 0 in
      let _ = reader cache path c in
      check int "3 folded" 3 !c;
      rewrite path "x\n" (* shorter than consumed offset *);
      let acc = reader cache path c in
      check int "reseeded: one new line folded" 4 !c;
      check (list string) "fresh accumulator after rotation" [ "x" ] acc)

let test_rewrite_during_fold_reseeds () =
  with_temp_file (fun path ->
      rewrite path "a\nb\n";
      let cache = P.create () in
      let rewritten = ref false in
      let first = P.read cache ~key:"k" ~path ~empty:[]
          ~initial_tail_bytes:big_tail
          ~add:(fun acc line ->
            if not !rewritten then (
              rewritten := true;
              rewrite path "x\ny\n");
            line :: acc) in
      check (list string) "fold uses the bytes it already read" ["b"; "a"] first;
      check (list string) "new bytes do not validate the old accumulator"
        ["y"; "x"] (reader cache path (ref 0)))

let test_rotation_during_fold_reseeds () =
  with_temp_file (fun path ->
      rewrite path "a\nb\n";
      let cache = P.create () in
      let replaced = ref false in
      let first = P.read cache ~key:"k" ~path ~empty:[]
          ~initial_tail_bytes:big_tail
          ~add:(fun acc line ->
            if not !replaced then (
              replaced := true;
              with_temp_file (fun replacement ->
                rewrite replacement "x\ny\n";
                Unix.rename replacement path));
            line :: acc) in
      check (list string) "one observation keeps one file's rows" ["b"; "a"] first;
      check (list string) "replacement starts a fresh projection"
        ["y"; "x"] (reader cache path (ref 0)))

let test_failed_fold_preserves_previous_projection () =
  with_temp_file (fun path ->
      rewrite path "a\n";
      let cache = P.create () in
      ignore (reader cache path (ref 0));
      append path "b\n";
      (match P.read cache ~key:"k" ~path ~empty:[]
          ~initial_tail_bytes:big_tail ~add:(fun _ _ -> raise Exit) with
       | exception Exit -> ()
       | _ -> fail "fold failure must propagate");
      check (option (list string)) "previous successful projection retained"
        (Some ["a"]) (P.peek cache ~key:"k");
      check (list string) "failed append remains unread"
        ["b"; "a"] (reader cache path (ref 0)))

let () =
  run "jsonl_incremental_projection"
    [
      ( "incremental",
        [
          test_case "seeds from the tail" `Quick test_seeds_from_tail;
          test_case "unchanged file re-folds nothing" `Quick test_no_change_no_refold;
          test_case "append folds only new lines" `Quick test_append_folds_only_new;
          test_case "same path distinct keys keep independent offsets" `Quick
            test_same_path_distinct_keys_do_not_share_offsets;
          test_case "partial trailing line is held" `Quick test_partial_line_held;
          test_case "truncation reseeds from tail" `Quick test_truncation_reseeds;
          test_case "rewrite during fold reseeds" `Quick test_rewrite_during_fold_reseeds;
          test_case "rotation during fold reseeds" `Quick test_rotation_during_fold_reseeds;
          test_case "failed fold preserves previous projection" `Quick
            test_failed_fold_preserves_previous_projection;
        ] );
    ]
