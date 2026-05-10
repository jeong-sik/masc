(** LSP Overlay Provider — inject MASC annotations into LSP protocol responses.

    Converts MASC annotations (comments, decisions, questions, bookmarks)
    into LSP CodeLens entries. Provides diagnostic merging and inlay hints
    for goal/task bindings. *)

open Ide_annotation_types

module Cache = struct
  let tbl : (string, annotation list) Hashtbl.t = Hashtbl.create 32

  let key ~base_dir ~file_path = base_dir ^ "/" ^ file_path

  let get ~base_dir ~file_path =
    let k = key ~base_dir ~file_path in
    match Hashtbl.find_opt tbl k with
    | Some annotations -> annotations
    | None ->
      let filter : annotation_filter =
        { file_path = Some file_path; keeper_id = None; goal_id = None; task_id = None }
      in
      let annotations = Ide_annotations.list ~base_dir ~filter in
      Hashtbl.replace tbl k annotations;
      annotations

  let invalidate ~base_dir ~file_path =
    Hashtbl.remove tbl (key ~base_dir ~file_path)

  let clear () = Hashtbl.clear tbl
end

(** LSP CodeLens entry as JSON. *)
let codelens_to_json (a : annotation) : Yojson.Safe.t =
  let range =
    `Assoc [
      ("start", `Assoc [("line", `Int (a.line_start - 1)); ("character", `Int 0)]);
      ("end", `Assoc [("line", `Int (a.line_end - 1)); ("character", `Int 0)]);
    ]
  in
  let kind_label = show_annotation_kind a.kind in
  let title =
    match a.goal_id with
    | Some g -> Printf.sprintf "[%s] %s (%s)" kind_label a.content g
    | None -> Printf.sprintf "[%s] %s" kind_label a.content
  in
  `Assoc [
    ("range", range);
    ("command", `Assoc [
      ("title", `String title);
      ("command", `String "masc.showAnnotation");
      ("arguments", `List [annotation_to_json a]);
    ]);
  ]

(** LSP InlayHint entry — shows goal/task binding inline. *)
let inlay_hint_to_json (a : annotation) : Yojson.Safe.t =
  let label =
    match (a.goal_id, a.task_id) with
    | Some g, Some t -> Printf.sprintf "goal:%s task:%s" g t
    | Some g, None -> Printf.sprintf "goal:%s" g
    | None, Some t -> Printf.sprintf "task:%s" t
    | None, None -> Printf.sprintf "[%s]" (show_annotation_kind a.kind)
  in
  `Assoc [
    ("position", `Assoc [("line", `Int (a.line_start - 1)); ("character", `Int 0)]);
    ("label", `String label);
    ("tooltip", `String a.content);
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
    Only annotations with goal_id or task_id bindings produce hints. *)
let inlay_hints ~base_dir ~file_path : Yojson.Safe.t list =
  let annotations = Cache.get ~base_dir ~file_path in
  List.filter_map (fun (a : annotation) ->
    if a.goal_id <> None || a.task_id <> None then
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
          ("message", `String a.content);
        ])
    | Decision | Bookmark | Comment -> None
  ) annotations in
  lsp_diagnostics @ masc_diags

let invalidate_cache ~base_dir ~file_path = Cache.invalidate ~base_dir ~file_path

let clear_cache () = Cache.clear ()
