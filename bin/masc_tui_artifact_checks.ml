module Check = Masc.Published_artifact_check
module Catalog = Masc_tui_resource_catalog
module Fetched = Masc_tui_fetched
module Gap = Masc_tui_value.Unknown

type inventory =
  { checks : Check.t list
  ; diagnostics : (string * string) list
  ; received_at : float }
type read_failure = Read_failed of string | Read_kept_back of string
type status =
  | Known of Check.t option
  | Unknown of Gap.t * string
  | Kept_back of string

open Result.Syntax
let fields names = function
  | `Assoc fields when List.length fields = List.length names
      && List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | `Assoc _ -> Error "invalid or duplicate confirmation inventory fields"
  | _ -> Error "expected confirmation inventory object"
let traverse f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest ->
      let* value = f value in
      loop (value :: acc) rest
  in
  loop [] values

let compare_target (id1, rev1) (id2, rev2) =
  let c = String.compare id1 id2 in
  if c <> 0 then c else Int.compare rev1 rev2

let of_json ~received_at json =
  let* root = fields ["checks"; "diagnostics"] json in
  match List.assoc_opt "checks" root, List.assoc_opt "diagnostics" root with
  | Some (`List checks), Some (`List diagnostics) ->
    let* checks = traverse Check.of_json checks in
    let targets = List.map (fun (check : Check.t) -> check.target.id, check.target.revision) checks in
    let* () = if List.length targets = List.length (List.sort_uniq compare_target targets)
      then Ok () else Error "duplicate artifact revision confirmation" in
    let* diagnostics = traverse (fun diagnostic ->
      let* fields = fields ["file"; "error"] diagnostic in
      match List.assoc_opt "file" fields, List.assoc_opt "error" fields with
      | Some (`String file), Some (`String error) -> Ok (file, error)
      | _ -> Error "invalid confirmation diagnostic") diagnostics in
    Ok { checks; diagnostics; received_at }
  | _ -> Error "invalid confirmation inventory"

let resolve inventory (report : Catalog.report) =
  if Fetched.in_flight inventory then Unknown (Gap.Unread, "confirmation query in progress")
  else match Fetched.view_for ~equal:Unit.equal inventory ~key:() with
    | Absent -> Unknown (Gap.Unread, "confirmation inventory has not been read")
    | Loading -> Unknown (Gap.Unread, "confirmation query in progress")
    | Stale (_, Read_failed detail) | Failed (Read_failed detail) -> Unknown (Gap.Read_failed, detail)
    | Stale (_, Read_kept_back notice) | Failed (Read_kept_back notice) -> Kept_back notice
    | Ready { diagnostics = _ :: _; _ } ->
      Unknown (Gap.Read_failed, "some confirmation records could not be read")
    | Ready { checks; diagnostics = []; _ } ->
      match List.find_opt (fun (check : Check.t) ->
        check.target.id = report.id && check.target.revision = report.revision.revision) checks with
      | Some check when check.target.body_sha256 <> report.revision.body.sha256 ->
        Unknown (Gap.Unreported, "confirmation record refers to a different report body")
      | (Some _ | None) as check -> Known check

let unchecked_on_day ~reports_complete ~day ~entries inventory =
  if not reports_complete then None
  else
    (* Validate the check inventory even when today's report set is empty. *)
    let authoritative = not (Fetched.in_flight inventory)
      && match Fetched.view_for ~equal:Unit.equal inventory ~key:() with
         | Ready { diagnostics = []; _ } -> true
         | Ready { diagnostics = _ :: _; _ } | Absent | Loading | Stale _ | Failed _ -> false in
    if not authoritative then None
    else List.fold_left (fun count entry ->
      match count, entry with
      | None, (Catalog.Mcp _ | Report _) -> None
      | Some count, Catalog.Mcp _ -> Some count
      | Some count, Catalog.Report report ->
        match resolve inventory report with
        | Unknown _ | Kept_back _ -> None
        | Known check ->
          let unchecked = match check with
            | None -> true
            | Some check -> check.state = Check.Unchecked in
          Some (if unchecked && Catalog.on_day day entry then count + 1 else count)) (Some 0) entries

let next_unchecked ~reports_complete ~entries ~cursor inventory =
  let* () =
    if not reports_complete then Error "report inventory is incomplete; refresh before navigating confirmations"
    else if Fetched.in_flight inventory then Error "confirmation query in progress"
    else match Fetched.view_for ~equal:Unit.equal inventory ~key:() with
      | Ready { diagnostics = []; _ } -> Ok ()
      | Ready { diagnostics = _ :: _; _ } -> Error "some confirmation records could not be read"
      | Absent -> Error "confirmation inventory has not been read"
      | Loading -> Error "confirmation query in progress"
      | Stale (_, (Read_failed detail | Read_kept_back detail))
      | Failed (Read_failed detail | Read_kept_back detail) -> Error detail in
  let* candidates = traverse (fun (index, entry) -> match entry with
    | Catalog.Mcp _ -> Ok None
    | Report report -> match resolve inventory report with
      | Unknown (_, detail) | Kept_back detail -> Error detail
      | Known None | Known (Some {state=Check.Unchecked;_}) -> Ok (Some index)
      | Known (Some {state=Check.Checked;_}) -> Ok None)
    (List.mapi (fun index entry -> index, entry) entries) in
  let candidates = List.filter_map Fun.id candidates in
  Ok (match List.find_opt (fun index -> index > cursor) candidates with
    | Some _ as next -> next
    | None -> List.nth_opt candidates 0)

(* A confirmation the TUI cannot answer wears the 6.4 mark of why (RFC
   tui-one-screen-grammar): not read yet or reading, a read that failed, or
   a record that does not answer for this exact body. A kept-back read was
   never sent, so it is not read. The column is headed CHECK, so the cell
   does not say "check" again. *)
let gap_word = function
  | Gap.Unread -> "not read"
  | Gap.Read_failed -> "read failed"
  | Gap.Unreported -> "not reported"

let gap_label gap = Gap.glyph gap ^ " " ^ gap_word gap

let unchecked_label = "○ unchecked"

(* The settled status mark (RFC tui-one-screen-grammar 7.2); [✓] is not one.
   Unchecked keeps the waiting mark it already wore. *)
let checked_label = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Settled ^ " checked"

let label = function
  | Unknown (gap, _) -> gap_label gap
  | Kept_back _ -> gap_label Gap.Unread
  | Known None | Known (Some {state=Check.Unchecked;_}) -> unchecked_label
  | Known (Some {state=Check.Checked;_}) -> checked_label

let widest_label_cells =
  List.fold_left (fun widest text ->
    max widest (Masc_tui_message_layout.display_width text)) 0
    [ gap_label Gap.Unread; gap_label Gap.Read_failed; gap_label Gap.Unreported
    ; unchecked_label; checked_label ]

let description status = match status with
  | Unknown (gap, detail) -> "Confirmation " ^ gap_word gap ^ ": " ^ detail
  | Kept_back notice -> notice
  | Known None -> "No confirmation for this exact report revision."
  | Known (Some check) -> label status ^ " · " ^ check.changed_by ^ " · " ^ check.changed_at
