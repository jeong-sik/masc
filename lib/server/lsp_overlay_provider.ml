(** LSP Overlay Provider — inject MASC annotations into LSP protocol responses.

    Converts MASC annotations (comments, decisions, questions, bookmarks)
    into LSP CodeLens entries. Provides diagnostic merging and inlay hints
    for route-context bindings. *)

open Ide_annotation_types

module Cache = struct
  let tbl : (string, annotation list) Hashtbl.t = Hashtbl.create 32
  let mutex = Eio.Mutex.create ()

  let key ~base_dir ~file_path = base_dir ^ "/" ^ file_path

  let get ~base_dir ~file_path =
    Eio.Mutex.use_rw ~protect:true mutex (fun () ->
      let k = key ~base_dir ~file_path in
      match Hashtbl.find_opt tbl k with
      | Some annotations -> annotations
      | None ->
        let filter : annotation_filter =
          { file_path = Some file_path; keeper_id = None; goal_id = None; task_id = None }
        in
        let annotations = Ide_annotations.list ~base_dir ~filter in
        Hashtbl.replace tbl k annotations;
        annotations)

  let invalidate ~base_dir ~file_path =
    Eio.Mutex.use_rw ~protect:true mutex (fun () ->
      Hashtbl.remove tbl (key ~base_dir ~file_path))

  let clear () =
    Eio.Mutex.use_rw ~protect:true mutex (fun () ->
      Hashtbl.clear tbl)
end

(** LSP CodeLens entry as JSON. *)
let tag_opt label value =
  match value with
  | Some raw when String.trim raw <> "" -> [ Printf.sprintf "%s:%s" label raw ]
  | _ -> []
;;

let annotation_route_tags (a : annotation) =
  tag_opt "goal" a.goal_id
  @ tag_opt "task" a.task_id
  @ tag_opt "board" a.board_post_id
  @ tag_opt "comment" a.comment_id
  @ tag_opt "PR" a.pr_id
  @ tag_opt "git" a.git_ref
  @ tag_opt "log" a.log_id
  @ tag_opt "session" a.session_id
  @ tag_opt "op" a.operation_id
  @ tag_opt "worker" a.worker_run_id
;;

let annotation_context_label (a : annotation) =
  String.concat " · " (annotation_route_tags a)
;;

let annotation_context_suffix (a : annotation) =
  match annotation_context_label a with
  | "" -> ""
  | label -> " · " ^ label
;;

let annotation_message_with_context (a : annotation) =
  match annotation_context_label a with
  | "" -> a.content
  | label -> Printf.sprintf "%s (%s)" a.content label
;;

let codelens_to_json (a : annotation) : Yojson.Safe.t =
  let range =
    `Assoc [
      ("start", `Assoc [("line", `Int (a.line_start - 1)); ("character", `Int 0)]);
      ("end", `Assoc [("line", `Int (a.line_end - 1)); ("character", `Int 0)]);
    ]
  in
  let kind_label = annotation_kind_to_string a.kind in
  let title = Printf.sprintf "[%s] %s%s" kind_label a.content (annotation_context_suffix a) in
  `Assoc [
    ("range", range);
    ("command", `Assoc [
      ("title", `String title);
      ("command", `String "masc.showAnnotation");
      ("arguments", `List [annotation_to_json a]);
    ]);
  ]

(** LSP InlayHint entry — shows route-context binding inline. *)
let inlay_hint_to_json (a : annotation) : Yojson.Safe.t =
  let label =
    match annotation_context_label a with
    | "" -> Printf.sprintf "[%s]" (annotation_kind_to_string a.kind)
    | label -> label
  in
  `Assoc [
    ("position", `Assoc [("line", `Int (a.line_start - 1)); ("character", `Int 0)]);
    ("label", `String label);
    ("tooltip", `String (annotation_message_with_context a));
    ("kind", `Int 2);  (* TypeParameter kind for inline annotations *)
  ]

(** Generate LSP CodeLens entries for a file. *)
let codelenses ~base_dir ~file_path : Yojson.Safe.t list =
  let annotations = Cache.get ~base_dir ~file_path in
  List.filter_map (fun (a : annotation) ->
    match a.kind with
    | Decision -> Some (codelens_to_json a)
    | Question -> Some (codelens_to_json a)
    | Bookmark -> Some (codelens_to_json a)
    | Comment -> None
  ) annotations

(** Generate LSP InlayHint entries for a file.
    Only annotations with route-context bindings produce hints. *)
let inlay_hints ~base_dir ~file_path : Yojson.Safe.t list =
  let annotations = Cache.get ~base_dir ~file_path in
  List.filter_map (fun (a : annotation) ->
    if annotation_route_tags a <> [] then
      Some (inlay_hint_to_json a)
    else
      None
  ) annotations

(** Merge MASC warnings with LSP diagnostics.
    Annotations of kind [Question] are elevated to [Information] severity
    diagnostics to surface unresolved questions in the editor. *)
let diagnostics ~base_dir ~file_path ~(lsp_diagnostics : Yojson.Safe.t list) :
  Yojson.Safe.t list =
  let annotations = Cache.get ~base_dir ~file_path in
  let masc_diags = List.filter_map (fun (a : annotation) ->
    match a.kind with
    | Question ->
        let range =
          `Assoc [
            ("start", `Assoc [("line", `Int (a.line_start - 1)); ("character", `Int 0)]);
            ("end", `Assoc [("line", `Int (a.line_end - 1)); ("character", `Int 0)]);
          ]
        in
        Some (`Assoc [
          ("range", range);
          ("severity", `Int 3);  (* Information *)
          ("source", `String "masc");
          ("message", `String (annotation_message_with_context a));
        ])
    | Decision | Bookmark | Comment -> None
  ) annotations in
  lsp_diagnostics @ masc_diags

let invalidate_cache ~base_dir ~file_path = Cache.invalidate ~base_dir ~file_path

let clear_cache () = Cache.clear ()

(** Find annotations overlapping a given LSP position (0-based line).
    An annotation covers lines [line_start, line_end] (1-based internally),
    so it overlaps LSP line [l] when [line_start - 1 <= l <= line_end - 1]. *)
let annotations_at_line ~base_dir ~file_path ~line =
  let annotations = Cache.get ~base_dir ~file_path in
  List.filter (fun (a : annotation) ->
    a.line_start - 1 <= line && line <= a.line_end - 1
  ) annotations

let has_annotations_at_line ~base_dir ~file_path ~line =
  annotations_at_line ~base_dir ~file_path ~line <> []

(** Normalize Hover.contents to MarkupContent (kind, value).
    Handles MarkupContent, MarkedString, and MarkedString[]. *)
let contents_to_markup = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields, List.assoc_opt "value" fields with
     | Some (`String k), Some (`String v) -> Some (k, v)
     | _ ->
       (match List.assoc_opt "language" fields, List.assoc_opt "value" fields with
        | Some (`String lang), Some (`String v) ->
          Some ("markdown", "```" ^ lang ^ "\n" ^ v ^ "\n```")
        | _ -> None))
  | `String s -> Some ("plaintext", s)
  | `List items ->
    let parts = List.filter_map (function
      | `String s -> Some s
      | `Assoc fs ->
        (match List.assoc_opt "language" fs, List.assoc_opt "value" fs with
         | Some (`String lang), Some (`String v) ->
           Some ("```" ^ lang ^ "\n" ^ v ^ "\n```")
         | _, Some (`String v) -> Some v
         | _ -> None)
      | _ -> None
    ) items in
    Some ("markdown", String.concat "\n\n" parts)
  | _ -> None

(** Append MASC annotation context to an LSP Hover response.
    Handles all LSP Hover.contents forms: MarkupContent, MarkedString, MarkedString[].
    Returns the enriched response unchanged if no annotations overlap. *)
let enrich_hover ~base_dir ~file_path ~line (result : Yojson.Safe.t) =
  let matching = annotations_at_line ~base_dir ~file_path ~line in
  if matching = [] then result
  else
    let masc_section =
      String.concat "\n" (List.map (fun (a : annotation) ->
        let kind = annotation_kind_to_string a.kind in
        Printf.sprintf "- **[%s]** %s" kind (annotation_message_with_context a)
      ) matching)
    in
    let masc_suffix = "\n---\n**MASC Annotations:**\n" ^ masc_section in
    match result with
    | `Assoc fields ->
      (match List.assoc_opt "contents" fields with
       | Some contents ->
         (match contents_to_markup contents with
          | Some (k, v) ->
            let enriched =
              `Assoc [ ("kind", `String k); ("value", `String (v ^ masc_suffix)) ]
            in
            `Assoc (List.map (fun (key, value) ->
              if String.equal key "contents"
              then ("contents", enriched)
              else (key, value)
            ) fields)
          | None -> result)
       | None -> result)
    | _ -> result
