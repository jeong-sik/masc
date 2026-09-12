let ( let* ) = Result.bind
type browser_selection = Live of Browser_lane.client_id | Automation
type lane_output = {
  installation_id : string;
  instance_id : string;
  run_id : string;
  configuration_revision : string;
  package_revision : string;
  observation_seq : int;
  output : Lane_addon_types.output;
  status : Lane_addon_types.coverage;
}
type source =
  | Snapshot_file of { id : string; path : string }
  | Msx_capture of { id : string }
  | Lane_output of { id : string; installation_id : string }
  | Browser_document of { id : string; selection : browser_selection;
      tab_id : int; target_id : string; environment : string; request_id : string }
let text fields key = match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> Error (key ^ " requires a non-blank string")
let parse_source = function
  | `Assoc fields ->
      let* id = text fields "source_id" in
      (match List.assoc_opt "kind" fields with
       | Some (`String "snapshot_file") -> let* path = text fields "path" in
           if Filename.is_relative path then Error "snapshot_file path must be absolute"
           else Ok (Snapshot_file {id;path})
       | Some (`String "msx_capture") -> Ok (Msx_capture {id})
       | Some (`String "lane_output") ->
           let* installation_id = text fields "installation_id" in
           (match List.assoc_opt "selection" fields with
            | Some (`String "latest_completed") -> Ok (Lane_output {id;installation_id})
            | _ -> Error "lane_output selection must be latest_completed")
       | Some (`String "browser_document") ->
           let* client_id = match List.assoc_opt "client_id" fields with
             | None | Some `Null -> Ok None
             | Some (`String value) ->
                 (match Browser_lane.client_id_of_string value with
                  | Ok id -> Ok (Some id) | Error error -> Error error)
             | _ -> Error "client_id requires a UUID" in
           let* selection = match List.assoc_opt "lane" fields, client_id with
             | Some (`String "live"), Some client -> Ok (Live client)
             | Some (`String "live"), None -> Error "live browser observation requires an explicit client_id"
             | Some (`String "automation"), None -> Ok Automation
             | Some (`String "automation"), Some _ -> Error "automation does not use a live client_id"
             | _ -> Error "browser source requires live or automation lane" in
           let* tab_id = match List.assoc_opt "tab_id" fields with
             | Some (`Int value) when value >= 0 -> Ok value
             | _ -> Error "tab_id requires a nonnegative integer" in
           let* target_id = text fields "target_id" in
           let* environment = text fields "environment" in
           let* request_id = text fields "request_id" in
           Ok (Browser_document {id;selection;tab_id;target_id;environment;request_id})
       | _ -> Error "unknown observation source kind")
  | _ -> Error "source requires an object"
let parse = function
  | `Assoc fields ->
      (match List.assoc_opt "sources" fields with
       | Some (`List values) ->
           let rec loop acc = function [] -> Ok (List.rev acc)
             | value :: rest -> let* source = parse_source value in loop (source :: acc) rest in
           loop [] values
       | _ -> Error "binding.sources requires an array of observation sources")
  | _ -> Error "binding requires an object"
let source_id = function Snapshot_file {id;_} | Msx_capture {id}
  | Lane_output {id;_} | Browser_document {id;_} -> id
let dependencies binding =
  let* sources = parse binding in
  Ok (List.filter_map (function Lane_output {installation_id;_} -> Some installation_id
    | _ -> None) sources |> List.sort_uniq String.compare)
let validate binding =
  let* sources = parse binding in
  let ids = List.map source_id sources in
  if List.length ids <> List.length (List.sort_uniq String.compare ids)
  then Error "source_id must be unique within a binding" else Ok ()
let evidence_json (e : Lane_addon_types.evidence) =
  `Assoc ["uri", `String e.uri; "sha256", (match e.sha256 with Some s -> `String s | None -> `Null)]
let envelope ~id ~incarnation ~cursor ~complete ~detail observations =
  `Assoc ["source_id", `String id; "incarnation", `String incarnation;
    "cursor", cursor; "complete", `Bool complete; "detail", detail;
    "observations", `List observations]
let unavailable source message = envelope ~id:(source_id source) ~incarnation:"unobserved"
  ~cursor:`Null ~complete:false ~detail:(`String message) []
let read_bounded ~max_bytes path =
  try
    let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC] 0 in
    let channel = Unix.in_channel_of_descr fd in
    Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      let stat = Unix.fstat fd in
      if stat.Unix.st_kind <> Unix.S_REG then Error "source must be a regular file"
      else if stat.Unix.st_size > max_bytes then Error "source snapshot exceeds package ingress envelope"
      else
        let bytes = really_input_string channel stat.Unix.st_size in
        match input_char channel with
        | _ -> Error "source grew while reading; retry from a completed snapshot"
        | exception End_of_file ->
            let after = Unix.fstat fd in
            if after.Unix.st_size <> stat.Unix.st_size
               || after.Unix.st_mtime <> stat.Unix.st_mtime
               || after.Unix.st_ctime <> stat.Unix.st_ctime
            then Error "source changed while reading; retry from a completed snapshot"
            else Ok bytes)
  with Sys_error message -> Error message
     | End_of_file -> Error "source changed while reading"
     | Unix.Unix_error (error,call,path) -> Error (call ^ " " ^ path ^ ": " ^ Unix.error_message error)
let snapshot_file ~store ~max_bytes ~id path =
  let* bytes = Eio_unix.run_in_systhread (fun () -> read_bounded ~max_bytes path) in
  try
    let json = Yojson.Safe.from_string bytes in
    let* fields = match json with `Assoc fields -> Ok fields | _ -> Error "snapshot must be an envelope" in
    let* observed_id = text fields "source_id" in
    let* _incarnation = text fields "incarnation" in
    if id <> observed_id then Error "snapshot source identity does not match binding"
    else match List.assoc_opt "cursor" fields, List.assoc_opt "complete" fields,
               List.assoc_opt "detail" fields, List.assoc_opt "observations" fields with
      | Some (`Null | `String _), Some (`Bool _), Some (`Null | `String _), Some (`List observations) ->
          let* reference = Eio_unix.run_in_systhread (fun () -> Lane_addon_store.write_blob store bytes) in
          let own_evidence = evidence_json reference in
          let rec retain acc = function
            | [] -> Ok (List.rev acc)
            | `Assoc observation :: rest ->
                let* existing = match List.assoc_opt "evidence" observation with
                  | None -> Ok []
                  | Some (`List refs) -> Ok refs
                  | Some _ -> Error "observation evidence must be an array" in
                let captured = `Assoc (("evidence", `List (own_evidence :: existing))
                  :: List.remove_assoc "evidence" observation) in
                retain (captured :: acc) rest
            | _ -> Error "observations must contain objects" in
          let* observations = retain [] observations in
          (* Preserve the original bytes, including formatting and original
             declared references. The extra evidence points to our own copy;
             nothing follows a URI supplied by the file or the package. *)
          Ok (`Assoc (("snapshot_evidence", own_evidence)
            :: ("observations", `List observations)
            :: List.remove_assoc "snapshot_evidence" (List.remove_assoc "observations" fields)))
      | _ -> Error "source must include cursor, complete, detail and observations"
  with Yojson.Json_error message -> Error message
let msx_capture ~store ~id =
  let* capture = Eio_unix.run_in_systhread (fun () -> Msx_lane.capture_with_identity ())
    |> Result.map_error Msx_lane.error_to_string in
  let frame = capture.Msx_lane.frame in
  let observed_at = Time_compat.now () in
  let image = `Assoc ["format", `String "rgb8"; "width", `Int frame.Msx_lane.width;
    "height", `Int frame.Msx_lane.height; "rgb_base64", `String (Base64.encode_string frame.Msx_lane.rgb)] in
  let* screen = Eio_unix.run_in_systhread (fun () -> Lane_addon_store.write_blob store (Yojson.Safe.to_string image)) in
  let cursor = `String (string_of_int capture.Msx_lane.input_count) in
  let observation = `Assoc ["id", `String (Printf.sprintf "%s/%d/%.6f" capture.incarnation frame.number observed_at);
    "kind", `String "capture"; "observed_at", `Float observed_at; "actor", `Null;
    "evidence", `List [evidence_json screen]; "screen", evidence_json screen;
    "machine_id", `String "workspace-msx"; "incarnation", `String capture.incarnation;
    "frame", `Int frame.number; "input_cursor", cursor] in
  Ok (envelope ~id ~incarnation:capture.incarnation ~cursor ~complete:true ~detail:`Null [observation])
let browser_document ~store ~max_bytes ~id ~selection ~tab_id ~target_id ~environment ~request_id =
  let lane, client_id = match selection with
    | Live client -> "live", Some client
    | Automation -> "automation", None in
  let* target = Browser_lane.resolve_target ~lane_name:lane ~client_id in
  (* Reuse the existing transport deadline; never create a new session, select
     a different document or wait for a primary browser action to finish. *)
  let* fields = match Browser_lane.issue_document_if_idle ~target ~tab_id
      ~timeout_sec:Tool_misc_browser_lane.default_timeout_sec with
    | Browser_lane.Answered (`Assoc envelope) ->
        (match List.assoc_opt "ok" envelope, List.assoc_opt "data" envelope with
         | Some (`Bool true), Some (`Assoc fields) -> Ok fields
         | _ -> Error "browser did not produce a document capture")
    | Browser_lane.Answered _ -> Error "invalid browser envelope"
    | Browser_lane.Lane_absent -> Error "browser lane unavailable"
    | Browser_lane.Timed_out -> Error "browser transport deadline elapsed"
    | Browser_lane.Refused reason | Browser_lane.Rejected_before_effect reason -> Error reason in
  let* url = text fields "url" in let* document_id = text fields "documentId" in
  let* client = text fields "clientId" in
  let* () = match selection with
    | Live expected when not (String.equal client (Browser_lane.client_id_to_string expected)) ->
        Error "document belongs to a different browser client"
    | Live _ | Automation -> Ok () in
  let* observed_at = match List.assoc_opt "observedAt" fields with
    | Some (`Float n) when Float.is_finite n -> Ok n
    | Some (`Int n) -> Ok (float_of_int n) | _ -> Error "document timestamp missing" in
  let* html, complete = match List.assoc_opt "html" fields, List.assoc_opt "htmlComplete" fields with
    | Some (`String html), Some (`Bool true) when String.length html <= max_bytes -> Ok (`String html,true)
    | Some (`String _), Some (`Bool true) -> Ok (`Null,false)
    | Some `Null, Some (`Bool false) -> Ok (`Null,false)
    | _ -> Error "inconsistent same-document HTML capture" in
  let* returned_tab = match List.assoc_opt "tabId" fields with Some (`Int value) -> Ok value
    | _ -> Error "document tab identity missing" in
  if returned_tab <> tab_id then Error "document belongs to a different tab" else
  let body = `Assoc fields in
  let body_bytes = Yojson.Safe.to_string body in
  let* () = if String.length body_bytes > max_bytes
    then Error "document capture exceeds package ingress envelope" else Ok () in
  let* evidence = Eio_unix.run_in_systhread (fun () -> Lane_addon_store.write_blob store body_bytes) in
  let observation = `Assoc ["id", `String (Printf.sprintf "%s/%d/%s/%.6f" client tab_id document_id observed_at);
    "kind", `String "browser"; "observed_at", `Float observed_at;
    "actor", `String ("browser:" ^ client); "evidence", `List [evidence_json evidence];
    "target", `Assoc ["id", `String target_id; "environment", `String environment; "url", `String url];
    "request_id", `String request_id; "client_id", `String client;
    "tab_id", `String (string_of_int returned_tab); "document_id", `String document_id; "html", html] in
  let detail = if complete then `Null else
    match List.assoc_opt "htmlUnavailableReason" fields with
    | Some (`String reason) when reason <> "" -> `String reason
    | _ -> `String "same-document HTML unavailable or exceeds ingress envelope" in
  Ok (envelope ~id ~incarnation:(client ^ "/" ^ document_id)
    ~cursor:(`String evidence.uri) ~complete
    ~detail [observation])
let lane_output ~store ~max_bytes ~resolve_lane_output ~id ~installation_id =
  let* captured = resolve_lane_output ~installation_id in
  let producer = `Assoc ["installation_id", `String captured.installation_id;
    "instance_id", `String captured.instance_id; "run_id", `String captured.run_id;
    "configuration_revision", `String captured.configuration_revision;
    "package_revision", `String captured.package_revision;
    "observation_seq", `Int captured.observation_seq] in
  let output = Lane_addon_types.output_to_json captured.output in
  let bytes = Yojson.Safe.to_string (`Assoc ["producer", producer; "output", output]) in
  if String.length bytes > max_bytes then Error "upstream output exceeds the remaining ingress envelope"
  else
    let* reference = Eio_unix.run_in_systhread (fun () -> Lane_addon_store.write_blob store bytes) in
    let complete = captured.status.complete
      && List.for_all (fun (c : Lane_addon_types.coverage) -> c.complete) captured.output.coverage in
    let detail = if complete then None else Some "latest completed output has incomplete source or worker coverage" in
    let observation = `Assoc ["id", `String (captured.instance_id ^ "/output/" ^ string_of_int captured.observation_seq);
      "kind", `String "lane_output"; "observed_at", `Float (Time_compat.now ());
      "actor", `Null; "producer", producer; "output", output;
      "producer_status", Lane_addon_types.coverage_to_json captured.status;
      "evidence", `List [evidence_json reference]] in
    Ok (envelope ~id ~incarnation:captured.instance_id
      ~cursor:(`String (string_of_int captured.observation_seq)) ~complete
      ~detail:(Option.fold ~none:`Null ~some:(fun value -> `String value) detail) [observation])

let acquire ~store ~(package : Lane_addon_types.package) ~resolve_lane_output ~binding =
  let* () = validate binding in
  let* sources = parse binding in
  let capture ~max_bytes source =
    let result = match source with
      | Snapshot_file {id;path} -> snapshot_file ~store ~max_bytes ~id path
      | Msx_capture {id} -> msx_capture ~store ~id
      | Lane_output {id;installation_id} ->
          lane_output ~store ~max_bytes ~resolve_lane_output ~id ~installation_id
      | Browser_document {id;selection;tab_id;target_id;environment;request_id} ->
          browser_document ~store ~max_bytes ~id ~selection
            ~tab_id ~target_id ~environment ~request_id in
    match result with Ok json -> json | Error message -> unavailable source message in
  (* Reserve room for an honest unavailable result for every source before
     capturing any. A large first snapshot cannot silently hide later sources
     or multiply the configured ingress envelope by the source count. *)
  let budget_message = "source omitted: combined observation ingress envelope exhausted" in
  let fallback source = unavailable source budget_message in
  let wire_length json = String.length (Yojson.Safe.to_string json) in
  let reserved = List.map (fun source -> source, fallback source, wire_length (fallback source)) sources in
  let separators = max 0 (List.length sources - 1) in
  let minimum = List.fold_left (fun n (_, _, length) -> n + length) (2 + separators) reserved in
  if minimum > package.resources.max_reply_bytes then
    Error "binding source identities exceed the combined ingress envelope"
  else
    let rec loop acc remaining reserved_rest = function
      | [] -> Ok (`List (List.rev acc))
      | (source, missing, missing_size) :: rest ->
          let tail_reserved = reserved_rest - missing_size in
          let available = remaining - tail_reserved in
          let captured = capture ~max_bytes:available source in
          let size = wire_length captured in
          let selected, size = if size <= available then captured, size else missing, missing_size in
          loop (selected :: acc) (remaining - size) tail_reserved rest in
    let available = package.resources.max_reply_bytes - 2 - separators in
    loop [] available (minimum - 2 - separators) reserved
