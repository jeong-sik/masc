(** Test_board_diversity — QCheck + Alcotest for Board_diversity.

    Property-based tests for the key invariants of the diversity
    reranking pipeline:

    1. find_dead_zones: every returned index is ≥2 (3rd post of a run)
    2. find_dead_zones: every returned index indeed starts a 3+ run
    3. find_dead_zones: no false-negative runs of 3+
    4. author_frequencies: sum of counts = length of input
    5. rerank_for_diversity: output length = input length
    6. rerank_for_diversity: no post is duplicated
    7. rerank_for_diversity: no post is dropped
    8. rerank_for_diversity: no-op for non-scored sort modes *)

open Alcotest

module D = Masc_board_handlers.Board_diversity

let agent_id_of_string s =
  Board_types.Agent_id.of_string s

let make_post ~author ~id ~created_at ~votes_up =
  {
    Board_types.id = Board_types.Post_id.of_string id;
    author = agent_id_of_string author;
    title = "";
    body = "";
    content = "";
    post_kind = Board_types.Discussion;
    meta_json = None;
    visibility = Board_types.Public;
    created_at;
    updated_at = created_at;
    expires_at = created_at +. 86400.0;
    votes_up;
    votes_down = 0;
    reply_count = 0;
    hearth = None;
    thread_id = None;
  }

(* ── Helpers ──────────────────────────────────────────── *)

(** Generate a list of n posts where each post has the given author. *)
let posts_of_author author n =
  List.init n (fun i ->
    make_post ~author ~id:(Printf.sprintf "p-%s-%d" author i)
      ~created_at:(float i) ~votes_up:100)

(** Generate a list of alternating-author posts. *)
let alternating_posts authors n =
  let rec go i =
    if i >= n then []
    else
      let author = List.nth authors (i mod List.length authors) in
      make_post ~author ~id:(Printf.sprintf "p-%s-%d" author i)
        ~created_at:(float i) ~votes_up:100
      :: go (i + 1)
  in
  go 0

(* ── Unit tests ──────────────────────────────────────────── *)

let test_author_frequencies_empty () =
  let freq = D.author_frequencies [] in
  check int "empty = 0" 0 (D.Author_map.cardinal freq)

let test_author_frequencies_single () =
  let posts = posts_of_author "alice" 3 in
  let freq = D.author_frequencies posts in
  let count = D.Author_map.find (agent_id_of_string "alice") freq in
  check int "alice = 3" 3 count

let test_author_frequencies_mixed () =
  let posts = posts_of_author "alice" 2 @ posts_of_author "bob" 3 in
  let freq = D.author_frequencies posts in
  let alice = D.Author_map.find (agent_id_of_string "alice") freq in
  let bob = D.Author_map.find (agent_id_of_string "bob") freq in
  check int "alice = 2" 2 alice;
  check int "bob = 3" 3 bob

let test_find_dead_zones_none () =
  let posts = alternating_posts ["alice"; "bob"; "charlie"] 9 in
  let zones = D.find_dead_zones posts in
  check int "no dead zones" 0 (List.length zones)

let test_find_dead_zones_single () =
  let posts = posts_of_author "alice" 5 in
  let zones = D.find_dead_zones posts in
  check (list int) "zones = [2;3;4]" [2;3;4] zones

let test_find_dead_zones_overlap () =
  let posts =
    posts_of_author "alice" 5
    @ alternating_posts ["bob"; "charlie"] 2
    @ posts_of_author "dave" 4
  in
  let zones = D.find_dead_zones posts in
  check (list int) "alice zones [2;3;4], dave zones [9;10]" [2;3;4;9;10] zones

let test_find_dead_zones_exact_three () =
  let posts = posts_of_author "alice" 3 @ alternating_posts ["bob"; "charlie"] 6 in
  let zones = D.find_dead_zones posts in
  check (list int) "exact 3-run = [2]" [2] zones

let test_find_dead_zones_two_separate () =
  let posts =
    posts_of_author "alice" 4
    @ alternating_posts ["bob"; "charlie"] 4
    @ posts_of_author "dave" 3
  in
  let zones = D.find_dead_zones posts in
  check (list int) "zones = [2;3;9]" [2;3;9] zones

let test_rerank_for_diversity_recent () =
  let posts = posts_of_author "alice" 10 in
  let result = D.rerank_for_diversity ~posts ~sort_by:`Recent in
  check int "same length" 10 (List.length result);
  let authors = List.map (fun p -> Board_types.Agent_id.to_string p.author) result in
  let all_alice = List.for_all (fun a -> a = "alice") authors in
  check bool "no-op for Recent" true all_alice

let test_rerank_for_diversity_hot () =
  let posts =
    posts_of_author "alice" 7 @ posts_of_author "bob" 3
  in
  let result = D.rerank_for_diversity ~posts ~sort_by:`Hot in
  check int "same length" 10 (List.length result);
  let unique_authors =
    List.map (fun p -> Board_types.Agent_id.to_string p.author) result
    |> List.sort_uniq String.compare
  in
  check int "both authors present" 2 (List.length unique_authors)

(* ── QCheck properties ───────────────────────────────────── *)

(** Generator: a list of posts with random author assignments. *)
let post_list_gen =
  let open QCheck.Gen in
  let string_gen = string_size (int_range 1 8) in
  let author_gen = map (fun s -> agent_id_of_string s) string_gen in
  let post_gen =
    map3
      (fun author i votes_up ->
        make_post ~author
          ~id:(Printf.sprintf "p-%s-%d" (Board_types.Agent_id.to_string author) i)
          ~created_at:(float i) ~votes_up)
      author_gen (int_range 1 200) (int_range 0 1000)
  in
  list_size (int_range 0 30) post_gen

let qc_author_frequencies_sum =
  QCheck.Test.make ~name:"author_frequencies: sum of counts = list length"
    ~count:200
    (QCheck.make post_list_gen)
    (fun posts ->
      let freq = D.author_frequencies posts in
      let total = D.Author_map.fold (fun _ v acc -> acc + v) freq 0 in
      total = List.length posts)

let qc_dead_zones_every_zone_is_valid =
  QCheck.Test.make ~name:"find_dead_zones: every zone index starts a 3+ run"
    ~count:200
    (QCheck.make post_list_gen)
    (fun posts ->
      let zones = D.find_dead_zones posts in
      List.for_all (fun zi ->
        zi >= 2
        && zi < List.length posts
        && Board_types.Agent_id.equal
             (List.nth posts (zi - 2)).author
             (List.nth posts (zi - 1)).author
        && Board_types.Agent_id.equal
             (List.nth posts (zi - 1)).author
             (List.nth posts zi).author)
      zones)

let qc_dead_zones_no_false_negative =
  QCheck.Test.make ~name:"find_dead_zones: no 3+ run goes undetected"
    ~count:200
    (QCheck.make post_list_gen)
    (fun posts ->
      let zones = D.find_dead_zones posts in
      (* Use array for O(1) reads — avoids List.nth scan *)
      let arr = Array.of_list posts in
      let n = Array.length arr in
      let result = ref true in
      for i = 0 to n - 3 do
        let a = arr.(i).author in
        let b = arr.(i + 1).author in
        let c = arr.(i + 2).author in
        if Board_types.Agent_id.equal a b && Board_types.Agent_id.equal b c then
          if not (List.mem (i + 2) zones) then result := false
      done;
      !result)

let qc_rerank_preserves_length =
  QCheck.Test.make ~name:"rerank_for_diversity: output length = input length"
    ~count:100
    (QCheck.make post_list_gen)
    (fun posts ->
      let result = D.rerank_for_diversity ~posts ~sort_by:`Hot in
      List.length result = List.length posts)

let qc_rerank_no_duplicates =
  QCheck.Test.make ~name:"rerank_for_diversity: no duplicate posts"
    ~count:100
    (QCheck.make post_list_gen)
    (fun posts ->
      let result = D.rerank_for_diversity ~posts ~sort_by:`Hot in
      let ids = List.map (fun p -> p.Board_types.id) result in
      let unique = List.sort_uniq Board_types.Post_id.compare ids in
      List.length ids = List.length unique)

let qc_rerank_no_new_posts =
  QCheck.Test.make ~name:"rerank_for_diversity: no posts added or removed"
    ~count:100
    (QCheck.make post_list_gen)
    (fun posts ->
      let result = D.rerank_for_diversity ~posts ~sort_by:`Hot in
      let input_ids = List.map (fun p -> p.Board_types.id) posts in
      let output_ids = List.map (fun p -> p.Board_types.id) result in
      let all_present = List.for_all (fun id -> List.mem id output_ids) input_ids in
      let no_extras = List.for_all (fun id -> List.mem id input_ids) output_ids in
      all_present && no_extras)

(* ── Registry ──────────────────────────────────────────── *)

let suite =
  [
    ("author_frequencies: empty", `Quick, test_author_frequencies_empty);
    ("author_frequencies: single author", `Quick, test_author_frequencies_single);
    ("author_frequencies: mixed authors", `Quick, test_author_frequencies_mixed);
    ("find_dead_zones: no zones", `Quick, test_find_dead_zones_none);
    ("find_dead_zones: single run", `Quick, test_find_dead_zones_single);
    ("find_dead_zones: overlapping runs", `Quick, test_find_dead_zones_overlap);
    ("find_dead_zones: exact three", `Quick, test_find_dead_zones_exact_three);
    ("find_dead_zones: two separate runs", `Quick, test_find_dead_zones_two_separate);
    ("rerank_for_diversity: Recent no-op", `Quick, test_rerank_for_diversity_recent);
    ("rerank_for_diversity: Hot preserves authors", `Quick, test_rerank_for_diversity_hot);
  ]

let () =
  Alcotest.run "Board_diversity" [
    "unit", suite;
  ];
  QCheck_runner.run_tests ~verbose:true [
    qc_author_frequencies_sum;
    qc_dead_zones_every_zone_is_valid;
    qc_dead_zones_no_false_negative;
    qc_rerank_preserves_length;
    qc_rerank_no_duplicates;
    qc_rerank_no_new_posts;
  ]