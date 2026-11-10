module Index = Keeper_tool_call_index

let with_store f =
  let root = Filename.temp_file "execution-fold-" ".store" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let store = Dated_jsonl.open_store
    (Dated_jsonl.Store.at (Dated_jsonl.Store.root_of_masc_dir root)
      Dated_jsonl.Store.Root.Tool_calls) in
  Fun.protect
    ~finally:(fun () ->
      Index.forget_for_ledger ~ledger_dir:(Dated_jsonl.base_dir store);
      Fs_compat.remove_tree root)
    (fun () -> f store)

let append store ~keeper ~execution_id ~tool =
  Dated_jsonl.append store
    (`Assoc ["ts", `Float (Unix.gettimeofday ()); "keeper", `String keeper;
             "execution_id", `String execution_id; "tool", `String tool])

let get = function Ok value -> value | Error detail -> Alcotest.fail detail

let test_empty_selection_does_not_read_the_index () =
  with_store (fun store ->
    let result = Index.fold_by_execution_ids ~store ~keeper_name:"alice"
      ~execution_ids:[] ~init:42 ~f:(fun _ _ -> Alcotest.fail "Unexpected callback") in
    Alcotest.(check int) "empty identity set keeps the accumulator" 42 (get result);
    let database = Index.database_path ~ledger_dir:(Dated_jsonl.base_dir store) in
    Alcotest.(check bool) "empty selection creates no derived index" false (Sys.file_exists database))

let test_owner_and_ambiguous_occurrences_are_preserved () =
  with_store (fun store ->
    append store ~keeper:"alice" ~execution_id:"duplicate" ~tool:"first";
    append store ~keeper:"bob" ~execution_id:"duplicate" ~tool:"foreign";
    append store ~keeper:"alice" ~execution_id:"duplicate" ~tool:"second";
    append store ~keeper:"alice" ~execution_id:"unique" ~tool:"own";
    append store ~keeper:"bob" ~execution_id:"foreign-only" ~tool:"foreign-only";
    let rows = Index.fold_by_execution_ids ~store ~keeper_name:"alice"
      ~execution_ids:["unique"; "duplicate"; "duplicate"; "missing"; "foreign-only"]
      ~init:[] ~f:(fun rows row ->
        let open Yojson.Safe.Util in
        Ok ((row |> member "execution_id" |> to_string,
             row |> member "tool" |> to_string) :: rows)) |> get in
    Alcotest.(check (list (pair string string)))
      "both ambiguous occurrences survive, without foreign or repeated-request rows"
      ["duplicate", "first"; "duplicate", "second"; "unique", "own"]
      (List.sort compare rows))

let test_semantic_refusal_does_not_replay_or_rebuild () =
  with_store (fun store ->
    append store ~keeper:"alice" ~execution_id:"one" ~tool:"one";
    append store ~keeper:"alice" ~execution_id:"two" ~tool:"two";
    let count () = Index.fold_by_execution_ids ~store ~keeper_name:"alice"
      ~execution_ids:["one"; "two"] ~init:0 ~f:(fun n _ -> Ok (n + 1)) |> get in
    Alcotest.(check int) "both source rows are readable" 2 (count ());
    let database = Index.database_path ~ledger_dir:(Dated_jsonl.base_dir store) in
    let before = Unix.stat database in
    let callbacks = ref 0 in
    let result = Index.fold_by_execution_ids ~store ~keeper_name:"alice"
      ~execution_ids:["one"; "two"] ~init:()
      ~f:(fun () _ -> incr callbacks; Error "semantic-refusal") in
    Alcotest.(check (result unit string)) "the caller's refusal is retained"
      (Error "semantic-refusal") result;
    Alcotest.(check int) "a semantic refusal is not retried" 1 !callbacks;
    let after = Unix.stat database in
    Alcotest.(check (pair int int)) "the valid derived index remains"
      (before.st_dev, before.st_ino) (after.st_dev, after.st_ino);
    Alcotest.(check int) "the next fold can read both rows" 2 (count ()))

let () =
  Alcotest.run "keeper_tool_call_execution_fold"
    ["execution identities",
      [Alcotest.test_case "empty selection does no read" `Quick test_empty_selection_does_not_read_the_index;
       Alcotest.test_case "owner and ambiguous occurrences" `Quick test_owner_and_ambiguous_occurrences_are_preserved;
       Alcotest.test_case "semantic refusal preserves the index" `Quick test_semantic_refusal_does_not_replay_or_rebuild]]
