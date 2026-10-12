module Markdown = Masc_tui_markdown
module Preview = Masc_tui_link_preview
module Layout = Masc_tui_message_layout

(* Digest of the presented body text. *)
type body_identity = Digest.t

let body_identity text = Digest.string text

(* Every position names the text it indexes as well as its place: a body by
   its identity, a generated label, preview field or journal field by its
   value. A place can hold another version of its text later, and an offset
   into the old version names no byte of the new one. *)
type position =
  | Body_byte of { body : body_identity; offset : int; expansion : int }
  | Body_label of { body : body_identity; block_start : int; field : Markdown.generated_field;
      value : string; byte : int }
  | Thinking_summary_byte of { body : body_identity; offset : int }
  | Thinking_summary_label of { body : body_identity; field : Masc_tui_markdown.generated_field;
      value : string; byte : int }
  | Projected_byte of { body : body_identity; projection : Layout.projected_body; offset : int; expansion : int }
  | Projected_label of { body : body_identity; projection : Layout.projected_body; block_start : int;
      field : Markdown.generated_field; value : string; byte : int }
  | Preview_byte of { url : string; index : int; field : Preview.card_field; order : Preview.card_order;
      value : string; byte : int; expansion : int }
  | Journal_byte of { line : int; field : Layout.journal_field; value : string; byte : int }
  | Request_byte of { request : string; byte : int }

let compare_position a b =
  match a,b with
  | Request_byte a, Request_byte b -> compare (a.request,a.byte) (b.request,b.byte)
  | Request_byte _, _ -> -1
  | _, Request_byte _ -> 1
  | Body_byte a, Body_byte b -> compare (a.body,a.offset,a.expansion) (b.body,b.offset,b.expansion)
  | Body_label a, Body_label b ->
      compare (a.body,a.block_start,a.field,a.value,a.byte) (b.body,b.block_start,b.field,b.value,b.byte)
  | Body_byte a, Body_label b ->
      let c=compare (a.body,a.offset) (b.body,b.block_start) in if c=0 then -1 else c
  | Body_label a, Body_byte b ->
      let c=compare (a.body,a.block_start) (b.body,b.offset) in if c=0 then 1 else c
  | (Body_byte _ | Body_label _), _ -> -1
  | _, (Body_byte _ | Body_label _) -> 1
  | Thinking_summary_byte a, Thinking_summary_byte b -> compare (a.body,a.offset) (b.body,b.offset)
  | Thinking_summary_label a, Thinking_summary_label b ->
      compare (a.body,a.field,a.value,a.byte) (b.body,b.field,b.value,b.byte)
  | Thinking_summary_byte a, Thinking_summary_label b ->
      let c=compare a.body b.body in if c=0 then -1 else c
  | Thinking_summary_label a, Thinking_summary_byte b ->
      let c=compare a.body b.body in if c=0 then 1 else c
  | (Thinking_summary_byte _ | Thinking_summary_label _), _ -> -1
  | _, (Thinking_summary_byte _ | Thinking_summary_label _) -> 1
  | Projected_byte a, Projected_byte b ->
      compare (a.body,a.projection,a.offset,a.expansion) (b.body,b.projection,b.offset,b.expansion)
  | Projected_label a, Projected_label b ->
      compare (a.body,a.projection,a.block_start,a.field,a.value,a.byte)
        (b.body,b.projection,b.block_start,b.field,b.value,b.byte)
  | Projected_byte a, Projected_label b ->
      let c=compare (a.body,a.projection,a.offset) (b.body,b.projection,b.block_start) in if c=0 then -1 else c
  | Projected_label a, Projected_byte b ->
      let c=compare (a.body,a.projection,a.block_start) (b.body,b.projection,b.offset) in if c=0 then 1 else c
  | (Projected_byte _ | Projected_label _), _ -> -1
  | _, (Projected_byte _ | Projected_label _) -> 1
  | Preview_byte a, Preview_byte b ->
      compare (a.index,a.url,a.order,a.field,a.value,a.byte,a.expansion)
        (b.index,b.url,b.order,b.field,b.value,b.byte,b.expansion)
  | Preview_byte _, Journal_byte _ -> -1
  | Journal_byte _, Preview_byte _ -> 1
  | Journal_byte a, Journal_byte b -> compare (a.line,a.field,a.value,a.byte) (b.line,b.field,b.value,b.byte)

let presentation_of_position = function
  | Body_byte _ | Body_label _ -> Some Layout.Source_body
  | Thinking_summary_byte _ | Thinking_summary_label _ -> Some Layout.Thinking_summary
  | Projected_byte {projection;_} | Projected_label {projection;_} -> Some (Layout.Projected_body projection)
  | Preview_byte _ | Journal_byte _ | Request_byte _ -> None

type run = {
  text : string;
  positions : position option array;
  visible_rows : (int * Markdown.source_range list) list;
  joins_previous : bool;
  reading : Markdown.reading_order;
}

(* The place a position's text occupies, and that text's identity. A label
   sits inside its body, so it has both the body's place and its own. *)
type slot =
  | Body_slot of Layout.body_presentation
  | Label_slot of Layout.body_presentation * int option * Markdown.generated_field
  | Preview_slot of string * int * Preview.card_field
  | Journal_slot of int * Layout.journal_field

let slots = function
  | Body_byte {body;_} -> [Body_slot Layout.Source_body, body]
  | Body_label {body;block_start;field;value;_} ->
      [Body_slot Layout.Source_body, body; Label_slot (Layout.Source_body, Some block_start, field), value]
  | Thinking_summary_byte {body;_} -> [Body_slot Layout.Thinking_summary, body]
  | Thinking_summary_label {body;field;value;_} ->
      [Body_slot Layout.Thinking_summary, body; Label_slot (Layout.Thinking_summary, None, field), value]
  | Projected_byte {body;projection;_} -> [Body_slot (Layout.Projected_body projection), body]
  | Projected_label {body;projection;block_start;field;value;_} ->
      [Body_slot (Layout.Projected_body projection), body;
       Label_slot (Layout.Projected_body projection, Some block_start, field), value]
  | Preview_byte {url;index;field;value;_} -> [Preview_slot (url,index,field), value]
  | Journal_byte {line;field;value;_} -> [Journal_slot (line,field), value]
  (* A request id names its request; no other text replaces it. *)
  | Request_byte _ -> []

let of_document ~presentation ~body ~body_length ~origins (document : Markdown.document_render) =
  let unavailable=ref (document.mapping<>Markdown.Complete_document) in
  (* A generated label's text is the label's own run, and it can be
     regenerated (a diagnostic names the current column count). Collect each
     label's text first, so every position of the label names the same value. *)
  let label_texts=Hashtbl.create 4 in
  List.iter (fun (run : Markdown.semantic_run) ->
    Array.iteri (fun at -> function
      | Some (Markdown.Generated {block_start;field;_}) ->
          let text=match Hashtbl.find_opt label_texts (block_start,field) with
            | Some text -> text
            | None -> let text=Buffer.create 32 in Hashtbl.replace label_texts (block_start,field) text; text in
          Buffer.add_char text run.semantic_text.[at]
      | Some (Markdown.Original _) | None -> ()) run.origins) document.semantic_runs;
  let label_values=Hashtbl.create 4 in
  Hashtbl.iter (fun key text -> Hashtbl.replace label_values key (Buffer.contents text)) label_texts;
  let label_value key=Option.value ~default:"" (Hashtbl.find_opt label_values key) in
  (* Drawn labels the document could not map have no run at all, so the runs
     it returned are each complete. A run that holds an unmapped generated
     label is left out whole: searching around the gap would match across
     text that has no position. *)
  let runs=List.filter_map (fun (run : Markdown.semantic_run) ->
    let omitted=ref false in
    let previous=ref None and expansion=ref 0 in
    let positions=Array.map (fun origin ->
      if origin= !previous then incr expansion else expansion:=0;
      previous:=origin;
      match origin with
      | None -> None
      | Some (Markdown.Original range) ->
          Option.map (function
            | Body_byte point -> Body_byte {point with expansion= !expansion}
            | Projected_byte point -> Projected_byte {point with expansion= !expansion}
            | Preview_byte point -> Preview_byte {point with expansion= !expansion}
            | (Body_label _ | Thinking_summary_byte _ | Thinking_summary_label _
              | Projected_label _ | Journal_byte _ | Request_byte _) as point -> point) origins.(range.start_byte)
      | Some (Markdown.Generated {block_start;field;byte}) ->
          if block_start<body_length then Some(match presentation with
            | Layout.Source_body -> Body_label {body;block_start;field;value=label_value (block_start,field);byte}
            | Layout.Thinking_summary -> Thinking_summary_label {body;field;value=label_value (block_start,field);byte}
            | Layout.Projected_body projection ->
                Projected_label {body;projection;block_start;field;value=label_value (block_start,field);byte})
          else (omitted:=true; None)) run.origins in
    if !omitted then (unavailable:=true; None)
    else Some {text=run.semantic_text;positions;visible_rows=run.visible_rows;joins_previous=run.joins_previous;
     reading=run.reading}) document.semantic_runs in
  runs,!unavailable

type matched = { body_row : int; position : position; ending_position : position }

(* [text] is case-folded, so one source scalar can become more or fewer
   bytes. [starts] holds, for every folded byte, the position of the first
   byte of the source scalar it came from, and [ends] the position of that
   scalar's last byte: a match starts at its first scalar's first byte and
   ends at its last scalar's last byte. *)
type searchable = {
  text : string;
  starts : position option array;
  ends : position option array;
  rows : int option array;
  boundaries : bool array;
}

(* Default caseless matching folds both the query and the text with the full
   Unicode Case_Folding property: [É] and [é] fold alike, [ß] folds to [ss]
   and the Kelvin sign to [k]. Each folded byte records the first and last
   byte of the scalar it came from. A byte that does not decode as UTF-8 is
   copied unchanged and is its own range. *)
let fold_case text =
  let folded = Buffer.create (String.length text) in
  let sources = Dynarray.create () in
  let at = ref 0 in
  while !at < String.length text do
    let decode = String.get_utf_8_uchar text !at in
    let length = Uchar.utf_decode_length decode in
    if Uchar.utf_decode_is_valid decode then begin
      let before = Buffer.length folded in
      (match Uucp.Case.Fold.fold (Uchar.utf_decode_uchar decode) with
       | `Self -> Buffer.add_substring folded text !at length
       | `Uchars scalars -> List.iter (Buffer.add_utf_8_uchar folded) scalars);
      for _ = before to Buffer.length folded - 1 do
        Dynarray.add_last sources (!at, !at + length - 1)
      done
    end else
      for byte = !at to !at + length - 1 do
        Buffer.add_char folded text.[byte];
        Dynarray.add_last sources (byte, byte)
      done;
    at := !at + length
  done;
  Buffer.contents folded, Dynarray.to_array sources

let searchable ~body_rows (run : run) =
  let rows=Array.make (String.length run.text) None in
  List.iter (fun (row,ranges) -> if row<body_rows then List.iter (fun (range : Markdown.source_range) ->
    for byte=range.start_byte to range.end_byte-1 do rows.(byte)<-Some row done) ranges) run.visible_rows;
  let text,copied=Masc_tui_theme.strip_sgr_with_positions run.text in
  let folded,sources=fold_case text in
  (* A folded byte is visible only when every byte of its source scalar is,
     on the last row among them. *)
  let scalar_row (first,last) =
    let rec gather byte row =
      if byte > last then row
      else match row, rows.(copied.(byte)) with
        | Some current, Some next -> gather (byte + 1) (Some (max current next))
        | None, _ | Some _, None -> None in
    gather (first + 1) rows.(copied.(first)) in
  {text=folded;
   starts=Array.map (fun (first,_) -> run.positions.(copied.(first))) sources;
   ends=Array.map (fun (_,last) -> run.positions.(copied.(last))) sources;
   rows=Array.map scalar_row sources;
   boundaries=Array.make (String.length folded) false}

let join_lines reversed =
  let lines=List.rev reversed in
  let intersperse separator pieces =
    let rec walk = function []->[] | [piece]->[piece] | piece::rest -> piece::separator::walk rest in
    walk pieces in
  {text=String.concat "\n" (List.map (fun (line : searchable) -> line.text) lines);
   starts=Array.concat (intersperse [|None|] (List.map (fun line -> line.starts) lines));
   ends=Array.concat (intersperse [|None|] (List.map (fun line -> line.ends) lines));
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
    if Option.is_some group.rows.(at) && Option.is_some group.ends.(at) then previous := Some at;
    visible_position.(at) <- !previous
  done;
  let next_position = Array.make (length + 1) length in
  for at = length - 1 downto 0 do
    next_position.(at) <- if Option.is_some group.starts.(at) then at
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
    | Some _ | None ->
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
                      group.rows.(rows.(!first))) group.ends.(ending)) visible_position.(at)) group.starts.(origin);
          matched := failure.(size - 1)
        end
  done

type prefix_observation = { first_position : position option; last_position : position option; last_row : int option }

(* A logical source-line boundary has the existing explicit contract: consume
   one query space/newline or skip it. Retain one best eligible observation per
   query-prefix state, rather than recursively replaying every branch/start.
   This is O(text * query), O(query) memory for groups with such boundaries;
   ordinary groups above are O(text + query). No query-length cap or timeout. *)
let find_optional_lines ~order ~needle ~eligible (group : searchable) consider =
  let size = String.length needle in
  let current = ref (Array.make (size + 1) []) in
  let spare = ref (Array.make (size + 1) []) in
  let keep states prefix observation =
    match observation.first_position with
    | Some position when not (eligible position) -> ()
    | Some _ | None ->
        let same_class previous = Option.is_some observation.first_position
          = Option.is_some previous.first_position in
        let replace = match List.find_opt same_class states.(prefix) with
          | None -> true
          | Some previous ->
              (match observation.first_position, previous.first_position with
               | Some left, Some right ->
                   let comparison = order left right in
                   comparison > 0 || (comparison = 0 && observation.last_row > previous.last_row)
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
                  | Some _ as position -> position | None -> group.starts.(at) in
                let last_row = match observation.last_row, row with
                  | Some left, Some right -> Some (max left right)
                  | None, row | row, None -> row in
                let last_position = match row, group.ends.(at) with
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

(* If the query cannot consume an optional separator, every separator has
   exactly one transition: skip. Compact only those marked presentation bytes
   while retaining each copied byte's source position and actual visible row. *)
let skip_optional_boundaries (group : searchable) =
  let retained = Array.to_list (Array.mapi (fun index boundary ->
    if boundary then None else Some index) group.boundaries)
    |> List.filter_map Fun.id |> Array.of_list in
  {text=String.init (Array.length retained) (fun index -> group.text.[retained.(index)]);
   starts=Array.map (Array.get group.starts) retained;
   ends=Array.map (Array.get group.ends) retained;
   rows=Array.map (Array.get group.rows) retained;
   boundaries=Array.make (Array.length retained) false}

(* A drawn Mermaid diagram places its labels by layout, not by source order:
   [flowchart BT] draws a label written later above an earlier one. The pane
   is read newest first from its bottom row, so the labels of one drawing are
   ranked by the last row each label is drawn on, then by source position.
   The drawing keeps its place among all other positions at its earliest
   label position. A match keeps its source position as its identity; only
   the ranking between occurrences changes. *)
type drawn_label = { drawing : position; row : int option }

let drawn_labels runs =
  let earliest = Hashtbl.create 4 in
  List.iter (fun (run : run) -> match run.reading with
    | Markdown.Source_order -> ()
    | Markdown.Drawn_diagram {block_start} ->
        Array.iter (Option.iter (fun position ->
          match Hashtbl.find_opt earliest block_start with
          | Some current when compare_position current position <= 0 -> ()
          | Some _ | None -> Hashtbl.replace earliest block_start position)) run.positions) runs;
  let labels = Hashtbl.create 16 in
  List.iter (fun (run : run) -> match run.reading with
    | Markdown.Source_order -> ()
    | Markdown.Drawn_diagram {block_start} ->
        Option.iter (fun drawing ->
          let row = List.fold_left (fun last (row,_) -> match last with
            | Some last -> Some (max last row)
            | None -> Some row) None run.visible_rows in
          Array.iter (Option.iter (fun position -> Hashtbl.replace labels position {drawing;row}))
            run.positions) (Hashtbl.find_opt earliest block_start)) runs;
  labels

(* Ordering by (drawing or own position, drawn row, position) is a key
   comparison, so it stays a total order even for a repeat cursor that the
   source fallback produced inside the fence body. *)
let reading_order labels a b =
  let label position = Hashtbl.find_opt labels position in
  let major position = match label position with
    | Some {drawing;_} -> drawing
    | None -> position in
  match compare_position (major a) (major b) with
  | 0 ->
      (match label a, label b with
       | Some left, Some right ->
           (match Option.compare Int.compare left.row right.row with
            | 0 -> compare_position a b
            | order -> order)
       | Some _, None | None, Some _ | None, None -> compare_position a b)
  | order -> order

(* A place can hold another version of its text under the same anchor: the
   OpenGraph fetch replaces a synthesized preview field, a recorded reply
   stands where the streamed text was, a diagnostic label is regenerated for
   the current width. A repeat cursor into the old version names no byte of
   the new one. The cursor's places whose text the runs now hold another
   version of are returned; every position in them counts as older than the
   cursor, so the replaced text is searched whole. *)
let replaced_slots runs = function
  | None -> []
  | Some cursor ->
      List.filter_map (fun (slot, text) ->
        let replaced position =
          List.exists (fun (other, now) -> other = slot && not (String.equal now text)) (slots position) in
        if List.exists (fun (run : run) ->
             Array.exists (Option.fold ~none:false ~some:replaced) run.positions) runs
        then Some slot else None) (slots cursor)

let find ~needle ~before ~body_rows runs =
  let needle = fst (fold_case needle) in
  if String.length needle = 0 then None else
  let replaced = replaced_slots runs before in
  let groups = List.fold_left (fun groups (run : run) ->
    let next = searchable ~body_rows run in
    match run.joins_previous, groups with
    | true, previous :: rest -> (next :: previous) :: rest
    | true, [] | false, _ -> [next] :: groups) [] runs |> List.map join_lines in
  let labels = drawn_labels runs in
  let order = if Hashtbl.length labels = 0 then compare_position else reading_order labels in
  let eligible position = match before with
    | None -> true
    | Some boundary ->
        List.exists (fun (slot, _) -> List.mem slot replaced) (slots position)
        || order position boundary < 0 in
  let newest = ref None in
  let consider found =
    if eligible found.position
    then match !newest with
      | Some current when order current.position found.position >= 0 -> ()
      | Some _ | None -> newest := Some found in
  List.iter (fun group ->
    if not (Array.exists Fun.id group.boundaries) then find_plain ~needle group consider
    else if not (String.exists (function ' ' | '\n' -> true | _ -> false) needle) then
      find_plain ~needle (skip_optional_boundaries group) consider
    else find_optional_lines ~order ~needle ~eligible group consider) groups;
  !newest
