open Keeper_meta_contract

(* The articles ride every turn of every keeper in the world. 12 KiB is still a
   rounding error against every context this fleet runs, and it stays well
   inside the smallest one. The operator raised this from 4 KiB (2026-10-05)
   when a cadence article no longer fit, and from 8 KiB (2026-10-10) so the
   adopted release-candidate norms (규약 제안 #15) could be recorded without
   first deleting norms. *)
let render_byte_ceiling = 12288

(* One norm is one sentence. Without a per-article cap a single write can be
   larger than the whole ceiling, and the ceiling message would then tell a
   keeper to remove something from an empty world. *)
let article_byte_cap = 512

let string_arg args field =
  match args with
  | `Assoc fields -> (
    match List.find_opt (fun (key, _) -> String.equal key field) fields with
    | Some (_, `String value) -> Some value
    | Some _ | None -> None)
  | _ -> None

let load_ledger ~(config : Workspace.config) =
  let result =
    let open Result.Syntax in
    let* resolve_subject = Keeper_constitution_roster.read ~config in
    World_constitution_store.load ~base_path:config.base_path ~resolve_subject
  in
  match result with
  | Ok ledger -> Ok ledger
  | Error error ->
    Error (World_constitution_store.read_error_to_string error)

(* A ledger that moved since this call read it is a state to read again; a
   directory or write failure is the runtime's. *)
let append_failure_class : World_constitution_store.append_error -> Tool_result.tool_failure_class
  = function
  | World_constitution_store.Ledger_moved _ -> Tool_result.Workflow_rejection
  | World_constitution_store.Directory_unavailable _
  | World_constitution_store.Write_failed _ -> Tool_result.Runtime_failure

(* Lines the ledger could not decode are the store's to report and this tool's
   to pass on, and lines from outside the roster go beside them. A keeper
   calling these tools is the one reader in a position to act, and saying
   nothing here is what would make the store's own contract a lie. Omitted
   when there are none, so the ordinary answer stays quiet. *)
(* Every other keeper tool answers inside an [ok] envelope, and the dispatch
   suite checks for it: a result without it reads as a failure to the same
   caller that reads the rest. *)
let ok_envelope fields = `Assoc (("ok", `Bool true) :: fields)

let with_line_diagnostics (ledger : World_constitution_store.ledger) fields =
  let with_unreadable =
    match ledger.World_constitution_store.rejected with
    | [] -> fields
    | rejected ->
      fields
      @ [ ( "unreadable_ledger_lines"
          , `List
              (List.map
                 (fun (line : World_constitution_store.rejected_line) ->
                   `Assoc
                     [ "line", `Int line.World_constitution_store.line_number
                     ; "detail", `String line.World_constitution_store.detail
                     ])
                 rejected) )
        ]
  in
  match ledger.World_constitution_store.isolated with
  | [] -> with_unreadable
  | isolated ->
    with_unreadable
    @ [ ( "isolated_ledger_lines"
        , `List
            (List.map
               (fun (line : World_constitution_store.isolated_line) ->
                 `Assoc
                   [ "line", `Int line.World_constitution_store.line_number
                   ; "subject", `String line.World_constitution_store.subject
                   ; ( "article_ids"
                     , `List
                         (List.map
                            (fun id ->
                              `String (World_constitution_types.Article_id.to_string id))
                            line.World_constitution_store.article_ids) )
                   ])
               isolated) )
      ]

let read_with_outcome ~(config : Workspace.config) =
  match load_ledger ~config with
  | Error detail -> Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure detail
  | Ok ledger ->
    Keeper_tool_execution.success_data
      (ok_envelope
         (with_line_diagnostics ledger
            [ "articles_held", `Int (List.length ledger.articles)
            ; "entries", `List (List.map World_constitution_wire.entry_to_json ledger.entries)
            ]))

(* [replaces] names the held articles one norm supersedes. Absent, null or
   empty is a plain write; anything else must be an array of article ids,
   each named once (RFC-0504 §2.2). *)
let replaces_arg args =
  match args with
  | `Assoc fields -> (
    match List.find_opt (fun (key, _) -> String.equal key "replaces") fields with
    | None | Some (_, `Null) -> Ok []
    | Some (_, `List items) ->
      let rec decode acc = function
        | [] -> Ok (List.rev acc)
        | `String raw :: rest -> (
          match World_constitution_types.Article_id.of_string raw with
          | Ok id -> decode (id :: acc) rest
          | Error detail -> Error detail)
        | _ :: _ -> Error "replaces must be an array of article_id strings"
      in
      (match decode [] items with
      | Error _ as error -> error
      | Ok ids ->
        let rec duplicate = function
          | [] -> None
          | id :: rest ->
            if
              List.exists
                (World_constitution_types.Article_id.equal id)
                rest
            then Some id
            else duplicate rest
        in
        (match duplicate ids with
        | None -> Ok ids
        | Some id ->
          Error
            (Printf.sprintf "replaces names article %s twice; name each retired article once"
               (World_constitution_types.Article_id.to_string id))))
    | Some _ -> Error "replaces must be an array of article_id strings")
  | _ -> Ok []

(* Every replaced id must name a norm the world holds now — retiring what is
   not held is a failure, not a quiet success, like removing it (RFC-0504
   §2.2). Answers the articles in [replaces] order. *)
let resolve_superseded held ids =
  let rec resolve acc = function
    | [] -> Ok (List.rev acc)
    | id :: rest -> (
      match
        List.find_opt
          (fun (article : World_constitution_types.t) ->
            World_constitution_types.Article_id.equal article.id id)
          held
      with
      | None ->
        Error
          (Printf.sprintf "no article %s is held by this world; nothing was replaced"
             (World_constitution_types.Article_id.to_string id))
      | Some article -> resolve (article :: acc) rest)
  in
  resolve [] ids

(* A reason is the digest a later reader gets: who retired the norm is in
   [by], but why is only here. Omitted when the caller gave none; a blank
   reason is refused rather than stored, because an empty digest answers
   nothing and an omitted field says so honestly. Shared by removal and
   replacement: both retire a norm someone may later ask after. *)
let reason_arg args =
  match string_arg args "reason" with
  | None -> Ok None
  | Some raw when String.equal (String.trim raw) "" ->
    Error
      "reason is present but blank: omit it or say why the norm is taken back"
  | Some raw when String.exists (fun c -> Char.equal c '\n' || Char.equal c '\r') raw ->
    Error "reason spans more than one line; give the reason on one line"
  | Some raw when String.length raw > article_byte_cap ->
    Error
      (Printf.sprintf
         "this reason is %d bytes, over the %d-byte limit for one article: say it in one sentence"
         (String.length raw) article_byte_cap)
  | Some raw -> Ok (Some raw)

let write_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~args =
  let base_path = config.Workspace.base_path in
  match string_arg args "text" with
  | None ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      "text is required and must be a string: the sentence the world agreed on"
  | Some text -> (
    (* [replaces] decides the move before anything else is validated: a
       replacement answers the bundle rule, not the per-article cap
       (RFC-0504 §2.2-§2.3). *)
    match replaces_arg args, reason_arg args with
    | Error detail, _ | _, Error detail ->
      Keeper_tool_execution.failure ~class_:Tool_result.Policy_rejection detail
    | Ok replaces, Ok reason -> (
      match replaces, reason with
      | [], Some _ ->
        Keeper_tool_execution.failure
          ~class_:Tool_result.Policy_rejection
          "reason names why a bundle was replaced; omit it for a plain write"
      | [], None | _ :: _, _ -> (
        let over_cap =
          match replaces with
          | [] -> String.length text > article_byte_cap
          | _ :: _ -> false
        in
        if over_cap then
          Keeper_tool_execution.failure
            ~class_:Tool_result.Policy_rejection
            (Printf.sprintf
               "this norm is %d bytes, over the %d-byte limit for one article: say it \
                in one sentence"
               (String.length text) article_byte_cap)
        else (
          let evidence =
      match string_arg args "evidence_uri" with
      | None -> []
      | Some uri -> [ { World_constitution_types.uri } ]
    in
    match
      World_constitution_types.make
        ~id:(World_constitution_types.Article_id.generate ())
        ~text ~author:meta.name ~at:(Time_compat.now ()) ~evidence
    with
    | Error invalid ->
      (* The author is this keeper's name, not the caller's argument. *)
      let class_ =
        match invalid with
        | World_constitution_types.Empty_text
        | World_constitution_types.Multiline_text
        | World_constitution_types.Empty_evidence_uri _ -> Tool_result.Policy_rejection
        | World_constitution_types.Empty_author -> Tool_result.Runtime_failure
      in
      Keeper_tool_execution.failure
        ~class_
        (World_constitution_types.invalid_to_string invalid)
    | Ok article -> (
      match load_ledger ~config with
      | Error detail -> Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure detail
      | Ok ledger ->
        let held = ledger.World_constitution_store.articles in
        match replaces with
        | [] ->
          let projected =
            World_constitution_render.articles (held @ [ article ])
          in
          if String.length projected > render_byte_ceiling then
            Keeper_tool_execution.failure
              ~class_:Tool_result.Workflow_rejection
              (Printf.sprintf
                 "the world's articles would reach %d bytes, over the %d-byte \
                  ceiling; it holds %d: remove one with \
                  keeper_constitution_remove before adding another"
                 (String.length projected) render_byte_ceiling
                 (List.length held))
          else (
            match
              World_constitution_store.append_at ~base_path
                ~expected_end_offset:ledger.World_constitution_store.end_offset
                (World_constitution_types.Added article)
            with
            | Error error ->
              Keeper_tool_execution.failure
                ~class_:(append_failure_class error)
                (World_constitution_store.append_error_to_string error)
            | Ok () ->
              Keeper_tool_execution.success_data
                (ok_envelope
                   (with_line_diagnostics ledger
                      [ ( "article_id"
                        , `String
                            (World_constitution_types.Article_id.to_string
                               article.id) )
                      ; "articles_held", `Int (List.length held + 1)
                      ; "rendered_bytes", `Int (String.length projected)
                      ])))
        | _ :: _ as ids -> (
          match resolve_superseded held ids with
          | Error detail ->
            Keeper_tool_execution.failure ~class_:Tool_result.Policy_rejection detail
          | Ok bundle ->
            (* RFC-0504 §2.3: the replacement must render smaller than the
               bundle it retires — a merge that grows the render is refused. *)
            let replacement_bytes =
              String.length (World_constitution_render.articles [ article ])
            in
            let bundle_bytes =
              List.fold_left ( + ) 0
                (List.map
                   (fun retired ->
                     String.length (World_constitution_render.articles [ retired ]))
                   bundle)
            in
            if replacement_bytes >= bundle_bytes then
              Keeper_tool_execution.failure
                ~class_:Tool_result.Policy_rejection
                (Printf.sprintf
                   "this replacement renders %d bytes, not smaller than the %d bytes \
                    of the %d articles it would retire: a merge must shrink the render"
                   replacement_bytes bundle_bytes (List.length bundle))
            else (
              let survivors =
                List.filter
                  (fun (existing : World_constitution_types.t) ->
                    not
                      (List.exists
                         (World_constitution_types.Article_id.equal existing.id)
                         ids))
                  held
              in
              let projected =
                World_constitution_render.articles (survivors @ [ article ])
              in
              if String.length projected > render_byte_ceiling then
                Keeper_tool_execution.failure
                  ~class_:Tool_result.Workflow_rejection
                  (Printf.sprintf
                     "the world's articles would reach %d bytes, over the %d-byte \
                      ceiling; it holds %d: remove one with \
                      keeper_constitution_remove before adding another"
                     (String.length projected) render_byte_ceiling
                     (List.length held))
              else (
                match
                  World_constitution_store.append_at ~base_path
                    ~expected_end_offset:ledger.World_constitution_store.end_offset
                    (World_constitution_types.Replaced
                       { superseded = ids; article; by = meta.name;
                         at = Time_compat.now (); reason })
                with
                | Error error ->
                  Keeper_tool_execution.failure
                    ~class_:(append_failure_class error)
                    (World_constitution_store.append_error_to_string error)
                | Ok () ->
                  Keeper_tool_execution.success_data
                    (ok_envelope
                       (with_line_diagnostics ledger
                          [ ( "article_id"
                            , `String
                                (World_constitution_types.Article_id.to_string
                                   article.id) )
                          ; "articles_held"
                          , `Int (List.length held - List.length bundle + 1)
                          ; "rendered_bytes", `Int (String.length projected)
                          ]))))))))))

let remove_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~args =
  let base_path = config.Workspace.base_path in
  match string_arg args "article_id" with
  | None ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      "article_id is required and must be a string"
  | Some raw -> (
    match World_constitution_types.Article_id.of_string raw with
    | Error detail -> Keeper_tool_execution.failure ~class_:Tool_result.Policy_rejection detail
    | Ok id -> (
      match reason_arg args with
      | Error detail ->
        Keeper_tool_execution.failure ~class_:Tool_result.Policy_rejection detail
      | Ok reason -> (
        match load_ledger ~config with
        | Error detail ->
          Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure detail
        | Ok ledger ->
          let held = ledger.World_constitution_store.articles in
          let found =
            List.find_opt
              (fun (article : World_constitution_types.t) ->
                World_constitution_types.Article_id.equal article.id id)
              held
          in
          (match found with
          | None ->
            Keeper_tool_execution.failure
              ~class_:Tool_result.Policy_rejection
              (Printf.sprintf
                 "no article %s is held by this world; nothing was removed"
                 raw)
          | Some removed -> (
            match
              World_constitution_store.append_at ~base_path
                ~expected_end_offset:
                  ledger.World_constitution_store.end_offset
                (World_constitution_types.Removed
                   { id; by = meta.name; at = Time_compat.now (); reason })
            with
            | Error error ->
              Keeper_tool_execution.failure
                ~class_:(append_failure_class error)
                (World_constitution_store.append_error_to_string error)
            | Ok () ->
              Keeper_tool_execution.success_data
                (ok_envelope
                   (with_line_diagnostics ledger
                      ([ "article_id", `String raw
                       ; "removed_text", `String removed.text
                       ; "articles_held", `Int (List.length held - 1)
                       ]
                       @ (match reason with
                         | None -> []
                         | Some why -> [ "reason", `String why ])))))))))
