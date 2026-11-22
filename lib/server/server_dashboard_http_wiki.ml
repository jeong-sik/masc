module Http = Http_server_eio
module Env = Server_dashboard_http_v2_envelope

type sort_order =
  | Sort_title
  | Sort_updated
  | Sort_rank

let sort_order_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "title" -> Some Sort_title
  | "updated" -> Some Sort_updated
  | "rank" -> Some Sort_rank
  | _ -> None
;;

type duplicate_title_candidate =
  { page_a : string
  ; title_a : string
  ; page_b : string
  ; title_b : string
  ; reason : string
  }

let normalize_title title =
  title
  |> String.lowercase_ascii
  |> String.to_seq
  |> Seq.map (fun ch ->
       match ch with
       | 'a' .. 'z' | '0' .. '9' -> ch
       | c when Char.code c >= 128 -> c
       | _ -> ' ')
  |> String.of_seq
  |> String.split_on_char ' '
  |> List.filter (fun s -> not (String.equal s ""))
  |> String.concat " "
;;

module String_set = Set.Make (String)

let token_set text =
  Wiki_rank.terms text |> List.fold_left (fun acc t -> String_set.add t acc) String_set.empty
;;

let jaccard a b =
  let inter = String_set.cardinal (String_set.inter a b) in
  let union = String_set.cardinal (String_set.union a b) in
  if union = 0 then 0.0 else float_of_int inter /. float_of_int union
;;

let detect_duplicate_titles pairs =
  let sorted =
    List.sort (fun (pa, _) (pb, _) -> String.compare pa pb) pairs
    |> List.map (fun (slug, title) -> slug, title, normalize_title title, token_set title)
  in
  let rec walk acc = function
    | [] -> List.rev acc
    | (pa, ta, na, sa) :: rest ->
      let acc =
        List.fold_left
          (fun acc (pb, tb, nb, sb) ->
             if (not (String.equal na "")) && String.equal na nb
             then
               { page_a = pa
               ; title_a = ta
               ; page_b = pb
               ; title_b = tb
               ; reason = "exact_normalized_title"
               }
               :: acc
             else if
               String_set.cardinal sa >= 2
               && String_set.cardinal sb >= 2
               && Float.compare (jaccard sa sb) 0.7 >= 0
             then
               { page_a = pa
               ; title_a = ta
               ; page_b = pb
               ; title_b = tb
               ; reason = "near_duplicate_title"
               }
               :: acc
             else acc)
          acc
          rest
      in
      walk acc rest
  in
  walk [] sorted
;;

let duplicate_candidate_to_json c =
  `Assoc
    [ "page_a", `String c.page_a
    ; "title_a", `String c.title_a
    ; "page_b", `String c.page_b
    ; "title_b", `String c.title_b
    ; "reason", `String c.reason
    ]
;;

let extract_updated_header raw =
  let lines = String.split_on_char '\n' raw in
  match lines with
  | first :: rest when String.equal (String.trim first) "---" ->
    let rec scan = function
      | [] -> None
      | line :: _ when String.equal (String.trim line) "---" -> None
      | line :: tl ->
        (match String.index_opt line ':' with
         | Some idx ->
           let key = String.sub line 0 idx |> String.trim |> String.lowercase_ascii in
           if String.equal key "updated"
           then
             let value =
               String.sub line (idx + 1) (String.length line - idx - 1) |> String.trim
             in
             if String.equal value "" then None else Some value
           else scan tl
         | None -> scan tl)
    in
    scan rest
  | _ -> None
;;

let read_file_safe path =
  match Fs_compat.load_file path with
  | content -> Ok content
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception Sys_error msg -> Error msg
  | exception Unix.Unix_error (err, op, _) ->
    Error (Printf.sprintf "%s: %s" op (Unix.error_message err))
;;

let read_log_raw ~base_path =
  let path = Filename.concat (Tool_wiki.wiki_root ~base_path) Wiki_journal.log_file in
  if not (Sys.file_exists path)
  then Ok ("", Wiki_log.empty)
  else (
    match read_file_safe path with
    | Error detail ->
      Error (Printf.sprintf "log.md exists but could not be read: %s" detail)
    | Ok raw ->
      Ok (raw, Wiki_log.parse ~minute_time:Wiki_log_clock.local_minute raw))
;;

type readable_page =
  { slug : string
  ; file : string
  ; sha256 : string
  ; fm : Wiki_page.frontmatter
  ; updated : string
  ; body : string
  ; links : Wiki_link.link list
  ; sources : Wiki_sources.t
  }

type unreadable_page =
  { file : string
  ; reason : string
  }

type loaded_page =
  | Loaded_readable of readable_page
  | Loaded_unreadable of unreadable_page

let load_pages ~base_path =
  match Tool_wiki.list_pages ~base_path with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception Sys_error msg -> Error msg
  | paths ->
    let pages =
      List.filter_map
        (fun path ->
           let file = Filename.basename path in
           match read_file_safe path with
           | Error msg ->
             if Sys.file_exists path
             then
               Some
                 (Loaded_unreadable
                    { file
                    ; reason = Printf.sprintf "the file could not be opened: %s" msg
                    })
             else None
           | Ok raw ->
             (match Wiki_page.parse_frontmatter raw with
              | Error err ->
                Some
                  (Loaded_unreadable
                     { file; reason = Wiki_page.frontmatter_error_to_string err })
              | Ok fm ->
                let slug = Filename.chop_suffix file ".md" in
                let body = Wiki_page.page_body raw in
                let updated =
                  match extract_updated_header raw with
                  | Some value -> value
                  | None -> (fm.created :> string)
                in
                Some
                  (Loaded_readable
                     { slug
                     ; file
                     ; sha256 = Env.sha256_hex raw
                     ; fm
                     ; updated
                     ; body
                     ; links = Wiki_link.extract body
                     ; sources = Wiki_sources.of_body body
                     })))
        paths
    in
    Ok pages
;;

let graph_of_loaded pages =
  pages
  |> List.map (function
       | Loaded_readable p ->
         Wiki_graph.Readable
           { page = p.slug
           ; links = p.links
           ; sources = p.sources
           ; revision = p.fm.revision
           }
       | Loaded_unreadable u -> Wiki_graph.Unreadable { file = u.file; reason = u.reason })
  |> Wiki_graph.of_nodes
;;

let finding_to_json finding =
  let base =
    [ "kind", `String (Wiki_lint.kind finding)
    ; "subject", `String (Wiki_lint.subject finding)
    ]
  in
  let extra =
    match finding with
    | Wiki_lint.Broken_link { page; line; target } ->
      [ "page", `String page; "line", `Int line; "target", `String target ]
    | Wiki_lint.Unsupported_link { page; line; form; target } ->
      [ "page", `String page
      ; "line", `Int line
      ; "form", `String form
      ; "target", `String target
      ]
    | Wiki_lint.Orphan { page } -> [ "page", `String page ]
    | Wiki_lint.Orphan_unconfirmed { page } -> [ "page", `String page ]
    | Wiki_lint.Missing_sources { page } -> [ "page", `String page ]
    | Wiki_lint.Hearsay_only { page } -> [ "page", `String page ]
    | Wiki_lint.Unreadable_page { file; reason } ->
      [ "file", `String file; "reason", `String reason ]
    | Wiki_lint.Revision_log_gap { page; log_revision; page_revision } ->
      [ "page", `String page
      ; "log_revision", `Int log_revision
      ; "page_revision", `Int page_revision
      ]
    | Wiki_lint.Revision_log_hole { page; missing } ->
      [ "page", `String page; "missing_revision", `Int missing ]
  in
  `Assoc (base @ extra)
;;

let frontmatter_to_json ~updated (fm : Wiki_page.frontmatter) =
  `Assoc
    [ "title", `String (fm.title :> string)
    ; "summary", `String (fm.summary :> string)
    ; "source", `String (Wiki_page.source_to_string fm.source)
    ; "author", `String (fm.author :> string)
    ; "created", `String (fm.created :> string)
    ; "updated", `String updated
    ; "revision", `Int fm.revision
    ; "tags", `List (List.map (fun (t : Wiki_page.Tag.t) -> `String (t :> string)) fm.tags)
    ]
;;

let link_to_json ~graph (link : Wiki_link.link) =
  let target_kind, target_name, exists =
    match link.target with
    | Wiki_link.Page slug -> "page", slug, Some (Wiki_graph.file_exists graph slug)
    | Wiki_link.Own_file f -> "own_file", f, None
    | Wiki_link.External url -> "external", url, None
    | Wiki_link.Invalid_name raw -> "invalid_name", raw, Some false
    | Wiki_link.Unsupported shape -> "unsupported:" ^ shape, link.raw, None
  in
  `Assoc
    [ "text", `String link.text
    ; "kind", `String target_kind
    ; "target", `String target_name
    ; "raw", `String link.raw
    ; "line", `Int link.line
    ; "exists", Json_util.bool_opt_to_json exists
    ]
;;

let backlinks_for ~pages target_slug =
  pages
  |> List.filter_map (function
       | Loaded_unreadable _ -> None
       | Loaded_readable p ->
         if String.equal p.slug target_slug
         then None
         else if
           List.exists
             (fun (link : Wiki_link.link) ->
                match link.target with
                | Wiki_link.Page dst -> String.equal dst target_slug
                | Wiki_link.Own_file _
                | Wiki_link.External _
                | Wiki_link.Invalid_name _
                | Wiki_link.Unsupported _ -> false)
             p.links
         then Some p.slug
         else None)
  |> List.sort String.compare
;;

let error_result ?field ?extra code message =
  Error (Env.error_status code, Env.error_json ?field ?extra ~code message)
;;

let list_json ?now ?tag ?source ?(sort = Sort_title) ~base_path () =
  (* Read log before pages, mirroring Tool_wiki.handle_lint consistency order. *)
  match read_log_raw ~base_path with
  | Error msg -> error_result Env.Store_unavailable msg
  | Ok (_raw_log, log) ->
    (match load_pages ~base_path with
     | Error msg -> error_result Env.Store_unavailable msg
     | Ok pages ->
       let graph = graph_of_loaded pages in
       let findings = Wiki_lint.run graph ~log in
       let readable =
         List.filter_map
           (function
             | Loaded_readable p -> Some p
             | Loaded_unreadable _ -> None)
           pages
       in
       let unreadable =
         List.filter_map
           (function
             | Loaded_unreadable u -> Some u
             | Loaded_readable _ -> None)
           pages
       in
       let duplicates =
         readable
         |> List.map (fun p -> p.slug, (p.fm.title :> string))
         |> detect_duplicate_titles
       in
       let tag_counts = Hashtbl.create 32 in
       let source_counts = Hashtbl.create 8 in
       List.iter
         (fun p ->
            let src_key = Wiki_page.source_to_string p.fm.source in
            let prev_src =
              match Hashtbl.find_opt source_counts src_key with
              | Some n -> n
              | None -> 0
            in
            Hashtbl.replace source_counts src_key (prev_src + 1);
            List.iter
              (fun (t : Wiki_page.Tag.t) ->
                 let key = (t :> string) in
                 let prev =
                   match Hashtbl.find_opt tag_counts key with
                   | Some n -> n
                   | None -> 0
                 in
                 Hashtbl.replace tag_counts key (prev + 1))
              p.fm.tags)
         readable;
       let filtered =
         readable
         |> List.filter (fun p ->
              let tag_ok =
                match tag with
                | None -> true
                | Some wanted ->
                  let wanted_lc = String.lowercase_ascii wanted in
                  List.exists
                    (fun (t : Wiki_page.Tag.t) ->
                       String.equal (String.lowercase_ascii (t :> string)) wanted_lc)
                    p.fm.tags
              in
              let source_ok =
                match source with
                | None -> true
                | Some wanted -> p.fm.source = wanted
              in
              tag_ok && source_ok)
       in
       let sorted =
         match sort with
         | Sort_title ->
           List.sort
             (fun a b ->
                String.compare
                  (String.lowercase_ascii (a.fm.title :> string))
                  (String.lowercase_ascii (b.fm.title :> string)))
             filtered
         | Sort_updated ->
           List.sort
             (fun a b ->
                let c = String.compare b.updated a.updated in
                if c <> 0 then c else String.compare a.slug b.slug)
             filtered
         | Sort_rank ->
           List.sort
             (fun a b ->
                let c =
                  Int.compare
                    (Wiki_graph.incoming graph b.slug)
                    (Wiki_graph.incoming graph a.slug)
                in
                if c <> 0 then c else String.compare a.slug b.slug)
             filtered
       in
       let page_rows =
         List.map
           (fun p ->
              `Assoc
                [ "slug", `String p.slug
                ; "file", `String p.file
                ; "title", `String (p.fm.title :> string)
                ; "summary", `String (p.fm.summary :> string)
                ; "source", `String (Wiki_page.source_to_string p.fm.source)
                ; "author", `String (p.fm.author :> string)
                ; "created", `String (p.fm.created :> string)
                ; "updated", `String p.updated
                ; "revision", `Int p.fm.revision
                ; ( "tags"
                  , `List
                      (List.map
                         (fun (t : Wiki_page.Tag.t) -> `String (t :> string))
                         p.fm.tags) )
                ; "backlink_count", `Int (Wiki_graph.incoming graph p.slug)
                ; "outgoing_link_count", `Int (List.length p.links)
                ; "sources_count", `Int p.sources.references
                ; "hearsay_count", `Int p.sources.hearsay
                ; "sha256", `String p.sha256
                ])
           sorted
       in
       let tags_json =
         Hashtbl.fold (fun k v acc -> (k, v) :: acc) tag_counts []
         |> List.sort (fun (ka, va) (kb, vb) ->
              let c = Int.compare vb va in
              if c <> 0 then c else String.compare ka kb)
         |> List.map (fun (k, v) -> `Assoc [ "tag", `String k; "count", `Int v ])
       in
       let sources_json =
         Wiki_page.valid_source_strings
         |> List.map (fun k ->
              let count =
                match Hashtbl.find_opt source_counts k with
                | Some n -> n
                | None -> 0
              in
              k, `Int count)
       in
       let lint_counts = Wiki_lint.counts findings in
       let orphans =
         List.filter_map
           (function
             | Wiki_lint.Orphan { page } | Wiki_lint.Orphan_unconfirmed { page } ->
               Some (`String page)
             | Wiki_lint.Broken_link _
             | Wiki_lint.Unsupported_link _
             | Wiki_lint.Missing_sources _
             | Wiki_lint.Hearsay_only _
             | Wiki_lint.Unreadable_page _
             | Wiki_lint.Revision_log_gap _
             | Wiki_lint.Revision_log_hole _ -> None)
           findings
       in
       let data =
         `Assoc
           [ "pages_total", `Int (List.length pages)
           ; "pages_readable", `Int (List.length readable)
           ; "pages_unreadable", `Int (List.length unreadable)
           ; "pages", `List page_rows
           ; ( "unreadable_pages"
             , `List
                 (List.map
                    (fun u ->
                       `Assoc [ "file", `String u.file; "reason", `String u.reason ])
                    unreadable) )
           ; "tags", `List tags_json
           ; "sources", `Assoc sources_json
           ; ( "lint"
             , `Assoc
                 [ "total_findings", `Int (List.length findings)
                 ; ( "counts"
                   , `Assoc
                       (( "duplicate_title_candidates", `Int (List.length duplicates) )
                        :: List.map (fun (k, v) -> k, `Int v) lint_counts) )
                 ; "log_hole_suppressed", `Bool (Wiki_lint.log_hole_suppressed log)
                 ; "orphans", `List orphans
                 ; ( "duplicate_title_candidates"
                   , `List (List.map duplicate_candidate_to_json duplicates) )
                 ; "findings", `List (List.map finding_to_json findings)
                 ] )
           ]
       in
       Ok (Env.ok ?now data))
;;

(* Extract optional author & note trailing text from a raw log.md line for display,
   without altering Wiki_log's authoritative parsed fields. *)
let raw_log_author_and_note raw =
  let lines = String.split_on_char '\n' raw in
  let tbl = Hashtbl.create 64 in
  List.iter
    (fun raw_line ->
       let trimmed = String.trim raw_line in
       if String.starts_with ~prefix:"## [" trimmed
       then (
         match String.split_on_char '|' trimmed with
         | head :: page_seg :: author_seg :: note_rest ->
           let page = String.trim page_seg in
           let author = String.trim author_seg in
           let note = String.trim (String.concat "|" note_rest) in
           (* Extract [action] and [rN] from head for stable lookup key *)
           (match String.index_opt head ']' with
            | Some close_idx ->
              let after =
                String.sub head (close_idx + 1) (String.length head - close_idx - 1)
                |> String.trim
              in
              let key = after ^ "|" ^ page in
              Hashtbl.replace tbl key (author, note)
            | None -> ())
         | _ -> ()))
    lines;
  tbl
;;

let log_json ?now ?(limit = 100) ?before_idx ?page ~base_path () =
  let limit = Server_utils.clamp ~min_v:1 ~max_v:500 limit in
  match read_log_raw ~base_path with
  | Error msg -> error_result Env.Store_unavailable msg
  | Ok (raw, log) ->
    let extras = raw_log_author_and_note raw in
    let indexed = List.mapi (fun idx line -> idx, line) log.Wiki_log.lines in
    let filtered =
      indexed
      |> List.filter (fun (idx, (line : Wiki_log.line)) ->
           let before_ok =
             match before_idx with
             | None -> true
             | Some cutoff -> idx < cutoff
           in
           let page_ok =
             match page with
             | None -> true
             | Some wanted -> String.equal line.page wanted
           in
           before_ok && page_ok)
      |> List.rev
      |> Server_utils.take limit
    in
    let entries =
      List.map
        (fun (idx, (line : Wiki_log.line)) ->
           let key =
             Printf.sprintf "%s r%d|%s" line.action line.revision line.page
           in
           let author, note =
             match Hashtbl.find_opt extras key with
             | Some (a, n) -> Some a, Some n
             | None -> None, None
           in
           `Assoc
             [ "idx", `Int idx
             ; "written_at_unix", `Float line.written_at
             ; "action", `String line.action
             ; "revision", `Int line.revision
             ; "page", `String line.page
             ; "author", Json_util.string_opt_to_json author
             ; "note", Json_util.string_opt_to_json note
             ])
        filtered
    in
    let data =
      `Assoc
        [ "total_lines", `Int (List.length log.lines)
        ; "unknown_action", `Int log.unknown_action
        ; "unreadable_line", `Int log.unreadable_line
        ; "limit", `Int limit
        ; "entries", `List entries
        ]
    in
    Ok (Env.ok ?now data)
;;

let extract_snippets ~query body =
  let lines = String.split_on_char '\n' body in
  let rec collect idx acc = function
    | [] -> List.rev acc
    | _ when List.length acc >= 3 -> List.rev acc
    | line :: rest ->
      let trimmed = String.trim line in
      let matched =
        (not (String.equal trimmed ""))
        && (String_util.contains_query_term_ci trimmed query
            || String_util.contains_all_query_terms_ci trimmed query)
      in
      let acc =
        if matched
        then
          let clipped =
            if String.length trimmed > 200
            then String.sub trimmed 0 200 ^ "..."
            else trimmed
          in
          `Assoc [ "line", `Int idx; "text", `String clipped ] :: acc
        else acc
      in
      collect (idx + 1) acc rest
  in
  collect 1 [] lines
;;

let search_json ?now ?(limit = 30) ~base_path ~query () =
  let query = String.trim query in
  if String.equal query ""
  then error_result ~field:"q" Env.Invalid_param "query parameter q is required"
  else (
    let limit = Server_utils.clamp ~min_v:1 ~max_v:100 limit in
    match load_pages ~base_path with
    | Error msg -> error_result Env.Store_unavailable msg
    | Ok pages ->
      let searchable =
        List.map
          (fun page ->
             let text =
               match page with
               | Loaded_readable p ->
                 String.concat
                   "\n"
                   [ (p.fm.title :> string)
                   ; (p.fm.summary :> string)
                   ; String.concat
                       " "
                       (List.map (fun (t : Wiki_page.Tag.t) -> (t :> string)) p.fm.tags)
                   ; p.body
                   ]
               | Loaded_unreadable u -> u.file
             in
             page, text)
          pages
      in
      let scores = Wiki_rank.scores ~query (List.map snd searchable) in
      let hits =
        List.combine searchable scores
        |> List.filter_map (fun ((page, text), score) ->
             let tier =
               if String_util.contains_query_term_ci text query
               then Some (`Whole_query, "whole_query")
               else if String_util.contains_all_query_terms_ci text query
               then Some (`Every_term, "every_term")
               else None
             in
             Option.map (fun (t, t_label) -> t, t_label, score, page) tier)
      in
      let whole, terms =
        List.partition (fun (t, _, _, _) -> t = `Whole_query) hits
      in
      let sort_desc =
        List.stable_sort (fun (_, _, sa, _) (_, _, sb, _) -> Float.compare sb sa)
      in
      let ordered = (sort_desc whole @ sort_desc terms) |> Server_utils.take limit in
      let results_json =
        List.filter_map
          (fun (_, tier_label, score, page) ->
             match page with
             | Loaded_unreadable _ -> None
             | Loaded_readable p ->
               Some
                 (`Assoc
                   [ "slug", `String p.slug
                   ; "title", `String (p.fm.title :> string)
                   ; "summary", `String (p.fm.summary :> string)
                   ; "source", `String (Wiki_page.source_to_string p.fm.source)
                   ; "updated", `String p.updated
                   ; "revision", `Int p.fm.revision
                   ; ( "tags"
                     , `List
                         (List.map
                            (fun (t : Wiki_page.Tag.t) -> `String (t :> string))
                            p.fm.tags) )
                   ; "score", `Float score
                   ; "match_tier", `String tier_label
                   ; "snippets", `List (extract_snippets ~query p.body)
                   ]))
          ordered
      in
      let data =
        `Assoc
          [ "query", `String query
          ; "count", `Int (List.length results_json)
          ; "limit", `Int limit
          ; "results", `List results_json
          ]
      in
      Ok (Env.ok ?now data))
;;

let lint_json ?now ?page ~base_path () =
  let page_valid =
    match page with
    | None -> Ok None
    | Some raw ->
      Wiki_page_name.validate_page_name raw
      |> Result.map Option.some
      |> Result.map_error (Wiki_page_name.page_name_error_to_string raw)
  in
  match page_valid with
  | Error msg -> error_result ~field:"page" Env.Invalid_param msg
  | Ok page_filter ->
    (match read_log_raw ~base_path with
     | Error msg -> error_result Env.Store_unavailable msg
     | Ok (_raw, log) ->
       (match load_pages ~base_path with
        | Error msg -> error_result Env.Store_unavailable msg
        | Ok pages ->
          let graph = graph_of_loaded pages in
          let all_findings = Wiki_lint.run graph ~log in
          let findings =
            match page_filter with
            | None -> all_findings
            | Some slug ->
              List.filter (fun f -> String.equal (Wiki_lint.subject f) slug) all_findings
          in
          let readable =
            List.filter_map
              (function
                | Loaded_readable p -> Some p
                | Loaded_unreadable _ -> None)
              pages
          in
          let duplicates =
            readable
            |> List.map (fun p -> p.slug, (p.fm.title :> string))
            |> detect_duplicate_titles
            |> List.filter (fun d ->
                 match page_filter with
                 | None -> true
                 | Some slug ->
                   String.equal d.page_a slug || String.equal d.page_b slug)
          in
          let unreadable_count =
            List.length pages - List.length readable
          in
          let counts =
            ("duplicate_title_candidates", `Int (List.length duplicates))
            :: List.map (fun (k, v) -> k, `Int v) (Wiki_lint.counts findings)
          in
          let data =
            `Assoc
              [ "pages_total", `Int (List.length pages)
              ; "pages_unreadable", `Int unreadable_count
              ; "log_hole_suppressed", `Bool (Wiki_lint.log_hole_suppressed log)
              ; "log_unknown_action", `Int log.unknown_action
              ; "log_unreadable_line", `Int log.unreadable_line
              ; "counts", `Assoc counts
              ; ( "duplicate_title_candidates"
                , `List (List.map duplicate_candidate_to_json duplicates) )
              ; "findings", `List (List.map finding_to_json findings)
              ]
          in
          Ok (Env.ok ?now data)))
;;

let get_page_json ?now ~base_path ~slug () =
  match Wiki_page_name.validate_page_name slug with
  | Error err ->
    error_result
      ~field:"slug"
      Env.Invalid_param
      (Wiki_page_name.page_name_error_to_string slug err)
  | Ok valid_slug ->
    (match read_log_raw ~base_path with
     | Error msg -> error_result Env.Store_unavailable msg
     | Ok (_raw_log, log) ->
       (match load_pages ~base_path with
        | Error msg -> error_result Env.Store_unavailable msg
        | Ok pages ->
          let found =
            List.find_opt
              (function
                | Loaded_readable p -> String.equal p.slug valid_slug
                | Loaded_unreadable u ->
                  String.equal u.file (valid_slug ^ ".md"))
              pages
          in
          (match found with
           | None ->
             error_result
               Env.Not_found
               (Printf.sprintf "wiki page %S not found" valid_slug)
           | Some (Loaded_unreadable u) ->
             error_result
               Env.Store_unavailable
               (Printf.sprintf "wiki page %s is unreadable: %s" u.file u.reason)
           | Some (Loaded_readable p) ->
             let graph = graph_of_loaded pages in
             let findings =
               Wiki_lint.run graph ~log
               |> List.filter (fun f ->
                    String.equal (Wiki_lint.subject f) valid_slug)
             in
             let backlinks = backlinks_for ~pages valid_slug in
             let data =
               `Assoc
                 [ "page", `String valid_slug
                 ; "slug", `String valid_slug
                 ; "file", `String p.file
                 ; "frontmatter", frontmatter_to_json ~updated:p.updated p.fm
                 ; "sha256", `String p.sha256
                 ; "body_markdown", `String p.body
                 ; ( "outgoing_links"
                   , `List (List.map (link_to_json ~graph) p.links) )
                 ; "backlinks", `List (List.map (fun s -> `String s) backlinks)
                 ; ( "sources"
                   , `Assoc
                       [ "references", `Int p.sources.references
                       ; "hearsay", `Int p.sources.hearsay
                       ] )
                 ; "lint_findings", `List (List.map finding_to_json findings)
                 ]
             in
             Ok (Env.ok ?now data))))
;;

let today_line now =
  let tm = Unix.localtime now in
  Wiki_page.Line.of_calendar_date
    ~year:(tm.tm_year + 1900)
    ~month:(tm.tm_mon + 1)
    ~day:tm.tm_mday
;;

let parse_line_field ~field value =
  Wiki_page.Line.of_string value
  |> Result.map_error (function
       | Wiki_page.Line.Blank -> field, Printf.sprintf "%s must not be blank" field
       | Wiki_page.Line.Spans_lines ->
         field, Printf.sprintf "%s must be a single line" field
       | Wiki_page.Line.Outer_whitespace ->
         field, Printf.sprintf "%s must not start or end with whitespace" field)
;;

let parse_tags_field fields =
  match List.assoc_opt "tags" fields with
  | None -> Ok None
  | Some (`List items) ->
    let rec loop acc = function
      | [] -> Ok (Some (List.rev acc))
      | `String raw :: rest ->
        (match Wiki_page.Tag.of_string raw with
         | Ok tag -> loop (tag :: acc) rest
         | Error problem ->
           let reason =
             match problem with
             | Wiki_page.Tag.Not_a_line Wiki_page.Line.Blank -> "must not be blank"
             | Wiki_page.Tag.Not_a_line Wiki_page.Line.Spans_lines ->
               "must not span lines"
             | Wiki_page.Tag.Not_a_line Wiki_page.Line.Outer_whitespace ->
               "must not have outer whitespace"
             | Wiki_page.Tag.Has_comma -> "must not contain a comma"
           in
           Error ("tags", Printf.sprintf "invalid tag %S: %s" raw reason))
      | _ :: _ -> Error ("tags", "tags must be a list of strings")
    in
    loop [] items
  | Some _ -> Error ("tags", "tags must be a list of strings")
;;

let string_field_opt fields name =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String s) -> Ok (Some s)
  | Some _ -> Error (name, Printf.sprintf "%s must be a string" name)
;;

let int_field_opt fields name =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int n) -> Ok (Some n)
  | Some _ -> Error (name, Printf.sprintf "%s must be an integer" name)
;;

let put_page_json ?(now = Time_compat.now ()) ~config ~actor ~slug ~body_str () =
  let base_path = config.Workspace.base_path in
  match Wiki_page_name.validate_page_name slug with
  | Error err ->
    error_result
      ~field:"slug"
      Env.Invalid_param
      (Wiki_page_name.page_name_error_to_string slug err)
  | Ok valid_slug ->
    (match Yojson.Safe.from_string body_str with
     | exception Yojson.Json_error msg ->
       error_result Env.Invalid_param ("invalid JSON: " ^ msg)
     | (`Assoc fields) ->
       let parsed =
         let open Result.Syntax in
         let* expected_sha256 = string_field_opt fields "expected_sha256" in
         let* expected_revision = int_field_opt fields "expected_revision" in
         let* raw_title = string_field_opt fields "title" in
         let* raw_summary = string_field_opt fields "summary" in
         let* raw_source = string_field_opt fields "source" in
         let* raw_body =
           match string_field_opt fields "body" with
           | Ok (Some b) -> Ok (Some b)
           | Ok None -> string_field_opt fields "body_markdown"
           | Error _ as err -> err
         in
         let* raw_note = string_field_opt fields "note" in
         let* tags = parse_tags_field fields in
         let* author_line =
           let actor_clean = String.trim actor in
           let actor_str = if String.equal actor_clean "" then "operator" else actor_clean in
           parse_line_field ~field:"actor" actor_str
         in
         let* title_line =
           match raw_title with
           | None -> Ok None
           | Some s -> Result.map Option.some (parse_line_field ~field:"title" s)
         in
         let* summary_line =
           match raw_summary with
           | None -> Ok None
           | Some s -> Result.map Option.some (parse_line_field ~field:"summary" s)
         in
         let* note_line =
           match raw_note with
           | None -> parse_line_field ~field:"note" "updated via HTTP API"
           | Some s -> parse_line_field ~field:"note" s
         in
         let* source_opt =
           match raw_source with
           | None -> Ok None
           | Some raw ->
             (match Wiki_page.source_of_string_opt raw with
              | Some src -> Ok (Some src)
              | None ->
                Error
                  ( "source"
                  , Printf.sprintf
                      "invalid source %S; expected one of: %s"
                      raw
                      (String.concat ", " Wiki_page.valid_source_strings) ))
         in
         let* body =
           match raw_body with
           | Some b when not (String.equal b "") -> Ok b
           | Some _ | None -> Error ("body", "body is required and must not be empty")
         in
         Ok
           ( expected_sha256
           , expected_revision
           , title_line
           , summary_line
           , source_opt
           , tags
           , body
           , note_line
           , author_line )
       in
       (match parsed with
        | Error (field, msg) -> error_result ~field Env.Validation_failed msg
        | Ok
            ( expected_sha256
            , expected_revision
            , title_line
            , summary_line
            , source_opt
            , tags
            , body
            , note_line
            , author_line ) ->
          let root = Tool_wiki.wiki_root ~base_path in
          (match Fs_compat.mkdir_p root with
           | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
           | exception exn ->
             error_result
               Env.Store_unavailable
               ("wiki directory error: " ^ Printexc.to_string exn)
           | () ->
             let lock_path = Filename.concat root ".wiki.lock" in
             (match
                File_lock_eio.with_durable_lock ~lock_path (fun () ->
                  let path = Tool_wiki.page_path ~base_path valid_slug in
                  let exists = Sys.file_exists path in
                  if exists
                  then (
                    match read_file_safe path with
                    | Error msg -> error_result Env.Store_unavailable msg
                    | Ok current_raw ->
                      let current_sha = Env.sha256_hex current_raw in
                      (match Wiki_page.parse_frontmatter current_raw with
                       | Error err ->
                         error_result
                           Env.Store_unavailable
                           ("existing page frontmatter is unreadable: "
                            ^ Wiki_page.frontmatter_error_to_string err)
                       | Ok current_fm ->
                         let cas_provided =
                           Option.is_some expected_sha256 || Option.is_some expected_revision
                         in
                         let cas_ok =
                           if not cas_provided
                           then false
                           else (
                             let sha_ok =
                               match expected_sha256 with
                               | None -> true
                               | Some exp ->
                                 String.equal (String.lowercase_ascii exp) current_sha
                             in
                             let rev_ok =
                               match expected_revision with
                               | None -> true
                               | Some exp -> exp = current_fm.revision
                             in
                             sha_ok && rev_ok)
                         in
                         if not cas_ok
                         then
                           error_result
                             Env.Conflict_cas
                             ~extra:
                               [ "current_sha256", `String current_sha
                               ; "current_revision", `Int current_fm.revision
                               ]
                             (if cas_provided
                              then "wiki page changed since last read"
                              else
                                "expected_sha256 or expected_revision is required when updating an existing wiki page")
                         else (
                           match source_opt with
                           | Some src when src <> current_fm.source ->
                             error_result
                               ~field:"source"
                               Env.Validation_failed
                               "source cannot change on update"
                           | Some _ | None ->
                             let next_rev = current_fm.revision + 1 in
                             let updated_day = today_line now in
                             let next_fm =
                               { current_fm with
                                 title = Option.value title_line ~default:current_fm.title
                               ; summary =
                                   Option.value summary_line ~default:current_fm.summary
                               ; revision = next_rev
                               ; tags = Option.value tags ~default:current_fm.tags
                               }
                             in
                             let rendered =
                               Wiki_page.render_page next_fm ~updated:updated_day ~body
                             in
                             (match Fs_compat.save_file_atomic path rendered with
                              | Error msg ->
                                error_result
                                  Env.Store_unavailable
                                  ("atomic write failed: " ^ msg)
                              | Ok () ->
                                let log_line =
                                  Wiki_journal.log_line
                                    ~time:(Unix.localtime now)
                                    ~action:Wiki_journal.Updated
                                    ~revision:next_rev
                                    ~page:valid_slug
                                    ~author:(author_line :> string)
                                    ~note:(note_line :> string)
                                in
                                let log_warning =
                                  match Wiki_journal.append_log ~wiki_root:root log_line with
                                  | Ok () -> None
                                  | Error msg -> Some ("log.md append failed: " ^ msg)
                                in
                                let index_warning =
                                  match Tool_wiki.read_index_entries ~base_path with
                                  | Error msg -> Some ("index scan failed: " ^ msg)
                                  | Ok entries ->
                                    (match Wiki_journal.write_index ~wiki_root:root entries with
                                     | Ok () -> None
                                     | Error msg -> Some ("index.md write failed: " ^ msg))
                                in
                                let new_sha = Env.sha256_hex rendered in
                                Audit_log.log_action
                                  config
                                  ~agent_id:(author_line :> string)
                                  ~action:(Audit_log.Custom "wiki_update")
                                  ~details:
                                    (`Assoc
                                      [ "slug", `String valid_slug
                                      ; "revision", `Int next_rev
                                      ; "before_sha256", `String current_sha
                                      ; "after_sha256", `String new_sha
                                      ])
                                  ~outcome:Audit_log.Success
                                  ();
                                Env.announce_v2_dataset
                                  ~base_path
                                  ~dataset:"wiki"
                                  ~extra:
                                    [ "slug", `String valid_slug
                                    ; "revision", `Int next_rev
                                    ]
                                  ();
                                let warnings =
                                  List.filter_map Fun.id [ log_warning; index_warning ]
                                in
                                Ok
                                  (Env.ok
                                     ~now
                                     (`Assoc
                                       [ "action", `String "updated"
                                       ; "slug", `String valid_slug
                                       ; "revision", `Int next_rev
                                       ; "sha256", `String new_sha
                                       ; ( "frontmatter"
                                         , frontmatter_to_json
                                             ~updated:(updated_day :> string)
                                             next_fm )
                                       ; ( "warnings"
                                         , `List
                                             (List.map (fun w -> `String w) warnings) )
                                       ]))))))
                  else (
                    (* Creating a new wiki page *)
                    match expected_sha256, expected_revision with
                    | Some _, _ | _, Some _ ->
                      error_result
                        Env.Conflict_cas
                        "cannot supply expected_sha256 or expected_revision when creating a new page"
                    | None, None ->
                      (match title_line, summary_line, source_opt with
                       | None, _, _ ->
                         error_result
                           ~field:"title"
                           Env.Validation_failed
                           "title is required when creating a new page"
                       | _, None, _ ->
                         error_result
                           ~field:"summary"
                           Env.Validation_failed
                           "summary is required when creating a new page"
                       | _, _, None ->
                         error_result
                           ~field:"source"
                           Env.Validation_failed
                           "source is required when creating a new page"
                       | Some title, Some summary, Some source ->
                         let day = today_line now in
                         let fm =
                           { Wiki_page.title
                           ; summary
                           ; source
                           ; author = author_line
                           ; created = day
                           ; revision = 1
                           ; tags = Option.value tags ~default:[]
                           }
                         in
                         let rendered = Wiki_page.render_page fm ~updated:day ~body in
                         (match Fs_compat.save_file_atomic path rendered with
                          | Error msg ->
                            error_result
                              Env.Store_unavailable
                              ("atomic write failed: " ^ msg)
                          | Ok () ->
                            let log_line =
                              Wiki_journal.log_line
                                ~time:(Unix.localtime now)
                                ~action:Wiki_journal.Created
                                ~revision:1
                                ~page:valid_slug
                                ~author:(author_line :> string)
                                ~note:(summary :> string)
                            in
                            let log_warning =
                              match Wiki_journal.append_log ~wiki_root:root log_line with
                              | Ok () -> None
                              | Error msg -> Some ("log.md append failed: " ^ msg)
                            in
                            let index_warning =
                              match Tool_wiki.read_index_entries ~base_path with
                              | Error msg -> Some ("index scan failed: " ^ msg)
                              | Ok entries ->
                                (match Wiki_journal.write_index ~wiki_root:root entries with
                                 | Ok () -> None
                                 | Error msg -> Some ("index.md write failed: " ^ msg))
                            in
                            let new_sha = Env.sha256_hex rendered in
                            Audit_log.log_action
                              config
                              ~agent_id:(author_line :> string)
                              ~action:(Audit_log.Custom "wiki_create")
                              ~details:
                                (`Assoc
                                  [ "slug", `String valid_slug
                                  ; "revision", `Int 1
                                  ; "after_sha256", `String new_sha
                                  ])
                              ~outcome:Audit_log.Success
                              ();
                            Env.announce_v2_dataset
                              ~base_path
                              ~dataset:"wiki"
                              ~extra:[ "slug", `String valid_slug; "revision", `Int 1 ]
                              ();
                            let warnings =
                              List.filter_map Fun.id [ log_warning; index_warning ]
                            in
                            Ok
                              (Env.ok
                                 ~now
                                 (`Assoc
                                   [ "action", `String "created"
                                   ; "slug", `String valid_slug
                                   ; "revision", `Int 1
                                   ; "sha256", `String new_sha
                                   ; ( "frontmatter"
                                     , frontmatter_to_json ~updated:(day :> string) fm )
                                   ; ( "warnings"
                                     , `List (List.map (fun w -> `String w) warnings) )
                                   ]))))))
              with
              | Ok res -> res
              | Error err ->
                error_result
                  Env.Store_unavailable
                  ("wiki lock failed: " ^ File_lock_eio.durable_lock_error_to_string err))))
     | _ -> error_result Env.Invalid_param "request body must be a JSON object")
;;

let respond_result ~req reqd = function
  | Ok json -> Http.Response.json_value ~compress:true ~request:req json reqd
  | Error (status, json) ->
    Http.Response.json_value ~status ~compress:true ~request:req json reqd
;;

let wiki_slug_prefix = "/api/v1/wiki/"

let extract_slug req =
  match Server_utils.extract_path_param ~prefix:wiki_slug_prefix (Http.Request.path req) with
  | None -> None
  | Some raw ->
    let decoded = Uri.pct_decode raw |> String.trim in
    if String.equal decoded "" || String.contains decoded '/'
    then None
    else Some decoded
;;

let add_routes router =
  router
  |> Server_route.get
       (Server_route.Permission Masc_domain.CanReadState)
       "/api/v1/wiki"
       (fun state req reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          let tag =
            Server_utils.query_param req "tag"
            |> Option.map String.trim
            |> Fun.flip Option.bind (fun s -> if String.equal s "" then None else Some s)
          in
          let source_res =
            match Server_utils.query_param req "source" with
            | None -> Ok None
            | Some raw ->
              let trimmed = String.trim raw in
              if String.equal trimmed ""
              then Ok None
              else (
                match Wiki_page.source_of_string_opt trimmed with
                | Some src -> Ok (Some src)
                | None ->
                  error_result
                    ~field:"source"
                    Env.Invalid_param
                    (Printf.sprintf
                       "unknown wiki source %S; valid: %s"
                       trimmed
                       (String.concat ", " Wiki_page.valid_source_strings)))
          in
          let sort_res =
            match Server_utils.query_param req "sort" with
            | None -> Ok Sort_title
            | Some raw ->
              (match sort_order_of_string raw with
               | Some s -> Ok s
               | None ->
                 error_result
                   ~field:"sort"
                   Env.Invalid_param
                   (Printf.sprintf "unknown sort %S; valid: title, updated, rank" raw))
          in
          let result =
            match source_res, sort_res with
            | Error err, _ | _, Error err -> Error err
            | Ok source, Ok sort ->
              Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                list_json ?tag ?source ~sort ~base_path ())
          in
          respond_result ~req reqd result)
  |> Server_route.get
       (Server_route.Permission Masc_domain.CanReadState)
       "/api/v1/wiki/log"
       (fun state req reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          let limit = Server_utils.int_query_param req "limit" ~default:100 in
          let before_idx_res =
            match Server_utils.query_param req "before_idx" with
            | None -> Ok None
            | Some raw ->
              (match int_of_string_opt (String.trim raw) with
               | Some n when n >= 0 -> Ok (Some n)
               | Some _ | None ->
                 error_result
                   ~field:"before_idx"
                   Env.Invalid_param
                   "before_idx must be a non-negative integer")
          in
          let page =
            Server_utils.query_param req "page"
            |> Option.map String.trim
            |> Fun.flip Option.bind (fun s -> if String.equal s "" then None else Some s)
          in
          let result =
            match before_idx_res with
            | Error err -> Error err
            | Ok before_idx ->
              Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                log_json ~limit ?before_idx ?page ~base_path ())
          in
          respond_result ~req reqd result)
  |> Server_route.get
       (Server_route.Permission Masc_domain.CanReadState)
       "/api/v1/wiki/search"
       (fun state req reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          let query =
            match Server_utils.query_param req "q" with
            | Some q -> q
            | None ->
              Option.value ~default:"" (Server_utils.query_param req "query")
          in
          let limit = Server_utils.int_query_param req "limit" ~default:30 in
          let result =
            Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
              search_json ~limit ~base_path ~query ())
          in
          respond_result ~req reqd result)
  |> Server_route.get
       (Server_route.Permission Masc_domain.CanReadState)
       "/api/v1/wiki/lint"
       (fun state req reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          let page =
            Server_utils.query_param req "page"
            |> Option.map String.trim
            |> Fun.flip Option.bind (fun s -> if String.equal s "" then None else Some s)
          in
          let result =
            Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
              lint_json ?page ~base_path ())
          in
          respond_result ~req reqd result)
  |> Server_route.prefix_get
       (Server_route.Permission Masc_domain.CanReadState)
       wiki_slug_prefix
       (fun state req reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          let result =
            match extract_slug req with
            | None ->
              error_result ~field:"slug" Env.Invalid_param "wiki page slug is required"
            | Some slug ->
              Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                get_page_json ~base_path ~slug ())
          in
          respond_result ~req reqd result)
  |> Server_route.prefix_put
       (Server_route.Token_permission Masc_domain.CanAdmin)
       wiki_slug_prefix
       (fun state actor req reqd ->
          Http.Request.read_body_async reqd (fun body_str ->
            let config = Mcp_server.workspace_config state in
            let result =
              match extract_slug req with
              | None ->
                error_result ~field:"slug" Env.Invalid_param "wiki page slug is required"
              | Some slug ->
                Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                  put_page_json ~config ~actor ~slug ~body_str ())
            in
            respond_result ~req reqd result))
;;
