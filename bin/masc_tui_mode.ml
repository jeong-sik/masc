(* The input-mode derivation. The order below is the dispatch's arm order in
   masc_tui.ml (image overlay before everything; the modals before the
   composer — composer_claimed's own guard yields to each of them; an armed
   two-press action only colours Normal-mode keys). test_tui_mode pins this
   order; if a dispatch arm moves, move the arm here and the test together. *)

type t =
  | Image_overlay
  | Help
  | Palette
  | Search
  | Board_compose
  | Message_edit
  | Composer
  | Pending of string
  | Normal

type flags = {
  image_open : bool;
  help_open : bool;
  palette_open : bool;
  search_active : bool;
  board_composing : bool;
  message_mode : bool;
  composer_focused : bool;
  pending : string option;
}

let no_flags =
  { image_open = false
  ; help_open = false
  ; palette_open = false
  ; search_active = false
  ; board_composing = false
  ; message_mode = false
  ; composer_focused = false
  ; pending = None
  }

let active flags =
  if flags.image_open then Image_overlay
  else if flags.help_open then Help
  else if flags.palette_open then Palette
  else if flags.search_active then Search
  else if flags.board_composing then Board_compose
  else if flags.message_mode then Message_edit
  else if flags.composer_focused then Composer
  else match flags.pending with Some name -> Pending name | None -> Normal

let label = function
  | Image_overlay -> Some "image"
  | Help -> Some "help"
  | Palette -> Some "palette"
  | Search -> Some "search"
  | Board_compose -> Some "compose"
  | Message_edit -> Some "chat"
  | Composer -> Some "composer"
  | Pending name -> Some (name ^ "?")
  | Normal -> None
