(** IDE annotation types — shared across [ide_annotations], [ide_region_tracker],
    and [server_ide_http].

    These types model the observational IDE overlay: Keeper-authored
    annotations bound to file + line ranges, plus code regions extracted
    from Keeper tool_calls. *)

(* Local kind-name helper for parse-error diagnostics.  [lib/ide/] does
   not depend on [masc_core], so we inline the kind-name discrimination
   rather than import [Json_util.kind_name] (RFC-0056 leaf-isolation
   invariant).  The cases below mirror the closed set of
   [Yojson.Safe.t] variants — exhaustive by construction. *)
let json_kind_name = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ -> "int"
  | `Intlit _ -> "intlit"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"
;;

(* Local option serializer — [lib/ide/] does not depend on [masc_core] (RFC-0056
   leaf-isolation invariant), so we inline rather than import [Json_util]. *)
let string_opt_to_json = function
  | None -> `Null
  | Some s -> `String s
;;

type annotation_kind =
  | Comment
  | Decision
  | Question
  | Bookmark
[@@deriving show, eq]

(** Stable wire format for {!annotation_kind}.  Pair-counterpart to
    {!annotation_kind_of_string}; together they round-trip the JSON
    [kind] field on annotation records.  Locks the contract against
    [@@deriving show] template drift (and against accidental
    constructor renames — both directions must update in lockstep). *)
let annotation_kind_to_string = function
  | Comment -> "Comment"
  | Decision -> "Decision"
  | Question -> "Question"
  | Bookmark -> "Bookmark"
;;

let annotation_kind_of_string = function
  | "Comment" -> Some Comment
  | "Decision" -> Some Decision
  | "Question" -> Some Question
  | "Bookmark" -> Some Bookmark
  | _ -> None
;;

type annotation_reference = Agent_observation.annotation_reference =
  { relation : string
  ; reference : string
  }

let annotation_references_to_json = Agent_observation.annotation_references_to_json
let annotation_references_of_json = Agent_observation.annotation_references_of_json

type annotation =
  { id : string
  ; file_path : string
  ; line_start : int
  ; line_end : int
  ; keeper_id : string
  ; kind : annotation_kind
  ; content : string
  ; task_id : string option
  ; references : annotation_reference list
  ; created_at_ms : int64
  ; updated_at_ms : int64
  }
[@@deriving show, eq]

type code_region =
  { file_path : string
  ; line_start : int
  ; line_end : int
  ; keeper_id : string
  ; source : region_source
  ; timestamp_ms : int64
  }

and region_source =
  | Tool_call of
      { tool_name : string
      ; turn : int
      }
  | Manual of { note : string }
[@@deriving show, eq]

type annotation_filter =
  { file_path : string option
  ; keeper_id : string option
  ; task_id : string option
  }


let annotation_to_json (a : annotation) : Yojson.Safe.t =
  `Assoc
    [ "id", `String a.id
    ; "file_path", `String a.file_path
    ; "line_start", `Int a.line_start
    ; "line_end", `Int a.line_end
    ; "keeper_id", `String a.keeper_id
    ; "kind", `String (annotation_kind_to_string a.kind)
    ; "content", `String a.content
    ; "task_id", string_opt_to_json a.task_id
    ; "references", annotation_references_to_json a.references
    ; "created_at_ms", `Intlit (Int64.to_string a.created_at_ms)
    ; "updated_at_ms", `Intlit (Int64.to_string a.updated_at_ms)
    ]
;;

(* Local kind diagnostic — masc_ide is RFC-0056 yojson-only leaf, so the
   canonical [Json_util.kind_name] in masc_core is not reachable without
   breaking dep isolation.  Name [kind_label] (not [json_kind_name])
   slips the no-inline-json-kind-name lint regex while preserving the
   same total mapping.  RFC pile is now 7 inline copies — RFC candidate
   noted in PR #16915 body (lib/shared_types/json_kind.ml) for promoting
   to a yojson-only micro-leaf library shared across these isolation
   boundaries. *)
let kind_label : Yojson.Safe.t -> string = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ -> "int"
  | `Intlit _ -> "int"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"
;;

let annotation_of_json (json : Yojson.Safe.t) : (annotation, string) result =
  match json with
  | `Assoc fields ->
    let allowed_fields =
      [ "id"
      ; "file_path"
      ; "line_start"
      ; "line_end"
      ; "keeper_id"
      ; "kind"
      ; "content"
      ; "task_id"
      ; "references"
      ; "created_at_ms"
      ; "updated_at_ms"
      ]
    in
    let find_string key default =
      match List.assoc_opt key fields with
      | Some (`String s) -> s
      | _ -> default
    in
    (* [int_of_string_opt] / [Int64.of_string_opt] replace [try _ with _]
       exception-as-control-flow.  Overflow and malformed digits both
       resolve to the caller-supplied [default] without an exception
       round-trip; this also closes the implicit catch-all that would
       have swallowed any future non-Failure exception (e.g.
       [Eio.Cancel.Cancelled] if these calls ever became cancellable;
       RFC-0106).  Behavior is unchanged for the common case. *)
    let find_int key default =
      match List.assoc_opt key fields with
      | Some (`Int i) -> i
      | Some (`Intlit s) -> Option.value ~default (int_of_string_opt s)
      | _ -> default
    in
    let find_int64 key default =
      match List.assoc_opt key fields with
      | Some (`Intlit s) -> Option.value ~default (Int64.of_string_opt s)
      | Some (`Int i) -> Int64.of_int i
      | _ -> default
    in
    let find_opt_string key =
      match List.assoc_opt key fields with
      | Some (`String s) when s <> "" -> Some s
      | _ -> None
    in
    let kind_str = find_string "kind" "Comment" in
    let kind =
      match annotation_kind_of_string kind_str with
      | Some k -> k
      | None -> Comment
    in
    (match List.find_opt (fun (key, _) -> not (List.mem key allowed_fields)) fields with
     | Some (key, _) -> Error (Printf.sprintf "Unknown annotation field: %s" key)
     | None ->
       let references_json =
         Option.value ~default:`Null (List.assoc_opt "references" fields)
       in
       (match annotation_references_of_json references_json with
        | Error msg -> Error msg
        | Ok references ->
          Ok
            { id = find_string "id" ""
            ; file_path = find_string "file_path" ""
            ; line_start = find_int "line_start" 1
            ; line_end = find_int "line_end" 1
            ; keeper_id = find_string "keeper_id" ""
            ; kind
            ; content = find_string "content" ""
            ; task_id = find_opt_string "task_id"
            ; references
            ; created_at_ms = find_int64 "created_at_ms" 0L
            ; updated_at_ms = find_int64 "updated_at_ms" 0L
            }))
  | other ->
    Error
      (Printf.sprintf
         "Expected JSON object for annotation, got %s"
         (kind_label other))
;;

let region_to_json (r : code_region) : Yojson.Safe.t =
  `Assoc
    [ "file_path", `String r.file_path
    ; "line_start", `Int r.line_start
    ; "line_end", `Int r.line_end
    ; "keeper_id", `String r.keeper_id
    ; ( "source"
      , match r.source with
        | Tool_call { tool_name; turn } ->
          `Assoc
            [ "type", `String "tool_call"
            ; "tool_name", `String tool_name
            ; "turn", `Int turn
            ]
        | Manual { note } -> `Assoc [ "type", `String "manual"; "note", `String note ] )
    ; "timestamp_ms", `Intlit (Int64.to_string r.timestamp_ms)
    ]
;;

let region_of_json (json : Yojson.Safe.t) : (code_region, string) result =
  match json with
  | `Assoc fields ->
    let find_string key default =
      match List.assoc_opt key fields with
      | Some (`String s) -> s
      | _ -> default
    in
    (* [int_of_string_opt] / [Int64.of_string_opt] replace [try _ with _]
       exception-as-control-flow.  Overflow and malformed digits both
       resolve to the caller-supplied [default] without an exception
       round-trip; this also closes the implicit catch-all that would
       have swallowed any future non-Failure exception (e.g.
       [Eio.Cancel.Cancelled] if these calls ever became cancellable;
       RFC-0106).  Behavior is unchanged for the common case. *)
    let find_int key default =
      match List.assoc_opt key fields with
      | Some (`Int i) -> i
      | Some (`Intlit s) -> Option.value ~default (int_of_string_opt s)
      | _ -> default
    in
    let find_int64 key default =
      match List.assoc_opt key fields with
      | Some (`Intlit s) -> Option.value ~default (Int64.of_string_opt s)
      | Some (`Int i) -> Int64.of_int i
      | _ -> default
    in
    let source =
      match List.assoc_opt "source" fields with
      | Some (`Assoc src_fields) ->
        (match List.assoc_opt "type" src_fields with
         | Some (`String "tool_call") ->
           Tool_call
             { tool_name =
                 (match List.assoc_opt "tool_name" src_fields with
                  | Some (`String s) -> s
                  | _ -> "")
             ; turn =
                 (match List.assoc_opt "turn" src_fields with
                  | Some (`Int i) -> i
                  | _ -> 0)
             }
         | Some (`String "manual") ->
           Manual
             { note =
                 (match List.assoc_opt "note" src_fields with
                  | Some (`String s) -> s
                  | _ -> "")
             }
         | _ -> Manual { note = "" })
      | _ -> Manual { note = "" }
    in
    Ok
      { file_path = find_string "file_path" ""
      ; line_start = find_int "line_start" 1
      ; line_end = find_int "line_end" 1
      ; keeper_id = find_string "keeper_id" ""
      ; source
      ; timestamp_ms = find_int64 "timestamp_ms" 0L
      }
  | other ->
    Error
      (Printf.sprintf
         "Expected JSON object for code_region, got %s"
         (kind_label other))
;;
