(** Tests for [Masc_tui_csi].

    The sequences here are what a terminal puts on the wire, written as the
    parameters and final byte the reader hands over. Ghostty, kitty, WezTerm,
    foot, Alacritty and iTerm2 all speak the Kitty keyboard protocol, so the
    modifier forms are not hypothetical -- they are what this surface receives
    the moment it asks for them. *)

open Alcotest

module Csi = Masc_tui_csi

let named ~parameters ~final = Csi.name ~parameters ~final

let check_name description expected parameters final =
  check (option string) description (Some expected) (named ~parameters ~final)
;;

(* Every binding that existed before modifiers were readable has to keep its
   spelling. A bare arrow gains no prefix, so nothing that reads "up" today
   starts reading "shift-up" tomorrow. *)
let test_legacy_arrows_keep_bare_names () =
  check_name "up" "up" "" 'A';
  check_name "down" "down" "" 'B';
  check_name "right" "right" "" 'C';
  check_name "left" "left" "" 'D';
  check_name "home" "home" "" 'H';
  check_name "end" "end" "" 'F'
;;

let test_legacy_tilde_keys () =
  check_name "pageup" "pageup" "5" '~';
  check_name "pagedown" "pagedown" "6" '~';
  check_name "home via 1" "home" "1" '~';
  check_name "end via 4" "end" "4" '~'
;;

(* [ESC \[ 1;2 A] is Shift+Up. This is the shape that used to fall through to
   "unknown-esc": the parameters were no longer empty, and nothing read them. *)
let test_modified_arrows () =
  check_name "shift-up" "shift-up" "1;2" 'A';
  check_name "alt-down" "alt-down" "1;3" 'B';
  check_name "ctrl-right" "ctrl-right" "1;5" 'C';
  check_name "ctrl-shift-left" "ctrl-shift-left" "1;6" 'D'
;;

(* The Kitty protocol's own final. The first parameter is a code point, so a
   letter comes back as itself rather than as its number. *)
let test_csi_u_letters () =
  check_name "ctrl-p" "ctrl-p" "112;5" 'u';
  check_name "ctrl-shift-f" "ctrl-shift-f" "102;6" 'u';
  check_name "alt-a" "alt-a" "97;3" 'u'
;;

(* A terminal may report an upper-case letter with Shift held. Both halves say
   the same thing, and the name is built from the modifier so the letter is
   lowered -- otherwise "shift-F" and "shift-f" would be two bindings. *)
let test_csi_u_lowers_the_letter () =
  check_name "upper-case is lowered" "shift-f" "70;2" 'u'
;;

let test_csi_u_named_keys () =
  check_name "tab" "tab" "9;1" 'u';
  check_name "enter" "enter" "13;1" 'u';
  check_name "backspace" "backspace" "127;1" 'u';
  check_name "ctrl-enter" "ctrl-enter" "13;5" 'u'
;;

(* One order for every chord. Two spellings would be two bindings, and the one
   nobody typed would look dead. *)
let test_modifier_order_is_fixed () =
  check_name "ctrl before alt before shift" "ctrl-alt-shift-up" "1;8" 'A'
;;

(* Backtab carried its own final long before modifiers were reportable, and it
   already means Shift+Tab. Routing it through the modifier path would spell
   it twice. *)
let test_backtab_is_not_double_named () =
  check_name "bare" "shift-tab" "" 'Z';
  check_name "with a mask" "shift-tab" "1;2" 'Z'
;;

(* A press whose mask does not parse is still that press. Dropping the key
   because the mask was odd would lose a keystroke to a detail nobody bound. *)
let test_unreadable_mask_reads_as_no_modifier () =
  check_name "empty" "up" "1;" 'A';
  check_name "not a number" "up" "1;x" 'A';
  check_name "below one" "up" "1;0" 'A'
;;

(* The mask is read through the name rather than directly: the name is what a
   binding holds, so a mask that disagreed with it would be a bug nobody could
   observe. 2 is Shift, 3 is Alt, 5 is Ctrl, and the bits add. *)
let test_modifier_bits () =
  check_name "2 is shift" "shift-up" "1;2" 'A';
  check_name "3 is alt" "alt-up" "1;3" 'A';
  check_name "5 is ctrl" "ctrl-up" "1;5" 'A';
  check_name "6 is ctrl+shift" "ctrl-shift-up" "1;6" 'A';
  check_name "7 is ctrl+alt" "ctrl-alt-up" "1;7" 'A';
  check_name "1 holds nothing" "up" "1;1" 'A'
;;

(* A sequence this vocabulary does not name keeps that shape. The reader turns
   [None] into its own unclaimed key rather than inventing a binding, which is
   what keeps an unread mouse report from arriving as a keystroke. *)
let test_unknown_sequences_are_none () =
  check (option string) "unknown final" None (named ~parameters:"" ~final:'q');
  check (option string) "unknown tilde number" None (named ~parameters:"99" ~final:'~');
  check (option string) "code point with no name" None (named ~parameters:"1;1" ~final:'u');
  check (option string) "u with no code point" None (named ~parameters:"x;1" ~final:'u')
;;

(* The enable asks only for disambiguation. The wider flags add key-release
   and text events, and bytes nothing reads are bytes the reader has to skip. *)
let test_enable_asks_for_disambiguation_only () =
  check string "enable" "\027[>1u" Csi.enable_kitty_keyboard;
  check string "disable pops it" "\027[<u" Csi.disable_kitty_keyboard
;;

(* SS3: a terminal in application cursor mode sends [ESC O A] for Up rather
   than [ESC \[ A]. read_input hands those finals here with no parameters, so
   the same table has to name them -- otherwise the arrows reach the surfaces
   as "unknown-esc" and move nothing while j/k keep working. *)
let test_ss3_finals_are_named_without_parameters () =
  List.iter
    (fun (final, expected) ->
      Alcotest.(check (option string))
        (Printf.sprintf "ESC O %c" final)
        (Some expected)
        (Masc_tui_csi.name ~parameters:"" ~final))
    [ ('A', "up"); ('B', "down"); ('C', "right"); ('D', "left")
    ; ('H', "home"); ('F', "end") ]

let test_an_unnamed_ss3_final_stays_unnamed () =
  (* [Z] is taken -- it is Shift+Tab -- so the check uses a final the table
     really does not name. Reaching the surfaces as "unknown-esc" is the
     right answer for those. *)
  List.iter
    (fun final ->
      Alcotest.(check (option string))
        (Printf.sprintf "ESC O %c is not named" final)
        None
        (Masc_tui_csi.name ~parameters:"" ~final))
    [ 'P'; 'Q'; 'R'; 'S' ]

let () =
  run "tui_csi"
    [ ( "legacy"
      , [ test_case "arrows keep bare names" `Quick test_legacy_arrows_keep_bare_names
        ; test_case "tilde keys" `Quick test_legacy_tilde_keys
        ; test_case "backtab is not double named" `Quick test_backtab_is_not_double_named
        ] )
    ; ( "modifiers"
      , [ test_case "modified arrows" `Quick test_modified_arrows
        ; test_case "order is fixed" `Quick test_modifier_order_is_fixed
        ; test_case "bits" `Quick test_modifier_bits
        ; test_case "unreadable mask" `Quick test_unreadable_mask_reads_as_no_modifier
        ] )
    ; ( "csi-u"
      , [ test_case "letters" `Quick test_csi_u_letters
        ; test_case "upper case is lowered" `Quick test_csi_u_lowers_the_letter
        ; test_case "named keys" `Quick test_csi_u_named_keys
        ] )
    ; ( "boundaries"
      , [ test_case "SS3 finals are named without parameters" `Quick
            test_ss3_finals_are_named_without_parameters
        ; test_case "an unnamed SS3 final stays unnamed" `Quick
            test_an_unnamed_ss3_final_stays_unnamed
        ; test_case "unknown sequences" `Quick test_unknown_sequences_are_none
        ; test_case "enable is minimal" `Quick test_enable_asks_for_disambiguation_only
        ] )
    ]
;;
