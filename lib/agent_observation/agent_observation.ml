(* RFC-0128 §4.1 neutral codebase slug derivation.

   Kept below the Keeper/IDE boundary so runtime producers can route
   observations without depending on the IDE storage module. *)
let strip_prefix ~prefix s =
  let n = String.length prefix in
  String.sub s n (String.length s - n)
;;

let strip_suffix ~suffix s =
  let ns = String.length s in
  let nf = String.length suffix in
  if ns >= nf && String.sub s (ns - nf) nf = suffix
  then String.sub s 0 (ns - nf)
  else s
;;

let split_host_path s =
  match String.index_opt s '/' with
  | None -> (s, "")
  | Some i ->
    let host = String.sub s 0 i in
    let path = String.sub s (i + 1) (String.length s - i - 1) in
    (host, path)
;;

let normalize_scp_like s =
  match String.index_opt s '@' with
  | None -> s
  | Some at ->
    let after = String.sub s (at + 1) (String.length s - at - 1) in
    (match String.index_opt after ':' with
     | None -> s
     | Some colon ->
       (match String.index_opt after '/' with
        | Some slash when slash < colon -> s
        | _ ->
          let host = String.sub after 0 colon in
          let path = String.sub after (colon + 1) (String.length after - colon - 1) in
          host ^ "/" ^ path))
;;

let strip_scheme s =
  let candidates = [ "https://"; "http://"; "ssh://"; "git://" ] in
  match List.find_opt (fun p -> String.starts_with ~prefix:p s) candidates with
  | Some p -> strip_prefix ~prefix:p s
  | None -> s
;;

let strip_userinfo s =
  match String.index_opt s '@' with
  | None -> s
  | Some at ->
    (match String.index_opt s '/' with
     | Some slash when slash < at -> s
     | _ -> String.sub s (at + 1) (String.length s - at - 1))
;;

let is_slug_char c =
  (c >= 'a' && c <= 'z')
  || (c >= '0' && c <= '9')
  || c = '_'
  || c = '-'
  || c = '.'
;;

let path_segment_to_slug seg =
  if seg = "" then None
  else if String.equal seg "." then None
  else if String.length seg >= 2 && String.sub seg 0 2 = ".."
  then None
  else if String.for_all is_slug_char seg
  then Some seg
  else None
;;

let canonical_url_of_remote raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None
  else
    let s = String.lowercase_ascii trimmed in
    let s = normalize_scp_like s in
    let s = strip_scheme s in
    let s = strip_userinfo s in
    let host, path = split_host_path s in
    if host = "" || path = "" then None
    else
      let path = strip_suffix ~suffix:".git" path in
      let segments =
        String.split_on_char '/' path |> List.filter (fun seg -> seg <> "")
      in
      if segments = [] then None
      else
        match path_segment_to_slug host with
        | None -> None
        | Some host_slug ->
          let rec collect acc = function
            | [] -> Some (List.rev acc)
            | seg :: rest ->
              (match path_segment_to_slug seg with
               | None -> None
               | Some s -> collect (s :: acc) rest)
          in
          (match collect [] segments with
           | None -> None
           | Some segs -> Some (String.concat "_" (host_slug :: segs)))
;;

(* RFC-0378 §5.1: a code fact's address, minted once where the write is
   attributed and carried as a parsed value from then on. Consumers never
   re-derive either half from tool input or store layout — [v] is the only
   way in, and it rejects every shape the per-codebase store cannot join on
   instead of repairing it. *)
module Code_address = struct
  type t =
    { codebase : string
    ; path : string
    }

  type invalid =
    | Empty_codebase
    | Malformed_codebase
    | Empty_path
    | Absolute_path
    | Malformed_path
    | Unnormalized_path

  let invalid_to_string = function
    | Empty_codebase -> "empty codebase slug"
    | Malformed_codebase ->
      "codebase is not a canonical host_path slug (e.g. example.com_owner_repo)"
    | Empty_path -> "empty repo-relative path"
    | Absolute_path -> "path is absolute, expected repo-root relative"
    | Malformed_path -> "path is not syntactically valid"
    | Unnormalized_path -> "path has ., .., or empty segments"
  ;;

  (* Same closed character set and leading-[..] guard as
     [path_segment_to_slug], so every slug [canonical_url_of_remote] can
     emit is accepted and nothing outside that alphabet is. Structure is
     part of the acceptance too: every canonical slug joins a host and at
     least one path segment with ['_'], so a bare host token is not an
     address. Live proof 2026-08-14: minutes after the RFC-0378 cut a
     bare-token scope probe passed this check and seeded a second store
     directory beside the canonical one. *)
  let valid_codebase slug =
    (* [canonical_url_of_remote] joins a non-empty host and at least one
       non-empty repository path segment with [_]. Requiring both the join
       marker and the shortest possible [a_b] shape keeps callers from
       inventing host-only partitions that the resolver can never emit. *)
    let joins =
      String.fold_left
        (fun count char -> if Char.equal char '_' then count + 1 else count)
        0
        slug
    in
    let single_join_suffix_is_dotdot =
      match String.index_opt slug '_' with
      | Some join when joins = 1 && String.length slug - join - 1 >= 2 ->
        String.sub slug (join + 1) 2 = ".."
      | Some _ | None -> false
    in
    let rec has_interior_join index =
      index < String.length slug - 1
      && (Char.equal slug.[index] '_' || has_interior_join (index + 1))
    in
    String.length slug >= 3
    && has_interior_join 1
    && not single_join_suffix_is_dotdot
    && not (String.length slug >= 2 && String.sub slug 0 2 = "..")
    && String.for_all is_slug_char slug
  ;;

  let v ~codebase ~path =
    if codebase = ""
    then Error Empty_codebase
    else if not (valid_codebase codebase)
    then Error Malformed_codebase
    else if path = ""
    then Error Empty_path
    else
      match Fpath.of_string path with
      | Error _ -> Error Malformed_path
      | Ok parsed ->
        if Fpath.is_abs parsed
        then Error Absolute_path
        else if
          not (String.equal path (Fpath.to_string parsed))
          || not (Fpath.equal parsed (Fpath.rem_empty_seg parsed))
          || List.exists Fpath.is_rel_seg (Fpath.segs parsed)
        then Error Unnormalized_path
        else Ok { codebase; path }
  ;;

  let codebase t = t.codebase
  let path t = t.path
  let equal a b = String.equal a.codebase b.codebase && String.equal a.path b.path
end

(* Typed reasons a write's file path failed attribution to a codebase.
   RFC-0378 §5.1: attribution failure is a fact kind, not a store
   location — the reason rides the fact as a queryable field.
   RFC-keeper-workspace-root-only 2a owns this vocabulary's evolution
   once attribution moves to git observation. *)
module Unattributed = struct
  type reason =
    | Blank_remote_url
    | Unparseable_remote_url of string
    | Unregistered_repo_id of string
    | Unregistered_path
    | Repository_catalog_unavailable
    | Unmintable of Code_address.invalid
      (* The repo and relative path were recovered but the address
         constructor rejected the residue. Reaching this is a resolver
         invariant break worth diagnosing, so the rejection is carried
         instead of being collapsed into another reason. *)

  let reason_to_string = function
    | Blank_remote_url -> "blank_remote_url"
    | Unparseable_remote_url _ -> "unparseable_remote_url"
    | Unregistered_repo_id _ -> "unregistered_repo_id"
    | Unregistered_path -> "unregistered_path"
    | Repository_catalog_unavailable -> "repository_catalog_unavailable"
    | Unmintable _ -> "unmintable_address"
  ;;
end

type addressed =
  { address : Code_address.t
  ; checkout : string option
    (* Projection metadata: which checkout the write was observed in.
       Never part of the join key. [None] until attribution measures it
       (workspace-root-only 2b). *)
  }

type unaddressed =
  { reason : Unattributed.reason
  ; attempted_path : string
    (* The path exactly as the resolver saw it — forensic identity for
       records that never joined a codebase. *)
  }

(* Where a fact that names a file belongs. An annotation or write region
   always names a file, so [Pathless] is unrepresentable for them. *)
type file_attribution =
  | Addressed of addressed
  | Unaddressed of unaddressed

(* Where any tool fact belongs: a pathless call is a keeper-timeline
   fact with no document — distinct from a failed attribution. *)
type attribution =
  | File of file_attribution
  | Pathless

type tool_event =
  { base_path : string
  ; attribution : attribution
    (* RFC-0378 §5.1: the address is minted where the write is attributed
       and carried as a parsed value. Producers must not hand consumers a
       raw tool argument — a consumer re-deriving the path from [input]
       produced three incompatible shapes in one store (masc#28582). *)
  ; tool_name : string
  ; keeper_id : string
  ; turn_id : string
  ; outcome : string
  ; typed_outcome : string
  ; duration_ms : float
  ; output_text : string
  ; input : Yojson.Safe.t
  }

type annotation_kind =
  | Comment
  | Decision
  | Question
  | Bookmark

let annotation_kind_to_string = function
  | Comment -> "Comment"
  | Decision -> "Decision"
  | Question -> "Question"
  | Bookmark -> "Bookmark"
;;

let all_annotation_kinds = [ Comment; Decision; Question; Bookmark ]

let valid_annotation_kind_strings =
  List.map annotation_kind_to_string all_annotation_kinds
;;

let annotation_kind_of_string = function
  | "Comment" -> Some Comment
  | "Decision" -> Some Decision
  | "Question" -> Some Question
  | "Bookmark" -> Some Bookmark
  | _ -> None
;;

type annotation_reference =
  { relation : string
  ; reference : string
  }

let annotation_reference_to_json reference =
  `Assoc
    [ "relation", `String reference.relation
    ; "reference", `String reference.reference
    ]
;;

let annotation_references_to_json references =
  `List (List.map annotation_reference_to_json references)
;;

let annotation_references_of_json = function
  | `Null -> Ok []
  | `List items ->
    let parse_one index = function
      | `Assoc fields ->
        let field_values key =
          List.filter_map
            (fun (candidate, value) -> if String.equal key candidate then Some value else None)
            fields
        in
        (match
           List.find_opt
             (fun (key, _) ->
                not (String.equal key "relation" || String.equal key "reference"))
             fields
         with
         | Some (key, _) ->
           Error (Printf.sprintf "references[%d] has unknown field: %s" index key)
         | None ->
           match field_values "relation", field_values "reference" with
         | [ `String relation ], [ `String reference ]
           when String.trim relation <> "" && String.trim reference <> "" ->
           Ok { relation; reference }
         | [ `String _ ], [ `String _ ] ->
           Error
             (Printf.sprintf
                "references[%d] relation and reference must be non-empty strings"
                index)
         | _ ->
           Error
             (Printf.sprintf
                "references[%d] requires string relation and reference fields"
                index))
      | _ -> Error (Printf.sprintf "references[%d] must be an object" index)
    in
    let rec loop index acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match parse_one index item with
         | Ok reference -> loop (index + 1) (reference :: acc) rest
         | Error _ as error -> error)
    in
    loop 0 [] items
  | _ -> Error "references must be an array"
;;

type annotation_request =
  { base_path : string
  ; attribution : file_attribution
  ; keeper_id : string
  ; line_start : int
  ; line_end : int
  ; kind : annotation_kind
  ; content : string
  ; goal_id : string option
  ; task_id : string option
  ; references : annotation_reference list
  }

type annotation_result =
  { id : string
  ; file_path : string
  ; line_start : int
  ; line_end : int
  }

type tool_event_sink = tool_event -> unit
type annotation_sink = annotation_request -> (annotation_result, string) result

let noop_tool_event_sink (_ : tool_event) = ()
let noop_annotation_sink (_ : annotation_request) = Error "annotation sink is not installed"

let tool_event_sink = Atomic.make noop_tool_event_sink
let annotation_sink = Atomic.make noop_annotation_sink

let register_tool_event_sink sink = Atomic.set tool_event_sink sink
let register_annotation_sink sink = Atomic.set annotation_sink sink

(* ── Observation snapshot accumulator (task-1686) ──────────────────── *)

type snapshot =
  { tool_events : tool_event list
  ; annotations : annotation_request list
  }

let empty_snapshot = { tool_events = []; annotations = [] }

let current_snapshot = Atomic.make empty_snapshot

let rec update_snapshot f =
  let before = Atomic.get current_snapshot in
  let after = f before in
  if not (Atomic.compare_and_set current_snapshot before after) then update_snapshot f
;;

let reverse_snapshot snap =
  { tool_events = List.rev snap.tool_events
  ; annotations = List.rev snap.annotations
  }
;;

let code_address_to_json address =
  `Assoc
    [ ("codebase", `String (Code_address.codebase address))
    ; ("path", `String (Code_address.path address))
    ]
;;

let file_attribution_to_json = function
  | Addressed { address; checkout } ->
    `Assoc
      ([ ("type", `String "Addressed"); ("address", code_address_to_json address) ]
       @
       match checkout with
       | None -> []
       | Some c -> [ ("checkout", `String c) ])
  | Unaddressed { reason; attempted_path } ->
    `Assoc
      [ ("type", `String "Unaddressed")
      ; ("reason", `String (Unattributed.reason_to_string reason))
      ; ("attempted_path", `String attempted_path)
      ]
;;

let attribution_to_json = function
  | File file_attribution -> file_attribution_to_json file_attribution
  | Pathless -> `String "Pathless"
;;

let tool_event_to_json (e : tool_event) =
  `Assoc
    [ ("base_path", `String e.base_path)
    ; ("attribution", attribution_to_json e.attribution)
    ; ("tool_name", `String e.tool_name)
    ; ("keeper_id", `String e.keeper_id)
    ; ("turn_id", `String e.turn_id)
    ; ("outcome", `String e.outcome)
    ; ("duration_ms", `Float e.duration_ms)
    ]
;;

let annotation_to_json (a : annotation_request) =
  `Assoc
    [ ("attribution", file_attribution_to_json a.attribution)
    ; ("line_start", `Int a.line_start)
    ; ("line_end", `Int a.line_end)
    ; ("keeper_id", `String a.keeper_id)
    ; ("kind", `String (annotation_kind_to_string a.kind))
    ; ("content", `String a.content)
    ; ("references", annotation_references_to_json a.references)
    ]
;;

let snapshot_to_json (snap : snapshot) =
  `Assoc
    [ ("tool_events", `List (List.map tool_event_to_json snap.tool_events))
    ; ("annotations", `List (List.map annotation_to_json snap.annotations))
    ; ( "summary"
      , `Assoc
          [ ("tool_event_count", `Int (List.length snap.tool_events))
          ; ("annotation_count", `Int (List.length snap.annotations))
          ] )
    ]
;;

let peek_snapshot () = Atomic.get current_snapshot |> reverse_snapshot

(* Emit wrappers: accumulate into snapshot + forward to registered sink. *)
let emit_tool_event event =
  update_snapshot (fun snap -> { snap with tool_events = event :: snap.tool_events });
  Atomic.get tool_event_sink event
;;

let emit_annotation_request request =
  update_snapshot (fun snap -> { snap with annotations = request :: snap.annotations });
  Atomic.get annotation_sink request
;;

let reset_for_testing () =
  Atomic.set tool_event_sink noop_tool_event_sink;
  Atomic.set annotation_sink noop_annotation_sink;
  Atomic.set current_snapshot empty_snapshot
;;
