(** Source-word metadata for keeper command path validation.

    This module keeps shell source syntax facts at the boundary where path
    validation still needs them.  Worker_dev_tools consumes these records
    instead of carrying its own legacy path-tokenizer helper. *)

type t =
  { value : string
  ; quoted : bool
  ; escaped : bool
  ; globbed : bool
  ; braced : bool
  }

let has_unsafe_rewrite_syntax word = word.quoted || word.escaped || word.braced

let of_literal value =
  { value; quoted = false; escaped = false; globbed = false; braced = false }
;;

let of_command cmd =
  let len = String.length cmd in
  let words = ref [] in
  let buf = Buffer.create 32 in
  let quoted = ref false in
  let escaped = ref false in
  let globbed = ref false in
  let braced = ref false in
  let push () =
    if Buffer.length buf > 0
       || !quoted
       || !escaped
       || !globbed
       || !braced
    then (
      words :=
        { value = Buffer.contents buf
        ; quoted = !quoted
        ; escaped = !escaped
        ; globbed = !globbed
        ; braced = !braced
        }
        :: !words;
      Buffer.clear buf;
      quoted := false;
      escaped := false;
      globbed := false;
      braced := false)
  in
  let rec scan i quote =
    if i >= len
    then push ()
    else
      match quote, cmd.[i] with
      | None, (' ' | '\t' | '\n' | '\r') ->
        push ();
        scan (i + 1) None
      | None, ('\'' | '"') ->
        quoted := true;
        scan (i + 1) (Some cmd.[i])
      | Some q, ch when ch = q -> scan (i + 1) None
      | _, '\\' ->
        escaped := true;
        if i + 1 < len
        then (
          Buffer.add_char buf cmd.[i + 1];
          scan (i + 2) quote)
        else scan (i + 1) quote
      | _, ('*' | '?' | '[' | ']') ->
        globbed := true;
        Buffer.add_char buf cmd.[i];
        scan (i + 1) quote
      | _, ('{' | '}') ->
        braced := true;
        Buffer.add_char buf cmd.[i];
        scan (i + 1) quote
      | _, ch ->
        Buffer.add_char buf ch;
        scan (i + 1) quote
  in
  scan 0 None;
  List.rev !words
;;
