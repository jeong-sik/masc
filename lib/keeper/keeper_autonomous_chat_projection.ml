type intent =
  { keeper_name : string
  ; turn_ref : Ids.Turn_ref.t
  ; content : string
  }

type append_result =
  | Appended of intent
  | Already_present

type issue_stage =
  | Load_pending
  | Persist_intent
  | Append_chat
  | Retire_intent

type issue =
  { stage : issue_stage
  ; detail : string
  }

type pending_batch =
  { intents : intent list
  ; issues : string list
  }

type io =
  { load_pending : unit -> (pending_batch, string) result
  ; persist : intent -> (unit, string) result
  ; append : intent -> (append_result, string) result
  ; retire : intent -> (unit, string) result
  ; broadcast : intent -> unit
  }

let ( let* ) = Result.bind
let schema = "masc.keeper.autonomous-chat-projection.v1"

let issue_stage_to_string = function
  | Load_pending -> "load_pending"
  | Persist_intent -> "persist_intent"
  | Append_chat -> "append_chat"
  | Retire_intent -> "retire_intent"
;;

let issue_to_string issue =
  Printf.sprintf "%s: %s" (issue_stage_to_string issue.stage) issue.detail
;;

let validate intent =
  if String.trim intent.keeper_name = ""
  then Error "projection keeper name must not be blank"
  else if String.trim intent.content = ""
  then Error "projection content must not be blank"
  else Ok ()
;;

let to_yojson intent =
  `Assoc
    [ "schema", `String schema
    ; "keeper_name", `String intent.keeper_name
    ; "turn_ref", `String (Ids.Turn_ref.to_string intent.turn_ref)
    ; "content", `String intent.content
    ]
;;

let of_yojson = function
  | `Assoc fields ->
    let keys = fields |> List.map fst |> List.sort String.compare in
    let expected =
      [ "content"; "keeper_name"; "schema"; "turn_ref" ]
    in
    if keys <> expected
    then Error "projection intent fields are not exact"
    else
      (match
         List.assoc "schema" fields,
         List.assoc "keeper_name" fields,
         List.assoc "turn_ref" fields,
         List.assoc "content" fields
       with
       | `String actual_schema, `String keeper_name, `String turn_ref, `String content
         when String.equal actual_schema schema ->
         (match Ids.Turn_ref.of_string turn_ref with
          | None -> Error "projection intent turn_ref is invalid"
          | Some turn_ref ->
            let intent = { keeper_name; turn_ref; content } in
            let* () = validate intent in
            Ok intent)
       | `String _, _, _, _ -> Error "projection intent schema is unsupported"
       | _ -> Error "projection intent fields have invalid types")
  | _ -> Error "projection intent must be a JSON object"
;;

let project_persisted io intent =
  match io.append intent with
  | Error detail -> [ { stage = Append_chat; detail } ]
  | Ok append_result ->
    (match append_result with
     | Appended appended_intent -> io.broadcast appended_intent
     | Already_present -> ());
    (match io.retire intent with
     | Ok () -> []
     | Error detail -> [ { stage = Retire_intent; detail } ])
;;

let record_and_project io intent =
  match validate intent with
  | Error detail -> [ { stage = Persist_intent; detail } ]
  | Ok () ->
    (match io.persist intent with
     | Error detail -> [ { stage = Persist_intent; detail } ]
     | Ok () -> project_persisted io intent)
;;

let order_pending intents =
  let compare_intent left right =
    Int.compare
      (Ids.Turn_ref.absolute_turn left.turn_ref)
      (Ids.Turn_ref.absolute_turn right.turn_ref)
  in
  let intents = List.sort compare_intent intents in
  let rec reject_ambiguous_order = function
    | left :: right :: _
      when Ids.Turn_ref.absolute_turn left.turn_ref
           = Ids.Turn_ref.absolute_turn right.turn_ref ->
      Error
        (Printf.sprintf
           "projection intents have ambiguous absolute turn %d"
           (Ids.Turn_ref.absolute_turn left.turn_ref))
    | _ :: rest -> reject_ambiguous_order rest
    | [] -> Ok intents
  in
  reject_ambiguous_order intents
;;

let retry_pending io =
  match io.load_pending () with
  | Error detail -> [ { stage = Load_pending; detail } ]
  | Ok { intents; issues } ->
    let load_issues =
      List.map (fun detail -> { stage = Load_pending; detail }) issues
    in
    (match order_pending intents with
     | Error detail -> load_issues @ [ { stage = Load_pending; detail } ]
     | Ok intents ->
       load_issues @ List.concat_map (project_persisted io) intents)
;;

let sha256 value = Digestif.SHA256.(digest_string value |> to_hex)

let root_dir base_dir =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path:base_dir)
    "keeper-chat-projections-v1"
;;

let keeper_dir ~base_dir keeper_name =
  Filename.concat
    (root_dir base_dir)
    ("keeper-" ^ sha256 keeper_name)
;;

let intent_path ~base_dir intent =
  Filename.concat
    (keeper_dir ~base_dir intent.keeper_name)
    (sha256 (Ids.Turn_ref.to_string intent.turn_ref) ^ ".json")
;;

let ensure_projection_dir ~base_dir keeper_name =
  try
    (* fire-and-forget: only the durable directory side effect is needed. *)
    ignore (Keeper_fs.ensure_dir (keeper_dir ~base_dir keeper_name) : string);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let load_intent path =
  let* json = Safe_ops.read_json_file_safe path in
  of_yojson json
;;

let production_io ~base_dir ~keeper_name =
  let load_pending () =
    let dir = keeper_dir ~base_dir keeper_name in
    if not (Fs_compat.file_exists dir)
    then Ok { intents = []; issues = [] }
    else
      try
        let names = Fs_compat.read_dir dir in
        let rec load intents issues = function
          | [] -> Ok { intents; issues = List.rev issues }
          | name :: rest ->
            if not (String.equal (Filename.extension name) ".json")
            then
              load
                intents
                (Printf.sprintf
                   "projection outbox contains unexpected entry %S"
                   name
                 :: issues)
                rest
            else
              let path = Filename.concat dir name in
              (match load_intent path with
               | Error detail ->
                 load
                   intents
                   (Printf.sprintf
                      "projection outbox entry %S is invalid: %s"
                      name
                      detail
                    :: issues)
                   rest
               | Ok intent ->
                 if String.equal intent.keeper_name keeper_name
                 then load (intent :: intents) issues rest
                 else
                   load
                     intents
                     (Printf.sprintf
                        "projection outbox entry %S belongs to keeper %S"
                        name
                        intent.keeper_name
                      :: issues)
                     rest)
        in
        load [] [] names
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
  in
  let persist intent =
    let* () = ensure_projection_dir ~base_dir intent.keeper_name in
    Keeper_fs.save_json_durable_atomic
      ~ownership_root:(root_dir base_dir)
      ~pretty:false
      (intent_path ~base_dir intent)
      (to_yojson intent)
    |> Result.map_error Keeper_fs.durable_write_error_to_string
  in
  let append intent =
    let redaction =
      Keeper_secret_redaction.snapshot
        ~base_path:base_dir
        ~keeper_name:intent.keeper_name
    in
    let appended_intent =
      { intent with
        content = Keeper_secret_redaction.redact_text redaction intent.content
      }
    in
    let turn_ref = appended_intent.turn_ref in
    let delivery_key =
      Keeper_chat_delivery_identity.Autonomous_turn turn_ref
    in
    Keeper_chat_store.append_assistant_message_once
      ~base_dir
      ~keeper_name:appended_intent.keeper_name
      ~delivery_key
      ~content:appended_intent.content
      ~surface:Surface_ref.Agent
      ~assistant_kind:Keeper_chat_store.Row_kind.Autonomous_activity
      ~blocks:(Keeper_chat_blocks.parse_text_to_blocks appended_intent.content)
      ~turn_ref
      ()
    |> Result.map (function
      | Keeper_chat_store.Appended _ -> Appended appended_intent
      | Keeper_chat_store.Already_present _ -> Already_present)
  in
  let retire intent =
    Keeper_fs.remove_file_durable
      ~ownership_root:(root_dir base_dir)
      (intent_path ~base_dir intent)
    |> Result.map_error Keeper_fs.durable_remove_error_to_string
  in
  let broadcast intent =
    Keeper_chat_broadcast.chat_appended
      ~keeper_name:intent.keeper_name
      ~source:(Surface_ref.lane_label Surface_ref.Agent)
      ~content:intent.content
      ()
  in
  { load_pending; persist; append; retire; broadcast }
;;
