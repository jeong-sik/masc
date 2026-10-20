module Store = Multimodal.Vision_artifact_store

type source = Path of string | Artifact of Store.handle

let ( let* ) = Result.bind

let source_of_args = function
  | `Assoc [ ("path", `String path) ] when String.trim path <> "" -> Ok (Path path)
  | `Assoc [ ("artifact", `String handle) ] when String.trim handle <> "" ->
      Ok (Artifact (Store.of_string handle))
  | _ -> Error "Provide exactly one non-empty string: path or artifact."

let handle ?turn_sandbox_factory ~config ~(meta : Keeper_meta_contract.keeper_meta)
    ~args () =
  let start_time = Tool_timing.start () in
  let failed class_ code detail =
    Keeper_tool_execution.failure_data ~class_ ~message:detail
      (`Assoc [ "ok", `Bool false; "error", `String code; "detail", `String detail ])
  in
  match source_of_args args with
  | Error detail -> failed Tool_result.Policy_rejection "invalid_args" detail
  | Ok source ->
      let bytes = match source with
        | Path path ->
            Keeper_tool_filesystem_runtime.read_sandbox_raw_prefix
              ?turn_sandbox_factory ~config ~meta ~path
              ~max_bytes:(Keeper_vision_tool.max_image_bytes () + 1) ()
            |> Result.map_error (function
                 | Keeper_sandbox_read_backend.Missing_file detail ->
                   Tool_result.Workflow_rejection, "path_not_found", detail
                 | Keeper_sandbox_read_backend.Not_a_file detail ->
                   Tool_result.Workflow_rejection, "path_not_a_file", detail
                 | Keeper_sandbox_read_backend.Read_refused detail ->
                   Tool_result.Workflow_rejection, "path_read_refused", detail
                 | Keeper_sandbox_read_backend.Read_failed detail ->
                   Tool_result.Runtime_failure, "sandbox_image_read_failed", detail)
        | Artifact handle ->
            Keeper_vision_tool.load_artifact
              ~dir:(Keeper_vision_tool.vision_store_dir ~keeper_name:meta.name) handle
            |> Result.map_error (fun error ->
                 let class_, code = match error with
                   | Store.Malformed_handle _ -> Tool_result.Policy_rejection, "invalid_artifact"
                   | Store.Missing_artifact _ -> Tool_result.Workflow_rejection, "artifact_not_found"
                   | Store.Hash_mismatch _ | Store.Read_failed _ ->
                       Tool_result.Runtime_failure, "artifact_load_failed"
                 in
                 class_, code, Store.load_error_to_string error)
      in
      let prepared =
        let* bytes = bytes in
        let* () = Keeper_vision_tool.validate_image_size bytes
          |> Result.map_error (fun detail -> Tool_result.Policy_rejection, "image_too_large", detail) in
        let* media_type = Keeper_vision_tool.sniff_image_media_type bytes
          |> Result.map_error (fun detail -> Tool_result.Policy_rejection, "invalid_media_type", detail) in
        let* dimensions = match Keeper_image_dimensions.image_dimensions bytes with
          | Some (width, height) when width <= 0 || height <= 0 ->
              Error (Tool_result.Policy_rejection, "invalid_image", "Image dimensions must be positive.")
          | dimensions -> Ok dimensions
        in
        (* Keep a frame's verified bytes before reporting a successful read:
           rotating browser frames must not invalidate this conversation. *)
        let* artifact = Keeper_vision_tool.store_kept ~keeper_name:meta.name bytes
          |> Result.map_error (fun detail -> Tool_result.Runtime_failure, "artifact_store_failed", detail) in
        Ok (bytes, media_type, dimensions, Store.to_string artifact)
      in
      match prepared with
      | Error (class_, code, detail) -> failed class_ code detail
      | Ok (bytes, media_type, dimensions, artifact) ->
          let data = `Assoc
            ([ "ok", `Bool true; "artifact", `String artifact
             ; "sha256", `String Digestif.SHA256.(digest_string bytes |> to_hex)
             ; "media_type", `String media_type; "bytes", `Int (String.length bytes)
             ; "visual_input", `Bool true ]
             @ (match dimensions with
                | Some (width, height) -> ["width", `Int width; "height", `Int height]
                | None -> [])
             @ match source with Path path -> [ "source_path", `String path ] | Artifact _ -> [])
          in
          Tool_result.make_ok ~tool_name:"keeper_image_read" ~start_time
            ~data ~content_blocks:
              [ Llm_provider.Types.Text (Yojson.Safe.to_string data)
              ; Llm_provider.Types.image_block ~media_type ~data:(Base64.encode_exn bytes) () ] ()
          |> Keeper_tool_execution.of_tool_result

let admission_hook ~accepts_image_input = function
  | Agent_core.Hooks.PreToolUse { tool_name = "keeper_image_read"; _ }
    when not accepts_image_input ->
      Agent_core.Hooks.Block
        "The selected runtime does not declare image input support. Use keeper_analyze_image for a delegated text reading. No pixels were read or sent."
  | Agent_core.Hooks.PreToolUse _
  | Agent_core.Hooks.BeforeTurn _ | Agent_core.Hooks.BeforeTurnParams _
  | Agent_core.Hooks.AfterTurn _ | Agent_core.Hooks.PostToolUse _
  | Agent_core.Hooks.PostToolUseFailure _ | Agent_core.Hooks.OnStop _
  | Agent_core.Hooks.OnError _ | Agent_core.Hooks.OnToolError _ ->
      Agent_core.Hooks.Continue
