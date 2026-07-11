(* test_keeper_board_signal_match.ml — pins two of the #60 board-mention
   fixes (RFC-0334 W3 census, issue #23837):

   - [Keeper_world_observation_board_signal.match_signal] now reuses the
     boundary-aware [Keeper_lane_mentions] parser (already proven for
     keeper chat lanes) instead of an ["@" ^ target] substring search, so
     (a) a target already stored with a leading '@' no longer builds a
     never-matching "@@name" needle, and (b) an email-like "user@name"
     token does not false-match a target named "name".
   - [Keeper_keepalive_signal.board_signal_wake_lane] routes a paused
     keeper whose operator-granted auto-resume is disallowed to
     [Mailbox_only] for an explicit mention, instead of [Excluded]
     (silently dropped with no wake and no mailbox entry). *)

open Alcotest
open Masc

module BS = Keeper_world_observation_board_signal
module KKS = Keeper_keepalive_signal

let signal ?(kind = Board_dispatch.Board_post_created) ?(post_id = "post-1")
    ?(author = "operator") ?(content = "") ?(title = "") () :
  Board_dispatch.board_signal =
  { kind; post_id; author; title; content; hearth = None; updated_at = Some 1.0 }

let meta ~name ?(mention_targets = []) () =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String (name ^ "-agent"))
      ; ( "mention_targets"
        , `List (List.map (fun t -> `String t) mention_targets) )
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error err -> fail ("meta fixture failed: " ^ err)

(* ── match_signal: boundary-aware extraction ─────────────────────── *)

let test_plain_mention_matches () =
  let m = meta ~name:"albini" () in
  let result =
    BS.match_signal ~meta:m ~signal:(signal ~content:"hey @albini look" ())
  in
  check bool "explicit mention" true result.explicit_mention

let test_similar_token_not_matched () =
  let m = meta ~name:"albini" () in
  let result =
    BS.match_signal ~meta:m ~signal:(signal ~content:"ping @albinix now" ())
  in
  check bool "a different token does not match" false result.explicit_mention

let test_email_like_token_not_matched () =
  let m = meta ~name:"albini" () in
  let result =
    BS.match_signal ~meta:m
      ~signal:(signal ~content:"send to user@albini.example" ())
  in
  check bool "email-like token does not match" false result.explicit_mention

let test_case_insensitive () =
  let m = meta ~name:"albini" () in
  let result =
    BS.match_signal ~meta:m ~signal:(signal ~content:"PING @ALBINI NOW" ())
  in
  check bool "case-insensitive match" true result.explicit_mention

let test_no_mention () =
  let m = meta ~name:"albini" () in
  let result =
    BS.match_signal ~meta:m ~signal:(signal ~content:"just chatting here" ())
  in
  check bool "no address, no mention" false result.explicit_mention

let test_self_authored_post_never_self_mentions () =
  let m = meta ~name:"albini" () in
  let result =
    BS.match_signal ~meta:m
      ~signal:(signal ~author:"albini" ~content:"@albini noting this" ())
  in
  check bool "self-authored post does not wake itself" false
    result.explicit_mention

(* RFC-0334 W3 census (#23837): a target already stored pre-prefixed with
   '@' used to build a never-matching "@@name" needle downstream. *)
let test_leading_at_configured_target_still_matches () =
  let m = meta ~name:"albini" ~mention_targets:[ "@albini" ] () in
  let result =
    BS.match_signal ~meta:m ~signal:(signal ~content:"hey @albini" ())
  in
  check bool "leading '@' on a configured target still matches" true
    result.explicit_mention

let test_persona_mention_target_matches () =
  let m = meta ~name:"albini" ~mention_targets:[ "@Curator" ] () in
  let result =
    BS.match_signal ~meta:m ~signal:(signal ~content:"paging @curator" ())
  in
  check bool "persona alias target matches case-insensitively" true
    result.explicit_mention

(* ── board_signal_wake_lane: routing matrix ──────────────────────── *)

let lane_to_string = function
  | KKS.Immediate reason -> "immediate:" ^ BS.wake_reason_label reason
  | KKS.Mailbox_only reason -> "mailbox_only:" ^ BS.wake_reason_label reason
  | KKS.Excluded -> "excluded"

let check_lane label ~phase ~auto_resume_allowed wake_reason expected =
  check string label expected
    (lane_to_string
       (KKS.board_signal_wake_lane ~phase ~auto_resume_allowed wake_reason))

let test_running_explicit_mention_is_immediate () =
  check_lane "running + explicit mention"
    ~phase:Keeper_state_machine.Running ~auto_resume_allowed:false
    (Some BS.Explicit_mention) "immediate:explicit_mention"

let test_running_no_reason_is_excluded () =
  check_lane "running + no deterministic address"
    ~phase:Keeper_state_machine.Running ~auto_resume_allowed:false
    None "excluded"

let test_paused_explicit_mention_with_auto_resume_is_immediate () =
  check_lane "paused + explicit mention + auto-resume allowed"
    ~phase:Keeper_state_machine.Paused ~auto_resume_allowed:true
    (Some BS.Explicit_mention) "immediate:explicit_mention"

(* This is the #60 fix: previously [Paused, _ -> None] dropped this case
   with no wake and no mailbox entry. *)
let test_paused_explicit_mention_without_auto_resume_is_mailbox_only () =
  check_lane "paused + explicit mention + auto-resume disallowed"
    ~phase:Keeper_state_machine.Paused ~auto_resume_allowed:false
    (Some BS.Explicit_mention) "mailbox_only:explicit_mention"

let test_paused_followup_reason_is_excluded () =
  check_lane "paused + thread-reply followup (no explicit address)"
    ~phase:Keeper_state_machine.Paused ~auto_resume_allowed:true
    (Some BS.Thread_reply_after_self_comment) "excluded"

let test_paused_no_reason_is_excluded () =
  check_lane "paused + no deterministic address"
    ~phase:Keeper_state_machine.Paused ~auto_resume_allowed:false
    None "excluded"

let test_other_phase_is_excluded () =
  check_lane "offline phase defensively excluded"
    ~phase:Keeper_state_machine.Offline ~auto_resume_allowed:true
    (Some BS.Explicit_mention) "excluded"

let () =
  run "keeper_board_signal_match"
    [ ( "match_signal"
      , [ test_case "plain mention matches" `Quick test_plain_mention_matches
        ; test_case "similar token not matched" `Quick
            test_similar_token_not_matched
        ; test_case "email-like token not matched" `Quick
            test_email_like_token_not_matched
        ; test_case "case-insensitive match" `Quick test_case_insensitive
        ; test_case "no mention" `Quick test_no_mention
        ; test_case "self-authored post never self-mentions" `Quick
            test_self_authored_post_never_self_mentions
        ; test_case "leading '@' on configured target still matches" `Quick
            test_leading_at_configured_target_still_matches
        ; test_case "persona alias target matches" `Quick
            test_persona_mention_target_matches
        ] )
    ; ( "board_signal_wake_lane"
      , [ test_case "running + explicit mention -> immediate" `Quick
            test_running_explicit_mention_is_immediate
        ; test_case "running + no reason -> excluded" `Quick
            test_running_no_reason_is_excluded
        ; test_case "paused + explicit mention + auto-resume -> immediate"
            `Quick test_paused_explicit_mention_with_auto_resume_is_immediate
        ; test_case
            "paused + explicit mention + no auto-resume -> mailbox_only"
            `Quick
            test_paused_explicit_mention_without_auto_resume_is_mailbox_only
        ; test_case "paused + followup reason -> excluded" `Quick
            test_paused_followup_reason_is_excluded
        ; test_case "paused + no reason -> excluded" `Quick
            test_paused_no_reason_is_excluded
        ; test_case "other phase -> excluded" `Quick test_other_phase_is_excluded
        ] )
    ]
;;
