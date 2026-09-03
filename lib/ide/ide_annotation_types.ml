(** IDE annotation types — shared across [ide_annotations] and
    [server_ide_http].

    These types model the observational IDE overlay: Keeper-authored
    annotations bound to file + line ranges. *)

(* Local option serializer — [lib/ide/] does not depend on [masc_core] (RFC-0056
   leaf-isolation invariant), so we inline rather than import [Json_util]. *)
let string_opt_to_json = function
  | None -> `Null
  | Some s -> `String s
;;

(* Equality re-declaration of the observation bus's kind, same pattern as
   {!annotation_reference} below: one variant, one codec, and the compiler
   proves every consumer against the single axis. This module used to carry
   its own copy of the type plus both codecs, which forced a hand-written
   4-arm converter at the ide_bridge boundary — three artifacts that had to
   move in lockstep with the bus on every new kind. *)
type annotation_kind =
  Agent_observation.annotation_kind =
  | Comment
  | Decision
  | Question
  | Bookmark
[@@deriving show, eq]

let annotation_kind_to_string = Agent_observation.annotation_kind_to_string
let annotation_kind_of_string = Agent_observation.annotation_kind_of_string

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
  ; goal_id : string option
  ; task_id : string option
  ; references : annotation_reference list
  ; created_at_ms : int64
  ; updated_at_ms : int64
  }
[@@deriving show, eq]

type annotation_filter =
  { file_path : string option
  ; keeper_id : string option
  ; goal_id : string option
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
    ; "goal_id", string_opt_to_json a.goal_id
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
(* The local copy is gone. It carried a comment explaining that its name
   was chosen to slip the lint counting these copies, and naming the pile
   [lib/shared_types/json_kind.ml] as the fix; that file exists now, and
   masc_ide reaches it without taking masc_core. *)
let kind_label = Shared_types.Json_kind.name
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
      ; "goal_id"
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
            ; goal_id = find_opt_string "goal_id"
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

