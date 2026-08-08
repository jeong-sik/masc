open Runtime
open Result_syntax

type descriptor = Runtime.artifact

let extension_of_kind kind =
  match String.lowercase_ascii (String.trim kind) with
  | "markdown" | "md" -> "md"
  | "json" -> "json"
  | "html" -> "html"
  | "csv" -> "csv"
  | "text" | "txt" | "" -> "txt"
  | other -> other
;;

let mime_type_of_kind kind =
  match String.lowercase_ascii (String.trim kind) with
  | "markdown" | "md" -> "text/markdown"
  | "json" -> "application/json"
  | "html" -> "text/html"
  | "csv" -> "text/csv"
  | "text" | "txt" | "" -> "text/plain"
  | unknown_kind ->
    let _unknown_kind = unknown_kind in
    "application/octet-stream"
;;

let generate_artifact_id () =
  Llm_provider.Random_id.create ()
  |> Result.map (fun id -> "art-" ^ id)
  |> Result.map_error (fun detail -> Error.Internal ("artifact ID: " ^ detail))
;;

let make_store ?session_root () = Runtime_store.create ?root:session_root ()

let save_text_internal store ~session_id ~name ~kind ~content =
  let%bind artifact_id = generate_artifact_id () in
  let extension = extension_of_kind kind in
  let path =
    Filename.concat
      (Runtime_store.artifacts_dir store session_id)
      (Printf.sprintf "%s.%s" artifact_id extension)
  in
  let%bind () = Runtime_store.ensure_tree store session_id in
  let%bind () = Runtime_store.save_text path content in
  Let_syntax.return
    { artifact_id
    ; name
    ; kind
    ; mime_type = mime_type_of_kind kind
    ; path = Some path
    ; inline_content = None
    ; size_bytes = String.length content
    ; created_at = Unix.gettimeofday ()
    }
;;

let persisted_path (artifact : descriptor) =
  match artifact.path with
  | Some path -> Ok path
  | None ->
    Error
      (Error.Io
         (FileOpFailed
            { op = "persisted_path"
            ; path = artifact.artifact_id
            ; detail =
                Printf.sprintf
                  "Artifact %S (%s) has no persisted file path"
                  artifact.name
                  artifact.artifact_id
            }))
;;

let overwrite_text_internal artifact ~content =
  let%bind path = persisted_path artifact in
  Runtime_store.save_text path content
;;

let list ?session_root ~session_id () =
  let%bind store = make_store ?session_root () in
  let%bind session = Runtime_store.load_session store session_id in
  Let_syntax.return session.artifacts
;;

let find_descriptor ?session_root ~session_id ~artifact_id () =
  let%bind artifacts = list ?session_root ~session_id () in
  match
    List.find_opt
      (fun (artifact : descriptor) -> String.equal artifact.artifact_id artifact_id)
      artifacts
  with
  | Some artifact -> Ok artifact
  | None ->
    Error
      (Error.Io
         (FileOpFailed
            { op = "read"
            ; path = artifact_id
            ; detail = Printf.sprintf "Artifact not found in session %s" session_id
            }))
;;

let get_text ?session_root ~session_id ~artifact_id () =
  let%bind artifact = find_descriptor ?session_root ~session_id ~artifact_id () in
  match artifact.inline_content, artifact.path with
  | Some content, _ -> Ok content
  | None, Some path -> Runtime_store.load_text path
  | None, None ->
    Error
      (Error.Io
         (FileOpFailed
            { op = "read"
            ; path = artifact_id
            ; detail = "Artifact has neither inline content nor persisted path"
            }))
;;
