(** ANSI escape codes and box drawing characters *)

let clear = "\027[2J\027[H"
let hide_cursor = "\027[?25l"
let show_cursor = "\027[?25h"

(* Colors *)
let reset = "\027[0m"
let bold = "\027[1m"
let dim = "\027[2m"

let _black = "\027[30m"
let red = "\027[31m"
let green = "\027[32m"
let yellow = "\027[33m"
let blue = "\027[34m"
let magenta = "\027[35m"
let cyan = "\027[36m"
let white = "\027[37m"
let gray = "\027[90m"

let _bg_black = "\027[40m"
let _bg_blue = "\027[44m"
let bg_white = "\027[47m"

(* Cursor movement *)
let _move_to row col = Printf.sprintf "\027[%d;%dH" row col

(* Reverse video for selection highlight *)
let reverse = "\027[7m"

(* Box drawing characters *)
let box_h = "\xe2\x94\x80"  (* horizontal line *)
let box_v = "\xe2\x94\x82"  (* vertical line *)
let box_tl = "\xe2\x94\x8c" (* top-left corner *)
let box_tr = "\xe2\x94\x90" (* top-right corner *)
let box_bl = "\xe2\x94\x94" (* bottom-left corner *)
let box_br = "\xe2\x94\x98" (* bottom-right corner *)
let _box_t = "\xe2\x94\xac"  (* top tee *)
let _box_b = "\xe2\x94\xb4"  (* bottom tee *)
let box_l = "\xe2\x94\x9c"  (* left tee *)
let box_r = "\xe2\x94\xa4"  (* right tee *)
let _box_x = "\xe2\x94\xbc"  (* cross *)
