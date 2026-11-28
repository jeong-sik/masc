type output =
  | Score
  | Midi
  | Audio

let all_outputs = [ Score; Midi; Audio ]

(* Audio is ten times the size of the other two and slower to render, so a
   Keeper asks for it by name. *)
let default_outputs = [ Score; Midi ]

let output_name = function
  | Score -> "score"
  | Midi -> "midi"
  | Audio -> "audio"

(* masc-alphatex's flag for each output, the file it writes there, and the
   media type the attachment store is told. *)
let export_flag = function
  | Score -> "--render"
  | Midi -> "--export-midi"
  | Audio -> "--audio"

let file_name = function
  | Score -> "score.png"
  | Midi -> "score.mid"
  | Audio -> "score.wav"

let media_type = function
  | Score -> "image/png"
  | Midi -> "audio/midi"
  | Audio -> "audio/wav"

let executable_name = "masc-alphatex"

(* A score of a few hundred bars is a few KiB of alphaTex. *)
let source_max_bytes = 64 * 1024

(* Two bars rendered to all three files in about 2 s on the development
   host. The bound stops a wedged Node process from holding the turn; it is
   not a budget on long scores. *)
let render_timeout_sec = 120.0

(* sysexits EX_DATAERR: masc-alphatex exits with it when the alphaTex does
   not parse, and prints alphaTab's diagnostics on stderr. *)
let exit_source_unreadable = 65

(* sysexits EX_CANTCREAT: masc-alphatex exits with it when --audio-max-bytes
   stops a WAV before it passes the limit; the partial file is already gone. *)
let exit_audio_too_large = 73

(* alphaTab's diagnostics name each error's line and column; this keeps a
   score with many errors from flooding the Keeper's context. *)
let stderr_max_bytes = 4096

type request =
  { source : string
  ; outputs : output list
  }

let outputs_of_json = function
  | `List [] -> Error "outputs names nothing; name one or more of score, midi, audio"
  | `List items ->
    let rec read named = function
      | [] -> Ok named
      | `String name :: rest ->
        (match List.find_opt (fun output -> String.equal (output_name output) name) all_outputs with
         | None -> Error (Printf.sprintf "outputs: %S is not one of score, midi, audio" name)
         | Some output when List.mem output named ->
           Error (Printf.sprintf "outputs names %s twice" name)
         | Some output -> read (output :: named) rest)
      | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) :: _ ->
        Error "outputs must be an array of strings"
    in
    Result.map
      (fun named -> List.filter (fun output -> List.mem output named) all_outputs)
      (read [] items)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
    Error "outputs must be an array"

let request_of_args = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* source =
      match List.assoc_opt "source" fields with
      | None -> Error "source is required: the score in alphaTex"
      | Some (`String source) when String.trim source = "" -> Error "source is empty"
      | Some (`String source) when String.length source > source_max_bytes ->
        Error
          (Printf.sprintf "source is %d bytes; the most accepted is %d"
             (String.length source) source_max_bytes)
      | Some (`String source) -> Ok source
      | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) ->
        Error "source must be a string"
    in
    let* outputs =
      match List.assoc_opt "outputs" fields with
      | None -> Ok default_outputs
      | Some json -> outputs_of_json json
    in
    Ok { source; outputs }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "keeper_music_render arguments must be a JSON object"

type summary =
  { title : string option
  ; tracks : int
  ; bars : int
  }

(* Which step failed decides what the Keeper is told and whether anything
   was stored: every failure but [Store_failed] comes before the first file
   is read or stored. *)
type render_error =
  | Source_unreadable of string
  | Render_failed of string
  | Too_large of string
  | Store_failed of string

(* masc-alphatex prints one JSON line: {"engine","version","title","tracks","bars"}.
   A score without \title prints an empty title. *)
let summary_of_stdout stdout =
  let unexpected detail =
    Error
      (Render_failed
         (Printf.sprintf "%s printed an unexpected summary: %s" executable_name detail))
  in
  match Yojson.Safe.from_string (String.trim stdout) with
  | exception Yojson.Json_error detail -> unexpected detail
  | `Assoc fields ->
    (match List.assoc_opt "tracks" fields, List.assoc_opt "bars" fields with
     | Some (`Int tracks), Some (`Int bars) ->
       let title =
         match List.assoc_opt "title" fields with
         | Some (`String title) when String.trim title <> "" -> Some title
         | Some _ | None -> None
       in
       Ok { title; tracks; bars }
     | _ -> unexpected "no integer tracks and bars")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    unexpected "not an object"

let bounded_stderr stderr =
  let text = String.trim stderr in
  if String.length text <= stderr_max_bytes then text
  else String.sub text 0 stderr_max_bytes ^ " ..."

let render ~executable ~dir request =
  let source_path = Filename.concat dir "score.atex" in
  match Fs_compat.save_file source_path request.source with
  | exception Sys_error detail -> Error (Render_failed ("score write failed: " ^ detail))
  | () ->
    (* WAV grows with the music, so its limit goes to masc-alphatex, which
       stops writing at it; the store would refuse a larger file anyway. *)
    let audio_limit =
      if List.mem Audio request.outputs then
        [ "--audio-max-bytes"; string_of_int (Attachment_store.max_bytes ()) ]
      else []
    in
    let argv =
      executable
      :: source_path
      :: List.concat_map
           (fun output -> [ export_flag output; Filename.concat dir (file_name output) ])
           request.outputs
      @ audio_limit
    in
    (* Every path in [argv] is absolute, so the process needs no working
       directory of its own. Process_eio opens a [~cwd] beneath its
       configured root only, and the scratch directory is under the system
       temp directory, outside it. *)
    (match
       Process_eio.run_argv_with_status_split_or_refusal ~timeout_sec:render_timeout_sec
         ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
         argv
     with
     | Error refusal ->
       Error
         (Render_failed
            (Printf.sprintf "%s: %s" executable_name
               (Process_eio.spawn_refusal_to_string refusal)))
     | Ok (status, stdout, stderr) ->
       (match Process_eio.exit_reason_of_status status with
        | Process_eio.Completed 0 -> summary_of_stdout stdout
        | Process_eio.Completed code when code = exit_source_unreadable ->
          Error (Source_unreadable (bounded_stderr stderr))
        | Process_eio.Completed code when code = exit_audio_too_large ->
          Error (Too_large (bounded_stderr stderr))
        | Process_eio.Completed code ->
          Error
            (Render_failed
               (Printf.sprintf "%s exited %d: %s" executable_name code
                  (bounded_stderr stderr)))
        | Process_eio.Timed_out ->
          Error
            (Render_failed
               (Printf.sprintf "%s did not finish within %.0f s" executable_name
                  render_timeout_sec))
        | Process_eio.Signaled signal ->
          Error (Render_failed (Printf.sprintf "%s was killed by signal %d" executable_name signal))
        | Process_eio.Stopped signal ->
          Error (Render_failed (Printf.sprintf "%s was stopped by signal %d" executable_name signal))))

let file_sizes ~dir outputs =
  List.fold_left
    (fun acc output ->
       Result.bind acc (fun sized ->
         match Unix.stat (Filename.concat dir (file_name output)) with
         | exception Unix.Unix_error (error, _, _) ->
           Error
             (Render_failed
                (Printf.sprintf "the %s file was not written: %s" (output_name output)
                   (Unix.error_message error)))
         | stats -> Ok ((output, stats.Unix.st_size) :: sized)))
    (Ok []) outputs
  |> Result.map List.rev

(* The store refuses one file over [Attachment_store.max_bytes] only after
   it holds the bytes, and keeps a Keeper's ephemeral files within
   [default_ephemeral_max_bytes] by evicting the oldest. WAV grows with the
   music, and a short source with repeats plays for minutes, so the sizes
   on disk are checked before any file is read: a score too long to store
   leaves nothing stored and the server never loads the file. *)
let within_store_limits sized =
  let one_max = Attachment_store.max_bytes () in
  let total_max = Attachment_store.default_ephemeral_max_bytes in
  match List.find_opt (fun (_, bytes) -> bytes > one_max) sized with
  | Some (output, bytes) ->
    Error
      (Too_large
         (Printf.sprintf
            "the %s file is %d bytes and one attachment holds at most %d; nothing \
             was stored. Shorten the score or leave %s out"
            (output_name output) bytes one_max (output_name output)))
  | None ->
    let total = List.fold_left (fun sum (_, bytes) -> sum + bytes) 0 sized in
    if total > total_max then
      Error
        (Too_large
           (Printf.sprintf
              "the files total %d bytes and a Keeper's ephemeral attachments hold at \
               most %d; nothing was stored. Ask for fewer outputs or shorten the score"
              total total_max))
    else Ok ()

let store_output store ~keeper_name ~dir output =
  let name = output_name output in
  match Fs_compat.load_file (Filename.concat dir (file_name output)) with
  | exception Sys_error detail ->
    Error (Printf.sprintf "the %s file was not written: %s" name detail)
  | bytes ->
    (match
       Attachment_store.put ~declared_mime:(media_type output) ~filename:(file_name output)
         ~origin:Attachment_store.Model_generated ~created_by:keeper_name
         ~retention:(Attachment_store.Ephemeral { keeper = keeper_name })
         store ~bytes
     with
     | Ok meta -> Ok (output, meta)
     | Error error ->
       Error
         (Printf.sprintf "the %s file was not stored: %s" name
            (Attachment_store.put_error_to_string error)))

(* [within_store_limits] keeps this call's files inside the Keeper's
   ephemeral budget, but the Keeper's other calls store into the same budget
   while this one runs, so every id is read back before it is returned. *)
let still_stored store (output, (meta : Attachment_store.meta)) =
  match Attachment_store.get_meta store ~id:meta.id with
  | Ok (Some _) -> Ok ()
  | Ok None ->
    Error
      (Printf.sprintf
         "the %s file was evicted by the Keeper's other attachments during this \
          call; render again and post the files before the next render"
         (output_name output))
  | Error error ->
    Error
      (Printf.sprintf "the %s file: %s" (output_name output)
         (Attachment_store.get_error_to_string error))

let store_outputs ~base_path ~keeper_name ~dir outputs =
  let open Result.Syntax in
  let store = Attachment_store.create ~base_path in
  let* stored =
    List.fold_left
      (fun acc output ->
         let* stored = acc in
         let* one = store_output store ~keeper_name ~dir output in
         Ok (one :: stored))
      (Ok []) outputs
  in
  let stored = List.rev stored in
  let* () =
    List.fold_left
      (fun acc entry -> Result.bind acc (fun () -> still_stored store entry))
      (Ok ()) stored
  in
  Ok stored

let result_json summary stored =
  `Assoc
    [ ("title", match summary.title with Some title -> `String title | None -> `Null)
    ; ("tracks", `Int summary.tracks)
    ; ("bars", `Int summary.bars)
    ; ( "files"
      , `List
          (List.map
             (fun (output, (meta : Attachment_store.meta)) ->
                `Assoc
                  [ ("output", `String (output_name output))
                  ; ("attachment_id", `String meta.id)
                  ; ("url", `String (Attachment_store.url_of_id meta.id))
                  ; ("mime_type", `String meta.mime_type)
                  ; ("bytes", `Int meta.bytes)
                  ])
             stored) )
    ]

let error_output message = Yojson.Safe.to_string (`Assoc [ ("error", `String message) ])

let remove_scratch dir =
  try Fs_compat.remove_tree dir with
  | Sys_error detail ->
    Log.Keeper.warn "music render scratch %s was not removed: %s" dir detail
  | Unix.Unix_error (error, call, _) ->
    Log.Keeper.warn "music render scratch %s was not removed: %s: %s" dir call
      (Unix.error_message error)

let run ~executable ~base_path ~keeper_name request =
  let outcome =
    (* The release hook runs under Eio.Cancel.protect, so the directory goes
       when the turn is cancelled during the render too. It is made inside
       the switch because Switch.run raises at entry in a cancelled fiber. *)
    Eio.Switch.run (fun sw ->
      match Filename.temp_dir "masc-music-render-" "" with
      | exception Sys_error detail -> Error (Render_failed ("scratch directory failed: " ^ detail))
      | dir ->
        Eio.Switch.on_release sw (fun () -> remove_scratch dir);
        let open Result.Syntax in
        let* summary = render ~executable ~dir request in
        let* sized = file_sizes ~dir request.outputs in
        let* () = within_store_limits sized in
        store_outputs ~base_path ~keeper_name ~dir request.outputs
        |> Result.map (fun stored -> (summary, stored))
        |> Result.map_error (fun detail -> Store_failed detail))
  in
  match outcome with
  | Ok (summary, stored) ->
    Keeper_tool_execution.success (Yojson.Safe.to_string (result_json summary stored))
  | Error (Source_unreadable diagnostics) ->
    Keeper_tool_execution.failure ~class_:Tool_result.Policy_rejection
      ~effect_disposition:Tool_result.Proven_pre_effect
      (error_output ("the alphaTex does not parse; fix the source: " ^ diagnostics))
  | Error (Render_failed detail) ->
    Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure
      ~effect_disposition:Tool_result.Proven_pre_effect (error_output detail)
  | Error (Too_large detail) ->
    Keeper_tool_execution.failure ~class_:Tool_result.Policy_rejection
      ~effect_disposition:Tool_result.Proven_pre_effect (error_output detail)
  | Error (Store_failed detail) ->
    (* Files stored before the failure stay as ephemeral attachments that
       nothing names; the store evicts them like any other. *)
    Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure (error_output detail)

let handle ~base_path ~keeper_name ~args =
  match request_of_args args with
  | Error reason ->
    Keeper_tool_execution.failure ~class_:Tool_result.Policy_rejection
      ~effect_disposition:Tool_result.Proven_pre_effect (error_output reason)
  | Ok request ->
    (match Executable_path.absolute_on_path executable_name with
     | None ->
       Keeper_tool_execution.failure ~class_:Tool_result.Dependency_unavailable
         ~effect_disposition:Tool_result.Proven_pre_effect
         (error_output
            (Printf.sprintf
               "%s is not on the server's PATH; an operator installs it with \
                scripts/install-alphatex.sh"
               executable_name))
     | Some executable -> run ~executable ~base_path ~keeper_name request)

module For_testing = struct
  let run = run
end
