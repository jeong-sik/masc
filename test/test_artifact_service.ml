(** Unit tests for Artifact_service — kind/mime coercion and persisted
    artifact descriptor behavior. *)

open Agent_sdk
open Alcotest

let with_temp_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "oas-artifact-service-%d-%06x"
         (Unix.getpid ())
         (Random.int 0xFFFFFF))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" dir)))
    (fun () -> f dir)
;;

let mk_session ?(artifacts = []) session_id : Runtime.session =
  { session_id
  ; goal = "artifact coverage"
  ; title = Some "Artifact coverage"
  ; tag = Some "test"
  ; phase = Runtime.Running
  ; created_at = 1.0
  ; updated_at = 2.0
  ; provider = None
  ; model = None
  ; system_prompt = None
  ; workdir = None
  ; planned_participants = []
  ; participants = []
  ; artifacts
  ; pending_input = None
  ; turn_count = 0
  ; last_seq = 0
  ; outcome = None
  }
;;

let unwrap_result = function
  | Ok value -> value
  | Error e -> fail (Error.to_string e)
;;

let is_lower_hex = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false
;;

(* ── extension_of_kind ────────────────────────────────── *)

let test_ext_markdown () =
  check string "markdown" "md" (Artifact_service.extension_of_kind "markdown")
;;

let test_ext_md_alias () =
  check string "md alias" "md" (Artifact_service.extension_of_kind "md")
;;

let test_ext_json () =
  check string "json" "json" (Artifact_service.extension_of_kind "json")
;;

let test_ext_html () =
  check string "html" "html" (Artifact_service.extension_of_kind "html")
;;

let test_ext_csv () = check string "csv" "csv" (Artifact_service.extension_of_kind "csv")

let test_ext_text_alias () =
  check string "text → txt" "txt" (Artifact_service.extension_of_kind "text")
;;

let test_ext_txt () = check string "txt" "txt" (Artifact_service.extension_of_kind "txt")

let test_ext_empty_defaults_txt () =
  check string "empty → txt" "txt" (Artifact_service.extension_of_kind "")
;;

let test_ext_unknown_passthrough () =
  (* implementation: unknown kinds pass through after lowercasing+trimming *)
  check
    string
    "unknown kind passes through"
    "yaml"
    (Artifact_service.extension_of_kind "yaml")
;;

let test_ext_uppercase () =
  check string "uppercase normalised" "json" (Artifact_service.extension_of_kind "JSON")
;;

let test_ext_whitespace () =
  check string "trimmed" "md" (Artifact_service.extension_of_kind "  md  ")
;;

(* ── mime_type_of_kind ────────────────────────────────── *)

let test_mime_markdown () =
  check string "md" "text/markdown" (Artifact_service.mime_type_of_kind "markdown")
;;

let test_mime_md_alias () =
  check string "md alias" "text/markdown" (Artifact_service.mime_type_of_kind "md")
;;

let test_mime_json () =
  check string "json" "application/json" (Artifact_service.mime_type_of_kind "json")
;;

let test_mime_html () =
  check string "html" "text/html" (Artifact_service.mime_type_of_kind "html")
;;

let test_mime_csv () =
  check string "csv" "text/csv" (Artifact_service.mime_type_of_kind "csv")
;;

let test_mime_text_alias () =
  check string "text" "text/plain" (Artifact_service.mime_type_of_kind "text")
;;

let test_mime_txt () =
  check string "txt" "text/plain" (Artifact_service.mime_type_of_kind "txt")
;;

let test_mime_empty_defaults () =
  check string "empty → text/plain" "text/plain" (Artifact_service.mime_type_of_kind "")
;;

let test_mime_unknown_falls_back () =
  check
    string
    "unknown → octet-stream"
    "application/octet-stream"
    (Artifact_service.mime_type_of_kind "yaml")
;;

let test_mime_uppercase () =
  check
    string
    "JSON normalised"
    "application/json"
    (Artifact_service.mime_type_of_kind "JSON")
;;

let test_mime_whitespace () =
  check
    string
    "trimmed"
    "text/markdown"
    (Artifact_service.mime_type_of_kind "  markdown  ")
;;

(* ── consistency: kind→ext and kind→mime cohere ───────── *)

let test_consistency_table () =
  List.iter
    (fun (kind, ext, mime) ->
       check string ("ext for " ^ kind) ext (Artifact_service.extension_of_kind kind);
       check string ("mime for " ^ kind) mime (Artifact_service.mime_type_of_kind kind))
    [ "markdown", "md", "text/markdown"
    ; "json", "json", "application/json"
    ; "html", "html", "text/html"
    ; "csv", "csv", "text/csv"
    ; "text", "txt", "text/plain"
    ]
;;

(* ── persisted artifacts ───────────────────────────────── *)

let test_save_text_internal_persists_descriptor () =
  with_temp_dir (fun root ->
    let store = unwrap_result (Runtime_store.create ~root ()) in
    let artifact =
      unwrap_result
        (Artifact_service.save_text_internal
           store
           ~session_id:"sess-art"
           ~name:" Report / One "
           ~kind:"markdown"
           ~content:"# report\n")
    in
    check int "artifact ID length" 36 (String.length artifact.artifact_id);
    check string "artifact ID prefix" "art-" (String.sub artifact.artifact_id 0 4);
    check
      bool
      "artifact ID suffix is lowercase hex"
      true
      (String.sub artifact.artifact_id 4 32 |> String.for_all is_lower_hex);
    check
      bool
      "artifact name is not encoded into ID"
      false
      (String.ends_with ~suffix:"Report___One" artifact.artifact_id);
    check string "name preserved" " Report / One " artifact.name;
    check string "kind preserved" "markdown" artifact.kind;
    check string "mime" "text/markdown" artifact.mime_type;
    check int "size" 9 artifact.size_bytes;
    (match artifact.path with
     | Some path ->
       check bool "sanitized filename" true (String.ends_with ~suffix:".md" path);
       check string "content" "# report\n" (unwrap_result (Runtime_store.load_text path))
     | None -> fail "expected persisted path");
    check bool "inline is absent" true (Option.is_none artifact.inline_content))
;;

let test_persisted_path_rejects_inline_only_artifact () =
  let artifact : Runtime.artifact =
    { artifact_id = "inline-1"
    ; name = "inline"
    ; kind = "text"
    ; mime_type = "text/plain"
    ; path = None
    ; inline_content = Some "body"
    ; size_bytes = 4
    ; created_at = 1.0
    }
  in
  match Artifact_service.persisted_path artifact with
  | Ok _ -> fail "expected inline-only artifact to fail persisted_path"
  | Error _ -> ()
;;

let test_overwrite_text_internal_updates_persisted_file () =
  with_temp_dir (fun root ->
    let store = unwrap_result (Runtime_store.create ~root ()) in
    let artifact =
      unwrap_result
        (Artifact_service.save_text_internal
           store
           ~session_id:"sess-overwrite"
           ~name:"notes"
           ~kind:"txt"
           ~content:"old")
    in
    unwrap_result (Artifact_service.overwrite_text_internal artifact ~content:"new");
    let path = unwrap_result (Artifact_service.persisted_path artifact) in
    check string "updated" "new" (unwrap_result (Runtime_store.load_text path)))
;;

let test_list_and_get_text_read_session_artifacts () =
  with_temp_dir (fun root ->
    let store = unwrap_result (Runtime_store.create ~root ()) in
    let persisted =
      unwrap_result
        (Artifact_service.save_text_internal
           store
           ~session_id:"sess-list"
           ~name:"persisted"
           ~kind:"json"
           ~content:{|{"ok":true}|})
    in
    let inline : Runtime.artifact =
      { artifact_id = "inline-art"
      ; name = "inline"
      ; kind = "text"
      ; mime_type = "text/plain"
      ; path = None
      ; inline_content = Some "inline body"
      ; size_bytes = 11
      ; created_at = 3.0
      }
    in
    unwrap_result
      (Runtime_store.save_session
         store
         (mk_session ~artifacts:[ persisted; inline ] "sess-list"));
    let listed =
      unwrap_result (Artifact_service.list ~session_root:root ~session_id:"sess-list" ())
    in
    check int "two artifacts" 2 (List.length listed);
    check
      string
      "persisted content"
      {|{"ok":true}|}
      (unwrap_result
         (Artifact_service.get_text
            ~session_root:root
            ~session_id:"sess-list"
            ~artifact_id:persisted.artifact_id
            ()));
    check
      string
      "inline content"
      "inline body"
      (unwrap_result
         (Artifact_service.get_text
            ~session_root:root
            ~session_id:"sess-list"
            ~artifact_id:inline.artifact_id
            ())))
;;

let test_get_text_reports_missing_or_unreadable_artifact () =
  with_temp_dir (fun root ->
    let store = unwrap_result (Runtime_store.create ~root ()) in
    let missing_path_artifact : Runtime.artifact =
      { artifact_id = "missing-path"
      ; name = "missing"
      ; kind = "text"
      ; mime_type = "text/plain"
      ; path = None
      ; inline_content = None
      ; size_bytes = 0
      ; created_at = 1.0
      }
    in
    unwrap_result
      (Runtime_store.save_session
         store
         (mk_session ~artifacts:[ missing_path_artifact ] "sess-errors"));
    (match
       Artifact_service.get_text
         ~session_root:root
         ~session_id:"sess-errors"
         ~artifact_id:"absent"
         ()
     with
     | Ok _ -> fail "expected missing artifact error"
     | Error _ -> ());
    match
      Artifact_service.get_text
        ~session_root:root
        ~session_id:"sess-errors"
        ~artifact_id:"missing-path"
        ()
    with
    | Ok _ -> fail "expected no content/path error"
    | Error _ -> ())
;;

let () =
  run
    "Artifact_service"
    [ ( "extension_of_kind"
      , [ test_case "markdown" `Quick test_ext_markdown
        ; test_case "md alias" `Quick test_ext_md_alias
        ; test_case "json" `Quick test_ext_json
        ; test_case "html" `Quick test_ext_html
        ; test_case "csv" `Quick test_ext_csv
        ; test_case "text alias" `Quick test_ext_text_alias
        ; test_case "txt" `Quick test_ext_txt
        ; test_case "empty → txt" `Quick test_ext_empty_defaults_txt
        ; test_case "unknown passes" `Quick test_ext_unknown_passthrough
        ; test_case "uppercase" `Quick test_ext_uppercase
        ; test_case "whitespace trimmed" `Quick test_ext_whitespace
        ] )
    ; ( "mime_type_of_kind"
      , [ test_case "markdown" `Quick test_mime_markdown
        ; test_case "md alias" `Quick test_mime_md_alias
        ; test_case "json" `Quick test_mime_json
        ; test_case "html" `Quick test_mime_html
        ; test_case "csv" `Quick test_mime_csv
        ; test_case "text alias" `Quick test_mime_text_alias
        ; test_case "txt" `Quick test_mime_txt
        ; test_case "empty → text/plain" `Quick test_mime_empty_defaults
        ; test_case "unknown → octet-stream" `Quick test_mime_unknown_falls_back
        ; test_case "uppercase" `Quick test_mime_uppercase
        ; test_case "whitespace trimmed" `Quick test_mime_whitespace
        ] )
    ; "consistency", [ test_case "kind table" `Quick test_consistency_table ]
    ; ( "persisted"
      , [ test_case
            "save_text_internal persists descriptor"
            `Quick
            test_save_text_internal_persists_descriptor
        ; test_case
            "persisted_path rejects inline only"
            `Quick
            test_persisted_path_rejects_inline_only_artifact
        ; test_case
            "overwrite_text_internal updates file"
            `Quick
            test_overwrite_text_internal_updates_persisted_file
        ; test_case
            "list and get_text"
            `Quick
            test_list_and_get_text_read_session_artifacts
        ; test_case
            "get_text error paths"
            `Quick
            test_get_text_reports_missing_or_unreadable_artifact
        ] )
    ]
;;
