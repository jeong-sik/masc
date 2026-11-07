module Reading = Masc.Tui_decode

(* Operator pause outranks the health reading: it is a person's decision about
   a keeper that may well be healthy, and a reader looking for why a keeper is
   quiet wants that answer first. *)
let paused_glyph = "\xe2\x97\x8b" (* ○ hollow: stopped on purpose *)
let unread_glyph = "-"

(* Opens every line about a failing keeper's past: the FAILING group heading,
   its count in the summary, and the sentence of its last failure. *)
let failing_glyph = "\xe2\x97\x82" (* ◂ *)

let health_glyph : Reading.keeper_health_reading -> string = function
  | Reading.Health_running -> "\xe2\x97\x8f" (* ● filled: keepalive running, has turned *)
  | Reading.Health_idle -> "\xc2\xb7" (* · small: keepalive running, no turn yet *)
  | Reading.Health_failing -> "!" (* keepalive running, its turns failing *)
  | Reading.Health_offline -> "\xc3\x97" (* × gone *)

let glyph ~paused reading =
  match reading with
  | None -> unread_glyph
  | Some _ when paused -> paused_glyph
  | Some value -> health_glyph value

let activity_glyph : Masc_tui_keeper_list_model.activity -> string = function
  | Held_call -> "!"
  | Attempt_failed -> "\xe2\x9c\x97" (* ✗: an attempt of the open turn failed *)
  | Question -> "?"
  | Confirmation | Verifying -> "\xe2\x97\x87" (* ◇ *)
  | Preparing | Running -> "\xe2\x97\x8f" (* ●; the list substitutes its animated mark *)
  | Streaming -> ">"
  | Async_working _ -> "&"
  | Deferred -> "\xe2\x97\x8c" (* ◌ *)
  | Tool_waiting -> "\xe2\x96\xa0" (* ■ *)
  | Model_waiting -> "\xe2\x97\x94" (* ◔ *)
  | External_waiting -> "\xe2\x97\x8c" (* ◌ *)
  | Delegate_result -> "\xe2\x86\xa9" (* ↩ *)
  | Idle -> "\xe2\x97\x8b" (* ○ *)
  | Paused -> "\xe2\x85\xa1" (* Ⅱ *)
  | Offline -> "\xc3\x97" (* × *)
  | Unknown -> unread_glyph

let badge_glyph : Masc_tui_keeper_list_model.badge -> string = function
  | Badge_read_error -> "!"
  | Badge_waiting_unavailable -> "!"
  | Badge_async _ -> "&"
  | Badge_async_queued _ -> ">"
  | Badge_async_cancelling _ -> "\xc3\x97" (* × *)
  | Badge_delegate -> "\xe2\x86\xa9" (* ↩ *)
  | Badge_verification -> "\xe2\x97\x87" (* ◇ *)
  | Badge_schedule -> "\xe2\x97\xb7" (* ◷ *)
  | Badge_quota_spent -> "\xe2\x8a\x98" (* ⊘ *)

let legend =
  [ health_glyph Reading.Health_running, "healthy"
  ; health_glyph Reading.Health_failing, "failing"
  ; health_glyph Reading.Health_idle, "idle"
  ; paused_glyph, "paused"
  ; health_glyph Reading.Health_offline, "offline"
  ; unread_glyph, "unread"
  ]

(* The roster's Mode S cell: a letter for how the keeper is started and a
   letter for the sandbox its row declares. The letters and the words the
   sheet prints for them are declared together, so the cell and its
   explanation cannot drift apart. *)
let activation_letter : Reading.keeper_activation_mode -> string = function
  | Reading.Activation_manual -> "M"
  | Reading.Activation_on_demand -> "D"
  | Reading.Activation_autonomous -> "A"

let activation_word : Reading.keeper_activation_mode -> string = function
  | Reading.Activation_manual -> "manual"
  | Reading.Activation_on_demand -> "on demand"
  | Reading.Activation_autonomous -> "autonomous"

let activations =
  [ Reading.Activation_manual; Reading.Activation_on_demand; Reading.Activation_autonomous ]

type sandbox = Masc.Keeper_types_profile.sandbox_profile =
  | Docker
  | Micro_vm
  | Remote_ssh

let sandbox_of_profile = Masc.Keeper_types_profile.sandbox_profile_of_string
let sandbox_letter = function Docker -> "D" | Micro_vm -> "M" | Remote_ssh -> "R"
let sandbox_word = Masc.Keeper_types_profile.sandbox_profile_to_string
let sandboxes = Masc.Keeper_types_profile.all_sandbox_profiles

(* The list's header words that the sheet explains, declared once. The list
   draws them and [column_legend] names them from these values, so a column
   that is renamed cannot keep its old name on the sheet. *)
let now_header = "NOW"
let age_header = "AGE"

let column_legend =
  let letters letter values = String.concat "/" (List.map letter values) in
  let words word values = String.concat " / " (List.map word values) in
  [ now_header, "what the keeper is doing at this moment"
  ; ( age_header
    , "time since it last moved: the open turn's latest update (its start before it \
       reports one), else the later of its last turn and the start of its wait" )
  ; "LIFECYCLE", "the keeper process"
  ; ( failing_glyph
    , "a failing keeper's last failure, in place of its runtime or first in DETAIL: \
       how long ago · cause · the runtime that ended it · candidates tried" )
  ; "Mode " ^ letters activation_letter activations, words activation_word activations
  ; "S " ^ letters sandbox_letter sandboxes, "sandbox: " ^ words sandbox_word sandboxes
  ]
