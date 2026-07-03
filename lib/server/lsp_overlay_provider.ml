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
        let annotations = Ide_annotations.list ~base_dir ~filter () in
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

(** Generate LSP Location links for annotations overlapping [line].
    Used by textDocument/definition to jump to annotation targets. *)
let definition_links ~base_dir ~file_path ~line : Yojson.Safe.t list =
  let matching = annotations_at_line ~base_dir ~file_path ~line in
  List.map (fun (a : annotation) ->
    `Assoc [
      ("uri", `String ("file://" ^ base_dir ^ "/" ^ a.file_path));
      ("range", `Assoc [
        ("start", `Assoc [("line", `Int (a.line_start - 1)); ("character", `Int 0)]);
        ("end", `Assoc [("line", `Int (a.line_end - 1)); ("character", `Int 0)]);
      ]);
    ]
  ) matching

(** Generate LSP Location[] for annotations related to those at [line].
    Finds annotations sharing the same goal_id or task_id across the file.
    Used by textDocument/references. *)
let reference_locations ~base_dir ~file_path ~line ~include_declaration:_ :
    Yojson.Safe.t list =
  let matching = annotations_at_line ~base_dir ~file_path ~line in
  let goal_ids = List.filter_map (fun (a : annotation) -> a.goal_id) matching in
  let task_ids = List.filter_map (fun (a : annotation) -> a.task_id) matching in
  let all = Cache.get ~base_dir ~file_path in
  let related = List.filter (fun (a : annotation) ->
    (match a.goal_id with Some g -> List.mem g goal_ids | None -> false)
    || (match a.task_id with Some t -> List.mem t task_ids | None -> false)
  ) all in
  let seen = Hashtbl.create 16 in
  let deduped = List.filter (fun (a : annotation) ->
    let key = (a.file_path, a.line_start) in
    if Hashtbl.mem seen key then false
    else (Hashtbl.add seen key (); true)
  ) (matching @ related) in
  List.map (fun (a : annotation) ->
    `Assoc [
      ("uri", `String ("file://" ^ base_dir ^ "/" ^ a.file_path));
      ("range", `Assoc [
        ("start", `Assoc [("line", `Int (a.line_start - 1)); ("character", `Int 0)]);
        ("end", `Assoc [("line", `Int (a.line_end - 1)); ("character", `Int 0)]);
      ]);
    ]
  ) deduped

(** Generate CompletionItem[] for MASC annotation snippets.
    Used by textDocument/completion. *)
let completion_items ~base_dir ~file_path ~line:_ : Yojson.Safe.t list =
  let annotations = Cache.get ~base_dir ~file_path in
  let kinds = [ "Comment"; "Decision"; "Question"; "Bookmark" ] in
  List.mapi (fun i kind ->
    let label = Printf.sprintf "masc:%s" (String.lowercase_ascii kind) in
    `Assoc [
      ("label", `String label);
      ("kind", `Int 15);
      ("detail", `String (Printf.sprintf "Insert a MASC %s annotation" kind));
      ("insertText", `String (Printf.sprintf "/* [%s]  */" kind));
      ("insertTextFormat", `Int 2);
      ("sortText", `String (Printf.sprintf "zzz_masc_%02d" i));
      ("data", `Assoc [
        ("file_path", `String file_path);
        ("annotations_count", `Int (List.length annotations));
      ]);
    ]
  ) kinds

(** Generate CodeAction[] for annotation operations.
    Used by textDocument/codeAction. *)
let code_actions ~base_dir ~file_path ~line ~diagnostics:_ : Yojson.Safe.t list =
  let matching = annotations_at_line ~base_dir ~file_path ~line in
  (* task-1692: the observation plane is read-only, so "Create MASC
     Annotation" must not return a WorkspaceEdit that inserts text into the
     source file (the old [edit]/[newText]). Annotations live in the MASC
     store, not the buffer, so this offers a MASC command (a separate write
     lane the client routes to the annotation API) instead of an LSP edit. *)
  let create_action =
    `Assoc [
      ("title", `String "Create MASC Annotation");
      ("kind", `String "quickfix.createAnnotation");
      ("command", `Assoc [
        ("title", `String "Create MASC Annotation");
        ("command", `String "masc.createAnnotation");
        ("arguments", `List [
          `Assoc [("file_path", `String file_path); ("line", `Int line)];
        ]);
      ]);
    ]
  in
  if matching <> [] then
    [
      create_action;
      `Assoc [
        ("title", `String "View MASC Annotations");
        ("kind", `String "quickfix.viewAnnotations");
        ("command", `Assoc [
          ("title", `String "Show Annotations");
          ("command", `String "masc.showAnnotations");
          ("arguments", `List [
            `Assoc [("file_path", `String file_path); ("line", `Int line)];
          ]);
        ]);
      ];
    ]
  else [ create_action ]

(** Generate SymbolInformation[] for MASC annotations.
    Used by textDocument/documentSymbol. *)
let document_symbols ~base_dir ~file_path : Yojson.Safe.t list =
  let annotations = Cache.get ~base_dir ~file_path in
  List.map (fun (a : annotation) ->
    let kind_label = annotation_kind_to_string a.kind in
    let truncated =
      if String.length a.content > 40 then
        String.sub a.content 0 40 ^ "..."
      else a.content
    in
    let name = Printf.sprintf "[%s] %s" kind_label truncated in
    `Assoc [
      ("name", `String name);
      ("kind", `Int 17);
      ("range", `Assoc [
        ("start", `Assoc [("line", `Int (a.line_start - 1)); ("character", `Int 0)]);
        ("end", `Assoc [("line", `Int (a.line_end - 1)); ("character", `Int 0)]);
      ]);
      ("selectionRange", `Assoc [
        ("start", `Assoc [("line", `Int (a.line_start - 1)); ("character", `Int 0)]);
        ("end", `Assoc [("line", `Int (a.line_end - 1)); ("character", `Int 0)]);
      ]);
    ]
  ) annotations

(** Generate FoldingRange[] for consecutive annotation blocks.
    Used by textDocument/foldingRange. *)
let folding_ranges ~base_dir ~file_path : Yojson.Safe.t list =
  let annotations = Cache.get ~base_dir ~file_path in
  let sorted_anns = List.sort (fun (a : annotation) (b : annotation) ->
    compare a.line_start b.line_start
  ) annotations in
  let rec group_anns (acc : annotation list list) (current : annotation list) (xs : annotation list) : annotation list list =
    match xs with
    | [] -> (match current with [] -> List.rev acc | _ -> List.rev (List.rev current :: acc))
    | a :: rest ->
      (match current with
       | [] -> group_anns acc [ a ] rest
       | _ ->
         let last = List.nth current (List.length current - 1) in
         if a.line_start - last.line_end <= 2 then
           group_anns acc (current @ [ a ]) rest
         else
           group_anns (List.rev current :: acc) [ a ] rest)
  in
  let groups = group_anns [] [] sorted_anns in
  List.filter_map (fun (grp : annotation list) ->
    match grp with
    | [] -> None
    | [ _ ] -> None
    | first :: _ ->
      let last = List.nth grp (List.length grp - 1) in
      if last.line_start > first.line_start then
        Some (`Assoc [
          ("startLine", `Int (first.line_start - 1));
          ("endLine", `Int (last.line_end - 1));
          ("kind", `String "region");
        ])
      else None
  ) groups

(** Generate DocumentHighlight[] for annotations sharing goal/task context.
    Used by textDocument/documentHighlight. *)
let document_highlights ~base_dir ~file_path ~line : Yojson.Safe.t list =
  let matching = annotations_at_line ~base_dir ~file_path ~line in
  if matching = [] then []
  else
    let goal_ids = List.filter_map (fun (a : annotation) -> a.goal_id) matching in
    let task_ids = List.filter_map (fun (a : annotation) -> a.task_id) matching in
    let all = Cache.get ~base_dir ~file_path in
    let related = List.filter (fun (a : annotation) ->
      (match a.goal_id with Some g -> List.mem g goal_ids | None -> false)
      || (match a.task_id with Some t -> List.mem t task_ids | None -> false)
    ) all in
    List.map (fun (a : annotation) ->
      `Assoc [
        ("range", `Assoc [
          ("start", `Assoc [("line", `Int (a.line_start - 1)); ("character", `Int 0)]);
          ("end", `Assoc [("line", `Int (a.line_end - 1)); ("character", `Int 0)]);
        ]);
        ("kind", `Int 2);
      ]
    ) related
