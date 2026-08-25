(** Tests for [Masc_tui_editor_jump].

    The expression assertions are pinned to what a live Neovim accepted:
    nvim 0.11.6, [--headless --listen], opening a file whose name holds an
    apostrophe and reading back [expand("%:t")] and [line(".")]. Documented
    forms were not enough on their own -- [--remote "+3" file] is spelled in
    [remote.txt] and a live server read the [+3] as a second file to open. *)

open Alcotest

module Jump = Masc_tui_editor_jump

let with_env name value f =
  let restore =
    match Sys.getenv_opt name with
    | Some previous -> fun () -> Unix.putenv name previous
    | None ->
        (* [Unix.unsetenv] does not exist. Emptying is enough: every reader
           here treats blank as absent, which is the property under test. *)
        fun () -> Unix.putenv name ""
  in
  Unix.putenv name value;
  Fun.protect ~finally:restore f
;;

(* A path can hold the quote that ends a Vim string literal. Doubling is the
   escape, and getting it wrong sends the rest of the path to Vim as syntax. *)
let test_expression_doubles_an_embedded_quote () =
  let expression = Jump.remote_expression { Jump.path = "/tmp/it's/x.ml"; line = 7 } in
  check bool "quote is doubled" true
    (String_util.contains_substring expression "'/tmp/it''s/x.ml'");
  check bool "line is carried" true (String_util.contains_substring expression "+7 ")
;;

let test_expression_wraps_in_fnameescape () =
  let expression = Jump.remote_expression { Jump.path = "/tmp/a b.ml"; line = 1 } in
  (* [fnameescape] covers what [:edit] reads as syntax -- a space among them.
     Doubling the quote does not, and neither covers the other. *)
  check bool "fnameescape is applied" true
    (String_util.contains_substring expression "fnameescape(")
;;

(* A line below 1 is not a line. Neovim would reject [+0]; reading it as the
   first line keeps a bad row from swallowing the whole jump. *)
let test_line_floor_is_one () =
  let expression = Jump.remote_expression { Jump.path = "/tmp/x.ml"; line = 0 } in
  check bool "zero becomes one" true (String_util.contains_substring expression "+1 ");
  let negative = Jump.remote_expression { Jump.path = "/tmp/x.ml"; line = -4 } in
  check bool "negative becomes one" true
    (String_util.contains_substring negative "+1 ")
;;

(* [$NVIM] means this surface is a child of the editor the operator is looking
   at. Sending there costs them nothing; taking the terminal costs them this
   surface, so the parent wins whenever there is one. *)
let test_parent_neovim_wins_over_editor () =
  with_env "NVIM" "/tmp/nvim.sock" (fun () ->
      with_env "EDITOR" "vi" (fun () ->
          match Jump.route () with
          | Jump.Remote_neovim { server } -> check string "server" "/tmp/nvim.sock" server
          | Jump.Terminal_handoff { editor } ->
              failf "expected the parent Neovim, got the terminal for %s" editor
          | Jump.No_editor -> fail "expected the parent Neovim"))
;;

let test_editor_when_no_parent_neovim () =
  with_env "NVIM" "" (fun () ->
      with_env "EDITOR" "vi" (fun () ->
          match Jump.route () with
          | Jump.Terminal_handoff { editor } -> check string "editor" "vi" editor
          | Jump.Remote_neovim { server } ->
              failf "blank NVIM is not a server, got %s" server
          | Jump.No_editor -> fail "EDITOR is set"))
;;

(* Named rather than silently doing nothing, so the key that did nothing can
   say why. *)
let test_no_editor_at_all () =
  with_env "NVIM" "" (fun () ->
      with_env "EDITOR" "" (fun () ->
          with_env "VISUAL" "" (fun () ->
              match Jump.route () with
              | Jump.No_editor -> ()
              | Jump.Remote_neovim { server } -> failf "no server expected, got %s" server
              | Jump.Terminal_handoff { editor } ->
                  failf "no editor expected, got %s" editor)))
;;

(* Whitespace is not an address. A shell that exports NVIM= as an empty or
   padded value must not be read as a running editor. *)
let test_whitespace_is_not_a_server () =
  with_env "NVIM" "   " (fun () ->
      with_env "EDITOR" "vi" (fun () ->
          match Jump.route () with
          | Jump.Terminal_handoff _ -> ()
          | Jump.Remote_neovim { server } -> failf "whitespace read as server %S" server
          | Jump.No_editor -> fail "EDITOR is set"))
;;

let () =
  run "tui_editor_jump"
    [ ( "expression"
      , [ test_case "doubles an embedded quote" `Quick
            test_expression_doubles_an_embedded_quote
        ; test_case "wraps in fnameescape" `Quick test_expression_wraps_in_fnameescape
        ; test_case "line floor is one" `Quick test_line_floor_is_one
        ] )
    ; ( "route"
      , [ test_case "parent Neovim wins" `Quick test_parent_neovim_wins_over_editor
        ; test_case "editor without a parent" `Quick test_editor_when_no_parent_neovim
        ; test_case "neither" `Quick test_no_editor_at_all
        ; test_case "whitespace is not a server" `Quick test_whitespace_is_not_a_server
        ] )
    ]
;;
