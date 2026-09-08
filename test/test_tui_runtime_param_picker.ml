(* Walking a param's closed set instead of typing one of its spellings.

   A bool already had this: Left/Right/Space toggled it, because "on" and
   "off" are values to pick, not text to enter. A param whose values are named
   is the same gesture with more than two stops, and the registry now says
   which values those are. What is checked here is the walk itself — where it
   starts, that it wraps, and that a value the picker does not list still
   reaches the route rather than being swallowed. *)

module Tui_types = Masc_tui_types
open Alcotest

let policy_choices = [ "mention_only"; "mention_or_thread"; "all" ]

let edit_with ?(choices = policy_choices) ?(value_type = "enum") draft =
  { Tui_types.rpe_key = "discord.trigger_policy"
  ; rpe_value_type = value_type
  ; rpe_draft = draft
  ; rpe_replace_on_type = true
  ; rpe_mode = Tui_types.Friendly_value
  ; rpe_choices = choices
  }
;;

let draft_after ~step edit =
  (Tui_types.runtime_param_edit_cycle_choice edit ~step).Tui_types.rpe_draft
;;

let test_forward_walks_to_the_next_value () =
  check string "the value after mention_only" "mention_or_thread"
    (draft_after ~step:1 (edit_with "mention_only"))
;;

let test_forward_wraps_at_the_end () =
  check string "past the last value comes the first" "mention_only"
    (draft_after ~step:1 (edit_with "all"))
;;

let test_backward_wraps_at_the_start () =
  check string "before the first value comes the last" "all"
    (draft_after ~step:(-1) (edit_with "mention_only"))
;;

(* A draft the set does not contain is where the reader typed something, or
   where a partly closed domain's parameterized form sits. Pressing a picker
   key is a request for a different value, so the walk starts rather than
   keeping what is there — keeping it would make the key look broken. *)
let test_a_value_outside_the_set_starts_the_walk () =
  check string "an unlisted value walks to the first choice" "mention_only"
    (draft_after ~step:1 (edit_with "user_only:123456789"))
;;

let test_surrounding_space_does_not_hide_a_match () =
  check string "a padded draft is still recognised" "all"
    (draft_after ~step:1 (edit_with "  mention_or_thread  "))
;;

let test_no_choices_leaves_the_draft_alone () =
  check string "a param with no closed set is typed, not walked" "30"
    (draft_after ~step:1 (edit_with ~choices:[] ~value_type:"int" "30"))
;;

(* One choice is a set the walk cannot leave. It must not divide by zero or
   spin off the end. *)
let test_a_single_choice_stays_put () =
  check string "the only value stays" "all"
    (draft_after ~step:1 (edit_with ~choices:[ "all" ] "all"))
;;

(* -- what the picker hands to the route -------------------------- *)

let value_of edit =
  match Tui_types.runtime_param_edit_value edit with
  | Ok json -> Ok (Yojson.Safe.to_string json)
  | Error detail -> Error detail
;;

let json_result = result string string

let test_a_picked_value_is_sent_as_a_string () =
  check json_result "the chosen name goes out as JSON"
    (Ok {|"mention_only"|})
    (value_of (edit_with "mention_only"))
;;

(* The picker lists three values; the domain has a fourth carrying an id. It is
   typed rather than walked to, and it must still reach the registry, which
   owns the grammar and is the only thing entitled to reject it. *)
let test_a_typed_parameterized_value_is_sent_through () =
  check json_result "an unlisted form still reaches the route"
    (Ok {|"user_only:123456789"|})
    (value_of (edit_with "user_only:123456789"))
;;

let test_an_empty_draft_is_refused () =
  check json_result "nothing chosen is not a value"
    (Error "Choose a value")
    (value_of (edit_with "   "))
;;

let () =
  run "tui_runtime_param_picker"
    [ ( "walking a closed set"
      , [ test_case "forward" `Quick test_forward_walks_to_the_next_value
        ; test_case "forward wraps" `Quick test_forward_wraps_at_the_end
        ; test_case "backward wraps" `Quick test_backward_wraps_at_the_start
        ; test_case "an unlisted value starts the walk" `Quick
            test_a_value_outside_the_set_starts_the_walk
        ; test_case "padding does not hide a match" `Quick
            test_surrounding_space_does_not_hide_a_match
        ; test_case "no closed set leaves the draft alone" `Quick
            test_no_choices_leaves_the_draft_alone
        ; test_case "a single choice stays put" `Quick
            test_a_single_choice_stays_put
        ] )
    ; ( "what reaches the route"
      , [ test_case "a picked value is a JSON string" `Quick
            test_a_picked_value_is_sent_as_a_string
        ; test_case "a typed parameterized value passes through" `Quick
            test_a_typed_parameterized_value_is_sent_through
        ; test_case "an empty draft is refused" `Quick
            test_an_empty_draft_is_refused
        ] )
    ]
;;
