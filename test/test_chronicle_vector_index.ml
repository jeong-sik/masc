(** Unit tests for Chronicle_vector_index (RFC-0035 PR-9,
    Master Report Dim02 P1 vector embedder). *)

open Masc_mcp.Chronicle_vector_index
module CE = Masc_mcp.Chronicle_event

let approx_eq a b = Float.abs (a -. b) <= 0.0001

let make_event ?(id = "ev-x") ?(timestamp = 1_000) () : CE.t =
  {
    id;
    event_type = CE.Ev_keeper_step;
    timestamp;
    actor = { kind = CE.Ak_keeper; id = "k1"; display_name = "Keeper" };
    target = { kind = CE.Tk_file; uri = "lib/x.ml"; range = None };
    content = { summary = "summary"; detail = None; diff = None; metadata = [] };
    context = {
      session_id = "s1";
      parent_event_id = None;
      related_event_ids = [];
      tags = [];
      project_state = None;
    };
    intent = None;
  }

let test_empty_without_dim () =
  let idx = empty () in
  Alcotest.(check int) "empty len" 0 (len idx);
  Alcotest.(check bool) "empty dim is None" true (dim idx = None)

let test_empty_with_dim () =
  let idx = empty ~dim:768 () in
  Alcotest.(check bool) "explicit dim preserved" true (dim idx = Some 768);
  Alcotest.(check int) "still empty" 0 (len idx)

let test_add_infers_dim () =
  let idx = empty () in
  match add_event idx (make_event ~id:"a" ()) [| 1.0; 0.0; 0.0 |] with
  | Ok idx' ->
    Alcotest.(check bool) "dim inferred to 3" true (dim idx' = Some 3);
    Alcotest.(check int) "len 1" 1 (len idx')
  | Error msg -> Alcotest.failf "add failed: %s" msg

let test_add_dim_mismatch_rejected () =
  let idx = empty ~dim:3 () in
  match add_event idx (make_event ~id:"a" ()) [| 1.0; 0.0 |] with
  | Ok _ -> Alcotest.fail "expected dim mismatch error"
  | Error _ -> ()

let test_add_explicit_dim_match () =
  let idx = empty ~dim:3 () in
  match add_event idx (make_event ~id:"a" ()) [| 1.0; 0.0; 0.0 |] with
  | Ok idx' -> Alcotest.(check int) "added" 1 (len idx')
  | Error msg -> Alcotest.failf "should accept matching dim: %s" msg

let test_cosine_similarity_unit_vectors () =
  let v1 = [| 1.0; 0.0 |] in
  let v2 = [| 0.0; 1.0 |] in
  let v3 = [| 1.0; 0.0 |] in
  Alcotest.(check bool) "orthogonal -> 0" true
    (approx_eq (cosine_similarity v1 v2) 0.0);
  Alcotest.(check bool) "identical -> 1" true
    (approx_eq (cosine_similarity v1 v3) 1.0);
  let v_neg = [| -1.0; 0.0 |] in
  Alcotest.(check bool) "opposite -> -1" true
    (approx_eq (cosine_similarity v1 v_neg) (-1.0))

let test_cosine_zero_vector () =
  let zero = [| 0.0; 0.0; 0.0 |] in
  let v = [| 1.0; 2.0; 3.0 |] in
  Alcotest.(check bool) "zero vector cos = 0" true
    (approx_eq (cosine_similarity zero v) 0.0);
  Alcotest.(check bool) "zero vs zero cos = 0" true
    (approx_eq (cosine_similarity zero zero) 0.0)

let test_cosine_dim_mismatch_returns_zero () =
  let v1 = [| 1.0; 2.0 |] in
  let v2 = [| 1.0; 2.0; 3.0 |] in
  Alcotest.(check bool) "dim mismatch returns 0 (not raise)" true
    (approx_eq (cosine_similarity v1 v2) 0.0)

let test_normalize_unit_length () =
  let v = [| 3.0; 4.0 |] in
  let n = normalize v in
  let mag = Float.sqrt ((n.(0) *. n.(0)) +. (n.(1) *. n.(1))) in
  Alcotest.(check bool) "normalised has unit norm" true (approx_eq mag 1.0)

let test_normalize_zero_vector () =
  let zero = [| 0.0; 0.0 |] in
  let n = normalize zero in
  Alcotest.(check bool) "zero vector unchanged" true
    (n.(0) = 0.0 && n.(1) = 0.0)

let test_search_orders_by_similarity () =
  let idx = empty () in
  let idx = Result.get_ok (add_event idx (make_event ~id:"orth" ())
                             [| 0.0; 1.0 |]) in
  let idx = Result.get_ok (add_event idx (make_event ~id:"same" ())
                             [| 1.0; 0.0 |]) in
  let idx = Result.get_ok (add_event idx (make_event ~id:"close" ())
                             [| 0.9; 0.4 |]) in
  let result = search idx ~query:[| 1.0; 0.0 |] () in
  let order = List.map (fun (ev, _) -> ev.CE.id) result in
  Alcotest.(check (list string))
    "ordered: same > close > orth" [ "same"; "close"; "orth" ] order

let test_search_respects_limit () =
  let idx = empty () in
  let idx =
    [ "a"; "b"; "c"; "d" ]
    |> List.fold_left
         (fun acc id ->
           Result.get_ok
             (add_event acc (make_event ~id ()) [| 1.0; 0.0 |]))
         idx
  in
  let result = search idx ~query:[| 1.0; 0.0 |] ~limit:2 () in
  Alcotest.(check int) "limit clamps result count" 2 (List.length result)

let test_search_query_dim_mismatch_raises () =
  let idx = empty () in
  let idx =
    Result.get_ok (add_event idx (make_event ()) [| 1.0; 0.0; 0.0 |])
  in
  Alcotest.check_raises
    "dim mismatch on query raises Invalid_argument"
    (Invalid_argument
       "Chronicle_vector_index.search: query dim 2, index dim 3")
    (fun () -> ignore (search idx ~query:[| 1.0; 0.0 |] ()))

let test_search_empty_index () =
  let idx = empty () in
  let result = search idx ~query:[| 1.0; 2.0; 3.0 |] () in
  Alcotest.(check int) "empty index → empty result" 0 (List.length result)

let test_add_copies_embedding_isolating_caller_mutation () =
  let mutable_v = [| 1.0; 0.0 |] in
  let idx = empty () in
  let idx = Result.get_ok (add_event idx (make_event ~id:"a" ()) mutable_v) in
  mutable_v.(0) <- 99.0;
  let entries = to_list idx in
  let stored = (List.hd entries).embedding in
  Alcotest.(check bool)
    "caller mutation does not affect stored embedding" true
    (approx_eq stored.(0) 1.0)

let test_search_stable_for_ties () =
  let idx = empty () in
  let same_vec = [| 1.0; 0.0 |] in
  let idx = Result.get_ok (add_event idx (make_event ~id:"first" ()) same_vec) in
  let idx = Result.get_ok (add_event idx (make_event ~id:"second" ()) same_vec) in
  let idx = Result.get_ok (add_event idx (make_event ~id:"third" ()) same_vec) in
  let result = search idx ~query:[| 1.0; 0.0 |] () in
  let order = List.map (fun (ev, _) -> ev.CE.id) result in
  Alcotest.(check (list string))
    "tie order matches insertion order under stable sort"
    [ "first"; "second"; "third" ]
    order

let () =
  Alcotest.run "chronicle_vector_index"
    [
      ( "store",
        [
          Alcotest.test_case "empty without dim" `Quick
            test_empty_without_dim;
          Alcotest.test_case "empty with dim" `Quick test_empty_with_dim;
          Alcotest.test_case "add infers dim" `Quick test_add_infers_dim;
          Alcotest.test_case "dim mismatch rejected" `Quick
            test_add_dim_mismatch_rejected;
          Alcotest.test_case "explicit dim match" `Quick
            test_add_explicit_dim_match;
          Alcotest.test_case "add copies embedding" `Quick
            test_add_copies_embedding_isolating_caller_mutation;
        ] );
      ( "math",
        [
          Alcotest.test_case "cosine unit vectors" `Quick
            test_cosine_similarity_unit_vectors;
          Alcotest.test_case "cosine zero vector" `Quick
            test_cosine_zero_vector;
          Alcotest.test_case "cosine dim mismatch returns 0" `Quick
            test_cosine_dim_mismatch_returns_zero;
          Alcotest.test_case "normalize unit length" `Quick
            test_normalize_unit_length;
          Alcotest.test_case "normalize zero vector" `Quick
            test_normalize_zero_vector;
        ] );
      ( "search",
        [
          Alcotest.test_case "orders by similarity" `Quick
            test_search_orders_by_similarity;
          Alcotest.test_case "respects limit" `Quick
            test_search_respects_limit;
          Alcotest.test_case "query dim mismatch raises" `Quick
            test_search_query_dim_mismatch_raises;
          Alcotest.test_case "empty index" `Quick
            test_search_empty_index;
          Alcotest.test_case "stable for ties" `Quick
            test_search_stable_for_ties;
        ] );
    ]
