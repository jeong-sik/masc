(** The single vocabulary for rendering [Unix.file_kind] in diagnostics.

    Four sites rendered this type independently and three spellings were
    in play: [S_REG] was both "regular_file" and "regular"; [S_LNK] was
    "symbolic_link", "symlink" and "symbolic-link". An operator reading
    two messages about the same path saw its kind named differently.

    The three copies now call {!Fs_compat.file_kind_to_string}. The labels
    are pinned here because nothing else does: they are operator-facing
    strings with no schema behind them, so a rename should be a visible
    diff rather than a silent divergence. *)

open Alcotest

let kinds : (string * Unix.file_kind) list =
  [ "S_REG", Unix.S_REG
  ; "S_DIR", Unix.S_DIR
  ; "S_CHR", Unix.S_CHR
  ; "S_BLK", Unix.S_BLK
  ; "S_LNK", Unix.S_LNK
  ; "S_FIFO", Unix.S_FIFO
  ; "S_SOCK", Unix.S_SOCK
  ]
;;

(* Unix.file_kind has exactly these seven; a list shorter than that would
   test less than it claims. *)
let test_every_kind_is_covered () =
  check int "seven file kinds" 7 (List.length kinds)
;;

let test_labels () =
  List.iter
    (fun (ctor, expected, kind) ->
      check string ctor expected (Fs_compat.file_kind_to_string kind))
    [ "S_REG", "regular_file", Unix.S_REG
    ; "S_DIR", "directory", Unix.S_DIR
    ; "S_CHR", "character_device", Unix.S_CHR
    ; "S_BLK", "block_device", Unix.S_BLK
    ; "S_LNK", "symbolic_link", Unix.S_LNK
    ; "S_FIFO", "fifo", Unix.S_FIFO
    ; "S_SOCK", "socket", Unix.S_SOCK
    ]
;;

(* Two kinds sharing a label would make a diagnostic ambiguous. *)
let test_labels_are_distinct () =
  let labels = List.map (fun (_, k) -> Fs_compat.file_kind_to_string k) kinds in
  check int "labels are pairwise distinct" (List.length labels)
    (List.length (List.sort_uniq String.compare labels))
;;

let () =
  Alcotest.run
    "File kind vocabulary"
    [ ( "vocabulary"
      , [ test_case "every kind is covered" `Quick test_every_kind_is_covered
        ; test_case "labels" `Quick test_labels
        ; test_case "labels are distinct" `Quick test_labels_are_distinct
        ] )
    ]
;;
