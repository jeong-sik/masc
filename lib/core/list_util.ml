(** List utilities — SSOT for cross-module list helpers that have no
    direct stdlib equivalent.

    [count_if] is the single-pass variant of [List.length (List.filter
    pred xs)] — it drops the intermediate filter list allocation. The
    pattern occurred 23 times across the codebase before this module
    landed; centralising avoids re-defining the helper per file and
    makes the intent searchable. *)


let count_if pred xs =
  List.fold_left (fun n x -> if pred x then n + 1 else n) 0 xs

(** [strip_prefix ~equal prefix xs] is [Some rest] when [xs] is the elements of
    [prefix] followed by [rest], each pair compared with [equal]. It is [None]
    when [xs] is shorter than [prefix] or an element differs. *)
let rec strip_prefix ~equal prefix xs =
  match prefix, xs with
  | [], rest -> Some rest
  | _ :: _, [] -> None
  | expected :: prefix, actual :: xs ->
    if equal expected actual then strip_prefix ~equal prefix xs else None

(** [is_prefix ~equal prefix xs] is [true] when [strip_prefix ~equal prefix xs]
    is [Some _]. *)
let is_prefix ~equal prefix xs = Option.is_some (strip_prefix ~equal prefix xs)

(** [take_last n xs] returns the last [n] elements of [xs].
    Returns [[]] when [n <= 0] and [xs] when [List.length xs <= n]. *)
let take_last n xs =
  if n <= 0 then []
  else
    let len = List.length xs in
    if len <= n then xs
    else
      let rec drop k ys =
        if k <= 0 then ys
        else
          match ys with
          | [] -> []
          | _ :: tl -> drop (k - 1) tl
      in
      drop (len - n) xs
