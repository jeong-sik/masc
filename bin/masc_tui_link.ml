type kind =
  | Board_post
  | Goal
  | Schedule
  | Task
  | Fusion_run
  | Keeper

let path = function
  | Board_post -> "board"
  | Goal -> "planning"
  | Schedule -> "schedules"
  | Task -> "overview/tasks"
  | Fusion_run -> "fusion"
  | Keeper -> "keepers"

let kind_label = function
  | Board_post -> "post"
  | Goal -> "goal"
  | Schedule -> "schedule"
  | Task -> "task"
  | Fusion_run -> "run"
  | Keeper -> "keeper"
;;

let is_unreserved = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
  | _ -> false

(* [`Generic] is the component that leaves only RFC 3986 unreserved bytes
   alone, which is what a masc:// segment needs. Checked against the byte
   string 0..255: identical to the hand-rolled encoder this replaced.
   [is_unreserved] stays because [reference_byte] below reads it for a
   different question -- which bytes a written reference may contain. *)
let percent_encode_segment value = Uri.pct_encode ~component:`Generic value

let reference kind id =
  Printf.sprintf "masc://%s/%s" (path kind) (percent_encode_segment id)

let kind_of_path = function
  | "board" -> Some Board_post
  | "planning" -> Some Goal
  | "schedules" -> Some Schedule
  | "overview/tasks" -> Some Task
  | "fusion" -> Some Fusion_run
  | "keepers" -> Some Keeper
  | _ -> None
;;

let percent_decode_segment value =
  let buf = Buffer.create (String.length value) in
  let limit = String.length value in
  let hex char =
    match char with
    | '0' .. '9' -> Some (Char.code char - Char.code '0')
    | 'a' .. 'f' -> Some (Char.code char - Char.code 'a' + 10)
    | 'A' .. 'F' -> Some (Char.code char - Char.code 'A' + 10)
    | _ -> None
  in
  let rec walk index =
    if index >= limit then Some (Buffer.contents buf)
    else if value.[index] = '%' then
      if index + 2 >= limit then None
      else
        match hex value.[index + 1], hex value.[index + 2] with
        | Some high, Some low ->
          Buffer.add_char buf (Char.chr ((high * 16) + low));
          walk (index + 3)
        (* A stray percent is not a reference this wrote. Answering [None]
           keeps a malformed one from becoming an id that names nothing. *)
        | _ -> None
    else (
      Buffer.add_char buf value.[index];
      walk (index + 1))
  in
  walk 0
;;

let scheme = "masc://"

let parse reference =
  let scheme_length = String.length scheme in
  if String.length reference <= scheme_length
     || not (String.equal (String.sub reference 0 scheme_length) scheme)
  then None
  else (
    let rest = String.sub reference scheme_length
                 (String.length reference - scheme_length) in
    (* The identifier is the last segment; every path this writes is one or
       two segments before it, so the split is from the right. *)
    match String.rindex_opt rest '/' with
    | None -> None
    | Some cut ->
      let path_part = String.sub rest 0 cut in
      let id_part = String.sub rest (cut + 1) (String.length rest - cut - 1) in
      if String.equal id_part "" then None
      else (
        match kind_of_path path_part, percent_decode_segment id_part with
        | Some kind, Some id -> Some (kind, id)
        | _ -> None))
;;

(* A reference ends where a path segment can no longer continue. The writer
   percent-encodes everything outside the unreserved set, so the scan stops at
   the first byte [reference] would never have emitted. *)
let reference_byte byte = is_unreserved byte || byte = '%' || byte = '/'

let scan body =
  let limit = String.length body in
  let scheme_length = String.length scheme in
  let rec extent index =
    if index < limit && reference_byte body.[index] then extent (index + 1) else index
  in
  let rec walk index found =
    if index + scheme_length > limit then List.rev found
    else if String.equal (String.sub body index scheme_length) scheme then (
      let stop = extent (index + scheme_length) in
      let candidate = String.sub body index (stop - index) in
      match parse candidate with
      | Some hit when not (List.mem hit found) -> walk stop (hit :: found)
      | Some _ -> walk stop found
      | None -> walk stop found)
    else walk (index + 1) found
  in
  walk 0 []
;;

let osc52_copy text =
  "\027]52;c;" ^ Base64.encode_string text ^ "\007"
