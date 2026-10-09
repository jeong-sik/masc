module Markdown = Masc_tui_markdown
module Preview = Masc_tui_link_preview
module Layout = Masc_tui_message_layout

type position =
  | Body_byte of { offset : int; expansion : int }
  | Body_label of { block_start : int; field : Markdown.generated_field; byte : int }
  | Thinking_summary_byte of int
  | Thinking_summary_label of { field : Masc_tui_markdown.generated_field; byte : int }
  | Preview_byte of { url : string; index : int; field : Preview.card_field; byte : int; expansion : int }
  | Journal_byte of { line : int; field : Layout.journal_field; byte : int }

let compare_position a b =
  match a,b with
  | Body_byte a, Body_byte b -> compare (a.offset,a.expansion) (b.offset,b.expansion)
  | Body_label a, Body_label b -> compare (a.block_start,a.field,a.byte) (b.block_start,b.field,b.byte)
  | Body_byte a, Body_label b -> let c=compare a.offset b.block_start in if c=0 then -1 else c
  | Body_label a, Body_byte b -> let c=compare a.block_start b.offset in if c=0 then 1 else c
  | (Body_byte _ | Body_label _), _ -> -1
  | _, (Body_byte _ | Body_label _) -> 1
  | Thinking_summary_byte a, Thinking_summary_byte b -> compare a b
  | Thinking_summary_label a, Thinking_summary_label b -> compare (a.field,a.byte) (b.field,b.byte)
  | Thinking_summary_byte _, Thinking_summary_label _ -> -1
  | Thinking_summary_label _, Thinking_summary_byte _ -> 1
  | (Thinking_summary_byte _ | Thinking_summary_label _), _ -> -1
  | _, (Thinking_summary_byte _ | Thinking_summary_label _) -> 1
  | Preview_byte a, Preview_byte b -> compare (a.index,a.url,a.field,a.byte,a.expansion) (b.index,b.url,b.field,b.byte,b.expansion)
  | Preview_byte _, Journal_byte _ -> -1
  | Journal_byte _, Preview_byte _ -> 1
  | Journal_byte a, Journal_byte b -> compare (a.line,a.field,a.byte) (b.line,b.field,b.byte)

type run = {
  text : string;
  positions : position option array;
  visible_rows : (int * Markdown.source_range list) list;
  joins_previous : bool;
}

let of_document ~presentation ~body_length ~origins (document : Markdown.document_render) =
  let unavailable=ref (document.mapping<>Markdown.Complete_document) in
  let runs=List.map (fun (run : Markdown.semantic_run) ->
    let previous=ref None and expansion=ref 0 in
    let positions=Array.map (fun origin ->
      if origin= !previous then incr expansion else expansion:=0;
      previous:=origin;
      match origin with
      | None -> None
      | Some (Markdown.Original range) ->
          Option.map (function
            | Body_byte point -> Body_byte {point with expansion= !expansion}
            | Preview_byte point -> Preview_byte {point with expansion= !expansion}
            | (Body_label _ | Thinking_summary_byte _ | Thinking_summary_label _ | Journal_byte _) as point -> point) origins.(range.start_byte)
      | Some (Markdown.Generated {block_start;field;byte}) ->
          if block_start<body_length then Some(match presentation with
            | Layout.Source_body -> Body_label {block_start;field;byte}
            | Layout.Thinking_summary -> Thinking_summary_label {field;byte})
          else (unavailable:=true; None)) run.origins in
    {text=run.semantic_text;positions;visible_rows=run.visible_rows;joins_previous=run.joins_previous}) document.semantic_runs in
  runs,!unavailable

type matched = { body_row : int; position : position; ending_position : position }

type searchable = {
  text : string;
  positions : position option array;
  rows : int option array;
  boundaries : bool array;
}

let searchable ~body_rows (run : run) =
  let rows=Array.make (String.length run.text) None in
  List.iter (fun (row,ranges) -> if row<body_rows then List.iter (fun (range : Markdown.source_range) ->
    for byte=range.start_byte to range.end_byte-1 do rows.(byte)<-Some row done) ranges) run.visible_rows;
  let text,copied=Masc_tui_theme.strip_sgr_with_positions run.text in
  {text=String.lowercase_ascii text;
   positions=Array.map (Array.get run.positions) copied;
   rows=Array.map (Array.get rows) copied;
   boundaries=Array.make (String.length text) false}

let join_lines reversed =
  let lines=List.rev reversed in
  let intersperse separator pieces =
    let rec walk = function []->[] | [piece]->[piece] | piece::rest -> piece::separator::walk rest in
    walk pieces in
  {text=String.concat "\n" (List.map (fun (line : searchable) -> line.text) lines);
   positions=Array.concat (intersperse [|None|] (List.map (fun line -> line.positions) lines));
   rows=Array.concat (intersperse [|None|] (List.map (fun line -> line.rows) lines));
   boundaries=Array.concat (intersperse [|true|] (List.map (fun line -> line.boundaries) lines))}

(* A semantic group without optional logical-line separators is an ordinary
   substring search. Failure links retain overlaps without replaying a long
   repetitive prefix for every candidate byte. Physical wrapping is already
   represented by visibility ranges; it does not change the semantic text. *)
let find_plain ~needle (group : searchable) consider =
  let size = String.length needle and length = String.length group.text in
  let failure = Array.make size 0 in
  let prefix = ref 0 in
  for at = 1 to size - 1 do
    while !prefix > 0 && needle.[at] <> needle.[!prefix] do
      prefix := failure.(!prefix - 1)
    done;
    if needle.[at] = needle.[!prefix] then incr prefix;
    failure.(at) <- !prefix
  done;
  let visible_position = Array.make length None in
  let previous = ref None in
  for at = 0 to length - 1 do
    if Option.is_some group.rows.(at) && Option.is_some group.positions.(at) then previous := Some at;
    visible_position.(at) <- !previous
  done;
  let next_position = Array.make (length + 1) length in
  for at = length - 1 downto 0 do
    next_position.(at) <- if Option.is_some group.positions.(at) then at
      else next_position.(at + 1)
  done;
  (* A monotone window provides the last visible row of the whole phrase in
     constant amortized work, even when many overlapping matches survive. *)
  let rows = Array.make length 0 in
  let first = ref 0 and ending = ref 0 and matched = ref 0 in
  for at = 0 to length - 1 do
    let start = at - size + 1 in
    while !first < !ending && rows.(!first) < start do incr first done;
    Option.iter (fun row ->
      while !first < !ending &&
        Option.exists (fun previous -> previous <= row) group.rows.(rows.(!ending - 1)) do
        decr ending
      done;
      rows.(!ending) <- at;
      incr ending) group.rows.(at);
    match group.rows.(at) with
    | None when group.text.[at] <> ' ' && group.text.[at] <> '\t' -> matched := 0
    | _ ->
        while !matched > 0 && needle.[!matched] <> group.text.[at] do
          matched := failure.(!matched - 1)
        done;
        if needle.[!matched] = group.text.[at] then incr matched;
        if !matched = size then begin
          let origin = next_position.(start) in
          if origin <= at && !first < !ending then
            Option.iter (fun position ->
              Option.iter (fun ending ->
                if ending >= start then
                  Option.iter (fun ending_position ->
                    Option.iter (fun body_row -> consider {body_row;position;ending_position})
                      group.rows.(rows.(!first))) group.positions.(ending)) visible_position.(at)) group.positions.(origin);
          matched := failure.(size - 1)
        end
  done

type prefix_observation = { first_position : position option; last_position : position option; last_row : int option }

(* A logical source-line boundary has the existing explicit contract: consume
   one query space/newline or skip it. Retain one best eligible observation per
   query-prefix state, rather than recursively replaying every branch/start.
   This is O(text * query), O(query) memory for groups with such boundaries;
   ordinary groups above are O(text + query). No query-length cap or timeout. *)
let find_optional_lines ~needle ~before (group : searchable) consider =
  let size = String.length needle in
  let current = ref (Array.make (size + 1) []) in
  let spare = ref (Array.make (size + 1) []) in
  let eligible position = match before with
    | None -> true | Some boundary -> compare_position position boundary < 0 in
  let keep states prefix observation =
    match observation.first_position with
    | Some position when not (eligible position) -> ()
    | _ ->
        let same_class previous = Option.is_some observation.first_position
          = Option.is_some previous.first_position in
        let replace = match List.find_opt same_class states.(prefix) with
          | None -> true
          | Some previous ->
              (match observation.first_position, previous.first_position with
               | Some left, Some right ->
                   let order = compare_position left right in
                   order > 0 || (order = 0 && observation.last_row > previous.last_row)
               | None, None -> observation.last_row > previous.last_row
               | Some _, None | None, Some _ -> false) in
        if replace then states.(prefix) <- observation :: List.filter (fun previous -> not (same_class previous)) states.(prefix)
  in
  for at = 0 to String.length group.text - 1 do
    let next = !spare in
    Array.fill next 0 (size + 1) [];
    if group.boundaries.(at) then begin
      for prefix = 1 to size - 1 do
        List.iter (fun observation ->
          keep next prefix observation;
          if needle.[prefix] = ' ' || needle.[prefix] = '\n' then
            keep next (prefix + 1) observation) (!current).(prefix)
      done
    end else begin
      for prefix = 0 to size - 1 do
        let previous = if prefix = 0 then [{first_position=None;last_position=None;last_row=None}]
          else (!current).(prefix) in
        List.iter (fun observation ->
          if group.text.[at] = needle.[prefix] then
            match group.rows.(at) with
            | None when group.text.[at] <> ' ' && group.text.[at] <> '\t' -> ()
            | row ->
                let first_position = match observation.first_position with
                  | Some _ as position -> position | None -> group.positions.(at) in
                let last_row = match observation.last_row, row with
                  | Some left, Some right -> Some (max left right)
                  | None, row | row, None -> row in
                let last_position = match row, group.positions.(at) with
                  | Some _, (Some _ as position) -> position
                  | Some _, None | None, _ -> observation.last_position in
                keep next (prefix + 1) {first_position;last_position;last_row}) previous
      done
    end;
    List.iter (fun observation ->
      match observation.first_position, observation.last_position, observation.last_row with
      | Some position, Some ending_position, Some body_row -> consider {body_row;position;ending_position}
      | None, _, _ | _, None, _ | _, _, None -> ()) next.(size);
    spare := !current;
    current := next
  done

let find ~needle ~before ~body_rows runs =
  let needle = String.lowercase_ascii needle in
  if String.length needle = 0 then None else
  let groups = List.fold_left (fun groups (run : run) ->
    let next = searchable ~body_rows run in
    match run.joins_previous, groups with
    | true, previous :: rest -> (next :: previous) :: rest
    | _ -> [next] :: groups) [] runs |> List.map join_lines in
  let newest = ref None in
  let consider found =
    if (match before with None -> true | Some boundary -> compare_position found.position boundary < 0)
    then match !newest with
      | Some current when compare_position current.position found.position >= 0 -> ()
      | _ -> newest := Some found in
  List.iter (fun group ->
    if Array.exists Fun.id group.boundaries then
      find_optional_lines ~needle ~before group consider
    else find_plain ~needle group consider) groups;
  !newest
