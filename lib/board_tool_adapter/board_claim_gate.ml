open Masc_board_handlers

type claim_kind =
  | Artifact_exists
  | Artifact_missing
  | Artifact_created
  | Artifact_endorsed
  | Verification_endorsement
  | Task_completion
  | Pr_state
  | Retraction_ack
  | Opinion_or_routing

type source_post_snapshot =
  { post_id : string
  ; post_updated_at : float
  ; body_sha256 : string
  ; body_excerpt : string
  ; read_at : float
  ; read_tool_call_id : string option
  }

type artifact_resolution =
  | Exists of { ref_ : string; kind : string; checked_at : float; digest : string option }
  | Missing of { ref_ : string; checked_at : float; reason : string }
  | Unknown of { ref_ : string; checked_at : float; reason : string }

type gate_decision =
  | Allow
  | Reject of string

type prechecked_write =
  | No_record
  | Record of
      { claims : claim_kind list
      ; snapshot : source_post_snapshot option
      ; artifact_refs : string list
      ; resolutions : artifact_resolution list
      ; decision : gate_decision
      }

let has_prefix ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.equal (String.sub s 0 plen) prefix
;;

let sha256_hex text = Digestif.SHA256.(digest_string text |> to_hex)

let digest_of_file path =
  (* Bind an artifact ref to the actual on-disk content: a sha256 of the file
     body, so "evidence" is more than "any file under the base happened to
     exist". *)
  try Ok ("sha256:" ^ sha256_hex (In_channel.with_open_text path In_channel.input_all))
  with Sys_error _ -> Error "file_path_digest_unavailable"

let normalize_sha256 raw =
  let trimmed = String.trim raw in
  if has_prefix ~prefix:"sha256:" trimmed
  then String.sub trimmed 7 (String.length trimmed - 7)
  else trimmed
;;

let source_snapshot_of_post (post : Board.post) : Yojson.Safe.t =
  let post_id = Board.Post_id.to_string post.id in
  let body_sha256 = "sha256:" ^ sha256_hex post.body in
  `Assoc
    [ "post_id", `String post_id
    ; "post_updated_at", `Float post.updated_at
    ; "body_sha256", `String body_sha256
    ; "body_excerpt", `String post.body
    ; "read_at", `Float (Time_compat.now ())
    ]
;;

let assoc_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let trim_nonempty = function
  | `String value ->
    let trimmed = String.trim value in
    if String.equal trimmed "" then None else Some trimmed
  | _ -> None
;;

let string_list_arg key args =
  match assoc_opt key args with
  | Some (`List values) -> List.filter_map trim_nonempty values
  | Some (`String value) ->
    let trimmed = String.trim value in
    if String.equal trimmed "" then [] else [ trimmed ]
  | _ -> []
;;

let string_opt key json = Option.bind (assoc_opt key json) trim_nonempty

let float_opt key json =
  match assoc_opt key json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | _ -> None
;;

let source_snapshot_arg args =
  match assoc_opt "source_post_snapshot" args with
  | Some (`Assoc _ as json) ->
    (match
       ( string_opt "post_id" json
       , string_opt "body_sha256" json
       , float_opt "post_updated_at" json
       , string_opt "body_excerpt" json
       , float_opt "read_at" json )
     with
     | Some post_id, Some body_sha256, Some post_updated_at, Some body_excerpt, Some read_at ->
       Some
         { post_id
         ; post_updated_at
         ; body_sha256
         ; body_excerpt
         ; read_at
         ; read_tool_call_id = string_opt "read_tool_call_id" json
         }
     | _ -> None)
  | _ -> None
;;

let normalize_claim raw =
  raw
  |> String.trim
  |> String.lowercase_ascii
  |> String.map (function
    | '-' | ' ' -> '_'
    | ch -> ch)
;;

let claim_kind_of_string raw =
  match normalize_claim raw with
  | "artifact_exists" -> Some Artifact_exists
  | "artifact_missing" -> Some Artifact_missing
  | "artifact_created" -> Some Artifact_created
  | "artifact_endorsed" -> Some Artifact_endorsed
  | "verification_endorsement" -> Some Verification_endorsement
  | "task_completion" -> Some Task_completion
  | "pr_state" -> Some Pr_state
  | "retraction_ack" -> Some Retraction_ack
  | "opinion_or_routing" | "opinion" | "routing" -> Some Opinion_or_routing
  | _ -> None
;;

let claim_kind_to_string = function
  | Artifact_exists -> "artifact_exists"
  | Artifact_missing -> "artifact_missing"
  | Artifact_created -> "artifact_created"
  | Artifact_endorsed -> "artifact_endorsed"
  | Verification_endorsement -> "verification_endorsement"
  | Task_completion -> "task_completion"
  | Pr_state -> "pr_state"
  | Retraction_ack -> "retraction_ack"
  | Opinion_or_routing -> "opinion_or_routing"
;;

let claims_arg args =
  string_list_arg "claims" args |> List.filter_map claim_kind_of_string
;;

let unknown_claims_arg args =
  string_list_arg "claims" args
  |> List.filter (fun raw -> Option.is_none (claim_kind_of_string raw))
;;

let artifact_refs_arg args =
  string_list_arg "artifact_refs" args @ string_list_arg "evidence_refs" args
;;

let contains_parent_segment path =
  path
  |> String.split_on_char '/'
  |> List.exists (String.equal "..")
;;

let is_absolute path = String.length path > 0 && Char.equal path.[0] '/'

let base_path_contains ~base path =
  String.equal path base || has_prefix ~prefix:(base ^ "/") path
;;

let resolve_file_path raw =
  let ref_ = String.trim raw in
  let checked_at = Time_compat.now () in
  if String.equal ref_ ""
  then Unknown { ref_; checked_at; reason = "empty_artifact_ref" }
  else if contains_parent_segment ref_
  then Unknown { ref_; checked_at; reason = "parent_path_segment_not_allowed" }
  else (
    let base = Board_paths.board_base_path () in
    let path =
      if is_absolute ref_
      then if base_path_contains ~base ref_ then Some ref_ else None
      else Some (Filename.concat base ref_)
    in
    match path with
    | None -> Unknown { ref_; checked_at; reason = "artifact_ref_outside_base_path" }
    | Some path ->
      if Sys.file_exists path
      then (
        match digest_of_file path with
        | Ok digest -> Exists { ref_; kind = "file_path"; checked_at; digest = Some digest }
        | Error reason -> Unknown { ref_; checked_at; reason })
      else Missing { ref_; checked_at; reason = "file_path_missing" })
;;

let artifact_resolution_to_yojson = function
  | Exists { ref_; kind; checked_at; digest } ->
    `Assoc
      ([ "ref", `String ref_
       ; "kind", `String kind
       ; "state", `String "exists"
       ; "checked_at", `Float checked_at
       ]
       @
       match digest with
       | Some value -> [ "digest", `String value ]
       | None -> [])
  | Missing { ref_; checked_at; reason } ->
    `Assoc
      [ "ref", `String ref_
      ; "state", `String "missing"
      ; "checked_at", `Float checked_at
      ; "reason", `String reason
      ]
  | Unknown { ref_; checked_at; reason } ->
    `Assoc
      [ "ref", `String ref_
      ; "state", `String "unknown"
      ; "checked_at", `Float checked_at
      ; "reason", `String reason
      ]
;;

let source_snapshot_to_yojson snapshot =
  `Assoc
    ([ "post_id", `String snapshot.post_id
     ; "post_updated_at", `Float snapshot.post_updated_at
     ; "body_sha256", `String snapshot.body_sha256
     ; "body_excerpt", `String snapshot.body_excerpt
     ; "read_at", `Float snapshot.read_at
     ]
     @
     match snapshot.read_tool_call_id with
     | Some id -> [ "read_tool_call_id", `String id ]
     | None -> [])
;;

let validate_source_snapshot ~target_post_id snapshot =
  if not (String.equal snapshot.post_id target_post_id)
  then Error "source_post_snapshot_post_id_mismatch"
  else
    match Board_dispatch.get_post ~post_id:target_post_id with
    | Error _ -> Error "source_post_snapshot_post_not_found"
    | Ok post ->
      let expected_hash = sha256_hex post.body in
      let actual_hash = normalize_sha256 snapshot.body_sha256 in
      if not (String.equal expected_hash actual_hash)
      then Error "source_post_snapshot_body_hash_mismatch"
      else if abs_float (post.updated_at -. snapshot.post_updated_at) > 0.001
      then Error "source_post_snapshot_stale"
      else Ok ()
;;

let claim_requires_existing_artifact = function
  | Artifact_exists | Artifact_created | Artifact_endorsed | Verification_endorsement ->
    true
  | Artifact_missing | Task_completion | Pr_state | Retraction_ack | Opinion_or_routing ->
    false
;;

let claim_requires_source_snapshot = function
  | Opinion_or_routing -> false
  | Artifact_exists
  | Artifact_missing
  | Artifact_created
  | Artifact_endorsed
  | Verification_endorsement
  | Task_completion
  | Pr_state
  | Retraction_ack -> true
;;

let resolution_is_exists = function
  | Exists _ -> true
  | Missing _ | Unknown _ -> false
;;

let has_missing_or_unknown = function
  | Exists _ -> false
  | Missing _ | Unknown _ -> true
;;

let decision_to_yojson = function
  | Allow -> `String "allow"
  | Reject reason -> `String ("reject:" ^ reason)
;;

let append_record ~tool_name ~author ~target_post_id ~content ~claims ~snapshot ~artifact_refs
      ~resolutions ~decision =
  let json =
    `Assoc
      ([ "schema", `String "masc.board_claim_evidence.v1"
       ; "tool_name", `String tool_name
       ; "author", `String author
       ; "target_post_id", `String target_post_id
       ; "content_sha256", `String ("sha256:" ^ sha256_hex content)
       ; "recorded_at", `Float (Time_compat.now ())
       ; "claims", `List (List.map (fun c -> `String (claim_kind_to_string c)) claims)
       ; "artifact_refs", `List (List.map (fun ref_ -> `String ref_) artifact_refs)
       ; "artifact_resolutions", `List (List.map artifact_resolution_to_yojson resolutions)
       ; "decision", decision_to_yojson decision
       ]
       @
       match snapshot with
       | Some s -> [ "source_post_snapshot", source_snapshot_to_yojson s ]
       | None -> [])
  in
  let path = Board_claim_evidence.sidecar_path () in
  Fs_compat.invalidate_cached_writer path;
  Fs_compat.append_jsonl path json;
  (* Mirror sibling sidecars (board_posts/comments/reactions/sub_boards), which
     rotate at [Board_paths.max_jsonl_bytes]. Without this the claim-evidence
     ledger grew unbounded and the projection re-read the whole file on every
     dashboard fetch. *)
  Board_paths.rotate_if_needed path
;;

let evaluate ~target_post_id ~claims ~snapshot ~artifact_refs ~resolutions =
  let snapshot_decision =
    match snapshot with
    | Some source ->
      (match target_post_id with
       | None -> Reject "source_post_snapshot_without_target_post"
       | Some target_post_id ->
         (match validate_source_snapshot ~target_post_id source with
          | Error reason -> Reject reason
          | Ok () -> Allow))
    | None -> Allow
  in
  match snapshot_decision with
  | Reject _ as reject -> reject
  | Allow ->
    let requires_artifact = List.exists claim_requires_existing_artifact claims in
    if requires_artifact && artifact_refs = []
    then Reject "missing_artifact_refs"
    else (
      if requires_artifact && (resolutions = [] || List.exists has_missing_or_unknown resolutions)
      then Reject "artifact_not_verified"
      else if List.mem Artifact_missing claims && List.exists resolution_is_exists resolutions
      then Reject "artifact_missing_claim_ref_exists"
      else Allow)
;;

let check_write ~requires_source_snapshot ~tool_name ~author ~target_post_id ~content
      ~args =
  let claims = claims_arg args in
  let unknown_claims = unknown_claims_arg args in
  let has_snapshot_arg = Option.is_some (assoc_opt "source_post_snapshot" args) in
  let snapshot = source_snapshot_arg args in
  let artifact_refs = artifact_refs_arg args in
  let target_high_risk =
    Board_claim_evidence.post_has_high_risk_evidence target_post_id
  in
  let high_risk =
    claims <> [] || unknown_claims <> [] || has_snapshot_arg || artifact_refs <> []
    || target_high_risk
  in
  if not high_risk
  then Ok ()
  else (
    let resolutions = List.map resolve_file_path artifact_refs in
    let decision =
      match unknown_claims with
      | claim :: _ -> Reject ("invalid_claim_kind:" ^ claim)
      | [] ->
        (match has_snapshot_arg, snapshot with
         | true, None -> Reject "invalid_source_post_snapshot"
         | false, None
           when requires_source_snapshot
                && List.exists claim_requires_source_snapshot claims ->
           Reject "missing_source_post_snapshot"
         | _, Some source ->
           (match validate_source_snapshot ~target_post_id source with
            | Error reason -> Reject reason
            | Ok () ->
             evaluate
               ~target_post_id:(Some target_post_id)
               ~claims
               ~snapshot
               ~artifact_refs
               ~resolutions)
         | false, None ->
           evaluate
             ~target_post_id:(Some target_post_id)
             ~claims
             ~snapshot
             ~artifact_refs
             ~resolutions)
    in
    try
      append_record
        ~tool_name
        ~author
        ~target_post_id
        ~content
        ~claims
        ~snapshot
        ~artifact_refs
        ~resolutions
        ~decision;
      match decision with
      | Allow -> Ok ()
      | Reject reason -> Error ("board_claim_gate rejected write: " ^ reason)
    with
    | exn ->
          Error
        ("board_claim_gate sidecar write failed: " ^ Printexc.to_string exn))
;;

let prepare_post_create ~args =
  let claims = claims_arg args in
  let unknown_claims = unknown_claims_arg args in
  let has_snapshot_arg = Option.is_some (assoc_opt "source_post_snapshot" args) in
  let snapshot = source_snapshot_arg args in
  let artifact_refs = artifact_refs_arg args in
  let high_risk =
    claims <> [] || unknown_claims <> [] || has_snapshot_arg || artifact_refs <> []
  in
  if not high_risk
  then Ok No_record
  else (
    let resolutions = List.map resolve_file_path artifact_refs in
    let decision =
      match unknown_claims with
      | claim :: _ -> Reject ("invalid_claim_kind:" ^ claim)
      | [] ->
        (match has_snapshot_arg, snapshot with
         | true, None -> Reject "invalid_source_post_snapshot"
         | _, Some _ -> Reject "source_post_snapshot_without_target_post"
         | false, None ->
           evaluate
             ~target_post_id:None
             ~claims
             ~snapshot
             ~artifact_refs
             ~resolutions)
    in
    Ok (Record { claims; snapshot; artifact_refs; resolutions; decision }))
;;

let record_prechecked ~tool_name ~author ~target_post_id ~content = function
  | No_record -> Ok ()
  | Record { claims; snapshot; artifact_refs; resolutions; decision } ->
    (try
       append_record
         ~tool_name
         ~author
         ~target_post_id
         ~content
         ~claims
         ~snapshot
         ~artifact_refs
         ~resolutions
         ~decision;
       match decision with
       | Allow -> Ok ()
       | Reject reason -> Error ("board_claim_gate rejected write: " ^ reason)
     with
     | exn ->
       Error ("board_claim_gate sidecar write failed: " ^ Printexc.to_string exn))
;;

let prechecked_reject_reason = function
  | No_record -> None
  | Record { decision = Allow; _ } -> None
  | Record { decision = Reject reason; _ } -> Some reason
;;

let check_comment ~tool_name ~author ~post_id ~content ~args =
  check_write
    ~requires_source_snapshot:true
    ~tool_name
    ~author
    ~target_post_id:post_id
    ~content
    ~args
;;

let check_post_create ~tool_name ~author ~content ~args =
  match prepare_post_create ~args with
  | Error msg -> Error msg
  | Ok prechecked ->
    (match prechecked_reject_reason prechecked with
     | None -> Ok prechecked
     | Some _ ->
       (match
          record_prechecked
            ~tool_name
            ~author
            ~target_post_id:"__new_post__"
            ~content
            prechecked
        with
        | Ok () -> Ok prechecked
        | Error msg -> Error msg))
;;

let record_post_create =
  record_prechecked
;;
