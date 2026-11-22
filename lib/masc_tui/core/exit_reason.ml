type t =
  | Quit_key
  | Interrupt
  | Terminate of string
  | Exception of string
  | Unrecorded

let wire_prefix = "[masc-tui] "

let label = function
  | Quit_key -> "quit key"
  | Interrupt -> "interrupt"
  | Terminate signal -> "signal " ^ signal
  | Exception detail -> "exception " ^ detail
  | Unrecorded -> "no cause was recorded"

let is_normal = function
  | Quit_key | Interrupt | Terminate _ -> true
  | Exception _ | Unrecorded -> false

let one_row text =
  String.map
    (fun c ->
      let code = Char.code c in
      if code < 0x20 || code = 0x7F then ' ' else c)
    text

let cause_limit = 200

let rec character_boundary text index =
  if index <= 0 then 0
  else if Char.code text.[index] land 0xC0 = 0x80 then
    character_boundary text (index - 1)
  else index

let format_grouped_int n =
  let digits = string_of_int (abs n) in
  let len = String.length digits in
  let buf = Buffer.create (len + (len / 3) + 1) in
  if n < 0 then Buffer.add_char buf '-';
  for i = 0 to len - 1 do
    let remaining = len - i in
    if i > 0 && remaining mod 3 = 0 then Buffer.add_char buf ',';
    Buffer.add_char buf digits.[i]
  done;
  Buffer.contents buf

let bounded text =
  let length = String.length text in
  if length <= cause_limit then text
  else
    let cut = character_boundary text cause_limit in
    Printf.sprintf "%s [%s more bytes]" (String.sub text 0 cut)
      (format_grouped_int (length - cut))

let line t =
  Printf.sprintf "exit: %s (%s)"
    (if is_normal t then "normal" else "abnormal")
    (bounded (one_row (label t)))

let wire_line t = wire_prefix ^ line t

let equal a b =
  match a, b with
  | Quit_key, Quit_key | Interrupt, Interrupt | Unrecorded, Unrecorded -> true
  | Terminate x, Terminate y | Exception x, Exception y -> String.equal x y
  | Quit_key, (Interrupt | Terminate _ | Exception _ | Unrecorded)
  | Interrupt, (Quit_key | Terminate _ | Exception _ | Unrecorded)
  | Terminate _, (Quit_key | Interrupt | Exception _ | Unrecorded)
  | Exception _, (Quit_key | Interrupt | Terminate _ | Unrecorded)
  | Unrecorded, (Quit_key | Interrupt | Terminate _ | Exception _) ->
      false
