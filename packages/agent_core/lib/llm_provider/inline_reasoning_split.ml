(** Splitting reasoning a provider embeds in the content channel. *)

let open_tag = "<think>"
let close_tag = "</think>"

type mode =
  | Outside
  | Inside

type state =
  { mutable mode : mode
  ; mutable pending : string
  }

type piece =
  { reasoning : string
  ; text : string
  }

let create () = { mode = Outside; pending = "" }
let inside state = state.mode = Inside

(* Naive search: the haystack here is one delta plus at most a tag's worth of
   held bytes, and the needles are seven and eight bytes long. *)
let find haystack needle =
  let hl = String.length haystack
  and nl = String.length needle in
  if nl = 0 || nl > hl
  then None
  else (
    let last = hl - nl in
    let rec go i =
      if i > last
      then None
      else if String.sub haystack i nl = needle
      then Some i
      else go (i + 1)
    in
    go 0)
;;

(* The longest suffix of [s] that is a proper prefix of [tag]. Those bytes are
   held back: the next delta may complete the tag, and emitting them now would
   put a fragment of "<think>" into the reply. *)
let held_suffix_len s tag =
  let sl = String.length s in
  let rec go k =
    if k = 0
    then 0
    else if String.sub s (sl - k) k = String.sub tag 0 k
    then k
    else go (k - 1)
  in
  go (min sl (String.length tag - 1))
;;

let drop s n = String.sub s n (String.length s - n)

let feed state chunk =
  state.pending <- state.pending ^ chunk;
  let reasoning = Buffer.create 64
  and text = Buffer.create 64 in
  let rec loop () =
    let target, sink =
      match state.mode with
      | Outside -> open_tag, text
      | Inside -> close_tag, reasoning
    in
    match find state.pending target with
    | Some i ->
      Buffer.add_string sink (String.sub state.pending 0 i);
      state.pending <- drop state.pending (i + String.length target);
      state.mode <- (match state.mode with Outside -> Inside | Inside -> Outside);
      loop ()
    | None ->
      let held = held_suffix_len state.pending target in
      Buffer.add_string
        sink
        (String.sub state.pending 0 (String.length state.pending - held));
      state.pending <- drop state.pending (String.length state.pending - held)
  in
  loop ();
  { reasoning = Buffer.contents reasoning; text = Buffer.contents text }
;;

let flush state =
  let rest = state.pending in
  state.pending <- "";
  match state.mode with
  | Outside -> { reasoning = ""; text = rest }
  | Inside ->
    (* An unterminated open tag is a cut stream, not a licence to drop what it
       carried. Every unbalanced block measured on the live fleet was short
       exactly one closing tag. *)
    { reasoning = rest; text = "" }
;;
