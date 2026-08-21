(** Typed evidence reference with optional provenance relation.
    
    Wire format (backward-compatible):
    - "artifact:path"          → Artifact { path; relation = Depend_on_implicit; context = None }
    - "note:text"              → Note text
    - "artifact:path:relation" → Artifact { path; relation; context = None }
    - "artifact:path:relation:context" → Artifact { path; relation; context = Some context }

    New typed refs can be serialized back to the wire format and stored
    in the existing [string list evidence_refs] field without breaking
    any consumer that reads raw strings. *)

type relation =
  | Depend_on_implicit
  | Depend_on of string
  | Implements of string
  | Tests of string
  | Fixes of string
  | Documents of string
  | Custom of string

type t =
  | Artifact of { path : string; relation : relation; context : string option }
  | Note of string

let relation_of_string = function
  | "depend-on:implicit" -> Depend_on_implicit
  | s when String.starts_with ~prefix:"depend-on:" s ->
    Depend_on (String.sub s 11 (String.length s - 11))
  | s when String.starts_with ~prefix:"implements:" s ->
    Implements (String.sub s 11 (String.length s - 11))
  | s when String.starts_with ~prefix:"tests:" s ->
    Tests (String.sub s 6 (String.length s - 6))
  | s when String.starts_with ~prefix:"fixes:" s ->
    Fixes (String.sub s 6 (String.length s - 6))
  | s when String.starts_with ~prefix:"documents:" s ->
    Documents (String.sub s 10 (String.length s - 10))
  | s -> Custom s

let relation_to_string = function
  | Depend_on_implicit -> "depend-on:implicit"
  | Depend_on s -> "depend-on:" ^ s
  | Implements s -> "implements:" ^ s
  | Tests s -> "tests:" ^ s
  | Fixes s -> "fixes:" ^ s
  | Documents s -> "documents:" ^ s
  | Custom s -> s

(** Parse a raw evidence reference string into a typed [t].
    Returns [None] for unrecognized formats (fail-open). *)
let parse (raw : string) : t option =
  let trimmed = String.trim raw in
  if trimmed = "" then None
  else if String.starts_with ~prefix:"artifact:" trimmed then begin
    let body = String.sub trimmed 9 (String.length trimmed - 9) in
    (* Try to extract :relation:context suffix *)
    match String.rindex_opt body ':' with
    | None ->
      (* "artifact:path" — no relation *)
      Some (Artifact { path = body; relation = Depend_on_implicit; context = None })
    | Some last_colon ->
      let path_prefix = String.sub body 0 last_colon in
      let suffix = String.sub body (last_colon + 1) (String.length body - last_colon - 1) in
      if String.starts_with ~prefix:"/" suffix || suffix = "" || String.length suffix > 64 then begin
        (* suffix looks like a path continuation, not a relation — no relation *)
        Some (Artifact { path = body; relation = Depend_on_implicit; context = None })
      end else begin
        (* Check for :context after relation *)
        match String.rindex_opt path_prefix ':' with
        | None ->
          (* "artifact:path:relation" *)
          Some (Artifact { path = path_prefix; relation = relation_of_string suffix; context = None })
        | Some prev_colon ->
          let base_path = String.sub path_prefix 0 prev_colon in
          let rel_str = String.sub path_prefix (prev_colon + 1) (String.length path_prefix - prev_colon - 1) in
          if String.length rel_str > 64 || String.length base_path = 0 then
            (* relation too long or empty base path — treat whole thing as path *)
            Some (Artifact { path = body; relation = Depend_on_implicit; context = None })
          else
            (* "artifact:path:relation:context" *)
            Some (Artifact { path = base_path; relation = relation_of_string rel_str; context = Some suffix })
      end
  end
  else if String.starts_with ~prefix:"note:" trimmed then
    Some (Note (String.sub trimmed 5 (String.length trimmed - 5)))
  else
    (* Unknown prefix — pass through as note for backward compat *)
    None

(** Serialize a typed [t] back to wire format. *)
let to_string = function
  | Note text -> "note:" ^ text
  | Artifact { path; relation; context } ->
    let rel = relation_to_string relation in
    match context with
    | None -> Printf.sprintf "artifact:%s:%s" path rel
    | Some ctx -> Printf.sprintf "artifact:%s:%s:%s" path rel ctx

(** Parse all evidence refs, returning typed and unrecognized separately. *)
let parse_list (raws : string list) : (t list * string list) =
  List.fold_left (fun (typed, unrecognized) raw ->
    match parse raw with
    | Some t -> (t :: typed, unrecognized)
    | None -> (typed, raw :: unrecognized)
  ) ([], []) raws

(** Check if a parsed ref has an explicit relation (not implicit). *)
let has_explicit_relation = function
  | Note _ -> false
  | Artifact { relation = Depend_on_implicit; _ } -> false
  | Artifact { relation = Depend_on _; _ }
  | Artifact { relation = Implements _; _ }
  | Artifact { relation = Tests _; _ }
  | Artifact { relation = Fixes _; _ }
  | Artifact { relation = Documents _; _ }
  | Artifact { relation = Custom _; _ } -> true
