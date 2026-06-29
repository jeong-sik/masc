(** Verify cap_snapshot bounds string and list growth.

    Gen7 persistence-layer guard against keeper_state_snapshot monotonic
    growth. Gen3 closed the prompt injection side, Gen4 closed the OAS
    compaction side; this caps the production side so meta.continuity_
    summary itself stops growing unboundedly even if the LLM emits
    longer [STATE] blocks turn after turn. *)

module KMP = Masc.Keeper_memory_policy

let long_string n ch = String.make n ch

let make_snapshot
    ?(priority = None)
    ?(goal = Some "short goal")
    ?(progress = None)
    ?(done_summary = None)
    ?(next_summary = None)
    ?(next_items = [])
    ?(decisions = [])
    ?(open_questions = [])
    ?(constraints = [])
    () : KMP.keeper_state_snapshot =
  { priority; goal; progress; done_summary; next_summary;
    next_items; decisions; open_questions; constraints }

let test_short_snapshot_unchanged () =
  let s = make_snapshot ~goal:(Some "ok") ~next_items:[ "a"; "b" ] () in
  let c = KMP.cap_snapshot s in
  Alcotest.(check (option string)) "goal unchanged" (Some "ok") c.goal;
  Alcotest.(check (list string)) "next_items unchanged" [ "a"; "b" ] c.next_items

let test_cap_long_string () =
  let s = make_snapshot ~goal:(Some (long_string 1000 'x')) () in
  let c = KMP.cap_snapshot ~max_string_chars:100 s in
  match c.goal with
  | Some cg ->
    (* 100 chars + 1 ellipsis codepoint (3 UTF-8 bytes in OCaml). *)
    Alcotest.(check bool) "goal length near cap"
      true (String.length cg <= 100 + 3);
    Alcotest.(check bool) "ellipsis appended"
      true (Astring.String.is_suffix ~affix:"…" cg)
  | None -> Alcotest.fail "expected capped goal"

let test_cap_long_list () =
  let items = List.init 20 (fun i -> Printf.sprintf "item-%d" i) in
  let s = make_snapshot ~decisions:items () in
  let c = KMP.cap_snapshot ~max_list_items:5 s in
  Alcotest.(check int) "decisions capped to 5"
    5 (List.length c.decisions);
  Alcotest.(check string) "first item preserved"
    "item-0" (List.hd c.decisions)

let test_cap_long_item_in_list () =
  let long_item = long_string 1000 'z' in
  let s = make_snapshot ~decisions:[ long_item ] () in
  let c = KMP.cap_snapshot ~max_item_chars:50 s in
  match c.decisions with
  | [ item ] ->
    Alcotest.(check bool) "item length near cap"
      true (String.length item <= 50 + 3);
    Alcotest.(check bool) "ellipsis appended"
      true (Astring.String.is_suffix ~affix:"…" item)
  | _ -> Alcotest.fail "expected single decision"

let test_none_fields_stay_none () =
  let s = make_snapshot () in
  let c = KMP.cap_snapshot s in
  Alcotest.(check (option string)) "progress stays None" None c.progress;
  Alcotest.(check (option string)) "done stays None" None c.done_summary

let test_idempotence () =
  let items = List.init 20 (fun i -> Printf.sprintf "item-%d" i) in
  let s = make_snapshot
    ~goal:(Some (long_string 500 'q'))
    ~decisions:items ()
  in
  let c1 = KMP.cap_snapshot s in
  let c2 = KMP.cap_snapshot c1 in
  Alcotest.(check (option string)) "goal idempotent" c1.goal c2.goal;
  Alcotest.(check (list string)) "decisions idempotent"
    c1.decisions c2.decisions

let test_continuity_summary_text_capped () =
  let capped =
    KMP.cap_continuity_summary_text ~max_chars:80 (long_string 500 'c')
  in
  Alcotest.(check bool) "summary length near cap"
    true (String.length capped <= 80 + 3);
  Alcotest.(check bool) "ellipsis appended"
    true (Astring.String.is_suffix ~affix:"…" capped)

let test_continuity_fallback_caps_legacy_summary () =
  let rendered =
    KMP.continuity_fallback_summary_text
      ~continuity_summary:(long_string 10_000 'f')
      ~last_continuity_update_ts:0.0
  in
  Alcotest.(check bool) "freshness retained"
    true (Astring.String.is_infix ~affix:"Freshness:" rendered);
  let payload =
    rendered
    |> String.split_on_char '\n'
    |> List.rev
    |> List.find_opt (fun line -> String.trim line <> "")
  in
  let payload = Option.value payload ~default:"" in
  Alcotest.(check bool) "legacy payload capped"
    true (String.length payload <= KMP.default_continuity_summary_max_chars + 3);
  Alcotest.(check bool) "legacy payload has ellipsis"
    true (Astring.String.is_suffix ~affix:"…" payload)

let () =
  Alcotest.run "snapshot_size_cap"
    [ ( "cap_snapshot",
        [ Alcotest.test_case "short snapshot unchanged" `Quick
            test_short_snapshot_unchanged;
          Alcotest.test_case "long string capped with ellipsis" `Quick
            test_cap_long_string;
          Alcotest.test_case "long list truncated" `Quick
            test_cap_long_list;
          Alcotest.test_case "long item in list capped" `Quick
            test_cap_long_item_in_list;
          Alcotest.test_case "None fields stay None" `Quick
            test_none_fields_stay_none;
          Alcotest.test_case "cap is idempotent" `Quick
            test_idempotence;
          Alcotest.test_case "continuity summary text capped" `Quick
            test_continuity_summary_text_capped;
          Alcotest.test_case "fallback caps legacy summary" `Quick
            test_continuity_fallback_caps_legacy_summary;
        ] );
    ]
