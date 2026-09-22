(** The Fusion launch form as the operator drives it: what it opens on, what a
    submit sends, what a refusal leaves behind. The screen and the network are
    not here; the form is pure. *)
open Alcotest
module Launch = Masc_tui_fusion_launch
module Decode = Masc.Tui_decode

let ok = function Ok value -> value | Error detail -> fail detail

let options ?(enabled = true) ?(default_preset = "trio") ?(presets = [ "trio"; "duo" ]) () =
  { Decode.flo_enabled = enabled; flo_default_preset = default_preset; flo_presets = presets }

let open_form ?(keepers = [ "analyst"; "scout" ]) ?keeper ?(options = options ()) () =
  Launch.open_form ~keepers ~keeper ~options |> ok

let editing = function
  | Launch.Editing form -> form
  | Launch.Submitted _ -> fail "editing must not submit"
  | Launch.Closed -> fail "editing must not close"

let press keys form = List.fold_left (fun form key -> editing (Launch.edit ~key form)) form keys

let submit form =
  match Launch.edit ~key:"enter" (press [ "\019" ] form) with
  | Launch.Submitted (form, request) -> form, request
  | Launch.Editing form ->
      fail (String.concat " | " ("review Enter must submit" :: Launch.lines form))
  | Launch.Closed -> fail "review Enter must not close"

(* Tab walks the fields in the order the schema declares them: keeper,
   preset, topology, prompt, web tools. *)
let to_prompt = [ "tab"; "tab"; "tab" ]

let holds needle lines =
  List.exists
    (fun line ->
      let n = String.length needle and h = String.length line in
      let rec scan i = i + n <= h && (String.equal (String.sub line i n) needle || scan (i + 1)) in
      scan 0)
    lines

let type_text text form =
  press (List.init (String.length text) (fun i -> String.make 1 text.[i])) form

let test_opens_on_the_roster_and_the_configured_default () =
  let form = open_form ~keeper:"scout" () in
  let _, request = form |> press to_prompt |> type_text "why" |> submit in
  check string "the named keeper when it is in the roster" "scout" request.Launch.keeper;
  check string "the configured default preset" "trio" request.preset;
  check bool "simple topology" true (request.topology = Fusion_types.Simple);
  check bool "web tools off" false request.web_tools;
  check string "the typed prompt" "why" request.prompt;
  let form = open_form ~keeper:"nobody" ~options:(options ~default_preset:"missing" ()) () in
  let _, request = form |> press to_prompt |> type_text "why" |> submit in
  check string "a keeper not in the roster falls to the first" "analyst" request.keeper;
  check string "a default preset not configured falls to the first" "trio" request.preset

let test_refuses_to_open_without_a_way_to_run () =
  let refused ~keepers ~options =
    match Launch.open_form ~keepers ~keeper:None ~options with
    | Ok _ -> fail "the form opened with nothing to run on"
    | Error detail -> detail
  in
  check bool "disabled names runtime.toml" true
    (holds "disabled" [ refused ~keepers:[ "analyst" ] ~options:(options ~enabled:false ()) ]);
  check bool "no preset names the presets table" true
    (holds "presets" [ refused ~keepers:[ "analyst" ] ~options:(options ~presets:[] ()) ]);
  check bool "no keeper names the roster" true
    (holds "Keeper" [ refused ~keepers:[] ~options:(options ()) ])

let test_choices_cycle_and_the_body_is_the_endpoints () =
  let form = open_form () in
  let form = form |> press [ "tab"; "tab"; "right" ] |> press [ "tab" ] |> type_text "compare" in
  let form = form |> press [ "tab"; "right" ] in
  let _, request = submit form in
  check bool "Right on topology steps to refine" true (request.Launch.topology = Fusion_types.Refine);
  check bool "Right on web tools turns them on" true request.web_tools;
  check string "the body carries what the endpoint reads, and no keeper"
    {|{"prompt":"compare","preset":"trio","topology":"refine","web_tools":true}|}
    (Yojson.Safe.to_string (Launch.request_body request))

let test_a_blank_prompt_never_leaves_the_form () =
  let form = open_form () in
  (* Nothing typed: the schema's required prompt refuses the review. *)
  let form = editing (Launch.edit ~key:"\019" form) in
  check bool "the missing prompt is an input error" true
    (holds "Input error" (Launch.lines form));
  (* Spaces pass minLength; the server would trim them, so the form does. *)
  let form = open_form () |> press to_prompt |> type_text "  " |> press [ "\019" ] in
  (match Launch.edit ~key:"enter" form with
   | Launch.Editing form ->
       check bool "a blank prompt is refused before a request goes out" true
         (holds "Input error: the prompt is blank" (Launch.lines form))
   | Launch.Submitted _ -> fail "a blank prompt must not submit"
   | Launch.Closed -> fail "a blank prompt must not close the form")

let test_a_refusal_keeps_the_values_and_reopens_editing () =
  let form = open_form () |> press to_prompt |> type_text "why" in
  let waiting, first = submit form in
  check bool "the form waits on the submit" true (Launch.submitting waiting);
  check bool "the waiting line names the keeper" true
    (holds "Starting the run for analyst" (Launch.lines waiting));
  (match Launch.edit ~key:"esc" waiting with
   | Launch.Editing form ->
       check bool "keys wait with the submit" true (Launch.submitting form)
   | Launch.Submitted _ | Launch.Closed -> fail "a waiting form must hold every key");
  check bool "paste waits with the submit" true
    (Launch.submitting (Launch.paste ~text:"more" waiting));
  let refused = Launch.refused ~detail:"HTTP 400: preset trio cannot run judge_of_judges" waiting in
  check bool "the refusal is the server's sentence" true
    (holds "Refused: HTTP 400: preset trio cannot run judge_of_judges" (Launch.lines refused));
  check bool "the form is editable again" false (Launch.submitting refused);
  let _, second = submit refused in
  check bool "the values survived the refusal" true (first = second)

let test_esc_closes_and_paste_keeps_its_lines () =
  (match Launch.edit ~key:"esc" (open_form ()) with
   | Launch.Closed -> ()
   | Launch.Editing _ | Launch.Submitted _ -> fail "Esc must close the form");
  let form = open_form () |> press to_prompt |> Launch.paste ~text:"first line\nsecond line" in
  let _, request = submit form in
  check string "a pasted prompt keeps its newline" "first line\nsecond line" request.Launch.prompt;
  let form = open_form () |> Launch.paste ~text:"typed into a choice" in
  let _, request = form |> press to_prompt |> type_text "why" |> submit in
  check string "a paste on a choice field changes nothing" "analyst" request.keeper

let () =
  run "tui_fusion_launch"
    [ ( "form"
      , [ test_case "opens on the roster and the configured default" `Quick
            test_opens_on_the_roster_and_the_configured_default
        ; test_case "refuses to open without a way to run" `Quick
            test_refuses_to_open_without_a_way_to_run
        ; test_case "choices cycle and the body is the endpoint's" `Quick
            test_choices_cycle_and_the_body_is_the_endpoints
        ; test_case "a blank prompt never leaves the form" `Quick
            test_a_blank_prompt_never_leaves_the_form
        ; test_case "a refusal keeps the values and reopens editing" `Quick
            test_a_refusal_keeps_the_values_and_reopens_editing
        ; test_case "Esc closes and paste keeps its lines" `Quick
            test_esc_closes_and_paste_keeps_its_lines
        ] )
    ]
