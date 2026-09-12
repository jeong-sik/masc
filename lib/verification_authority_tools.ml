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

let tool_name = function
  | Read_file -> "tool_read_file"
  | Search_files -> "tool_search_files"
  | Web_fetch -> "masc_web_fetch"
  | Board_source -> "masc_board_post_get"
  | Fusion_source -> "masc_fusion_status"
;;

let all_tools = [ Read_file; Search_files; Web_fetch; Board_source; Fusion_source ]

type t =
  { ownership_root : string
  ; config : Workspace.config
  ; collaboration_authority : Verification_collaboration_evidence.authority
  ; producer_scope : producer_scope
  ; tools : (tool * Keeper_tool_descriptor.t) list
  }

and producer_scope =
  | Keeper_producer of Keeper_meta_contract.keeper_meta
  | Workspace_producer

let descriptor_of_tool tool =
  match Keeper_tool_descriptor.descriptors_for_internal (tool_name tool) with
  | [ descriptor ] -> Ok (tool, descriptor)
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

let create ~config ~producer =
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
      (match producer_scope with
       | Keeper_producer _ -> all_tools
       | Workspace_producer -> [ Read_file; Web_fetch; Board_source; Fusion_source ])
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
  Ok { ownership_root; config; producer_scope; tools
     ; collaboration_authority = Verification_collaboration_evidence.Task_producer producer }
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
let create_goal_proof ~(config : Workspace.config) =
  let open Result.Syntax in
  let* tools = resolve_tools [ Read_file; Web_fetch; Board_source; Fusion_source ] in
  let project_root =
    Workspace_verification_store.project_root_of_base_path config.base_path
  in
  let ownership_root =
    Env_config_core.strip_trailing_slashes
      (Filename.concat project_root Playground_paths.all_playgrounds_prefix)
  in
  Ok { ownership_root; config; producer_scope = Workspace_producer; tools
     ; collaboration_authority = Verification_collaboration_evidence.Goal_workspace }
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

let checkout_lines root =
  match Keeper_playground_checkouts.discover ~root with
  | Error error ->
    Error (Keeper_playground_checkouts.scan_error_to_string error)
  | Ok (Keeper_playground_checkouts.Partial { limit; _ }) ->
    Error
      (Printf.sprintf
         "checkout discovery is partial: %s"
         (Keeper_playground_checkouts.limit_to_string limit))
  | Ok (Keeper_playground_checkouts.Complete checkouts) ->
    let describe (checkout : Keeper_playground_checkouts.checkout) =
      Printf.sprintf
        "  %s/    (git checkout — a repository-relative path is rooted here)"
        checkout.relative_path
    in
    Ok (List.map describe checkouts)
;;

let entry_lines_of root ~cap =
  let open Result.Syntax in
  let* entries =
    children root
    |> Result.map_error (fun detail ->
      Printf.sprintf "verification root unreadable: %s" detail)
  in
  let entries = List.sort String.compare entries in
  let shown = List.filteri (fun index _ -> index < cap) entries in
  let omitted = List.length entries - List.length shown in
  let lines = List.map (fun entry -> "  " ^ entry) shown in
  Ok
    (if omitted <= 0
     then lines
     else lines @ [ Printf.sprintf "  ... and %d more" omitted ])
;;

let root_kind root =
  try Ok (Fs_compat.exact_path_kind ~follow:false root) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error detail -> Error detail
  | Unix.Unix_error (code, operation, _) ->
    Error (Printf.sprintf "%s: %s" operation (Unix.error_message code))
;;

let absent_root_layout root =
  match
    Prompt_registry.render_prompt_template
      Prompt_names.verification_lookup_root_layout_absent
      [ "root", root ]
  with
  | Ok text -> Ok [ String.trim text ]
  | Error detail ->
    Error
      (Printf.sprintf
         "prompt %s: %s"
         Prompt_names.verification_lookup_root_layout_absent
         detail)
;;

(* Nothing creates a workspace producer's playground: no boot, no sandbox.
   So its absence is a fact about the producer, not an unavailable surface,
   and the judge receives it as the layout and rules on the evidence that is
   there (the snapshot's notes, URLs, and typed unreadable artifacts).
   Treating it as unavailable deferred the review on every sweep and left
   every Task submitted over MCP in AwaitingVerification with nobody told:
   nine Tasks, 131 identical warning lines on 2026-09-11. A Keeper's root is
   different -- the sandbox creates it at boot, so its absence is
   infrastructure and stays a deferral. *)
let root_layout t =
  let open Result.Syntax in
  match t.producer_scope, root_kind t.ownership_root with
  | Workspace_producer, Ok Fs_compat.Exact_missing ->
    absent_root_layout t.ownership_root
  | ( Workspace_producer
    , (Ok (Fs_compat.Exact_unknown | Fs_compat.Exact_kind _) | Error _) )
  | Keeper_producer _, _ ->
    let* entry_lines = entry_lines_of t.ownership_root ~cap:root_entry_cap in
    let* checkout_lines = checkout_lines t.ownership_root in
    Ok (entry_lines @ checkout_lines)
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
   and embedded audio/video playback are not inspected. \
   MP4 files are inspected whole with \
   FFprobe and FFmpeg: original source SHA-256/bytes, stream metadata and direct \
   complete audio/video decode results are returned. That decode is not a visual \
   frame inspection or an accessibility verdict."

let schema_of_tool (tool, (descriptor : Keeper_tool_descriptor.t)) : Types_core.tool_schema =
  { Types_core.name = tool_name tool
  ; description =
      (match tool with
       | Read_file -> descriptor.description ^ " " ^ image_delivery_note
       | Board_source ->
         "Read an exact Board post and its paginated comments as original structured evidence, including identities and full metadata. Task reviews can read shared posts and their producer's own Direct posts; Goal reviews read shared workspace posts only. Read-only: no posting, voting or adoption."
       | Fusion_source ->
         "Read original durable Fusion panel/judge/source-context evidence and separately recorded Keeper decisions by required exact run_id. Task reviews read the actual producer's Fusion source; Goal reviews read shared workspace Fusion source. This does not run Fusion or adopt advice."
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
    read ~config:t.config ~authority:t.collaboration_authority ~args
    |> Result.map Yojson.Safe.to_string
    |> Result.map_error (fun error -> Collaboration_error error)
  in
  match t.producer_scope, tool with
  | Keeper_producer producer_meta, Read_file ->
    Keeper_tool_filesystem_runtime.handle_read_file_with_outcome
      ~turn_sandbox_factory:None
      ~config:t.config
      ~meta:producer_meta
      ~args
    |> execution_result
  | Keeper_producer producer_meta, Search_files ->
    Keeper_workspace_ops.handle_tool_search_files_with_outcome
      ~turn_sandbox_factory:None
      ~config:t.config
      ~meta:producer_meta
      ~args
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
  | (Keeper_producer _ | Workspace_producer), Web_fetch ->
    Tool_misc_web_fetch.handle
      ~tool_name:(tool_name Web_fetch)
      ~start_time:(Time_compat.now ())
      args
    |> Keeper_tool_execution.of_tool_result
    |> execution_result
;;

let is_pdf path bytes =
  String.equal (String.lowercase_ascii (Filename.extension path)) ".pdf"
  || String.starts_with ~prefix:"%PDF-" bytes

let is_mp4 path = String.equal (String.lowercase_ascii (Filename.extension path)) ".mp4"

let video_result t ~name ~path ~bytes ~start_time =
  match Verification_video_inspection.inspect ~base_path:t.config.base_path ~bytes with
  | Error error -> Tool_result.error ~failure_class:Tool_result.Runtime_failure
      ~tool_name:name ~start_time (Verification_video_inspection.error_to_string error)
  | Ok inspection ->
    let data = `Assoc ["path",`String path; "inspection",Verification_video_inspection.to_yojson inspection] in
    Tool_result.make_ok ~tool_name:name ~start_time ~data ()

let pdf_result t ~name ~path ~bytes ~start_time ~max_image_bytes =
  match Verification_pdf_inspection.inspect
    ~base_path:t.config.base_path ~max_image_bytes ~bytes with
  | Error error ->
    let failure_class = match error with
      | Verification_pdf_inspection.Image_policy_rejected _ -> Tool_result.Policy_rejection
      | Dependency_unavailable _ | Command_failed _ | Invalid_output _ | Storage_failed _ ->
        Tool_result.Runtime_failure in
    Tool_result.error ~failure_class ~tool_name:name ~start_time
      (Verification_pdf_inspection.error_to_string error)
  | Ok inspection ->
    let page_count = List.length inspection.pages in
    let pages = List.map (fun (page : Verification_pdf_inspection.page) ->
      `Assoc ["page",`Int page.number;"width_points",`Float page.width_points;
              "height_points",`Float page.height_points;"text",`String page.text;
              "rendered_media_type",`String "image/png";
              "rendered_bytes",`Int (String.length page.png);
              "rendered_sha256",`String Digestif.SHA256.(digest_string page.png |> to_hex)]) inspection.pages in
    let data = `Assoc ["path",`String path;"media_type",`String "application/pdf";
      "bytes",`Int inspection.source_bytes;"sha256",`String inspection.source_sha256;
      "page_count",`Int page_count;"pages",`List pages;
      "inspection",`String "Poppler pdftotext XML and pdftoppm rendering of the same complete captured PDF";
      "diagnostics",`List (List.map (fun text -> `String text) inspection.diagnostics);
      "visual_input",`Bool true] in
    let content_blocks = Llm_provider.Types.Text (Yojson.Safe.to_string data) ::
      List.concat_map (fun (page : Verification_pdf_inspection.page) ->
        [Llm_provider.Types.Text (Printf.sprintf "PDF page %d of %d; source sha256=%s"
          page.number page_count inspection.source_sha256);
         Llm_provider.Types.image_block ~media_type:"image/png" ~data:(Base64.encode_exn page.png) ()]) inspection.pages in
    Tool_result.make_ok ~tool_name:name ~start_time ~data ~content_blocks ()

let is_presentation path =
  String.equal (String.lowercase_ascii (Filename.extension path)) ".pptx"

let presentation_result t ~name ~path ~bytes ~start_time ~max_image_bytes =
  match Verification_presentation_inspection.inspect
    ~base_path:t.config.base_path ~max_image_bytes ~bytes with
  | Error error ->
    let failure_class = match error with
      | Verification_presentation_inspection.Policy_rejected _
      | Pdf_inspection_failed (Verification_pdf_inspection.Image_policy_rejected _) ->
        Tool_result.Policy_rejection
      | Dependency_unavailable _ | Command_failed _ | Invalid_output _
      | Storage_failed _ | Pdf_inspection_failed _ -> Tool_result.Runtime_failure in
    Tool_result.error ~failure_class ~tool_name:name ~start_time
      (Verification_presentation_inspection.error_to_string error)
  | Ok inspection ->
    let slides = List.map (fun (slide : Verification_presentation_inspection.slide) ->
      `Assoc ["slide",`Int slide.number; "text",`String slide.text;
        "speaker_notes",(match slide.speaker_notes with None -> `Null | Some notes -> `String notes)])
      inspection.slides in
    let pages = List.map (fun (page : Verification_pdf_inspection.page) ->
      `Assoc ["slide",`Int page.number;"width_points",`Float page.width_points;
        "height_points",`Float page.height_points;"rendered_text",`String page.text;
        "rendered_bytes",`Int (String.length page.png);
        "rendered_sha256",`String Digestif.SHA256.(digest_string page.png |> to_hex)])
      inspection.rendered_pdf.pages in
    let data = `Assoc ["path",`String path;
      "media_type",`String "application/vnd.openxmlformats-officedocument.presentationml.presentation";
      "bytes",`Int inspection.source_bytes;"sha256",`String inspection.source_sha256;
      "slide_count",`Int (List.length inspection.slides);"slides",`List slides;
      "rendered_pdf_sha256",`String inspection.rendered_pdf.source_sha256;
      "rendered_pdf_bytes",`Int inspection.rendered_pdf.source_bytes;
      "rendered_slides",`List pages;"visual_input",`Bool true;
      "inspection",`String "python-pptx source parsing and LibreOffice PDF rendering of the same complete captured PPTX; every PDF page inspected with Poppler";
      "not_inspected",`List [ `String "animations";`String "embedded audio/video playback";`String "chart data";`String "accessibility verdict" ];
      "diagnostics",`List (List.map (fun text -> `String text) inspection.diagnostics)] in
    let content_blocks = Llm_provider.Types.Text (Yojson.Safe.to_string data) ::
      List.concat_map (fun (page : Verification_pdf_inspection.page) ->
        [ Llm_provider.Types.Text (Printf.sprintf "PPTX slide %d of %d; original sha256=%s"
            page.number (List.length inspection.slides) inspection.source_sha256);
          Llm_provider.Types.image_block ~media_type:"image/png"
            ~data:(Base64.encode_exn page.png) () ]) inspection.rendered_pdf.pages in
    Tool_result.make_ok ~tool_name:name ~start_time ~data ~content_blocks ()

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
           (* The bounded probe identifies the format only. Its potentially
              text-projected body never becomes image input or hash evidence. *)
           (match Keeper_tool_filesystem_runtime.read_sandbox_bytes
                    ~config:t.config ~meta ~path ?cwd
                    ~max_bytes:(min (limit + 1) Tool_shard_limits.read_file_default_max_bytes) () with
            | Error _ as error -> error
            | Ok probe ->
              (match (is_pdf path probe || is_presentation path || is_mp4 path), Keeper_vision_tool.sniff_image_media_type probe with
               | false, Error _ -> Ok probe
               | true, _ | false, Ok _ -> Keeper_tool_filesystem_runtime.read_complete_sandbox_bytes
                   ~config:t.config ~meta ~path ?cwd ()))
         | Workspace_producer ->
           (match Keeper_tool_filesystem_runtime.read_owned_bytes
             ~ownership_root:t.ownership_root ~path ?cwd ~max_bytes:(limit + 1) () with
            | Ok probe when is_pdf path probe || is_presentation path || is_mp4 path ->
              Keeper_tool_filesystem_runtime.read_complete_owned_bytes
                ~ownership_root:t.ownership_root ~path ?cwd ()
            | result -> result)
       in
       (match bytes with
        | Error detail when is_pdf path "" || is_presentation path || is_mp4 path ->
          Some (Tool_result.error ~failure_class:Tool_result.Runtime_failure
            ~tool_name:name ~start_time detail)
        | Error _ -> None (* The ordinary Read preserves its own error contract. *)
        | Ok bytes when is_presentation path ->
          if List.mem_assoc "offset" fields || List.mem_assoc "limit" fields then
            Some (Tool_result.error ~failure_class:Tool_result.Workflow_rejection
              ~tool_name:name ~start_time "PPTX files are inspected whole; omit line offset and limit")
          else Some (presentation_result t ~name ~path ~bytes ~start_time ~max_image_bytes:limit)
        | Ok bytes when is_mp4 path ->
          if List.mem_assoc "offset" fields || List.mem_assoc "limit" fields then
            Some (Tool_result.error ~failure_class:Tool_result.Workflow_rejection
              ~tool_name:name ~start_time "MP4 files are inspected whole; omit line offset and limit")
          else Some (video_result t ~name ~path ~bytes ~start_time)
        | Ok bytes when is_pdf path bytes ->
          if List.mem_assoc "offset" fields || List.mem_assoc "limit" fields then
            Some (Tool_result.error ~failure_class:Tool_result.Workflow_rejection
              ~tool_name:name ~start_time "PDFs are inspected whole; omit line offset and limit")
          else Some (pdf_result t ~name ~path ~bytes ~start_time ~max_image_bytes:limit)
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
                 ; "sha256", `String Digestif.SHA256.(digest_string bytes |> to_hex)
                 ; "visual_input", `Bool true ] in
               Some (Tool_result.make_ok ~tool_name:name ~start_time ~data
                 ~content_blocks:
                   [ Llm_provider.Types.Text (Yojson.Safe.to_string data)
                   ; Llm_provider.Types.image_block ~media_type
                       ~data:(Base64.encode_exn bytes) () ] ()) ))
     | _ -> None)
  | (Read_file | Search_files | Web_fetch | Board_source | Fusion_source), _ -> None
;;

let dispatch t ~name ~args =
  let start_time = Time_compat.now () in
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
                     `String Digestif.SHA256.(digest_string bytes |> to_hex)
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
