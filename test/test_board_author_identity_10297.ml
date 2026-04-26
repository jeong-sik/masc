(** #10297 — pin the dispatcher's identity-enforcement contract for
    [keeper_board_post] / [keeper_board_comment] /
    [keeper_board_vote] / [keeper_board_comment_vote].

    Pre-fix [ensure_board_post_author] only consulted the runtime
    contract's [agent_name] when the caller's [author] argument was
    blank.  Any non-blank caller-supplied [author] passed through
    canonicalisation without comparison, so an LLM running as
    keeper [velvet-hammer] could write [author = "analyst"] and
    impersonate a different principal on the public board.
    [canonicalize_board_actor_field] (board_comment, board_vote,
    comment_vote) didn't even receive [agent_name] — it could not
    have caught spoofing if it tried.

    These tests pin the unified [enforce_caller_identity]
    contract — the 3-branch SSOT pattern from
    feedback memory [mcp-dispatcher-ctx-agent-name-ssot]:

    1. Empty / "anonymous" caller field → fill from ctx canonical.
    2. Caller's canonical equals ctx canonical → preserve canonical
       form, optionally stash raw surface in
       [meta.<field>_raw_agent_name] when the caller passed a
       different surface form (e.g. [keeper-velvet-hammer-agent]
       vs [velvet-hammer]).
    3. Caller's canonical disagrees with ctx canonical → REWRITE to
       ctx canonical, preserve the caller's claim under
       [meta.<field>_caller_claim] for forensics, and increment
       [masc_board_actor_identity_spoof_total{tool, field}]. *)

open Alcotest
module D = Masc_mcp.Tool_inline_dispatch_extra
module Prom = Masc_mcp.Prometheus

(* --- helpers ----------------------------------------------------- *)

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let json_string_field name json =
  match json_field name json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let meta_string_field name = function
  | `Assoc fields ->
    (match List.assoc_opt "meta" fields with
     | Some (`Assoc meta_fields) ->
       (match List.assoc_opt name meta_fields with
        | Some (`String value) -> Some value
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let counter_for ~tool ~field =
  Prom.metric_value_or_zero
    "masc_board_actor_identity_spoof_total"
    ~labels:[ "tool", tool; "field", field ]
    ()
;;

let assoc fields = `Assoc fields

(* --- 1. blank field fills from ctx ------------------------------ *)

let test_blank_field_fills_from_ctx () =
  let result =
    D.enforce_caller_identity
      ~tool:"masc_board_post"
      ~field:"author"
      ~agent_name:"keeper-velvet-hammer-agent"
      (assoc [ "body", `String "hi" ])
  in
  check
    (option string)
    "blank author rewritten to ctx canonical"
    (Some "velvet-hammer")
    (json_string_field "author" result);
  check
    (option string)
    "no caller_claim recorded for blank source"
    None
    (meta_string_field "author_caller_claim" result)
;;

let test_anonymous_field_fills_from_ctx () =
  let result =
    D.enforce_caller_identity
      ~tool:"masc_board_post"
      ~field:"author"
      ~agent_name:"keeper-velvet-hammer-agent"
      (assoc [ "author", `String "anonymous"; "body", `String "hi" ])
  in
  check
    (option string)
    "anonymous author rewritten to ctx canonical"
    (Some "velvet-hammer")
    (json_string_field "author" result);
  check
    (option string)
    "no caller_claim recorded for anonymous source"
    None
    (meta_string_field "author_caller_claim" result)
;;

(* --- 2. caller canonical matches ctx canonical ------------------ *)

let test_caller_short_name_matches_ctx () =
  let result =
    D.enforce_caller_identity
      ~tool:"masc_board_post"
      ~field:"author"
      ~agent_name:"keeper-velvet-hammer-agent"
      (assoc [ "author", `String "velvet-hammer" ])
  in
  check
    (option string)
    "matching short-name preserved"
    (Some "velvet-hammer")
    (json_string_field "author" result);
  check
    (option string)
    "no caller_claim because no spoof"
    None
    (meta_string_field "author_caller_claim" result)
;;

let test_caller_passes_full_agent_name_form () =
  (* Caller passed a different surface form (full agent_name) that
     resolves to the same keeper.  Canonical form ends up in [author]
     and the original surface ends up in
     [meta.author_raw_agent_name] — legacy semantic preserved. *)
  let result =
    D.enforce_caller_identity
      ~tool:"masc_board_post"
      ~field:"author"
      ~agent_name:"velvet-hammer"
      (assoc [ "author", `String "keeper-velvet-hammer-agent" ])
  in
  check
    (option string)
    "canonical short-name in author"
    (Some "velvet-hammer")
    (json_string_field "author" result);
  check
    (option string)
    "raw surface preserved in meta.author_raw_agent_name"
    (Some "keeper-velvet-hammer-agent")
    (meta_string_field "author_raw_agent_name" result);
  check
    (option string)
    "no caller_claim because canonicals match"
    None
    (meta_string_field "author_caller_claim" result)
;;

(* --- 3. caller canonical disagrees with ctx canonical ----------- *)

let test_velvet_hammer_cannot_post_as_analyst () =
  (* The exact #10297 reproducer: velvet-hammer keeper attempts to
     write a board post under analyst's name.  Dispatcher must
     rewrite the author to velvet-hammer, preserve the analyst
     claim in meta, and increment the spoof counter. *)
  let before = counter_for ~tool:"masc_board_post" ~field:"author" in
  let result =
    D.enforce_caller_identity
      ~tool:"masc_board_post"
      ~field:"author"
      ~agent_name:"keeper-velvet-hammer-agent"
      (assoc [ "author", `String "analyst"; "body", `String "spoof attempt" ])
  in
  check
    (option string)
    "author rewritten to ctx canonical"
    (Some "velvet-hammer")
    (json_string_field "author" result);
  check
    (option string)
    "caller claim preserved in meta.author_caller_claim"
    (Some "analyst")
    (meta_string_field "author_caller_claim" result);
  check
    (float 0.0001)
    "spoof counter +1"
    (before +. 1.0)
    (counter_for ~tool:"masc_board_post" ~field:"author")
;;

let test_voter_field_spoof_also_rewritten () =
  (* Vote/comment_vote calls used to bypass identity entirely
     because [canonicalize_board_actor_field] never saw [agent_name].
     Now they share the same gate. *)
  let before = counter_for ~tool:"masc_board_vote" ~field:"voter" in
  let result =
    D.enforce_caller_identity
      ~tool:"masc_board_vote"
      ~field:"voter"
      ~agent_name:"keeper-velvet-hammer-agent"
      (assoc [ "voter", `String "analyst"; "post_id", `String "p1" ])
  in
  check
    (option string)
    "voter rewritten to ctx canonical"
    (Some "velvet-hammer")
    (json_string_field "voter" result);
  check
    (option string)
    "voter claim preserved in meta.voter_caller_claim"
    (Some "analyst")
    (meta_string_field "voter_caller_claim" result);
  check
    (float 0.0001)
    "voter spoof counter +1"
    (before +. 1.0)
    (counter_for ~tool:"masc_board_vote" ~field:"voter")
;;

(* --- 4. counter cardinality / label separation ------------------ *)

let test_counter_separates_by_tool_and_field () =
  (* Bumping (board_post, author) must NOT move (board_vote, voter):
     operators rate-alert per tool×field surface. *)
  let other_before = counter_for ~tool:"masc_board_vote" ~field:"voter" in
  let _ =
    D.enforce_caller_identity
      ~tool:"masc_board_post"
      ~field:"author"
      ~agent_name:"keeper-velvet-hammer-agent"
      (assoc [ "author", `String "analyst" ])
  in
  check
    (float 0.0001)
    "vote/voter unchanged when post/author bumps"
    other_before
    (counter_for ~tool:"masc_board_vote" ~field:"voter")
;;

(* --- 5. empty ctx is a no-op (defensive) ------------------------ *)

let test_empty_ctx_preserves_legacy_canonicalisation () =
  (* If [agent_name] is somehow empty (HTTP path with no auth, test
     fixture without ctx), the helper should not invent a value but
     should still canonicalise the caller's surface form.  This
     keeps the legacy [canonicalize_board_actor_field] semantics
     for the empty-ctx case. *)
  let result =
    D.enforce_caller_identity
      ~tool:"masc_board_post"
      ~field:"author"
      ~agent_name:""
      (assoc [ "author", `String "keeper-velvet-hammer-agent" ])
  in
  check
    (option string)
    "canonical short-name even without ctx"
    (Some "velvet-hammer")
    (json_string_field "author" result)
;;

let () =
  run
    "board_author_identity_10297"
    [ ( "blank-fills-from-ctx"
      , [ test_case "blank author -> ctx canonical" `Quick test_blank_field_fills_from_ctx
        ; test_case
            "anonymous author -> ctx canonical"
            `Quick
            test_anonymous_field_fills_from_ctx
        ] )
    ; ( "matching-canonical"
      , [ test_case "short-name matches ctx" `Quick test_caller_short_name_matches_ctx
        ; test_case
            "full agent_name form preserves raw in meta"
            `Quick
            test_caller_passes_full_agent_name_form
        ] )
    ; ( "spoof-rewrite"
      , [ test_case
            "velvet-hammer cannot post as analyst"
            `Quick
            test_velvet_hammer_cannot_post_as_analyst
        ; test_case
            "voter spoof also rewritten"
            `Quick
            test_voter_field_spoof_also_rewritten
        ] )
    ; ( "counter-isolation"
      , [ test_case
            "counter separates by (tool, field)"
            `Quick
            test_counter_separates_by_tool_and_field
        ] )
    ; ( "empty-ctx"
      , [ test_case
            "empty ctx preserves legacy canonical"
            `Quick
            test_empty_ctx_preserves_legacy_canonicalisation
        ] )
    ]
;;
