open Alcotest

module Title = Masc_tui_terminal_title

type sink =
  { mutable writes : string list
  ; mutable flushes : int
  }

let sink () = { writes = []; flushes = 0 }
let write sink value = sink.writes <- sink.writes @ [ value ]
let flush sink () = sink.flushes <- sink.flushes + 1

let snapshot ?(activity = Title.Working) ?keeper_name ?runtime_id workspace =
  Title.make ~activity ~keeper_name ~runtime_id ~workspace
;;

let test_projects_the_typed_status_segments () =
  check string
    "activity, keeper/runtime and workspace"
    "working \xc2\xb7 alpha/ollama-cloud.deepseek-v4 \xc2\xb7 me"
    (Title.text
       (snapshot ~keeper_name:"alpha" ~runtime_id:"ollama-cloud.deepseek-v4" "me"));
  check string
    "connection state comes from the shared vocabulary"
    "reconnecting... \xc2\xb7 MASC"
    (Title.text
       (snapshot ~activity:(Title.Connection Masc_tui_types.Reconnecting) ""))
;;

let test_removes_terminal_and_bidi_controls () =
  let unsafe =
    "alpha\027]0;owned\007\n\194\157\226\128\174flip\226\129\166isolated"
  in
  check string
    "OSC, C1, bidi override and isolate controls cannot reach the payload"
    "working \xc2\xb7 alpha]0;owned flipisolated \xc2\xb7 me"
    (Title.text (snapshot ~keeper_name:unsafe "me"))
;;

let scalar_count text =
  let rec loop offset count =
    if offset >= String.length text then count
    else
      let decoded = String.get_utf_8_uchar text offset in
      loop
        (offset + max 1 (Uchar.utf_decode_length decoded))
        (if Uchar.utf_decode_is_valid decoded then count + 1 else count)
  in
  loop 0 0
;;

let test_caps_the_complete_title_without_splitting_utf8 () =
  let long_workspace = String.concat "" (List.init 300 (fun _ -> "\240\159\167\170")) in
  let rendered = Title.text (snapshot long_workspace) in
  check int "maximum Unicode scalars" 240 (scalar_count rendered);
  check bool "result remains valid UTF-8" true (String.is_valid_utf_8 rendered)
;;

let test_bounds_sanitizer_work_before_a_printable_suffix () =
  let hostile_prefix = String.make 10_000 '\001' in
  check string
    "a remote control-only prefix cannot force an unbounded scan"
    "working \xc2\xb7 me"
    (Title.text (snapshot ~keeper_name:(hostile_prefix ^ "unreachable") "me"))
;;

let test_writes_only_on_change_and_clears_once () =
  let title = Title.create () in
  let captured = sink () in
  let first = snapshot ~keeper_name:"alpha" "me" in
  Title.present title ~write:(write captured) ~flush:(flush captured) first;
  Title.present title ~write:(write captured) ~flush:(flush captured) first;
  check int "identical title writes once" 1 (List.length captured.writes);
  check int "identical title flushes once" 1 captured.flushes;
  let second =
    snapshot
      ~activity:(Title.Connection Masc_tui_types.Connected)
      ~keeper_name:"alpha"
      "me"
  in
  Title.present title ~write:(write captured) ~flush:(flush captured) second;
  check int "changed title writes again" 2 (List.length captured.writes);
  Title.clear title ~write:(write captured) ~flush:(flush captured);
  Title.clear title ~write:(write captured) ~flush:(flush captured);
  check int "clear writes once" 3 (List.length captured.writes);
  check string "clear uses an empty OSC 0" "\027]0;\007" (List.nth captured.writes 2);
  check int "changed and cleared titles flush" 3 captured.flushes
;;

let test_selects_the_keeper_with_explicit_priority () =
  let selected ~live ~inflight ~visible =
    Title.select_keeper ~live ~inflight ~visible
  in
  check (option string)
    "live stream wins"
    (Some "live")
    (selected
       ~live:(Some "live")
       ~inflight:[ "first"; "visible" ]
       ~visible:(Some "visible"));
  check (option string)
    "visible in-flight Keeper wins"
    (Some "visible")
    (selected
       ~live:None
       ~inflight:[ "first"; "visible" ]
       ~visible:(Some "visible"));
  check (option string)
    "first in-flight Keeper is the fallback"
    (Some "first")
    (selected
       ~live:None
       ~inflight:[ "first"; "second" ]
       ~visible:(Some "idle"));
  check (option string)
    "visible idle Keeper is the final fallback"
    (Some "idle")
    (selected ~live:None ~inflight:[] ~visible:(Some "idle"))
;;

let test_present_retries_after_write_failure () =
  let title = Title.create () in
  let first = snapshot ~keeper_name:"alpha" "me" in
  let attempted = ref 0 in
  Title.present title
    ~write:(fun _ ->
      incr attempted;
      raise Exit)
    ~flush:(fun () -> fail "flush must not follow a failed write")
    first;
  check int "write failure is swallowed" 1 !attempted;
  let captured = sink () in
  Title.present title ~write:(write captured) ~flush:(flush captured) first;
  check int "same snapshot is retried" 1 (List.length captured.writes);
  check int "successful retry flushes" 1 captured.flushes
;;

let test_clear_runs_after_present_flush_failure () =
  let title = Title.create () in
  let captured = sink () in
  Title.present title
    ~write:(write captured)
    ~flush:(fun () -> raise Exit)
    (snapshot ~keeper_name:"alpha" "me");
  check int "possible title bytes were written" 1 (List.length captured.writes);
  Title.clear title ~write:(write captured) ~flush:(flush captured);
  check int "cleanup is not skipped when flush failed" 2 (List.length captured.writes);
  check string "cleanup writes empty OSC 0" "\027]0;\007" (List.nth captured.writes 1);
  check int "successful cleanup flushes" 1 captured.flushes
;;

let test_clear_retries_after_failure () =
  let title = Title.create () in
  let first = snapshot ~keeper_name:"alpha" "me" in
  let captured = sink () in
  Title.present title ~write:(write captured) ~flush:(flush captured) first;
  let clear_attempts = ref 0 in
  Title.clear title
    ~write:(fun _ ->
      incr clear_attempts;
      raise Exit)
    ~flush:(fun () -> fail "flush must not follow a failed clear write");
  check int "failed clear is attempted" 1 !clear_attempts;
  Title.clear title ~write:(write captured) ~flush:(flush captured);
  check int "clear is retried" 2 (List.length captured.writes);
  check string "retry writes empty OSC 0" "\027]0;\007" (List.nth captured.writes 1);
  check int "present and successful clear flush" 2 captured.flushes
;;

let () =
  run
    "tui_terminal_title"
    [ ( "projection"
      , [ test_case "typed segments" `Quick test_projects_the_typed_status_segments
        ; test_case "terminal safety" `Quick test_removes_terminal_and_bidi_controls
        ; test_case "bounded UTF-8" `Quick test_caps_the_complete_title_without_splitting_utf8
        ; test_case "bounded scan" `Quick test_bounds_sanitizer_work_before_a_printable_suffix
        ; test_case "Keeper priority" `Quick test_selects_the_keeper_with_explicit_priority
        ] )
    ; ( "writes"
      , [ test_case "change-driven and cleanup" `Quick test_writes_only_on_change_and_clears_once
        ; test_case "retry present" `Quick test_present_retries_after_write_failure
        ; test_case "clear after partial present" `Quick test_clear_runs_after_present_flush_failure
        ; test_case "retry clear" `Quick test_clear_retries_after_failure
        ] )
    ]
;;
