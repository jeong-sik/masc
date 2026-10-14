type finding =
  | Broken_link of
      { page : string
      ; line : int
      ; target : string
      }
  | Unsupported_link of
      { page : string
      ; line : int
      ; form : string
      ; target : string
      }
  | Orphan of { page : string }
  | Orphan_unconfirmed of { page : string }
  | Missing_sources of { page : string }
  | Hearsay_only of { page : string }
  | Unreadable_page of
      { file : string
      ; reason : string
      }
  | Revision_log_gap of
      { page : string
      ; log_revision : int
      ; page_revision : int
      }

let kind = function
  | Broken_link _ -> "broken_link"
  | Unsupported_link _ -> "unsupported_link"
  | Orphan _ -> "orphan"
  | Orphan_unconfirmed _ -> "orphan_unconfirmed"
  | Missing_sources _ -> "missing_sources"
  | Hearsay_only _ -> "hearsay_only"
  | Unreadable_page _ -> "unreadable_page"
  | Revision_log_gap _ -> "revision_log_gap"
;;

let all_kinds =
  [ "broken_link"
  ; "unsupported_link"
  ; "orphan"
  ; "orphan_unconfirmed"
  ; "missing_sources"
  ; "hearsay_only"
  ; "unreadable_page"
  ; "revision_log_gap"
  ]
;;

let subject = function
  | Broken_link { page; _ }
  | Unsupported_link { page; _ }
  | Orphan { page }
  | Orphan_unconfirmed { page }
  | Missing_sources { page }
  | Hearsay_only { page }
  | Revision_log_gap { page; _ } -> page
  | Unreadable_page { file; _ } -> file
;;

let line_of = function
  | Broken_link { line; _ } | Unsupported_link { line; _ } -> line
  | Orphan _
  | Orphan_unconfirmed _
  | Missing_sources _
  | Hearsay_only _
  | Revision_log_gap _
  | Unreadable_page _ -> 0
;;

let compare_findings left right =
  match String.compare (subject left) (subject right) with
  | 0 ->
    (match Int.compare (line_of left) (line_of right) with
     | 0 ->
       (match String.compare (kind left) (kind right) with
        | 0 -> Stdlib.compare left right
        | order -> order)
     | order -> order)
  | order -> order
;;

let link_findings graph page =
  List.filter_map
    (fun (link : Wiki_link.link) ->
       match link.target with
       | Wiki_link.Page name ->
         if Wiki_graph.file_exists graph name
         then None
         else Some (Broken_link { page; line = link.line; target = link.raw })
       | Wiki_link.Invalid_name raw ->
         Some (Broken_link { page; line = link.line; target = raw })
       | Wiki_link.Unsupported form ->
         Some (Unsupported_link { page; line = link.line; form; target = link.raw })
       | Wiki_link.Own_file _ | Wiki_link.External _ -> None)
    (Wiki_graph.links_of graph page)
;;

let page_findings graph ~has_unreadable page =
  let source_findings =
    match Wiki_graph.sources_of graph page with
    | None -> []
    | Some { Wiki_sources.references; hearsay } ->
      if references > 0
      then []
      else if hearsay > 0
      then [ Hearsay_only { page } ]
      else [ Missing_sources { page } ]
  in
  let orphan_findings =
    if Wiki_graph.incoming graph page > 0
    then []
    else if has_unreadable
    then [ Orphan_unconfirmed { page } ]
    else [ Orphan { page } ]
  in
  link_findings graph page @ source_findings @ orphan_findings
;;

(* One finding per page, not per log line: a page four revisions behind its
   log would otherwise be reported four times. The highest revision the log
   records for the page is the one it must have reached. *)
let log_gap_findings graph (log : Wiki_log.t) =
  let highest = Hashtbl.create 16 in
  List.iter
    (fun (line : Wiki_log.line) ->
       let seen = Option.value (Hashtbl.find_opt highest line.page) ~default:0 in
       if line.revision > seen then Hashtbl.replace highest line.page line.revision)
    log.lines;
  Hashtbl.fold
    (fun page log_revision acc ->
       match Wiki_graph.revision_of graph page with
       | Some page_revision when page_revision < log_revision ->
         Revision_log_gap { page; log_revision; page_revision } :: acc
       | Some _ | None -> acc)
    highest
    []
;;

let run graph ~log =
  let unreadable = Wiki_graph.unreadable_files graph in
  let has_unreadable = unreadable <> [] in
  let from_pages =
    List.concat_map (page_findings graph ~has_unreadable) (Wiki_graph.readable_pages graph)
  in
  let from_files =
    List.map (fun (file, reason) -> Unreadable_page { file; reason }) unreadable
  in
  List.sort compare_findings (from_pages @ from_files @ log_gap_findings graph log)
;;

let counts findings =
  List.map
    (fun name ->
       name, List.length (List.filter (fun finding -> String.equal (kind finding) name) findings))
    all_kinds
;;
