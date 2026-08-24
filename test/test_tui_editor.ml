open Alcotest

(* The editor contract is exit-code-based: 0 hands the bytes back, anything
   else means the operator walked away. [cat] and [false] make both halves
   runnable without a terminal. The terminal callbacks are recorded, not
   asserted in detail -- the pair being called around the child in the right
   order is what the TUI relies on. *)
let with_editor env_value f =
  let previous_editor = Sys.getenv_opt "EDITOR" in
  let previous_visual = Sys.getenv_opt "VISUAL" in
  (match env_value with
  | Some value -> Unix.putenv "EDITOR" value
  | None -> Unix.putenv "EDITOR" "");
  Unix.putenv "VISUAL" "";
  Fun.protect
    ~finally:(fun () ->
      (match previous_editor with
      | Some value -> Unix.putenv "EDITOR" value
      | None -> Unix.putenv "EDITOR" "");
      (match previous_visual with
      | Some value -> Unix.putenv "VISUAL" value
      | None -> Unix.putenv "VISUAL" ""))
    f
;;

let test_editor_command_prefers_editor_over_visual () =
  with_editor (Some "cat") (fun () ->
      check (option string) "EDITOR wins" (Some "cat")
        (Masc_tui_editor.editor_command ()))
;;

let test_editor_command_empty_editor_falls_back_to_none () =
  (* An empty EDITOR is not an editor; the fallback (VISUAL) is also empty,
     so the answer is "no editor" and the caller says so instead of guessing
     one. *)
  with_editor (Some " ") (fun () ->
      check (option string) "blank editor is no editor" None
        (Masc_tui_editor.editor_command ()))
;;

let test_roundtrip_exit_zero_hands_bytes_back () =
  with_editor (Some "cat") (fun () ->
      let calls = ref [] in
      let result =
        Masc_tui_editor.roundtrip
          ~restore:(fun () -> calls := "restore" :: !calls)
          ~reenter:(fun () -> calls := "reenter" :: !calls)
          "{\n}\n"
      in
      check (option string) "content round-trips" (Some "{\n}\n") result;
      check (list string) "restore runs before reenter"
        [ "reenter"; "restore" ]
        !calls)
;;

let test_roundtrip_nonzero_exit_is_no_change () =
  with_editor (Some "false") (fun () ->
      let result =
        Masc_tui_editor.roundtrip ~restore:Fun.id ~reenter:Fun.id "keep me"
      in
      check (option string) "non-zero exit leaves nothing" None result)
;;

let () =
  run
    "tui_editor"
    [ ( "roundtrip"
      , [ test_case "EDITOR wins over VISUAL" `Quick
            test_editor_command_prefers_editor_over_visual
        ; test_case "blank editor is no editor" `Quick
            test_editor_command_empty_editor_falls_back_to_none
        ; test_case "exit 0 hands the bytes back in order" `Quick
            test_roundtrip_exit_zero_hands_bytes_back
        ; test_case "non-zero exit means no change" `Quick
            test_roundtrip_nonzero_exit_is_no_change
        ] )
    ]
;;
