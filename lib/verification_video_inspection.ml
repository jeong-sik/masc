type stream_kind = Video | Audio | Subtitle | Data | Attachment | Unknown
type stream =
  { index : int
  ; kind : stream_kind
  ; codec : string option
  ; duration_seconds : float option
  ; width : int option
  ; height : int option
  ; channels : int option
  ; sample_rate : int option
  }
type command = { program : string; arguments : string list; stdout : string; stderr : string }
type t =
  { source_bytes : int
  ; source_sha256 : string
  ; format_name : string
  ; duration_seconds : float option
  ; streams : stream list
  ; probe : command
  ; decode : command
  ; versions : command list
  }
type error =
  | Dependency_unavailable of string list
  | Budget_spent of { program : string; budget_sec : float }
  | Command_failed of { program : string; status : Unix.process_status; detail : string }
  | Invalid_output of string
  | Storage_failed of string

(* Submitted evidence is not trusted input. A malformed or deliberately long
   MP4 can make either FFmpeg command sit there, and the completion verifier
   holds one of only four global review slots while it waits -- so the bound is
   what keeps one recording from wedging Task and Goal verification. [inspect]
   runs exactly four commands, so the whole inspection is bounded by four times
   this, and the sibling PDF inspection spends the same budget per command for
   the same reason. Generous enough to decode a long recording on a loaded
   machine; past it the command is reported as a refusal rather than waited on. *)
let command_timeout_sec = 120.

let ( let* ) = Result.bind
let error_to_string = function
  | Dependency_unavailable programs ->
    "video_dependency_unavailable: install FFmpeg with ffprobe in the verifier service environment; missing "
    ^ String.concat ", " programs
  | Budget_spent {program;budget_sec} ->
    Printf.sprintf
      "video_budget_spent: %s did not finish within %.0f seconds; submit a shorter or less \
       expensive recording"
      program budget_sec
  | Command_failed {program;status;detail} ->
    let status = match status with
      | Unix.WEXITED code -> Printf.sprintf "exit=%d" code
      | Unix.WSIGNALED signal -> Printf.sprintf "signal=%d" signal
      | Unix.WSTOPPED signal -> Printf.sprintf "stopped=%d" signal in
    Printf.sprintf "video_inspection_failed: %s %s: %s" program status detail
  | Invalid_output detail -> "video_inspection_invalid_output: " ^ detail
  | Storage_failed detail -> "video_inspection_storage_failed: " ^ detail

let field name = function `Assoc fields -> List.assoc_opt name fields | _ -> None
let invalid name = Error (Invalid_output ("invalid FFprobe " ^ name))
let text name json = match field name json with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> invalid name
let optional_text name json = match field name json with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | _ -> invalid name
let optional_number parse valid name json =
  match field name json with
  | None | Some `Null | Some (`String "N/A") -> Ok None
  | Some value ->
    let raw = match value with
      | `String s -> Some s | `Int i -> Some (string_of_int i)
      | `Float f -> Some (string_of_float f) | _ -> None in
    (match Option.bind raw parse with
     | Some number when valid number -> Ok (Some number)
     | None | Some _ -> invalid name)
let duration = optional_number float_of_string_opt (fun n -> Float.is_finite n && n >= 0.) "duration"
let positive_int = optional_number int_of_string_opt (fun n -> n > 0)
let stream_of_json json =
  let* index = match field "index" json with
    | Some (`Int n) when n >= 0 -> Ok n | _ -> invalid "stream index" in
  let* kind = match field "codec_type" json with
    | Some (`String "video") -> Ok Video | Some (`String "audio") -> Ok Audio
    | Some (`String "subtitle") -> Ok Subtitle | Some (`String "data") -> Ok Data
    | Some (`String "attachment") -> Ok Attachment | Some (`String "unknown") -> Ok Unknown
    | _ -> invalid "stream type" in
  let* codec = optional_text "codec_name" json in
  let* duration_seconds = duration json in
  let* width = positive_int "width" json in
  let* height = positive_int "height" json in
  let* channels = positive_int "channels" json in
  let* sample_rate = positive_int "sample_rate" json in
  Ok {index;kind;codec;duration_seconds;width;height;channels;sample_rate}
let parse_probe output =
  try
    let json = Yojson.Safe.from_string output in
    let* format = match field "format" json with Some (`Assoc _ as f) -> Ok f | _ -> invalid "format" in
    let* format_name = text "format_name" format in
    let* duration_seconds = duration format in
    let* entries = match field "streams" json with Some (`List entries) -> Ok entries | _ -> invalid "streams" in
    let* streams = List.fold_left (fun acc json ->
      let* streams = acc in let* stream = stream_of_json json in
      if List.exists (fun previous -> previous.index = stream.index) streams then invalid "duplicate stream index"
      else Ok (stream :: streams)) (Ok []) entries |> Result.map List.rev in
    Ok (format_name,duration_seconds,streams)
  with Yojson.Json_error detail -> Error (Invalid_output detail)

let decoded = function Video | Audio -> true | Subtitle | Data | Attachment | Unknown -> false
let kind_name = function Video -> "video" | Audio -> "audio" | Subtitle -> "subtitle"
  | Data -> "data" | Attachment -> "attachment" | Unknown -> "unknown"
let option_json encode = function Some value -> encode value | None -> `Null
let int_json n = `Int n
let float_json n = `Float n
let string_json s = `String s
let command_json command = `Assoc
  ["program",`String command.program; "arguments",`List (List.map string_json command.arguments);
   "exit_code",`Int 0; "stdout",`String command.stdout; "stderr",`String command.stderr]
let to_yojson t =
  let streams = List.map (fun s -> `Assoc
    ["index",`Int s.index; "kind",`String (kind_name s.kind);
     "codec",option_json string_json s.codec; "duration_seconds",option_json float_json s.duration_seconds;
     "width",option_json int_json s.width; "height",option_json int_json s.height;
     "channels",option_json int_json s.channels; "sample_rate",option_json int_json s.sample_rate]) t.streams in
  let indices predicate = t.streams |> List.filter (fun s -> predicate s.kind)
    |> List.map (fun s -> `Int s.index) in
  `Assoc ["media_type",`String "video/mp4"; "bytes",`Int t.source_bytes;
    "sha256",`String t.source_sha256; "format_name",`String t.format_name;
    "duration_seconds",option_json float_json t.duration_seconds; "streams",`List streams;
    "decoded_stream_indices",`List (indices decoded);
    "uninspected_stream_indices",`List (indices (fun kind -> not (decoded kind)));
    "audio_present",`Bool (List.exists (fun s -> s.kind = Audio) t.streams);
    "video_present",`Bool (List.exists (fun s -> s.kind = Video) t.streams);
    "probe",command_json t.probe; "full_decode",command_json t.decode;
    "program_versions",`List (List.map command_json t.versions);
    "visual_input",`Bool false;
    "inspection_scope",`String "Original captured MP4 metadata and complete audio/video stream decode. No frame visual inspection or accessibility verdict is inferred."]

let inspect ~base_path ~bytes =
  let missing = List.filter (fun name -> not (Executable_path.command_available name)) ["ffprobe";"ffmpeg"] in
  if missing <> [] then Error (Dependency_unavailable missing) else
  Eio.Switch.run @@ fun sw ->
  let root = Filename.concat (Keeper_execute_output_files.capture_directory ~base_path)
    ("video-" ^ Random_id.uuid_v7 ()) in
  try
    Fs_compat.mkdir_p root; Unix.chmod root 0o700;
    Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree root);
    let source = Filename.concat root "source.mp4" in
    Auth.save_private_text_file source bytes; Unix.chmod source 0o400;
    let run program arguments =
      let status, stdout, stderr = Process_eio.run_argv_with_status_split
        ~timeout_sec:command_timeout_sec
        ~env:(Env_keeper_scrub.filter_environment (Unix.environment ())) ~cwd:root (program :: arguments) in
      match status with
      | Unix.WEXITED 0 -> Ok {program;arguments;stdout;stderr}
      (* [run_argv_with_status_split] synthesises 124 on its own timeout, the
         way timeout(1) does. Naming it separately keeps a spent budget from
         reading as a decode error the submitter cannot act on. *)
      | Unix.WEXITED 124 -> Error (Budget_spent {program;budget_sec=command_timeout_sec})
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error (Command_failed {program;status;detail=stderr}) in
    let* probe_version = run "ffprobe" ["-version"] in
    let* decode_version = run "ffmpeg" ["-version"] in
    (* Fixed demuxer plus disabled external data references keeps a file read
       from becoming another filesystem or network lookup. *)
    let input = ["-protocol_whitelist";"file";"-f";"mov";"-enable_drefs";"0";"-use_absolute_path";"0";"-i";source] in
    let* probe = run "ffprobe" (["-v";"error"] @ input @
      ["-show_entries";"format=format_name,duration:stream=index,codec_name,codec_type,width,height,channels,sample_rate,duration";
       "-of";"json"]) in
    let* format_name,duration_seconds,streams = parse_probe probe.stdout in
    let selected = List.filter (fun stream -> decoded stream.kind) streams in
    let* () = if selected = [] then Error (Invalid_output "no audio/video streams to decode") else Ok () in
    let maps = List.concat_map (fun stream -> ["-map";"0:" ^ string_of_int stream.index]) selected in
    let* decode = run "ffmpeg"
      (["-hide_banner";"-nostdin";"-v";"error";"-xerror";"-err_detect";"explode";
        "-abort_on";"empty_output_stream"] @ input @ maps @ ["-f";"null";"-"]) in
    let* retained = match Fs_compat.load_owned_regular_file ~ownership_root:root source with
      | Ok (Some contents) -> Ok contents
      | Ok None -> Error (Storage_failed "captured video disappeared")
      | Error error -> Error (Storage_failed (Fs_compat.owned_regular_file_read_error_to_string error)) in
    if not (String.equal retained bytes) then Error (Invalid_output "captured video changed during inspection") else
    Ok {source_bytes=String.length bytes;source_sha256=Digestif.SHA256.(digest_string bytes |> to_hex);
        format_name;duration_seconds;streams;probe;decode;versions=[probe_version;decode_version]}
  with
  | Sys_error detail -> Error (Storage_failed detail)
  | Unix.Unix_error (code,operation,_) -> Error (Storage_failed (operation ^ ": " ^ Unix.error_message code))
