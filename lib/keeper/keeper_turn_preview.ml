(* Live preview of the turn a keeper is running: the tail of its latest
   agent-core response and the tool it is calling right now.

   Process memory on purpose, like the other telemetry planes: this is a
   glance ("what is it doing?"), not durable truth — a keeper turn's real
   record is its transcript. Entries are never cleared on turn end; the
   consumer (the turns projection) only reads a preview while the Owner says
   a turn is running, so a stale entry is unreachable rather than managed. *)

type t =
  { text_tail : string
  ; current_tool : string option
  ; updated_at : float
  }

(* Enough to recognize the work ("ah, it is writing the PR body"), small
   enough that the turns poll stays a light projection. *)
let tail_bytes = 240

let table : (string, t) Hashtbl.t = Hashtbl.create 16

(* Last [max_bytes] of [s], starting on a UTF-8 boundary so a cut Hangul
   glyph never reaches a terminal. Walking forward from the byte cut skips
   continuation bytes (0b10xxxxxx) only — at most 3 steps. *)
let utf8_tail ~max_bytes s =
  let len = String.length s in
  if len <= max_bytes then s
  else begin
    let start = ref (len - max_bytes) in
    while
      !start < len && Char.code s.[!start] land 0xC0 = 0x80
    do
      incr start
    done;
    String.sub s !start (len - !start)
  end
;;

let current ~keeper_name = Hashtbl.find_opt table keeper_name

let note_text ~keeper_name ~now text =
  let text = String.trim text in
  if not (String.equal text "") then begin
    let text_tail = utf8_tail ~max_bytes:tail_bytes text in
    let current_tool =
      match Hashtbl.find_opt table keeper_name with
      | Some existing -> existing.current_tool
      | None -> None
    in
    Hashtbl.replace table keeper_name { text_tail; current_tool; updated_at = now }
  end
;;

let note_tool ~keeper_name ~now current_tool =
  let text_tail =
    match Hashtbl.find_opt table keeper_name with
    | Some existing -> existing.text_tail
    | None -> ""
  in
  Hashtbl.replace table keeper_name { text_tail; current_tool; updated_at = now }
;;
