type output =
  | Printed of string
  | Stored of Tool_output.artifact_ref

type t = {
  ok : bool;
  status : Unix.process_status;
  execution_time_ms : int;
  timeout_limit_sec : float option;
  output : output option;
  stderr : string option;
}

let of_result text =
  let ( let* ) = Option.bind in
  let* fields =
    match Yojson.Safe.from_string text with
    | exception Yojson.Json_error _ -> None
    | `Assoc fields -> Some fields
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
  in
  let member name = List.assoc_opt name fields in
  let* ok = match member "ok" with Some (`Bool ok) -> Some ok | Some _ | None -> None in
  let* status =
    match Option.map Masc.Exec_core.process_status_of_json (member "status") with
    | Some (Ok status) -> Some status
    | Some (Error _) | None -> None
  in
  let* () = match member "typed" with Some (`Bool _) -> Some () | Some _ | None -> None in
  let* execution_time_ms =
    match member "execution_time_ms" with
    | Some (`Int ms) -> Some ms
    | Some _ | None -> None
  in
  (* The producer writes the output inline or, past the size it carries
     inline, as an artifact; never both. *)
  let* output =
    match member "output", member "output_artifact" with
    | Some (`String printed), None -> Some (Some (Printed printed))
    | None, Some reference -> (
        match Tool_output.normalized_artifact_ref_of_json reference with
        | Tool_output.Decoded_normalized_artifact_ref reference ->
            Some (Some (Stored reference))
        | Tool_output.Not_normalized_artifact_ref
        | Tool_output.Invalid_normalized_artifact_ref _ -> None)
    | None, None -> Some None
    | Some _, None | Some _, Some _ -> None
  in
  let* stderr =
    match member "stderr" with
    | Some (`String stderr) -> Some (Some stderr)
    | None -> Some None
    | Some _ -> None
  in
  let* timeout_limit_sec =
    match member "timeout" with
    | None -> Some None
    | Some (`Assoc timeout) -> (
        match List.assoc_opt "limit_sec" timeout with
        | Some (`Float seconds) -> Some (Some seconds)
        | Some (`Int seconds) -> Some (Some (float_of_int seconds))
        | Some _ | None -> None)
    | Some _ -> None
  in
  Some { ok; status; execution_time_ms; timeout_limit_sec; output; stderr }

let status_text t =
  let ended =
    match t.status with
    | Unix.WEXITED code -> Printf.sprintf "exit %d" code
    | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
    | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
  in
  let ran = Printf.sprintf "%s \xc2\xb7 %d ms" ended t.execution_time_ms in
  match t.timeout_limit_sec with
  | None -> ran
  | Some seconds -> Printf.sprintf "%s \xc2\xb7 timed out at %g s" ran seconds

(* Enough of the digest to tell two artifacts apart by eye, the length git
   shortens a commit to. *)
let shown_sha256_chars = 12

let stored_text (reference : Tool_output.artifact_ref) =
  let digest = reference.sha256 in
  let shown = String.sub digest 0 (min shown_sha256_chars (String.length digest)) in
  Printf.sprintf "artifact sha256:%s\xe2\x80\xa6 \xc2\xb7 %d bytes" shown reference.bytes
