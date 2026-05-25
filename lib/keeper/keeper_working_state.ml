(** Pure keeper working-state vessel. *)

let schema_version = "keeper_working_state.v1"

type loop_status =
  | Active
  | Resolved
  | Archived

let loop_status_to_string = function
  | Active -> "active"
  | Resolved -> "resolved"
  | Archived -> "archived"

let loop_status_of_string = function
  | "active" -> Some Active
  | "resolved" -> Some Resolved
  | "archived" -> Some Archived
  | _ -> None

let loop_status_to_json status = `String (loop_status_to_string status)

type evidence_ref = {
  kind : string;
  target : string;
}

type six_w = {
  who : string;
  what : string;
  when_ : string;
  where_ : string;
  why : string;
  how : string;
}

type loop = {
  id : string;
  title : string;
  status : loop_status;
  six_w : six_w;
  evidence_refs : evidence_ref list;
  resolution_refs : evidence_ref list;
  updated_at_unix : float;
}

type t = {
  active_loops : loop list;
  resolved_loops : loop list;
  archived_loops : loop list;
  prompt_digest_ids : string list;
}

let empty =
  { active_loops = []
  ; resolved_loops = []
  ; archived_loops = []
  ; prompt_digest_ids = []
  }

let make_evidence_ref ~kind ~target = { kind; target }

let make_six_w ~who ~what ~when_ ~where_ ~why ~how =
  { who; what; when_; where_; why; how }

let make_loop
    ~id
    ~title
    ?(status = Active)
    ~six_w
    ~evidence_refs
    ?(resolution_refs = [])
    ~updated_at_unix
    () =
  { id; title; status; six_w; evidence_refs; resolution_refs; updated_at_unix }

let active_open_loop_count state = List.length state.active_loops

let take_last n values =
  let len = List.length values in
  if len <= n then values else List.drop (len - n) values

let ids loops = List.map (fun loop -> loop.id) loops

let prompt_digest_for ?(max_digest = 32) ~active_loops ~resolved_loops () =
  let active_ids = ids active_loops in
  let resolved_budget = max 0 (max_digest - List.length active_ids) in
  active_ids @ List.take resolved_budget (ids resolved_loops)

let compact ?max_digest state =
  { state with
    prompt_digest_ids =
      prompt_digest_for ?max_digest ~active_loops:state.active_loops
        ~resolved_loops:state.resolved_loops ()
  }

let all_loops state =
  state.active_loops @ state.resolved_loops @ state.archived_loops

let all_loop_ids state = ids (all_loops state)

let has_loop_id state loop_id =
  List.exists (String.equal loop_id) (all_loop_ids state)

let set_status status loop = { loop with status }

let capture_loop ?max_digest state loop =
  if has_loop_id state loop.id then
    Error (Printf.sprintf "working-state loop id already exists: %s" loop.id)
  else if loop.status <> Active then
    Error "captured working-state loop must have active status"
  else
    Ok (compact ?max_digest { state with active_loops = state.active_loops @ [ loop ] })

let resolve_loop ?max_digest state ~loop_id ~resolution_refs ~updated_at_unix =
  if resolution_refs = [] then
    Error "resolution requires at least one resolution_ref"
  else
    let rec move_active acc = function
      | [] -> None
      | loop :: rest when String.equal loop.id loop_id ->
        let resolved =
          { (set_status Resolved loop) with
            resolution_refs = loop.resolution_refs @ resolution_refs
          ; updated_at_unix
          }
        in
        Some (List.rev_append acc rest, resolved)
      | loop :: rest -> move_active (loop :: acc) rest
    in
    match move_active [] state.active_loops with
    | None -> Error (Printf.sprintf "active working-state loop not found: %s" loop_id)
    | Some (active_loops, resolved) ->
      Ok
        (compact ?max_digest
           { state with
             active_loops
           ; resolved_loops = state.resolved_loops @ [ resolved ]
           })

let archive_resolved_loop ?max_digest ?(max_archived = 128) state ~loop_id =
  let rec move_resolved acc = function
    | [] -> None
    | loop :: rest when String.equal loop.id loop_id ->
      Some (List.rev_append acc rest, set_status Archived loop)
    | loop :: rest -> move_resolved (loop :: acc) rest
  in
  match move_resolved [] state.resolved_loops with
  | None -> Error (Printf.sprintf "resolved working-state loop not found: %s" loop_id)
  | Some (resolved_loops, archived) ->
    let archived_loops = take_last max_archived (state.archived_loops @ [ archived ]) in
    Ok (compact ?max_digest { state with resolved_loops; archived_loops })

let is_blank s = String.trim s = ""

let evidence_ref_valid ref_ =
  (not (is_blank ref_.kind)) && not (is_blank ref_.target)

let six_w_valid six_w =
  [ six_w.who; six_w.what; six_w.when_; six_w.where_; six_w.why; six_w.how ]
  |> List.for_all (fun s -> not (is_blank s))

let duplicate_ids ids =
  let rec loop seen duplicates = function
    | [] -> List.rev duplicates
    | id :: rest when List.mem id seen ->
      loop seen (if List.mem id duplicates then duplicates else id :: duplicates) rest
    | id :: rest -> loop (id :: seen) duplicates rest
  in
  loop [] [] ids

let status_bucket_mismatch expected loops =
  loops
  |> List.filter_map (fun loop ->
         if loop.status = expected then None
         else
           Some
             (Printf.sprintf "loop %s is in %s bucket but has status %s" loop.id
                (loop_status_to_string expected)
                (loop_status_to_string loop.status)))

let validate state =
  let errors = ref [] in
  let add error = errors := error :: !errors in
  let known_ids = all_loop_ids state in
  List.iter
    (fun id -> add (Printf.sprintf "duplicate working-state loop id: %s" id))
    (duplicate_ids known_ids);
  List.iter add (status_bucket_mismatch Active state.active_loops);
  List.iter add (status_bucket_mismatch Resolved state.resolved_loops);
  List.iter add (status_bucket_mismatch Archived state.archived_loops);
  all_loops state
  |> List.iter (fun loop ->
         if is_blank loop.id then add "working-state loop id must not be blank";
         if is_blank loop.title then
           add (Printf.sprintf "working-state loop %s title must not be blank" loop.id);
         if not (six_w_valid loop.six_w) then
           add (Printf.sprintf "working-state loop %s missing 6W metadata" loop.id);
         if loop.evidence_refs = [] then
           add (Printf.sprintf "working-state loop %s missing evidence_refs" loop.id);
         if not (List.for_all evidence_ref_valid loop.evidence_refs) then
           add (Printf.sprintf "working-state loop %s has invalid evidence_ref" loop.id);
         if not (List.for_all evidence_ref_valid loop.resolution_refs) then
           add
             (Printf.sprintf "working-state loop %s has invalid resolution_ref" loop.id);
         if
           (loop.status = Resolved || loop.status = Archived)
           && loop.resolution_refs = []
         then
           add
             (Printf.sprintf
                "working-state loop %s is resolved/archived without resolution_refs"
                loop.id));
  state.active_loops
  |> List.iter (fun loop ->
         if not (List.mem loop.id state.prompt_digest_ids) then
           add
             (Printf.sprintf
                "active working-state loop %s missing from prompt_digest_ids"
                loop.id));
  state.prompt_digest_ids
  |> List.iter (fun id ->
         if not (List.mem id (ids state.active_loops @ ids state.resolved_loops)) then
           add
             (Printf.sprintf
                "prompt_digest_ids contains non-active/non-resolved loop: %s" id));
  match List.rev !errors with
  | [] -> Ok ()
  | errors -> Error errors

let evidence_ref_to_json ref_ =
  `Assoc [ ("kind", `String ref_.kind); ("target", `String ref_.target) ]

let six_w_to_json six_w =
  `Assoc
    [ ("who", `String six_w.who)
    ; ("what", `String six_w.what)
    ; ("when", `String six_w.when_)
    ; ("where", `String six_w.where_)
    ; ("why", `String six_w.why)
    ; ("how", `String six_w.how)
    ]

let json_list f values = `List (List.map f values)

let loop_to_json loop =
  `Assoc
    [ ("id", `String loop.id)
    ; ("title", `String loop.title)
    ; ("status", loop_status_to_json loop.status)
    ; ("six_w", six_w_to_json loop.six_w)
    ; ("evidence_refs", json_list evidence_ref_to_json loop.evidence_refs)
    ; ("resolution_refs", json_list evidence_ref_to_json loop.resolution_refs)
    ; ("updated_at_unix", `Float loop.updated_at_unix)
    ]

let to_json state =
  `Assoc
    [ ("schema_version", `String schema_version)
    ; ("active_loops", json_list loop_to_json state.active_loops)
    ; ("resolved_loops", json_list loop_to_json state.resolved_loops)
    ; ("archived_loops", json_list loop_to_json state.archived_loops)
    ; ("prompt_digest_ids", Json_util.json_string_list state.prompt_digest_ids)
    ]

let ( let* ) = Result.bind

let assoc_of_json = function
  | `Assoc fields -> Ok fields
  | json -> Error (Printf.sprintf "expected object, got %s" (Yojson.Safe.to_string json))

let field key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing field %s" key)

let string_field key fields =
  let* value = field key fields in
  match value with
  | `String s -> Ok s
  | json ->
    Error (Printf.sprintf "field %s expected string, got %s" key (Yojson.Safe.to_string json))

let float_field key fields =
  let* value = field key fields in
  match value with
  | `Float f -> Ok f
  | `Int i -> Ok (Float.of_int i)
  | json ->
    Error (Printf.sprintf "field %s expected float, got %s" key (Yojson.Safe.to_string json))

let list_field key parse fields =
  let* value = field key fields in
  match value with
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        let* parsed = parse value in
        loop (parsed :: acc) rest
    in
    loop [] values
  | json ->
    Error (Printf.sprintf "field %s expected list, got %s" key (Yojson.Safe.to_string json))

let string_of_json = function
  | `String s -> Ok s
  | json -> Error (Printf.sprintf "expected string, got %s" (Yojson.Safe.to_string json))

let evidence_ref_of_json json =
  let* fields = assoc_of_json json in
  let* kind = string_field "kind" fields in
  let* target = string_field "target" fields in
  Ok { kind; target }

let six_w_of_json json =
  let* fields = assoc_of_json json in
  let* who = string_field "who" fields in
  let* what = string_field "what" fields in
  let* when_ = string_field "when" fields in
  let* where_ = string_field "where" fields in
  let* why = string_field "why" fields in
  let* how = string_field "how" fields in
  Ok { who; what; when_; where_; why; how }

let loop_of_json json =
  let* fields = assoc_of_json json in
  let* id = string_field "id" fields in
  let* title = string_field "title" fields in
  let* status_raw = string_field "status" fields in
  let* status =
    match loop_status_of_string status_raw with
    | Some status -> Ok status
    | None -> Error (Printf.sprintf "unknown loop status: %s" status_raw)
  in
  let* six_w_json = field "six_w" fields in
  let* six_w = six_w_of_json six_w_json in
  let* evidence_refs = list_field "evidence_refs" evidence_ref_of_json fields in
  let* resolution_refs =
    list_field "resolution_refs" evidence_ref_of_json fields
  in
  let* updated_at_unix = float_field "updated_at_unix" fields in
  Ok { id; title; status; six_w; evidence_refs; resolution_refs; updated_at_unix }

let of_json json =
  let* fields = assoc_of_json json in
  let* active_loops = list_field "active_loops" loop_of_json fields in
  let* resolved_loops = list_field "resolved_loops" loop_of_json fields in
  let* archived_loops = list_field "archived_loops" loop_of_json fields in
  let* prompt_digest_ids = list_field "prompt_digest_ids" string_of_json fields in
  let state = { active_loops; resolved_loops; archived_loops; prompt_digest_ids } in
  match validate state with
  | Ok () -> Ok state
  | Error errors -> Error (String.concat "; " errors)
