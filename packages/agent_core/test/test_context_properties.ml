(** QCheck property-based tests for Context.t.

    Verifies:
    - Scope isolation (create_scope / merge_back)
    - Copy independence
    - Serialization roundtrip
    - Diff correctness
    - Key non-leakage across scopes *)

open Agent_sdk

(* ── Generators ────────────────────────────────────────── *)

let gen_key =
  QCheck.Gen.(
    let* len = int_range 1 20 in
    let* chars = list_size (return len) (char_range 'a' 'z') in
    return (String.init len (fun i -> List.nth chars i)))
;;

let gen_value =
  QCheck.Gen.(
    oneof
      [ map (fun s -> `String s) (string_size ~gen:(char_range 'a' 'z') (int_range 1 30))
      ; map (fun i -> `Int i) (int_range (-1000) 1000)
      ; return (`Bool true)
      ; return (`Bool false)
      ; return `Null
      ])
;;

let gen_kv_pair = QCheck.Gen.(pair gen_key gen_value)
let gen_kv_list = QCheck.Gen.(list_size (int_range 0 20) gen_kv_pair)

(* ── Property 1: Copy Independence ─────────────────────── *)

let test_copy_independence =
  QCheck.Test.make
    ~count:200
    ~name:"copy_independence"
    QCheck.(pair (make gen_kv_list) (make gen_kv_pair))
    (fun (initial_pairs, (new_key, new_value)) ->
       let ctx = Context.create_sync () in
       List.iter (fun (k, v) -> Context.set ctx k v) initial_pairs;
       let copy = Context.copy ctx in
       (* Mutate copy *)
       Context.set copy new_key new_value;
       Context.delete copy "nonexistent_sentinel";
       (* Original must be unaffected by copy mutation *)
       let orig_snapshot = Context.snapshot ctx in
       (* Original should have same keys as initial (modulo dedup by last write) *)
       let orig_keys = List.map fst orig_snapshot in
       let expected_keys =
         List.rev initial_pairs
         |> List.sort_uniq (fun (a, _) (b, _) -> String.compare a b)
         |> List.map fst
       in
       (* Key count should match: copy mutation must not affect original *)
       List.length orig_keys = List.length expected_keys)
;;

(* ── Property 2: Serialization Roundtrip ───────────────── *)

let test_json_roundtrip =
  QCheck.Test.make
    ~count:200
    ~name:"json_roundtrip"
    (QCheck.make gen_kv_list)
    (fun pairs ->
       let ctx = Context.create_sync () in
       List.iter (fun (k, v) -> Context.set ctx k v) pairs;
       let json = Context.to_json ctx in
       let restored = Context.of_json json in
       let original_snapshot = Context.snapshot ctx in
       let restored_snapshot = Context.snapshot restored in
       original_snapshot = restored_snapshot)
;;

(* ── Property 3: Scope Isolation — No Leakage ─────────── *)

let test_scope_no_leakage =
  QCheck.Test.make
    ~count:300
    ~name:"scope_no_leakage"
    QCheck.(
      triple
        (make gen_kv_list) (* parent initial keys *)
        (make gen_kv_list) (* keys written in child scope *)
        (make gen_kv_list))
    (* propagate_down/up lists *)
    (fun (parent_pairs, child_pairs, prop_pairs) ->
       let parent = Context.create_sync () in
       List.iter (fun (k, v) -> Context.set parent k v) parent_pairs;
       let parent_before = Context.snapshot parent in
       (* Choose propagate lists from prop_pairs keys *)
       let prop_down = List.map fst prop_pairs in
       let prop_up_keys =
         if child_pairs = [] then [] else [ fst (List.hd child_pairs) ]
       in
       let scope =
         Context.create_scope ~parent ~propagate_down:prop_down ~propagate_up:prop_up_keys
       in
       (* Write to child scope *)
       List.iter (fun (k, v) -> Context.set scope.local k v) child_pairs;
       (* Before merge_back: parent should be UNCHANGED *)
       let parent_during = Context.snapshot parent in
       let parent_unchanged = parent_before = parent_during in
       (* After merge_back: only prop_up keys should appear *)
       Context.merge_back scope;
       let parent_after = Context.snapshot parent in
       (* Check: keys NOT in prop_up should not have been added from child *)
       let child_only_keys =
         List.map fst child_pairs
         |> List.filter (fun k -> not (List.mem k prop_up_keys))
         |> List.filter (fun k ->
           (* Exclude keys that were already in parent *)
           not (List.exists (fun (pk, _) -> pk = k) parent_pairs))
       in
       let no_leak =
         List.for_all
           (fun k ->
              (* This key should NOT exist in parent unless it was there originally *)
              match List.assoc_opt k parent_after with
              | None -> true
              | Some v ->
                (* If it exists, it must have been in parent_before *)
                List.exists (fun (pk, pv) -> pk = k && pv = v) parent_before)
           child_only_keys
       in
       parent_unchanged && no_leak)
;;

(* ── Property 4: propagate_down Completeness ───────────── *)

let test_propagate_down_complete =
  QCheck.Test.make
    ~count:200
    ~name:"propagate_down_complete"
    (QCheck.make gen_kv_list)
    (fun pairs ->
       let parent = Context.create_sync () in
       List.iter (fun (k, v) -> Context.set parent k v) pairs;
       let all_keys = List.sort_uniq String.compare (List.map fst pairs) in
       let scope =
         Context.create_scope ~parent ~propagate_down:all_keys ~propagate_up:[]
       in
       (* All requested keys should be in local *)
       List.for_all
         (fun k ->
            let parent_val = Context.get parent k in
            let local_val = Context.get scope.local k in
            parent_val = local_val)
         all_keys)
;;

(* ── Property 5: propagate_up Selective ────────────────── *)

let test_propagate_up_selective =
  QCheck.Test.make
    ~count:200
    ~name:"propagate_up_selective"
    QCheck.(pair (make gen_kv_list) (make gen_kv_list))
    (fun (child_pairs, extra_pairs) ->
       let parent = Context.create_sync () in
       (* Only first pair's key is in propagate_up (if any) *)
       let up_keys =
         match child_pairs with
         | (k, _) :: _ -> [ k ]
         | [] -> []
       in
       let scope =
         Context.create_scope ~parent ~propagate_down:[] ~propagate_up:up_keys
       in
       (* Write all pairs to child *)
       List.iter (fun (k, v) -> Context.set scope.local k v) child_pairs;
       List.iter (fun (k, v) -> Context.set scope.local k v) extra_pairs;
       Context.merge_back scope;
       (* Only up_keys should be in parent *)
       let parent_keys = Context.keys parent in
       List.for_all (fun pk -> List.mem pk up_keys) parent_keys)
;;

(* ── Property 6: Diff Correctness ──────────────────────── *)

let test_diff_correct =
  QCheck.Test.make
    ~count:200
    ~name:"diff_correct"
    QCheck.(pair (make gen_kv_list) (make gen_kv_list))
    (fun (before_pairs, after_pairs) ->
       let before = Context.create_sync () in
       let after = Context.create_sync () in
       List.iter (fun (k, v) -> Context.set before k v) before_pairs;
       List.iter (fun (k, v) -> Context.set after k v) after_pairs;
       let d = Context.diff before after in
       let before_snap = Context.snapshot before in
       let after_snap = Context.snapshot after in
       (* added: in after but not in before *)
       let added_ok =
         List.for_all
           (fun (k, _) -> not (List.exists (fun (bk, _) -> bk = k) before_snap))
           d.added
       in
       (* removed: in before but not in after *)
       let removed_ok =
         List.for_all
           (fun k -> not (List.exists (fun (ak, _) -> ak = k) after_snap))
           d.removed
       in
       (* changed: in both, different value *)
       let changed_ok =
         List.for_all
           (fun (k, new_v) ->
              match List.assoc_opt k before_snap with
              | Some old_v -> old_v <> new_v && List.assoc_opt k after_snap = Some new_v
              | None -> false)
           d.changed
       in
       added_ok && removed_ok && changed_ok)
;;

(* ── Property 7: Scope Keys Never Cross-Contaminate ────── *)

let test_scope_isolation_parallel =
  QCheck.Test.make
    ~count:100
    ~name:"parallel_scope_isolation"
    QCheck.(pair (make gen_kv_list) (make gen_kv_list))
    (fun (pairs_a, pairs_b) ->
       let parent = Context.create_sync () in
       (* Two isolated scopes from same parent *)
       let scope_a =
         Context.create_scope ~parent ~propagate_down:[] ~propagate_up:[ "result_a" ]
       in
       let scope_b =
         Context.create_scope ~parent ~propagate_down:[] ~propagate_up:[ "result_b" ]
       in
       (* Write different data to each *)
       List.iter (fun (k, v) -> Context.set scope_a.local k v) pairs_a;
       Context.set scope_a.local "result_a" (`String "from_a");
       List.iter (fun (k, v) -> Context.set scope_b.local k v) pairs_b;
       Context.set scope_b.local "result_b" (`String "from_b");
       (* Merge both back *)
       Context.merge_back scope_a;
       Context.merge_back scope_b;
       (* Parent should have exactly result_a and result_b *)
       let parent_keys = List.sort String.compare (Context.keys parent) in
       parent_keys = [ "result_a"; "result_b" ]
       && Context.get parent "result_a" = Some (`String "from_a")
       && Context.get parent "result_b" = Some (`String "from_b"))
;;

(* ── Runner ────────────────────────────────────────────── *)

let () =
  let suite =
    List.map
      QCheck_alcotest.to_alcotest
      [ test_copy_independence
      ; test_json_roundtrip
      ; test_scope_no_leakage
      ; test_propagate_down_complete
      ; test_propagate_up_selective
      ; test_diff_correct
      ; test_scope_isolation_parallel
      ]
  in
  Alcotest.run "Context.t Properties" [ "qcheck", suite ]
;;
