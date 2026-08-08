open Agent_sdk

(* ── Helpers ──────────────────────────────────────────────── *)

let make_tool name =
  Tool.create ~name ~description:("desc_" ^ name) ~parameters:[] (fun _ ->
    Ok { Types.content = "ok"; _meta = None })
;;

let make_tool_v2 name =
  Tool.create ~name ~description:("v2_" ^ name) ~parameters:[] (fun _ ->
    Ok { Types.content = "v2"; _meta = None })
;;

(* ── Alcotest ────────────────────────────────────────────── *)

let test_empty () =
  Alcotest.(check int) "empty size" 0 (Tool_set.size Tool_set.empty);
  Alcotest.(check (list string)) "empty names" [] (Tool_set.names Tool_set.empty);
  Alcotest.(check (list string))
    "empty to_list"
    []
    (List.map (fun (t : Tool.t) -> t.schema.name) (Tool_set.to_list Tool_set.empty))
;;

let test_singleton () =
  let t = make_tool "alpha" in
  let s = Tool_set.singleton t in
  Alcotest.(check int) "singleton size" 1 (Tool_set.size s);
  Alcotest.(check (list string)) "singleton names" [ "alpha" ] (Tool_set.names s);
  Alcotest.(check bool) "singleton mem" true (Tool_set.mem "alpha" s);
  Alcotest.(check bool) "singleton not mem" false (Tool_set.mem "beta" s)
;;

let test_of_list_dedup () =
  let t1 = make_tool "alpha" in
  let t2 = make_tool_v2 "alpha" in
  let s = Tool_set.of_list [ t1; t2 ] in
  Alcotest.(check int) "dedup size" 1 (Tool_set.size s);
  (* last-writer-wins *)
  match Tool_set.find "alpha" s with
  | None -> Alcotest.fail "expected to find alpha"
  | Some found -> Alcotest.(check string) "last wins" "v2_alpha" found.schema.description
;;

let test_merge_last_writer_wins () =
  let a = Tool_set.of_list [ make_tool "x"; make_tool "y" ] in
  let b = Tool_set.of_list [ make_tool_v2 "y"; make_tool "z" ] in
  let m = Tool_set.merge a b in
  Alcotest.(check int) "merge size" 3 (Tool_set.size m);
  match Tool_set.find "y" m with
  | None -> Alcotest.fail "expected y"
  | Some found -> Alcotest.(check string) "right wins" "v2_y" found.schema.description
;;

let test_validate_ok () =
  let s = Tool_set.of_list [ make_tool "a"; make_tool "b" ] in
  match Tool_set.validate s with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "expected Ok"
;;

let test_concat () =
  let a = Tool_set.singleton (make_tool "a") in
  let b = Tool_set.singleton (make_tool "b") in
  let c = Tool_set.singleton (make_tool "c") in
  let all = Tool_set.concat [ a; b; c ] in
  Alcotest.(check int) "concat size" 3 (Tool_set.size all);
  Alcotest.(check (list string))
    "concat names"
    [ "a"; "b"; "c" ]
    (List.sort String.compare (Tool_set.names all))
;;

(* ── QCheck property tests ───────────────────────────────── *)

let gen_tool_name =
  QCheck.Gen.(
    let* len = int_range 1 8 in
    let* chars = list_size (return len) (char_range 'a' 'z') in
    return (String.init len (fun i -> List.nth chars i)))
;;

let gen_tool =
  QCheck.Gen.(
    let* name = gen_tool_name in
    return (make_tool name))
;;

let gen_tool_set =
  QCheck.Gen.(
    let* tools = list_size (int_range 0 10) gen_tool in
    return (Tool_set.of_list tools))
;;

let arb_tool_set = QCheck.make gen_tool_set

(** Associativity: merge (merge a b) c = merge a (merge b c) *)
let prop_merge_assoc =
  QCheck.Test.make
    ~count:200
    ~name:"merge_associativity"
    QCheck.(triple arb_tool_set arb_tool_set arb_tool_set)
    (fun (a, b, c) ->
       let lhs = Tool_set.merge (Tool_set.merge a b) c in
       let rhs = Tool_set.merge a (Tool_set.merge b c) in
       let names_eq =
         List.sort String.compare (Tool_set.names lhs)
         = List.sort String.compare (Tool_set.names rhs)
       in
       let size_eq = Tool_set.size lhs = Tool_set.size rhs in
       names_eq && size_eq)
;;

(** Left identity: merge empty s = s *)
let prop_merge_left_id =
  QCheck.Test.make ~count:200 ~name:"merge_left_identity" arb_tool_set (fun s ->
    let m = Tool_set.merge Tool_set.empty s in
    Tool_set.size m = Tool_set.size s
    && List.sort String.compare (Tool_set.names m)
       = List.sort String.compare (Tool_set.names s))
;;

(** Right identity: merge s empty = s *)
let prop_merge_right_id =
  QCheck.Test.make ~count:200 ~name:"merge_right_identity" arb_tool_set (fun s ->
    let m = Tool_set.merge s Tool_set.empty in
    Tool_set.size m = Tool_set.size s
    && List.sort String.compare (Tool_set.names m)
       = List.sort String.compare (Tool_set.names s))
;;

(** Idempotence: merge s s = s *)
let prop_merge_idempotent =
  QCheck.Test.make ~count:200 ~name:"merge_idempotent" arb_tool_set (fun s ->
    let m = Tool_set.merge s s in
    Tool_set.size m = Tool_set.size s
    && List.sort String.compare (Tool_set.names m)
       = List.sort String.compare (Tool_set.names s))
;;

(** validate always Ok for well-constructed sets *)
let prop_validate_ok =
  QCheck.Test.make ~count:200 ~name:"validate_always_ok" arb_tool_set (fun s ->
    Tool_set.validate s = Ok ())
;;

(* ── Runner ──────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Tool_set"
    [ ( "unit"
      , [ Alcotest.test_case "empty" `Quick test_empty
        ; Alcotest.test_case "singleton" `Quick test_singleton
        ; Alcotest.test_case "of_list dedup" `Quick test_of_list_dedup
        ; Alcotest.test_case "merge last-writer-wins" `Quick test_merge_last_writer_wins
        ; Alcotest.test_case "validate ok" `Quick test_validate_ok
        ; Alcotest.test_case "concat" `Quick test_concat
        ] )
    ; ( "properties"
      , List.map
          QCheck_alcotest.to_alcotest
          [ prop_merge_assoc
          ; prop_merge_left_id
          ; prop_merge_right_id
          ; prop_merge_idempotent
          ; prop_validate_ok
          ] )
    ]
;;
