module Diff = Masc_tui_diff
module Layout = Masc_tui_message_layout
module Markdown = Masc_tui_markdown
module Projection = Masc_tui_keeper_chat_projection
module Transcript = Masc_tui_keeper_chat_transcript
module Execution_ids = Map.Make (String)

type prepared_kind =
  | Edited of {
      preview : Diff.row list;
      omitted : int;
      removed : int;
      added : int;
      replace_all : bool;
    }
  | Written of {
      preview : Diff.row list;
      omitted : int;
      row_count : int;
    }

type prepared_change = {
  change : Masc.Tui_decode.file_change;
  kind : prepared_kind;
}

type candidate =
  | One of prepared_change
  | Many of int

type index = {
  candidates : candidate Execution_ids.t;
  missing_execution_ids : int;
  ambiguous_execution_ids : int;
}

type association =
  | No_recorded_change
  | Exact of prepared_change
  | Ambiguous of int

let empty =
  { candidates = Execution_ids.empty
  ; missing_execution_ids = 0
  ; ambiguous_execution_ids = 0
  }

let preview_rows = 12
let preview_context = 3

let nonblank = function
  | Some value when String.trim value <> "" -> Some value
  | Some _ | None -> None

let prepare (change : Masc.Tui_decode.file_change) =
  let kind =
    match change.fc_kind with
    | Masc.Tui_decode.Fc_edited { before; after; replace_all } ->
        let rows = Diff.rows ~before ~after in
        let removed, added = Diff.counts rows in
        let preview, omitted =
          Diff.preview ~context:preview_context ~max_rows:preview_rows rows
        in
        Edited { preview; omitted; removed; added; replace_all }
    | Masc.Tui_decode.Fc_inserted { text; _ } ->
        (* A memo is an edit that removed nothing: the one line, added. *)
        let rows = Diff.rows ~before:"" ~after:text in
        let removed, added = Diff.counts rows in
        let preview, omitted =
          Diff.preview ~context:preview_context ~max_rows:preview_rows rows
        in
        Edited { preview; omitted; removed; added; replace_all = false }
    | Masc.Tui_decode.Fc_written { content } ->
        let rows = Diff.rows ~before:"" ~after:content in
        let preview, omitted =
          Diff.preview ~context:0 ~max_rows:preview_rows rows
        in
        Written { preview; omitted; row_count = List.length rows }
  in
  { change; kind }

let index changes =
  List.fold_left
    (fun indexed (change : Masc.Tui_decode.file_change) ->
      match nonblank change.fc_execution_id with
      | None ->
          { indexed with
            missing_execution_ids = indexed.missing_execution_ids + 1
          }
      | Some execution_id ->
          (match Execution_ids.find_opt execution_id indexed.candidates with
           | None ->
               { indexed with
                 candidates =
                   Execution_ids.add execution_id (One (prepare change))
                     indexed.candidates
               }
           | Some (One _) ->
               { candidates =
                   Execution_ids.add execution_id (Many 2) indexed.candidates
               ; missing_execution_ids = indexed.missing_execution_ids
               ; ambiguous_execution_ids = indexed.ambiguous_execution_ids + 1
               }
           | Some (Many count) ->
               { indexed with
                 candidates =
                   Execution_ids.add execution_id (Many (count + 1))
                     indexed.candidates
               }))
    empty changes

let missing_execution_ids indexed = indexed.missing_execution_ids
let ambiguous_execution_ids indexed = indexed.ambiguous_execution_ids

let associate indexed (activity : Transcript.tool_activity) =
  match nonblank activity.execution_id with
  | None -> No_recorded_change
  | Some execution_id -> (
      match Execution_ids.find_opt execution_id indexed.candidates with
      | None -> No_recorded_change
      | Some (One change) -> Exact change
      | Some (Many count) -> Ambiguous count)

let clipped ~max_cells text =
  let max_cells = max 1 max_cells in
  let text = Projection.terminal_safe_text text in
  if Layout.display_width text <= max_cells then text
  else
    let prefix_cells = max 1 (max_cells - 1) in
    match Layout.split_cells ~max_cells:prefix_cells text with
    | [] -> "…"
    | prefix :: _ -> prefix ^ "…"

let change_address (change : Masc.Tui_decode.file_change) =
  match change.fc_location with
  | Masc.Tui_decode.Fc_in_repo { repo_id; relative_path } ->
      Printf.sprintf "%s:%s" repo_id relative_path
  | Masc.Tui_decode.Fc_in_bundle { bundle_path } -> bundle_path
  | Masc.Tui_decode.Fc_at_absolute_path { path } -> path

let max_previews_per_block = 3

let diff_line ~max_line_cells = function
  | Diff.Context line -> " " ^ clipped ~max_cells:(max_line_cells - 1) line
  | Diff.Removed line -> "-" ^ clipped ~max_cells:(max_line_cells - 1) line
  | Diff.Added line -> "+" ^ clipped ~max_cells:(max_line_cells - 1) line

let preview_block ~max_line_cells ~language lines =
  match Markdown.non_colliding_fence_marker lines with
  | None ->
      [ clipped ~max_cells:max_line_cells
          (Printf.sprintf
             "(%d recorded preview row%s withheld: text contains both supported fence markers; open Changes)"
             (List.length lines) (if List.length lines = 1 then "" else "s"))
      ]
  | Some marker ->
      (marker ^ language) :: lines @ [ marker ]

let omission_row ~max_line_cells omitted =
  if omitted = 0 then []
  else
    [ clipped ~max_cells:max_line_cells
        (Printf.sprintf "(%d more recorded row%s; open Changes for the full view)"
           omitted (if omitted = 1 then "" else "s"))
    ]

let attempted_suffix (change : Masc.Tui_decode.file_change) =
  if change.fc_succeeded then "" else " · failed attempt"

let line_range_label (range : Masc.Keeper_file_change_evidence.line_range) =
  if range.start_line = range.end_line then Printf.sprintf "L%d" range.start_line
  else Printf.sprintf "L%d-%d" range.start_line range.end_line

let occurrence_range_label
      (occurrence : Masc.Keeper_file_change_evidence.edit_occurrence)
  =
  let old_range = "old " ^ line_range_label occurrence.old_range in
  match occurrence.new_range with
  | Some new_range -> old_range ^ " -> new " ^ line_range_label new_range
  | None -> old_range ^ " -> deleted"

let rec take count = function
  | _ when count <= 0 -> []
  | [] -> []
  | value :: rest -> value :: take (count - 1) rest

let max_occurrence_range_rows = 3

let edited_evidence_rows ~max_line_cells ~replace_all
      (change : Masc.Tui_decode.file_change) =
  let attempted = attempted_suffix change in
  match change.fc_line_evidence with
  | None ->
    ( (if replace_all then
         "  replace-all template · match count unavailable"
       else "  recorded replacement")
      ^ attempted
    , [] )
  | Some
      (Masc.Keeper_file_change_evidence.Edited
        { occurrence_count; occurrences = None }) ->
    ( Printf.sprintf
        "  %d matches · line ranges omitted · replace-all template%s"
        occurrence_count
        attempted
    , [] )
  | Some
      (Masc.Keeper_file_change_evidence.Edited
        { occurrence_count; occurrences = Some occurrences }) ->
    let detail =
      if replace_all then
        Printf.sprintf
          "  %d match%s · replace-all template%s"
          occurrence_count
          (if occurrence_count = 1 then "" else "es")
          attempted
      else "  recorded replacement" ^ attempted
    in
    let shown = take max_occurrence_range_rows occurrences in
    let range_rows =
      List.mapi
        (fun index occurrence ->
           let prefix =
             if occurrence_count = 1 then "  "
             else Printf.sprintf "  #%d " (index + 1)
           in
           clipped
             ~max_cells:max_line_cells
             (prefix ^ occurrence_range_label occurrence))
        shown
    in
    let hidden = occurrence_count - List.length shown in
    let hidden_row =
      if hidden <= 0 then []
      else
        [ clipped
            ~max_cells:max_line_cells
            (Printf.sprintf
               "(%d more recorded line range%s withheld)"
               hidden
               (if hidden = 1 then "" else "s"))
        ]
    in
    detail, range_rows @ hidden_row
  | Some (Masc.Keeper_file_change_evidence.Written _) ->
    (* The strict endpoint decoder rejects this mismatch. Keep the renderer
       fail-closed for directly-constructed test values too. *)
    ( (if replace_all then
         "  replace-all template · match count unavailable"
       else "  recorded replacement")
      ^ attempted
    , [] )

let address_row ~max_line_cells ~summary change =
  let prefix = "↳ " in
  let suffix = " " ^ summary in
  let address =
    let address = change_address change |> Projection.terminal_safe_text in
    let address_cells =
      max 1
        (max_line_cells - Layout.display_width prefix
       - Layout.display_width suffix)
    in
    if Layout.display_width address <= address_cells then address
    else Layout.fit_middle address_cells address
  in
  clipped ~max_cells:max_line_cells (prefix ^ address ^ suffix)

let edited_section ~max_line_cells change ~preview ~omitted ~removed ~added
    ~replace_all =
  let detail, evidence_rows =
    edited_evidence_rows ~max_line_cells ~replace_all change
  in
  let summary =
    if replace_all then Printf.sprintf "(+%d -%d per match)" added removed
    else Printf.sprintf "(+%d -%d)" added removed
  in
  let address = address_row ~max_line_cells ~summary change in
  if removed = 0 && added = 0 then
    [ address
    ; clipped ~max_cells:max_line_cells (detail ^ " · no textual delta")
    ]
    @ evidence_rows
  else
    let detail = clipped ~max_cells:max_line_cells detail in
    let lines = List.map (diff_line ~max_line_cells) preview in
    address :: detail :: (evidence_rows
                          @ preview_block ~max_line_cells ~language:"diff" lines
                          @ omission_row ~max_line_cells omitted)

let written_section ~max_line_cells (change : Masc.Tui_decode.file_change)
      ~preview ~omitted ~row_count =
  let summary =
    if change.fc_succeeded then
      Printf.sprintf "(%d row%s written)" row_count
        (if row_count = 1 then "" else "s")
    else Printf.sprintf "(%d-row write attempt)" row_count
  in
  let address = address_row ~max_line_cells ~summary change in
  let evidence_rows =
    match change.fc_line_evidence with
    | Some (Masc.Keeper_file_change_evidence.Written { new_range = Some range }) ->
      [ clipped ~max_cells:max_line_cells ("  new " ^ line_range_label range) ]
    | Some (Masc.Keeper_file_change_evidence.Written { new_range = None }) ->
      [ "  empty body" ]
    | None | Some (Masc.Keeper_file_change_evidence.Edited _) -> []
  in
  let detail =
    Printf.sprintf
      "  recorded write body · previous content unavailable%s"
      (attempted_suffix change)
    |> clipped ~max_cells:max_line_cells
  in
  if row_count = 0 then [ address; detail ] @ evidence_rows
  else
    let lines =
      List.filter_map
        (function
          | Diff.Added line -> Some (clipped ~max_cells:max_line_cells line)
          | Diff.Context _ | Diff.Removed _ -> None)
        preview
    in
    address :: detail :: (evidence_rows
                          @ preview_block ~max_line_cells ~language:"" lines
                          @ omission_row ~max_line_cells omitted)

let section ~max_line_cells prepared =
  let change = prepared.change in
  match prepared.kind with
  | Edited { preview; omitted; removed; added; replace_all } ->
      edited_section ~max_line_cells change ~preview ~omitted ~removed ~added
        ~replace_all
  | Written { preview; omitted; row_count } ->
      written_section ~max_line_cells change ~preview ~omitted ~row_count

let rows ~mode ~max_line_cells ?(activity_details = fun _ -> []) indexed
    (projection : Transcript.tool_projection) =
  match mode with
  | Transcript.Compact -> projection.rows
  | Transcript.Full ->
      if List.length projection.rows < List.length projection.activities then
        projection.rows
      else
        let rec weave previews_left withheld reversed activities activity_rows =
          match activities, activity_rows with
          | activity :: activity_rest, row :: row_rest ->
              let extra, previews_left, withheld =
                match associate indexed activity with
                | No_recorded_change -> [], previews_left, withheld
                | Exact prepared when previews_left > 0 ->
                    ( section ~max_line_cells prepared
                    , previews_left - 1
                    , withheld )
                | Exact _ -> [], previews_left, withheld + 1
                | Ambiguous count when previews_left > 0 ->
                    ( [ clipped ~max_cells:max_line_cells
                          (Printf.sprintf
                             "(%d recorded changes share this execution_id; inline preview withheld)"
                             count)
                      ]
                    , previews_left - 1
                    , withheld )
                | Ambiguous _ -> [], previews_left, withheld + 1
              in
              let details = activity_details activity in
              weave previews_left withheld
                (List.rev_append extra
                   (List.rev_append details (row :: reversed)))
                activity_rest row_rest
          | [], remaining ->
              let rows = List.rev reversed in
              let withheld_row =
                if withheld = 0 then []
                else
                  [ clipped ~max_cells:max_line_cells
                      (Printf.sprintf
                         "(%d more recorded-change annotation%s withheld; open Changes)"
                         withheld (if withheld = 1 then "" else "s"))
                  ]
              in
              rows @ withheld_row @ remaining
          | _ :: _, [] -> projection.rows
        in
        weave max_previews_per_block 0 [] projection.activities projection.rows
