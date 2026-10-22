module Published = Masc.Published_artifact

type report = { id : string; revision : Published.revision }
type key = Mcp_uri of string | Report_revision of report
type t = Mcp of Masc_tui_mcp.resource | Report of report
type listing = { entries : t list; notes : string list }
type reading = { parts : Masc_tui_mcp.resource_content list; revisions : report list }
type scope = All_resources | Published_reports | Markdown_reports | Html_reports
type layout = Full_width | Side_by_side
type presentation = Document | Source
type day = { year : int; month : int; day : int }

let local_day seconds =
  let tm = Unix.localtime seconds in
  { year = tm.tm_year + 1900; month = tm.tm_mon + 1; day = tm.tm_mday }

let on_day day = function
  | Mcp _ -> false
  | Report report ->
    match Time_codec.parse_rfc3339 report.revision.created_at with
    | Ok seconds -> local_day seconds = day
    | Error Time_codec.Invalid_rfc3339 -> false

let select ~scope ~day entries =
  List.filter (fun entry ->
    let included = match scope, entry with
      | All_resources, (Mcp _ | Report _) -> true
      | Published_reports, Report _ -> true
      | Markdown_reports, Report report -> report.revision.format = Published.Markdown
      | Html_reports, Report report -> report.revision.format = Published.Html
      | (Published_reports | Markdown_reports | Html_reports), Mcp _ -> false in
    included && match day with None -> true | Some day -> on_day day entry) entries

let scope_label = function
  | All_resources -> "All resources"
  | Published_reports -> "Artifacts"
  | Markdown_reports -> "Markdown documents"
  | Html_reports -> "HTML pages"

let next_scope = function
  | All_resources -> Published_reports
  | Published_reports -> Markdown_reports
  | Markdown_reports -> Html_reports
  | Html_reports -> All_resources

type direction = Older | Newer
type read_request = { key : key; owner : unit ref }

let ( let* ) = Result.bind
let key = function Mcp resource -> Mcp_uri resource.uri | Report report -> Report_revision report
let equal_key left right = match left, right with
  | Mcp_uri left, Mcp_uri right -> String.equal left right
  | Report_revision left, Report_revision right -> left = right
  | Mcp_uri _, Report_revision _ | Report_revision _, Mcp_uri _ -> false

let owns_key entry requested = match entry, requested with
  | Mcp resource, Mcp_uri uri -> String.equal resource.uri uri
  | Report report, Report_revision requested -> String.equal report.id requested.id
  | Mcp _, Report_revision _ | Report _, Mcp_uri _ -> false

let entry_for_key entries requested =
  Option.map (fun entry -> match requested with
    | Mcp_uri _ -> entry
    | Report_revision report -> Report report)
    (List.find_opt (fun entry -> owns_key entry requested) entries)

let adjacent_revision direction ~current revisions =
  let rec find previous = function
    | [] -> None
    | report :: rest ->
      if equal_key (Report_revision report) (Report_revision current) then
        let candidate = match direction with Older -> List.nth_opt rest 0 | Newer -> previous in
        (match candidate with
         | Some report when String.equal report.id current.id -> Some report
         | Some _ | None -> None)
      else find (Some report) rest in
  find None revisions

let mcp_reading parts = { parts; revisions = [] }

let report_path report =
  Printf.sprintf "/api/v1/published-artifacts/%s?revision=%d" report.id report.revision.revision

let metadata = function
  | Mcp resource -> resource
  | Report { id; revision } ->
    { Masc_tui_mcp.uri = Published.url ~revision:revision.revision id
    ; name = id; title = Some revision.title
    ; description = Some (Printf.sprintf "%s\n\n%s · %s · revision %d"
        revision.summary revision.author revision.created_at revision.revision)
    ; mime_type = Some revision.body.mime; size = Some revision.body.bytes }

let display_name = function
  | Mcp resource -> Masc_tui_mcp.display_name resource
  | Report report -> Printf.sprintf "%s · %s · v%d"
      (match report.revision.format with Published.Markdown -> "Markdown" | Html -> "HTML")
      report.revision.title report.revision.revision

let origin = function
  | Mcp _ -> "MCP resource — read-only data exposed by this server."
  | Report _ -> "Published report — exact revision from this workspace. v: document/source."

let object_fields = function
  | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
  | `Assoc _ -> Error "duplicate report fields"
  | _ -> Error "expected a report object"

let summary json =
  let* fields = object_fields json in
  match List.assoc_opt "id" fields, List.assoc_opt "url" fields with
  | Some (`String id), Some (`String url) when Published.valid_id id && String.equal url (Published.url id) ->
    let* revision = Published.revision_of_json
      (`Assoc (List.filter (fun (name, _) -> name <> "id" && name <> "url") fields)) in
    Ok { id; revision }
  | _ -> Error "invalid report identity or URL"

let traverse f items = List.fold_right (fun item rest ->
  let* item = f item in let* rest = rest in Ok (item :: rest)) items (Ok [])

let reports_of_json json =
  let* fields = object_fields json in
  match List.assoc_opt "artifacts" fields, List.assoc_opt "diagnostics" fields with
  | Some (`List items), Some (`List diagnostics) ->
    let* reports = traverse summary items in
    let ids = List.map (fun report -> report.id) reports in
    if List.length ids <> List.length (List.sort_uniq String.compare ids) then Error "duplicate report IDs"
    else
      let* notes = traverse (fun json ->
        let* fields = object_fields json in
        match List.assoc_opt "id" fields, List.assoc_opt "error" fields with
        | Some (`String id), Some (`String error) -> Ok ("Report " ^ id ^ ": " ^ error)
        | _ -> Error "invalid report diagnostic") diagnostics in
      Ok (List.map (fun report -> Report report) reports, notes)
  | _ -> Error "invalid published report inventory"

let report_contents expected json =
  let* fields = object_fields json in
  match List.assoc_opt "artifact" fields, List.assoc_opt "content" fields,
        List.assoc_opt "revisions" fields with
  | Some artifact, Some (`String content), Some revisions ->
    let* actual = summary artifact in
    let* history = Published.of_json (`Assoc ["id", `String expected.id; "revisions", revisions]) in
    if not (equal_key (Report_revision expected) (Report_revision actual))
       || not (List.mem expected.revision history.revisions)
    then Error "report revision changed since listing; refresh Resources"
    else if String.length content <> expected.revision.body.bytes
         || not (String.equal (Digestif.SHA256.(to_hex (digest_string content))) expected.revision.body.sha256)
         || not (String.is_valid_utf_8 content)
    then Error "report body does not match its published reference"
    else Ok { parts = [{ Masc_tui_mcp.rc_uri = Some (metadata (Report expected)).uri
                       ; rc_mime_type = Some expected.revision.body.mime
                       ; rc_kind = Resource_text content }]
            ; revisions = List.map (fun revision -> { id = expected.id; revision }) history.revisions }
  | _ -> Error "invalid published report body"

let walk_note = function
  | `Complete -> []
  | `Page_limit_reached pages -> [Printf.sprintf "MCP listing may be incomplete: stopped after %d pages." pages]
  | `Repeated_cursor _ -> ["MCP listing may be incomplete: the server repeated a cursor."]

let combine mcp reports = match mcp, reports with
  | Error mcp, Error reports -> Error ("MCP: " ^ mcp ^ " · Reports: " ^ reports)
  | Ok (rows, stop), Error detail ->
    Ok { entries = List.map (fun row -> Mcp row) rows; notes = walk_note stop @ ["Reports: " ^ detail] }
  | Error detail, Ok (entries, notes) -> Ok { entries; notes = ("MCP: " ^ detail) :: notes }
  | Ok (rows, stop), Ok (reports, notes) ->
    Ok { entries = List.map (fun row -> Mcp row) rows @ reports; notes = walk_note stop @ notes }
