type entry =
  { mutable count : int
  ; mutable threshold_emitted : bool
  }

type t =
  { state : (string, entry) Hashtbl.t
  ; mutex : Mutex.t
  }

type occurrence_outcome =
  | First
  | Repeated of int

type threshold_payload =
  { count : int
  ; threshold : int
  }

type threshold_outcome =
  | First_threshold
  | Repeated_threshold of int
  | Threshold of threshold_payload

let default_normalize_length_cap = 80
let component_separator = "\x00"
let create ?(initial_capacity = 32) () =
  { state = Hashtbl.create initial_capacity; mutex = Mutex.create () }
;;

let key components = String.concat component_separator components

let is_ws = function
  | ' ' | '\t' | '\r' | '\n' -> true
  | _ -> false
;;

let lowercase_ascii = function
  | 'A' .. 'Z' as c -> Char.chr (Char.code c + 32)
  | c -> c
;;

let normalize_signature ?(length_cap = default_normalize_length_cap) raw =
  let n = String.length raw in
  let buf = Buffer.create (min n length_cap) in
  let rec walk i prev_was_space =
    if i >= n
    then ()
    else (
      let c = String.unsafe_get raw i in
      if is_ws c
      then (
        if not prev_was_space then Buffer.add_char buf ' ';
        walk (i + 1) true)
      else (
        Buffer.add_char buf (lowercase_ascii c);
        walk (i + 1) false))
  in
  walk 0 true;
  let s = Buffer.contents buf in
  let len = String.length s in
  let s =
    if len > 0 && Char.equal (String.unsafe_get s (len - 1)) ' '
    then String.sub s 0 (len - 1)
    else s
  in
  if String.length s > length_cap then String.sub s 0 length_cap else s
;;

let with_lock t f = Mutex.protect t.mutex f

let make_entry () = { count = 1; threshold_emitted = false }

let record t ~key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.state key with
    | None ->
      Hashtbl.replace t.state key (make_entry ());
      First
    | Some entry ->
      entry.count <- entry.count + 1;
      Repeated entry.count)
;;

let record_threshold t ~key ~threshold =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.state key with
    | None ->
      Hashtbl.replace t.state key (make_entry ());
      First_threshold
    | Some entry ->
      entry.count <- entry.count + 1;
      if entry.count >= threshold && not entry.threshold_emitted
      then (
        entry.threshold_emitted <- true;
        Threshold { count = entry.count; threshold })
      else Repeated_threshold entry.count)
;;

let reset t = with_lock t (fun () -> Hashtbl.reset t.state)
let remove t ~key = with_lock t (fun () -> Hashtbl.remove t.state key)
let cardinality t = with_lock t (fun () -> Hashtbl.length t.state)

let count t ~key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.state key with
    | None -> 0
    | Some entry -> entry.count)
;;
