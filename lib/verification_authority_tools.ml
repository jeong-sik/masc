(** See [verification_authority_tools.mli]. *)

(* The tool names the evaluator may call. Parsed once at the dispatch boundary
   so the rest of this module matches on a constructor: a name that is not one
   of these cannot reach an implementation, and adding a tool without wiring it
   fails to compile. *)
type tool =
  | Read_file
  | Search_files
  | Web_fetch
  | Board_source
  | Fusion_source
  | Task_source

let tool_name = function
  | Read_file -> "tool_read_file"
  | Search_files -> "tool_search_files"
  | Web_fetch -> "masc_web_fetch"
  | Board_source -> "masc_board_post_get"
  | Fusion_source -> "masc_fusion_status"
  | Task_source -> "keeper_tasks_list"
;;

let source_tools submitted_evidence =
  let has_task_source = List.exists (function
    | Workspace_verification_store.Evidence_collaboration {reference; _} ->
      (match Workspace_verification_store.collaboration_reference reference with
       | Some (Workspace_verification_store.Task_source, _) -> true
       | Some ((Workspace_verification_store.Board_source | Workspace_verification_store.Fusion_source), _) | None -> false)
    | Evidence_note _ | Evidence_artifact _ | Evidence_invalid_reference
    | Evidence_artifact_unreadable _ | Evidence_artifact_binary _ -> false) submitted_evidence in
  [Board_source; Fusion_source] @ if has_task_source then [Task_source] else []

type t =
  { ownership_root : string
  ; read_authority : Keeper_sandbox_remote_lane.read_authority option
  ; config : Workspace.config
  ; submitted_evidence : Workspace_verification_store.submitted_evidence_item list
  ; producer_scope : producer_scope
  ; tools : (tool * Keeper_tool_descriptor.t) list
  }

and producer_scope =
  | Keeper_producer of Keeper_meta_contract.keeper_meta
  | Workspace_producer

(* A Keeper's masc_fusion_status lists its tracked runs when run_id is omitted.
   This reader has no listing: it reads one exact run. Reusing the Keeper schema
   advertised {} as a valid call that the reader then refused, so the verifier
   declares its own input. Dispatch validates against this same descriptor, so
   the advertised schema is the accepted one. *)
let exact_fusion_run_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ ( "run_id"
            , `Assoc
                [ "type", `String "string"
                ; ( "description"
                  , `String
                      "Exact Fusion run id (the run_id returned by masc_fusion) \
                       whose submission-bound evidence to read." )
                ] )
          ] )
    ; "required", `List [ `String "run_id" ]
    ; "additionalProperties", `Bool false
    ]
;;

let exact_task_source_schema =
  `Assoc ["type", `String "object";
    "properties", `Assoc ["task_ids", `Assoc ["type", `String "array";
      "items", `Assoc ["type", `String "string"; "minLength", `Int 1];
      "minItems", `Int 1; "maxItems", `Int 1]];
    "required", `List [`String "task_ids"]; "additionalProperties", `Bool false]

let source_pagination_schema = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* properties = match List.assoc_opt "properties" fields with
      | Some (`Assoc properties) -> Ok properties
      | _ -> Error "source descriptor properties must be an object" in
    let cursor = `Assoc ["type", `String "object";
      "description", `String "Continue with next_cursor from a source_json_page; keep the same source id and comment pagination. Concatenate content until next_cursor is null to recover exact source JSON. A changed source rejects the cursor.";
      "properties", `Assoc ["source_sha256", `Assoc ["type", `String "string"];
        "byte_offset", `Assoc ["type", `String "integer"; "minimum", `Int 1]];
      "required", `List [`String "source_sha256"; `String "byte_offset"];
      "additionalProperties", `Bool false] in
    Ok (`Assoc (("properties", `Assoc (("cursor", cursor) :: properties)) :: List.remove_assoc "properties" fields))
  | _ -> Error "source descriptor schema must be an object"
;;

let descriptor_of_tool tool =
  match Keeper_tool_descriptor.descriptors_for_internal (tool_name tool) with
  | [ descriptor ] ->
    (match tool with
     | Fusion_source ->
       Result.map (fun input_schema -> tool, { descriptor with input_schema })
         (source_pagination_schema exact_fusion_run_schema)
     | Board_source ->
       Result.map (fun input_schema -> tool, { descriptor with input_schema })
         (source_pagination_schema descriptor.input_schema)
     | Task_source ->
       Result.map (fun input_schema -> tool, { descriptor with input_schema })
         (source_pagination_schema exact_task_source_schema)
     | Read_file | Search_files | Web_fetch -> Ok (tool, descriptor))
  | [] ->
    Error
      (Printf.sprintf
         "tool %s is missing from the keeper descriptor registry"
         (tool_name tool))
  | descriptors ->
    Error
      (Printf.sprintf
         "tool %s has %d keeper descriptors"
         (tool_name tool)
         (List.length descriptors))
;;

let rec resolve_tools = function
  | [] -> Ok []
  | tool :: rest ->
    let open Result.Syntax in
    let* descriptor = descriptor_of_tool tool in
    let* descriptors = resolve_tools rest in
    Ok (descriptor :: descriptors)
;;

let create ~config ~producer ~submitted_evidence =
  let open Result.Syntax in
  let* producer_scope =
    match Keeper_meta_store.read_effective_meta config producer with
    | Error message ->
      Error (Printf.sprintf "producer %s meta unreadable: %s" producer message)
    | Ok None -> Ok Workspace_producer
    | Ok (Some producer_meta) -> Ok (Keeper_producer producer_meta)
  in
  let* tools =
    resolve_tools
      ((match producer_scope with
        | Keeper_producer _ -> [Read_file; Search_files; Web_fetch]
        | Workspace_producer -> [Read_file; Web_fetch]) @ source_tools submitted_evidence)
  in
  let* ownership_root =
    match producer_scope with
    | Keeper_producer producer_meta ->
      Ok (Keeper_sandbox.host_root_abs_of_meta ~config producer_meta)
    (* A workspace agent is not a Keeper and declares no sandbox profile. Its
       root comes from the resolver the submit-time snapshot used for it
       ([Workspace_verification_store.snapshot_submitted_evidence_json]), so
       the judge reads where the submitter's artifacts were captured. *)
    | Workspace_producer ->
      let project_root =
        Workspace_verification_store.project_root_of_base_path config.base_path
      in
      Ok
        (Keeper_sandbox_config.host_root_abs_of_producer
           ~base_path:project_root
           ~agent_name:producer)
  in
  let ownership_root =
    Env_config_core.strip_trailing_slashes ownership_root
  in
  let* read_authority = match producer_scope with
    | Workspace_producer -> Ok None
    | Keeper_producer meta -> Keeper_sandbox_remote_lane.capture_read_authority ~config ~meta () in
  Ok { ownership_root; read_authority; config; producer_scope; tools
     ; submitted_evidence }
;;

(* The Goal proof surface. A Goal names no producer: it is a shared intent
   that any Keeper may advance, so there is no owned tree to bind the tools
   to. The root is the shared playground prefix — one fixed workspace
   location, the same for every Goal, derived from nothing the Goal happens
   to be linked to. Every producer's tree sits under it, so a measurement
   written anywhere in the workspace is reachable.

   [tool_search_files] is absent. Its containment runs through a Keeper's
   sandbox meta and this surface has no Keeper identity; reimplementing that
   jail here would be a second containment boundary to keep correct. The
   judge navigates from [root_layout] instead, which names the producers and
   the checkouts under them. *)
let create_goal_proof ~(config : Workspace.config) ~submitted_evidence =
  let open Result.Syntax in
  let* tools = resolve_tools ([Read_file; Web_fetch] @ source_tools submitted_evidence) in
  let project_root =
    Workspace_verification_store.project_root_of_base_path config.base_path
  in
  let ownership_root =
    Env_config_core.strip_trailing_slashes
      (Filename.concat project_root Playground_paths.all_playgrounds_prefix)
  in
  Ok { ownership_root; read_authority=None; config; producer_scope = Workspace_producer; tools
     ; submitted_evidence }
;;

(* The listing answers one question for the evaluator: where do the paths the
   submitter wrote actually resolve. Two facts do that, and they are different
   facts.

   The immediate entries say what the root holds — [artifacts/] and the rest
   are read directly and need no prefix.

   The checkouts say where a repository-relative path has to be rooted, and
   they come from [Keeper_playground_checkouts], which finds a checkout by its
   [.git] entry wherever the keeper put it. This module must not scan for them
   itself: that module exists because three separate scans each hardcoded a
   [repos/] segment and each disagreed about what counted as a checkout
   (RFC-keeper-workspace-root-only §1.2). [repos/masc] is one keeper's own
   convention, written in its config, not a layout the system imposes — a
   keeper with a checkout at the top level or under another name is equally
   valid, and a fourth hardcoded scan here would miss it. *)
let root_entry_cap = 32

(* The Goal proof root lists producers rather than one producer's contents, so
   its cap is the number of producers a workspace is expected to carry, not the
   number of entries in one tree. A truncated producer list costs the judge a
   place it may not look; the live workspace carries 38. *)
let goal_root_entry_cap = 128

let children path =
  try Ok (Fs_compat.read_dir path) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error detail -> Error detail
  | Unix.Unix_error (code, operation, _) ->
    Error (Printf.sprintf "%s: %s" operation (Unix.error_message code))
;;

(* What the judge may conclude about a checkout's age. The probe reads the
   local clone only, so every wording names the local [origin/<branch>] ref and
   none says the checkout is current with the remote's main: a file missing
   here is a fact about this tree, and it is a fact about main only when the
   tree is known to hold main's commit. [Current] is the one case where the
   local ref was seen to move within the freshness window, and it still does
   not read the remote. [Ahead], [Behind] and [Diverged] carry no observation
   time: [Ahead] says the ref may itself be behind the remote, and [Behind]
   and [Diverged] say files absent here may exist on that branch. *)
let describe_standing : Keeper_sandbox_control.checkout_freshness -> string = function
  | Keeper_sandbox_control.Current { target_ref; upstream_head; age_s; _ } ->
    Printf.sprintf
      "HEAD equals local %s (%s), last observed moving %ds ago; the remote was not compared"
      target_ref upstream_head age_s
  | Keeper_sandbox_control.Stale_ref { target_ref; upstream_head; age_s; _ } ->
    Printf.sprintf
      "HEAD equals local %s (%s), but that ref was last observed moving %s; it may be behind the remote"
      target_ref upstream_head
      (match age_s with
       | Some seconds -> Printf.sprintf "%ds ago" seconds
       | None -> "at an unknown time")
  | Keeper_sandbox_control.Ahead { target_ref; upstream_head; ahead } ->
    Printf.sprintf
      "HEAD is %d commit(s) ahead of local %s (%s); that ref may be behind the remote"
      ahead target_ref upstream_head
  | Keeper_sandbox_control.Behind { target_ref; upstream_head; behind } ->
    Printf.sprintf
      "HEAD is %d commit(s) behind local %s (%s); files absent here may exist on that branch"
      behind target_ref upstream_head
  | Keeper_sandbox_control.Diverged { target_ref; upstream_head; ahead; behind } ->
    Printf.sprintf
      "HEAD is %d commit(s) ahead and %d behind local %s (%s); files absent here may exist on that branch"
      ahead behind target_ref upstream_head
  | Keeper_sandbox_control.Freshness_unavailable reason ->
    (* A git error can span lines; the layout indents only a line's first row. *)
    Printf.sprintf
      "no comparison with main (%s); do not treat this tree as main"
      (String.concat " " (String.split_on_char '\n' (String.trim reason)))
;;

let checkout_marker = "(git checkout — a repository-relative path is rooted here)"

let describe_checkout (row : Keeper_sandbox_control.identity_row) =
  Printf.sprintf
    "  %s/    %s branch=%s head=%s; %s"
    row.Keeper_sandbox_control.identity_checkout_path
    checkout_marker
    (match row.Keeper_sandbox_control.identity_branch with
     | Some "HEAD" -> "HEAD (detached)"
     | Some branch -> branch
     | None -> "unreadable")
    (Option.value row.Keeper_sandbox_control.identity_head ~default:"unreadable")
    (describe_standing row.Keeper_sandbox_control.identity_freshness)
;;

(* Remote discovery describes the producer's actual endpoint tree. Its paths
   are not host checkout paths, so host git probes cannot establish identity. *)
let describe_unprobed_checkout (checkout : Keeper_playground_checkouts.checkout) =
  Printf.sprintf
    "  %s/    %s identity not probed on the producer endpoint; no comparison with main, do not treat this tree as main"
    checkout.relative_path
    checkout_marker
;;

let checkout_lines ~describe discovery =
  match discovery with
  | Error error ->
    Error (Keeper_playground_checkouts.scan_error_to_string error)
  | Ok (Keeper_playground_checkouts.Partial { limit; _ }) ->
    Error
      (Printf.sprintf
         "checkout discovery is partial: %s"
         (Keeper_playground_checkouts.limit_to_string limit))
  | Ok (Keeper_playground_checkouts.Complete checkouts) ->
    Ok (describe checkouts)
;;

let entry_lines entries ~cap =
  let entries = List.sort String.compare entries in
  let shown = List.filteri (fun index _ -> index < cap) entries in
  let omitted = List.length entries - List.length shown in
  let lines = List.map (fun entry -> "  " ^ entry) shown in
  if omitted <= 0 then lines
  else lines @ [ Printf.sprintf "  ... and %d more" omitted ]
;;

let entry_lines_of root ~cap =
  children root
  |> Result.map_error (fun detail ->
    Printf.sprintf "verification root unreadable: %s" detail)
  |> Result.map (fun entries -> entry_lines entries ~cap)
;;

let root_kind root =
  try Ok (Fs_compat.exact_path_kind ~follow:false root) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error detail -> Error detail
  | Unix.Unix_error (code, operation, _) ->
    Error (Printf.sprintf "%s: %s" operation (Unix.error_message code))
;;

(* Nothing creates a workspace producer's playground: no boot, no sandbox.
   So its absence is a fact about the producer, not an unavailable surface,
   and the judge is told so in its own lookup section and rules on the
   evidence that is there (the snapshot's typed items, submitted Board and
   Fusion sources, and URLs it opens).
   Treating it as unavailable deferred the review on every sweep and left
   every Task submitted over MCP in AwaitingVerification with nobody told:
   nine Tasks, 131 identical warning lines on 2026-09-11. A Keeper's root is
   different -- the sandbox creates it at boot, so its absence is
   infrastructure and stays a deferral. *)
let root_layout t =
  let open Result.Syntax in
  let host_layout () =
    let* entry_lines = entry_lines_of t.ownership_root ~cap:root_entry_cap in
    let* checkout_lines = checkout_lines
      ~describe:(fun checkouts -> List.map describe_checkout
        (Keeper_sandbox_control.checkout_identity_rows ~config:t.config checkouts))
      (Keeper_playground_checkouts.discover ~root:t.ownership_root) in
    Ok (Task.Anti_rationalization.Producer_tree (entry_lines @ checkout_lines))
  in
  match t.producer_scope with
  | Keeper_producer meta ->
    (match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
     | Keeper_types_profile_sandbox.Shared_mount -> host_layout ()
     | Keeper_types_profile_sandbox.Endpoint_owned ->
       let* layout = Keeper_sandbox_remote_checkouts.discover_layout
         ?read_authority:t.read_authority ~timeout_sec:Repo_git.inspection_timeout_sec ~config:t.config ~meta ()
         |> Result.map_error Keeper_playground_checkouts.scan_error_to_string in
       let* checkout_lines = checkout_lines
         ~describe:(List.map describe_unprobed_checkout)
         (Ok layout.discovery) in
       Ok (Task.Anti_rationalization.Producer_tree
         (entry_lines layout.entries ~cap:root_entry_cap @ checkout_lines)))
  | Workspace_producer ->
  match root_kind t.ownership_root with
  | Ok Fs_compat.Exact_missing ->
    Ok (Task.Anti_rationalization.Producer_root_absent { root = t.ownership_root })
  | Ok (Fs_compat.Exact_unknown | Fs_compat.Exact_kind _) | Error _ -> host_layout ()
;;

(* The Goal proof root holds every producer, so the checkout scan that maps one
   producer's tree does not apply: it walks all of them at once and stops on
   the reported-checkout budget long before it is done. That stop is an
   [Error], so running it here deferred every Goal review and the lane
   committed no verdict at all (observed live 2026-08-23 on a workspace with
   38 producers: "checkout budget exhausted (budget 32)", 0.85s, evaluator
   never reached).

   The scan is an [Error] once it finds more than [max_reported_checkouts]
   checkouts (32; the live workspace had 41), so it completes only on small
   workspaces. Leaving it out removes nothing the judge could use: the lookup
   surface is [Read_file] and [Web_fetch], neither lists a directory, and the
   path the judge opens comes from the Goal's metric, not from this listing.
   The listing tells the judge which producer directories exist under the
   root. The cap is per-producer-entry and states its own omissions. *)
let goal_proof_root_layout t = entry_lines_of t.ownership_root ~cap:goal_root_entry_cap
;;

(* ================================================================ *)
(* Schemas                                                          *)
(* ================================================================ *)

(* The lookup surface reads images as visual input for the judge -- a fact of
   this surface, not of the keeper descriptor it starts from. Named so the
   schema-parity test reuses the same spelling instead of restating it. *)
let image_delivery_note =
  "Image files are delivered as visual input with byte count and SHA-256; \
   read them without line offset/limit. PDF files are inspected whole with Poppler; \
   the result contains the source SHA-256/bytes, parsed page count and text, \
   and every rendered page as visual input. PPTX files are inspected whole with \
   python-pptx and LibreOffice: ordered slide text, speaker notes, and every \
   rendered slide are returned with the original source identity. Animations \
   and embedded audio/video playback are not inspected. MP4 files are inspected \
   whole with FFprobe and FFmpeg: original source SHA-256/bytes, stream metadata \
   and direct complete audio/video decode results are returned. That decode is \
   not a visual frame inspection or an accessibility verdict."

let schema_of_tool (tool, (descriptor : Keeper_tool_descriptor.t)) : Types_core.tool_schema =
  { Types_core.name = tool_name tool
  ; description =
      (match tool with
       | Read_file -> descriptor.description ^ " " ^ image_delivery_note
       | Board_source ->
         "Read a Board post and its paginated comments frozen in this verification submission, including identities and full metadata. Large sources return source_json_page content fragments under the bridge byte budget; follow next_cursor to null and concatenate exact JSON before reviewing. Task reviews can read shared posts and their producer's own Direct posts; Goal reviews read shared workspace posts only. Read-only: no posting, voting or adoption."
       | Fusion_source ->
         "Read Fusion panel/judge/source-context evidence frozen in this verification submission and separately recorded Keeper decisions by required exact run_id. Task reviews read the actual producer's Fusion source; Goal reviews read shared workspace Fusion source. Large sources return source_json_page content fragments under the bridge byte budget; follow next_cursor to null and concatenate exact JSON before reviewing. This does not run Fusion or adopt advice."
       | Task_source ->
         "Read exactly one Task frozen by an explicit task:<id> reference in this verification submission. Supply task_ids with that one id. Includes the canonical Task state, completion timestamp and notes plus primary backlog revision; no live listing, recovery snapshot or other Task is read. A Done row is committed state, not complete approval history or external acceptance. Large sources return source_json_page fragments; follow next_cursor to null and concatenate the exact JSON. Read-only."
       | Search_files | Web_fetch -> descriptor.description)
  ; input_schema = descriptor.input_schema
  }
;;

let schemas t = List.map schema_of_tool t.tools

(* ================================================================ *)
(* Dispatch                                                         *)
(* ================================================================ *)

(* How one call ended. A closed sum rather than a string because the log level
   is derived from it: a rejected call reported at the same level as a resolved
   one is invisible in exactly the case an operator needs to see. *)
type lookup_outcome =
  | Resolved
  | Rejected
  | Unknown_tool
  | Invalid_input

let lookup_outcome_label = function
  | Resolved -> "resolved"
  | Rejected -> "rejected"
  | Unknown_tool -> "unknown_tool"
  | Invalid_input -> "invalid_input"
;;

let lookup_outcome_level = function
  | Resolved -> Log.Info
  | Rejected | Unknown_tool | Invalid_input -> Log.Warn
;;

(* What the judge ran, and whether it got an answer. An operator reading the
   logs otherwise cannot tell a review that inspected the tree from one that
   only read the submitted snapshot, and that difference is the whole point of
   this surface. Output is never logged — only the tool name and the model's own
   arguments, which the run registry records anyway. *)
let log_call t ~name ~argument ~outcome =
  Log.Task.emit
    (lookup_outcome_level outcome)
    (Printf.sprintf
       "[verification-lookup] tool=%s root=%s argument=%s outcome=%s"
       name
       t.ownership_root
       argument
       (lookup_outcome_label outcome))
;;

(* [Keeper_tool_execution.t] carries the runtime's own disposition. A failed
   call has to reach the model as [Error]: handing back [raw_output] on both
   paths would let a build that never ran read like one that produced no
   findings. *)
let result_of_execution (execution : Keeper_tool_execution.t) =
  match execution.disposition with
  | Tool_result.Completed () -> Ok execution.raw_output
  | Tool_result.Failed _ | Tool_result.Deferred () -> Error execution.raw_output
;;

(* The producer's meta binds the jail. [turn_sandbox_factory] is a keeper-turn
   construct and the judge has no turn of its own, so it passes [None] — the
   one caller outside a turn. That names what the judge lacks, not what it may
   read: a Docker producer's tree is a shared mount the read backend reaches
   through its own container, and a microvm producer's guest is named by the
   keeper and the base path, so the backend attaches to a running one. Neither
   route lets the judge start anything or touch the host outside the
   playground, which is the property [None] is protecting. *)
type run_error = Runtime_error of string | Collaboration_error of Verification_collaboration_evidence.error

let run t tool ~args =
  let execution_result execution =
    result_of_execution execution |> Result.map_error (fun detail -> Runtime_error detail) in
  let collaboration_read read =
    read ~submitted_evidence:t.submitted_evidence ~args
    |> Result.map Yojson.Safe.to_string
    |> Result.map_error (fun error -> Collaboration_error error)
  in
  match t.producer_scope, tool with
  | Keeper_producer producer_meta, Read_file ->
    (match t.read_authority with
     | None -> Keeper_tool_filesystem_runtime.handle_read_file_with_outcome
         ~turn_sandbox_factory:None ~config:t.config ~meta:producer_meta ~args
     | Some read_authority -> Keeper_tool_filesystem_runtime.handle_read_file_with_authority
         ~read_authority ~turn_sandbox_factory:None ~config:t.config ~meta:producer_meta ~args)
    |> execution_result
  | Keeper_producer producer_meta, Search_files ->
    (match t.read_authority with
     | None -> Keeper_workspace_ops.handle_tool_search_files_with_outcome
         ~turn_sandbox_factory:None ~config:t.config ~meta:producer_meta ~args
     | Some read_authority -> Keeper_workspace_ops.handle_tool_search_files_with_authority
         ~read_authority ~turn_sandbox_factory:None ~config:t.config ~meta:producer_meta ~args)
    |> execution_result
  | Workspace_producer, Read_file ->
    Keeper_tool_filesystem_runtime.handle_owned_read_file_with_outcome
      ~ownership_root:t.ownership_root
      ~args
    |> execution_result
  | Workspace_producer, Search_files ->
    Error (Runtime_error "workspace producers do not expose tool_search_files")
  (* Evidence notes carry URLs (a PR, a CI run) the judge must be able to
     dereference itself — a producer's claim about a URL is not inspection
     (masc#28989: three genuinely-completed submissions rejected because the
     PR URL arrived as "a note, not proof"). The shared web-fetch tool owns
     the boundary guards: http/https only, private-network and localhost
     targets refused, validated redirects, bounded extraction. It reads the
     public internet, not the producer tree, so it is producer-scope
     independent; it dispatches directly because the judge has no turn
     continuation for a Gate to resume. *)
  | (Keeper_producer _ | Workspace_producer), Board_source ->
    collaboration_read Verification_collaboration_evidence.read_board
  | (Keeper_producer _ | Workspace_producer), Fusion_source ->
    collaboration_read Verification_collaboration_evidence.read_fusion
  | (Keeper_producer _ | Workspace_producer), Task_source ->
    collaboration_read Verification_collaboration_evidence.read_task
  | (Keeper_producer _ | Workspace_producer), Web_fetch ->
    Tool_misc_web_fetch.handle
      ~tool_name:(tool_name Web_fetch)
      ~start_time:(Tool_timing.start ())
      args
    |> Keeper_tool_execution.of_tool_result
    |> execution_result
;;


(* The probe read is bounded, but the whole-file escalation below is what the
   inspectors hash, copy to disk and decode. Without a ceiling the size is the
   submitter's choice: the read returns one OCaml string, [inspect] writes it
   back out and reads it again, so a single oversized artifact costs several
   times its own length in resident memory before any verdict exists. Reading
   one byte past the ceiling is what separates "this is the whole file" from
   "this file is over the limit" without loading the rest of it. Sits above the
   image byte limit, which stays the binding number for images. *)
(* One ceiling for every whole-media escalation on this surface. The number is
   the PDF inspection's, because that is where it was first needed and main now
   carries it; MP4 escalates through the same read and must not grow a second
   copy that can drift away from it. The name says media because both formats
   are bounded here. *)
let max_media_source_bytes = Verification_pdf_inspection.max_source_bytes

let media_result t tool ~name ~args ~start_time =
  match tool, args with
  | Read_file, `Assoc fields ->
    (match List.assoc_opt "path" fields with
     | Some (`String path) when String_util.is_valid_utf8 path ->
       let cwd =
         match List.assoc_opt "cwd" fields with Some (`String cwd) -> Some cwd | _ -> None
       in
       let limit = Env_config_keeper.KeeperVision.max_image_bytes () in
       let bytes =
         match t.producer_scope with
         | Keeper_producer meta ->
           (* Probe exact bytes so non-UTF-8 box sizes cannot shift the
              signature before format detection. *)
           (match Keeper_tool_filesystem_runtime.read_sandbox_raw_prefix ?read_authority:t.read_authority
                    ~config:t.config ~meta ~path ?cwd
                    ~max_bytes:(min (limit + 1) Tool_shard_limits.read_file_default_max_bytes) () with
            | Error _ as error -> error
            | Ok probe ->
              (match (Verification_media_inspection.is_pdf path probe || Verification_media_inspection.is_presentation path || Verification_media_inspection.is_mp4 path probe), Keeper_vision_tool.sniff_image_media_type probe with
               | false, Error _ -> Ok probe
               | true, _ -> Keeper_tool_filesystem_runtime.read_sandbox_raw_prefix ?read_authority:t.read_authority
                   ~config:t.config ~meta ~path ?cwd
                   ~max_bytes:(max_media_source_bytes + 1) ()
               | false, Ok _ -> Keeper_tool_filesystem_runtime.read_sandbox_raw_prefix ?read_authority:t.read_authority
                   ~config:t.config ~meta ~path ?cwd ~max_bytes:(limit + 1) ()))
         | Workspace_producer ->
           (match Keeper_tool_filesystem_runtime.read_owned_bytes
             ~ownership_root:t.ownership_root ~path ?cwd ~max_bytes:(limit + 1) () with
            | Ok probe when Verification_media_inspection.is_pdf path probe || Verification_media_inspection.is_presentation path || Verification_media_inspection.is_mp4 path probe ->
              (match Keeper_tool_filesystem_runtime.read_owned_bytes
                 ~ownership_root:t.ownership_root ~path ?cwd
                 ~max_bytes:(max_media_source_bytes + 1) () with
               | Error detail -> Error (Keeper_sandbox_read_backend.Read_failed detail)
               | Ok whole -> Ok whole)
            | (Ok _ | Error _) as result ->
              Result.map_error
                (fun detail -> Keeper_sandbox_read_backend.Read_failed detail)
                result)
       in
       (match bytes with
        (* Unreachable today: [bytes] above wraps every error as [Read_failed].
           Kept for exhaustiveness; [Workflow_rejection] stays the right class
           if a future refactor lets these variants through. *)
        | Error (Keeper_sandbox_read_backend.Missing_file detail)
        | Error (Keeper_sandbox_read_backend.Not_a_file detail) ->
          Some (Tool_result.error ~failure_class:Tool_result.Workflow_rejection
            ~tool_name:name ~start_time detail)
        | Error (Keeper_sandbox_read_backend.Read_failed detail)
          when Verification_media_inspection.is_pdf path ""
               || Verification_media_inspection.is_presentation path
               || Verification_media_inspection.is_mp4 path "" ->
          Some (Tool_result.error ~failure_class:Tool_result.Runtime_failure
            ~tool_name:name ~start_time detail)
        | Error (Keeper_sandbox_read_backend.Read_failed _) ->
          None (* The ordinary Read preserves its own error contract. *)
        | Error (Keeper_sandbox_read_backend.Read_refused detail) ->
          Some (Tool_result.error ~failure_class:Tool_result.Workflow_rejection
            ~tool_name:name ~start_time detail)
        (* Only an escalated whole-file read can reach this length: every other
           path here is already capped at the image byte limit or below. PPTX,
           MP4 and PDF all escalate to the same ceiling, so the check sits ahead
           of every one of them. *)
        | Ok bytes when String.length bytes > max_media_source_bytes ->
          Some (Tool_result.error ~failure_class:Tool_result.Policy_rejection
            ~tool_name:name ~start_time
            (Printf.sprintf
               "media_source_too_large: this verifier inspects at most %d bytes whole"
               max_media_source_bytes))
        | Ok bytes when Verification_media_inspection.is_presentation path ->
          if List.mem_assoc "offset" fields || List.mem_assoc "limit" fields then
            Some (Tool_result.error ~failure_class:Tool_result.Workflow_rejection
              ~tool_name:name ~start_time "PPTX files are inspected whole; omit line offset and limit")
          else Some (Verification_media_inspection.presentation_result
            ~base_path:t.config.base_path ~name ~path ~bytes ~start_time ~max_image_bytes:limit)
        | Ok bytes when Verification_media_inspection.is_mp4 path bytes ->
          if List.mem_assoc "offset" fields || List.mem_assoc "limit" fields then
            Some (Tool_result.error ~failure_class:Tool_result.Workflow_rejection
              ~tool_name:name ~start_time "MP4 files are inspected whole; omit line offset and limit")
          else Some (Verification_media_inspection.video_result
            ~base_path:t.config.base_path ~name ~path ~bytes ~start_time)
        | Ok bytes when Verification_media_inspection.is_pdf path bytes ->
          if List.mem_assoc "offset" fields || List.mem_assoc "limit" fields then
            Some (Tool_result.error ~failure_class:Tool_result.Workflow_rejection
              ~tool_name:name ~start_time "PDFs are inspected whole; omit line offset and limit")
          else Some (Verification_media_inspection.pdf_result
            ~base_path:t.config.base_path ~name ~path ~bytes ~start_time ~max_image_bytes:limit)
        | Ok bytes ->
          (match Keeper_vision_tool.sniff_image_media_type bytes with
           | Error _ -> None
           | Ok media_type ->
             let size = String.length bytes in
             if size > limit then
               Some (Tool_result.error ~failure_class:Tool_result.Policy_rejection
                 ~tool_name:name ~start_time "Image exceeds the configured image byte limit")
             else if List.mem_assoc "offset" fields || List.mem_assoc "limit" fields then
               Some (Tool_result.error ~failure_class:Tool_result.Workflow_rejection
                 ~tool_name:name ~start_time "Images are read whole; omit line offset and limit")
             else
               let data = `Assoc
                 [ "path", `String path; "media_type", `String media_type
                 ; "bytes", `Int size
                 ; "sha256", `String Agent_core_sha256.(digest_string bytes |> to_hex)
                 ; "visual_input", `Bool true ] in
               Some (Tool_result.make_ok ~tool_name:name ~start_time ~data
                 ~content_blocks:
                   [ Llm_provider.Types.Text (Yojson.Safe.to_string data)
                   ; Llm_provider.Types.image_block ~media_type
                       ~source:(Llm_provider.Types.Base64 (Base64.encode_exn bytes)) ] ()) ))
     | _ -> None)
  | (Read_file | Search_files | Web_fetch | Board_source | Fusion_source | Task_source), _ -> None
;;

let dispatch t ~name ~args =
  let start_time = Tool_timing.start () in
  let text_result = function
    | Ok text -> Tool_result.ok ~tool_name:name ~start_time text
    | Error (Runtime_error detail) -> Tool_result.error ~failure_class:Tool_result.Runtime_failure
        ~tool_name:name ~start_time detail
    | Error (Collaboration_error error) ->
      let failure_class = match error with
        | Verification_collaboration_evidence.Invalid_request _ | Source_unavailable _ -> Tool_result.Workflow_rejection
        | Access_denied _ -> Tool_result.Policy_rejection
        | Storage_failed _ -> Tool_result.Runtime_failure in
      Tool_result.error ~failure_class ~tool_name:name ~start_time
        (Verification_collaboration_evidence.error_to_string error)
  in
  match List.find_opt (fun (tool, _) -> String.equal (tool_name tool) name) t.tools with
  | None ->
    let detail =
      Printf.sprintf
        "unknown tool %s; this review offers %s"
        name
        (String.concat ", " (List.map (fun (tool, _) -> tool_name tool) t.tools))
    in
    log_call t ~name ~argument:"" ~outcome:Unknown_tool;
    Tool_result.error ~failure_class:Tool_result.Workflow_rejection
      ~tool_name:name ~start_time detail
  | Some (tool, descriptor) ->
    let argument = Yojson.Safe.to_string args in
    (match
       Keeper_tool_descriptor_resolution.prepare_model_input_for_descriptor
         ~tool_name:name
         descriptor
         ~input:args
     with
     | Error rejection ->
       let detail = Tool_result.message rejection in
       log_call t ~name ~argument ~outcome:Invalid_input;
       Tool_result.error ~failure_class:Tool_result.Workflow_rejection
         ~tool_name:name ~start_time detail
     | Ok prepared_args ->
       (* Original image bytes and parser-rendered PDF pages travel as typed
          model content. Raw binary bytes are never a visual/text substitute. *)
       let result =
         match media_result t tool ~name ~args:prepared_args ~start_time with
         | Some result -> result
         | None -> text_result (
         match run t tool ~args:prepared_args with
         | (Ok text | Error (Runtime_error text)) as result when String_util.is_valid_utf8 text ->
           result
         | Error (Collaboration_error _) as result -> result
         | Ok bytes | Error (Runtime_error bytes) ->
           Error (Runtime_error
             (Yojson.Safe.to_string
                (`Assoc
                   [ "code", `String "lookup_output_invalid_utf8"
                   ; "tool", `String name
                   ; "output_bytes", `Int (String.length bytes)
                   ; "output_sha256",
                     `String Agent_core_sha256.(digest_string bytes |> to_hex)
                   ; "error",
                     `String "The lookup returned non-UTF-8 bytes, not readable text. No text content was delivered. Binary file bytes are not a visual inspection."
                   ]))))
       in
       log_call
         t
         ~name
         ~argument
         ~outcome:(match result with Tool_result.Completed _ -> Resolved
           | Tool_result.Failed _ | Tool_result.Deferred _ -> Rejected);
       result)
;;

(* This capability is constructed from the host's submitted snapshot, never
   from a caller's dispatch closure or tool-name/layout assertions. *)
type task_review =
  { review_tools : t
  ; subject : Workspace_verification_store.request_header
  ; layout : Task.Anti_rationalization.lookup_root
  ; route : Yojson.Safe.t
  ; binding : string
  }

let keeper_review_route (meta : Keeper_meta_contract.keeper_meta) route =
  `Assoc ["kind", `String "keeper"; "name", `String meta.name;
    "profile", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile);
    "network", `String (Keeper_types_profile_sandbox.network_mode_to_string meta.network_mode);
    "route", route]

let review_route t =
  let open Result.Syntax in
  match t.producer_scope with
  | Workspace_producer -> Ok (`Assoc ["kind", `String "workspace"])
  | Keeper_producer meta ->
    let* route = match meta.sandbox_profile with
      | Docker -> Ok (`Assoc ["kind", `String "shared_mount"])
      | Remote_ssh ->
        let* endpoint = Keeper_sandbox_ssh.resolve_endpoint
          ~base_path:t.config.base_path ~keeper_name:meta.name in
        Ok (`Assoc ["kind", `String "ssh"; "endpoint", `String (Exec_ssh_endpoint.to_toml endpoint)])
      | Micro_vm ->
        (match meta.microvm_backend with
         | Some Keeper_microvm_backend.Apple_container ->
           Keeper_sandbox_remote_lane.apple_snapshot_route ~config:t.config ~meta
         | None | Some (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ->
           let* endpoint = Keeper_sandbox_remote_lane.attached_guest_endpoint ~config:t.config ~meta () in
           Ok (`Assoc ["kind", `String "microvm";
             "argv", `List (List.map (fun x -> `String x) (Keeper_sandbox_remote.transport_argv endpoint));
             "root", `String (Keeper_sandbox_remote.workspace_root endpoint)])) in
    Ok (keeper_review_route meta route)

let captured_review_route t =
  match t.producer_scope, t.read_authority with
  | Keeper_producer meta, Some authority ->
    Ok (keeper_review_route meta (Keeper_sandbox_remote_lane.read_authority_route authority))
  | (Workspace_producer | Keeper_producer _), None -> review_route t
  | Workspace_producer, Some _ -> Error "workspace producer cannot own a Keeper endpoint"


let create_task_review ~config ~verification_id ~task_id ~producer ~evidence_access =
  let open Result.Syntax in
  match evidence_access with
  | Workspace_verification_store.Evidence_unavailable {request_id; reason} ->
    Error (Workspace_verification_store.evidence_access_failure_to_string ~request_id reason)
  | Evidence_available {request; items} ->
    if not (String.equal request.id verification_id && String.equal request.task_id task_id
      && String.equal request.worker producer)
    then Error "submitted evidence does not name this verification, task and producer"
    else
      let* review_tools = create ~config ~producer ~submitted_evidence:items in
      let layout = Task.Anti_rationalization.Producer_namespace
        {root=review_tools.ownership_root} in
      let* route = captured_review_route review_tools in
      let tool_json (tool : Types_core.tool_schema) =
        `Assoc ["name", `String tool.name; "description", `String tool.description;
          "input_schema", tool.input_schema] in
      let projection = `Assoc ["purpose", `String "task_review";
        "subject", Workspace_verification_store.request_header_to_yojson request;
        "base_path", `String config.Workspace.base_path;
        "ownership_root", `String review_tools.ownership_root;
        "route", route;
        "read_authority", (match review_tools.read_authority with None -> `Null
          | Some authority -> Keeper_sandbox_remote_lane.read_authority_identity authority);
        "schemas", `List (List.map tool_json (schemas review_tools));
        "submitted_evidence", `List (List.map Workspace_verification_store.submitted_evidence_item_to_yojson items)] in
      let* canonical = Lane_addon_action.canonical projection in
      let binding = Lane_addon_store.digest (Yojson.Safe.to_string canonical) in
      Ok {review_tools; subject=request; layout; route; binding}

let task_review_binding t = t.binding
let task_review_base_path t = t.review_tools.config.base_path
let task_review_root t = t.layout
let task_review_tools t = t.review_tools
let task_review_subject t = t.subject

let validate_task_review t =
  let open Result.Syntax in
  let* route = review_route t.review_tools in
  if Yojson.Safe.equal route t.route then Ok ()
  else Error "verifier lookup route changed after authority preparation"

let task_review_lookup t : Task.Anti_rationalization.lookup_surface =
  { schemas = schemas t.review_tools
  ; dispatch = (fun ~name ~args ->
      match validate_task_review t with
      | Ok () -> dispatch t.review_tools ~name ~args
      | Error detail -> Tool_result.error ~failure_class:Tool_result.Policy_rejection
          ~tool_name:name ~start_time:(Tool_timing.start ()) detail)
  }

type goal_subject = {
  goal_id : string;
  request_id : string;
  criterion : Goal_store.criterion;
}

type goal_review = {
  goal_tools : t;
  goal_subject : goal_subject;
  goal_measurement : Goal_measurement.observation;
  goal_layout : string list;
  goal_binding : string;
}

let create_goal_review ~config ~goal_id =
  let open Result.Syntax in
    let* goal, (request_id, criterion, submitted_evidence) =
      Goal_verification.bind_review config ~goal_id in
    let subject = {goal_id; request_id; criterion} in
    let goal_measurement = Goal_measurement.latest_for_goal
      (Goal_measurement.load config) goal in
    let* goal_tools = create_goal_proof ~config ~submitted_evidence in
    let* goal_layout = goal_proof_root_layout goal_tools in
    let tool_json (tool : Types_core.tool_schema) =
      `Assoc ["name", `String tool.name; "description", `String tool.description;
        "input_schema", tool.input_schema] in
    let projection = `Assoc ["purpose", `String "goal_proof_review";
      "goal_id", `String subject.goal_id; "request_id", `String subject.request_id;
      "criterion", Goal_store.criterion_to_yojson subject.criterion;
      "base_path", `String config.Workspace.base_path;
      "ownership_root", `String goal_tools.ownership_root;
      "schemas", `List (List.map tool_json (schemas goal_tools));
      "submitted_evidence", `List (List.map
        Workspace_verification_store.submitted_evidence_item_to_yojson submitted_evidence)] in
    let* canonical = Lane_addon_action.canonical projection in
    let goal_binding = Lane_addon_store.digest (Yojson.Safe.to_string canonical) in
    (* The report is context, not a grant. Its bytes enter the retained
       original prompt; an updated report cannot revoke that original's
       unchanged subject, submitted snapshot or read-only lookup authority. *)
    Ok {goal_tools; goal_subject=subject; goal_measurement; goal_layout; goal_binding}

let goal_review_subject t = t.goal_subject
let goal_review_measurement t = t.goal_measurement
let goal_review_evidence t = t.goal_tools.submitted_evidence
let goal_review_binding t = t.goal_binding
let goal_review_root_layout t = t.goal_layout
let goal_review_base_path t = t.goal_tools.config.base_path
let goal_review_lookup t : Task.Anti_rationalization.lookup_surface =
  {schemas=schemas t.goal_tools; dispatch=dispatch t.goal_tools}
