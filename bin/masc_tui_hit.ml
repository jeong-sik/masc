(* Each registry owns one pair of parameter codes, so marks of two registries
   can wrap the same text and each [extract] reads only its own. The pairs are
   handed out in the order registries are made; nobody picks a number. *)
let channels = Atomic.make 0

type 'target registry = {
  targets : 'target Dynarray.t;
  open_code : string;
  close_code : string;
}

let registry () =
  let channel = Atomic.fetch_and_add channels 1 in
  { targets = Dynarray.create ();
    open_code = string_of_int ((2 * channel) + 1);
    close_code = string_of_int ((2 * channel) + 2) }

let reset registry = Dynarray.clear registry.targets

(* A CSI whose parameters open with [=] is one no sequence this TUI draws
   uses, and ending it in [m] is what makes every measure treat it as a
   zero-width style. [<open>;n] opens the mark numbered [n]; [<close>]
   closes it. *)
let introducer = "\027[="

let mark registry target text =
  let number = Dynarray.length registry.targets in
  Dynarray.add_last registry.targets target;
  Printf.sprintf "%s%s;%dm%s%s%sm" introducer registry.open_code number text
    introducer registry.close_code

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

(* The code of the mark that starts at [offset], and the offset after it.
   [None] for an escape that is not one of this registry's marks, which is
   kept as it is -- another registry's marks included. *)
let mark_at registry line offset =
  let length = String.length line in
  let introducer_length = String.length introducer in
  if offset + introducer_length > length
     || not (String.equal (String.sub line offset introducer_length) introducer)
  then None
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
          match String.split_on_char ';' parameters with
          | [ close ] when String.equal close registry.close_code -> Some Close
          | [ opened; number ] when String.equal opened registry.open_code ->
              Option.map (fun n -> Open n) (int_of_string_opt number)
          | _ -> None
        in
        Option.map (fun code -> (code, final_index + 1)) code

let extract_line registry ~row line =
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
          match mark_at registry line escape with
          | None ->
              Buffer.add_char clean '\027';
              scan (escape + 1)
          | Some (Close, next) ->
              finish_open ();
              scan next
          | Some (Open number, next) ->
              finish_open ();
              (if number >= 0 && number < Dynarray.length registry.targets then
                 open_zone := Some (cells () + 1, Dynarray.get registry.targets number));
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
