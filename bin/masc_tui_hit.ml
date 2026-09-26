type 'target registry = 'target Dynarray.t

let registry () = Dynarray.create ()
let reset = Dynarray.clear

(* A CSI whose parameters open with [=] is one no sequence this TUI draws
   uses, and ending it in [m] is what makes every measure treat it as a
   zero-width style. [1;n] opens the mark numbered [n]; [2] closes it. *)
let introducer = "\027[="
let open_parameter = "1;"
let close_parameters = "2"

let mark registry target text =
  let number = Dynarray.length registry in
  Dynarray.add_last registry target;
  Printf.sprintf "%s%s%dm%s%s%sm" introducer open_parameter number text
    introducer close_parameters

type 'target zone = {
  row : int;
  first : int;
  last : int;
  target : 'target;
}

type 'target zones = 'target zone list

let no_zones = []

type mark_code =
  | Open of int
  | Close

(* Whether the mark introducer starts at [offset], read in place: every
   escape of every row is asked this, and most rows carry no mark at all. *)
let introducer_at line offset =
  let length = String.length introducer in
  offset + length <= String.length line
  &&
  let rec same index =
    index >= length
    || (Char.equal line.[offset + index] introducer.[index] && same (index + 1))
  in
  same 0

let has_marks line =
  let rec from offset =
    match String.index_from_opt line offset '\027' with
    | None -> false
    | Some escape -> introducer_at line escape || from (escape + 1)
  in
  from 0

(* The code of the mark that starts at [offset], and the offset after it.
   [None] for an escape that is not one of ours, which is kept as it is. *)
let mark_at line offset =
  let length = String.length line in
  let introducer_length = String.length introducer in
  if not (introducer_at line offset) then None
  else
    let parameters_start = offset + introducer_length in
    let rec final index =
      if index >= length then None
      else
        match line.[index] with
        | '0' .. '9' | ';' -> final (index + 1)
        | 'm' -> Some index
        | _ -> None
    in
    match final parameters_start with
    | None -> None
    | Some final_index ->
        let parameters =
          String.sub line parameters_start (final_index - parameters_start)
        in
        let code =
          if String.equal parameters close_parameters then Some Close
          else if String.starts_with ~prefix:open_parameter parameters then
            let number =
              String.sub parameters (String.length open_parameter)
                (String.length parameters - String.length open_parameter)
            in
            Option.map (fun n -> Open n) (int_of_string_opt number)
          else None
        in
        Option.map (fun code -> (code, final_index + 1)) code

let extract_line registry ~row line =
  if not (has_marks line) then (line, []) else
  let length = String.length line in
  let clean = Buffer.create length in
  let cells () = Masc_tui_message_layout.display_width (Buffer.contents clean) in
  let zones = ref [] in
  let close_at ~first ~target last =
    if last >= first then zones := { row; first; last; target } :: !zones
  in
  let open_zone = ref None in
  let finish_open () =
    match !open_zone with
    | None -> ()
    | Some (first, target) ->
        open_zone := None;
        close_at ~first ~target (cells ())
  in
  let rec scan offset =
    if offset >= length then ()
    else
      match String.index_from_opt line offset '\027' with
      | None -> Buffer.add_substring clean line offset (length - offset)
      | Some escape -> (
          Buffer.add_substring clean line offset (escape - offset);
          match mark_at line escape with
          | None ->
              Buffer.add_char clean '\027';
              scan (escape + 1)
          | Some (Close, next) ->
              finish_open ();
              scan next
          | Some (Open number, next) ->
              finish_open ();
              (if number >= 0 && number < Dynarray.length registry then
                 open_zone := Some (cells () + 1, Dynarray.get registry number));
              scan next)
  in
  scan 0;
  finish_open ();
  (Buffer.contents clean, List.rev !zones)

let extract registry lines =
  let extracted =
    List.mapi (fun index line -> extract_line registry ~row:(index + 1) line) lines
  in
  (List.map fst extracted, List.concat_map snd extracted)

let target_at zones ~row ~column =
  List.find_map
    (fun zone ->
      if zone.row = row && column >= zone.first && column <= zone.last then
        Some zone.target
      else None)
    zones

let to_list zones =
  List.map (fun zone -> (zone.row, zone.first, zone.last, zone.target)) zones
