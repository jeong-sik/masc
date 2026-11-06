open Keeper_meta_contract
open Keeper_tool_filesystem_runtime_shared

let check_invariant_sandbox_isolation
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~confined
  =
  let target = Keeper_alerting_path.confined_containment_path confined in
  match turn_sandbox_factory with
  | None -> Ok ()
  | Some factory ->
    let cwd = Filename.dirname target in
    (match Keeper_sandbox_factory.resolve_opt (Some factory) ~cwd with
     (* No guest root to check against; the call itself is refused where it
        would run. No turn runtime exists to scope the isolation invariant to
        ([Remote_ssh_profile] included: its calls are scoped on the remote
        side, not against a local guest root). *)
     | No_factory | Remote_ssh_profile -> Ok ()
     | Runtime { runtime; _ } ->
       let host_root = Keeper_turn_sandbox_runtime.host_root runtime in
       Keeper_invariant.sandbox_isolation
         ~sandbox_roots:[ host_root ]
         ~sandbox_paths:[ target ])
;;

(* Invert the recorded Gate effect back into the write mode that produced
   it. Only the modes this module can reproduce exactly are accepted; an
   unrecognised effect yields [None] so a caller replays nothing rather than
   silently downgrading, say, an approved append into an overwrite. *)
let fs_write_mode_of_gate_effect_operation raw =
  let spelled operation =
    String.equal raw (Keeper_alerting_path.path_effect_operation_to_string operation)
  in
  if spelled Keeper_alerting_path.Atomic_replace_entry
  then Some Overwrite
  else if spelled Keeper_alerting_path.Append_pinned_resource
  then Some Append
  else if spelled Keeper_alerting_path.Patch_then_atomic_replace_entry
  then Some Patch
  else None
;;

type approved_write =
  { target : string
  ; mode : fs_write_mode
  ; carried : (string * Yojson.Safe.t) list
  }

(* Decode a recorded Gate input back into the write it approved. The Gate
   input carries the resolved target under [requested_target] and the mode
   inside the effect. Only fields the approval carried are kept, so a content
   write cannot gain edit fields. *)
let approved_write_of_gate_input input =
  let ( let* ) = Result.bind in
  match input with
  | `Assoc fields ->
    let field name = List.assoc_opt name fields in
    let* target =
      match field "requested_target" with
      | Some (`String target) -> Ok target
      | Some _ -> Error "approved Gate input has a non-string requested_target"
      | None -> Error "approved Gate input has no requested_target"
    in
    let* mode =
      match field "effect" with
      | Some (`Assoc effect_fields) ->
        (match List.assoc_opt "operation" effect_fields with
         | Some (`String operation) ->
           (match fs_write_mode_of_gate_effect_operation operation with
            | Some mode -> Ok mode
            | None ->
              Error ("approved Gate effect is not replayable: " ^ operation))
         | _ -> Error "approved Gate effect has no operation")
      | _ -> Error "approved Gate input has no effect"
    in
    let carried =
      List.filter_map
        (fun name -> Option.map (fun value -> name, value) (field name))
        [ "content"; "content_artifact"; "old_string"; "new_string"; "replace_all"; "insert_before_line"; "insert_text" ]
    in
    Ok { target; mode; carried }
  | _ -> Error "approved Gate input is not a JSON object"
;;

(* Rebuild the write arguments the handler reads from the approved write. *)
let replay_args_of_gate_input input =
  Result.map
    (fun { target; mode; carried } ->
       `Assoc
         (("path", `String target)
          :: ("mode", `String (fs_write_mode_to_string mode))
          :: carried))
    (approved_write_of_gate_input input)
;;

(* What a write approval is about, in one line: the path it would write. The
   submitting handler states it from the target it resolved; replay states it
   from [approved_write_of_gate_input]. *)
let write_call_summary ~requested_target =
  String_util.first_nonblank_line requested_target
;;

(* The opaque Gate operation identity for every local write this module
   performs. The Gate never parses it; consumers that must recognise the
   same effect read it from here instead of repeating the literal. *)
let gate_operation = Keeper_gate.filesystem_write_gate_operation

let file_write_gate_input
      ~effect_json
      ~requested_target
      ~content
      ?content_source
      ?old_string
      ?new_string
      ?replace_all
      ?insert_before_line
      ?insert_text
      ()
  =
  let optional_string name = function
    | None -> []
    | Some value -> [ name, `String value ]
  in
  let optional_bool name = function
    | None -> []
    | Some value -> [ name, `Bool value ]
  in
  let optional_int name = function
    | None -> []
    | Some value -> [ name, `Int value ]
  in
  `Assoc
    ([ "effect", effect_json
     ; "requested_target", `String requested_target
     ]
     @ Keeper_write_content.fields (match content_source with
         | Some source -> source
         | None -> Keeper_write_content.Text content)
     @ optional_string "old_string" old_string
     @ optional_string "new_string" new_string
     @ optional_bool "replace_all" replace_all
     @ optional_int "insert_before_line" insert_before_line
     @ optional_string "insert_text" insert_text)
;;

let decide_file_write
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~requested_target
      ~input
      ()
  =
  Keeper_gate.decide
    ?cycle_grant:gate_grant
    ~keeper_always_allow:(Option.value ~default:false meta.always_allow)
    { keeper_name = meta.name
    ; operation = gate_operation
    ; input
    ; call_summary = write_call_summary ~requested_target
    ; sandbox_profile = None
    ; base_path = config.Workspace.base_path
    ; causal_context = Option.map (fun current -> current ()) gate_context
    ; task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
    ; continuation_channel
    }
;;

(* The Gate effect names what the write does to the file. A host write
   carries a pinned capability ([Keeper_alerting_path.path_effect]); an
   endpoint's file has none this host can pin, so a write under a declared
   root names the endpoint and its path. The operation is spelled as for a
   host write, and [fs_write_mode_of_gate_effect_operation] reads it back, so
   an approved endpoint write replays as the same mode. *)
let path_effect_operation_of_write_mode = function
  | Overwrite -> Keeper_alerting_path.Atomic_replace_entry
  | Append -> Keeper_alerting_path.Append_pinned_resource
  | Patch -> Keeper_alerting_path.Patch_then_atomic_replace_entry
;;

(* A write to a path under an endpoint's declared roots (#38593) is outside
   the keeper's tree, so it takes the Gate decision a host write outside the
   playground takes, with the same operation and the same input shape. The
   effect carries the endpoint's whole configuration, not only its name:
   replay rebuilds this input from the configuration current then, so an
   approval given for one host, key or pinned host key is not spent on
   another that took the same name. The configuration is the endpoint's own
   runtime.toml serialization, so a field added to the endpoint joins it. *)
let declared_root_write_gate_input
      ~(endpoint : Exec_ssh_endpoint.t)
      ~requested_target
      ~mode
      ~content_source
      ~content
      ~(patch : Keeper_tool_filesystem_remote_write.patch_request option)
  =
  let effect_json =
    `Assoc
      [ ( "operation"
        , `String
            (Keeper_alerting_path.path_effect_operation_to_string
               (path_effect_operation_of_write_mode mode)) )
      ; ( "endpoint"
        , `Assoc
            [ "name", `String endpoint.name
            ; "config_toml", `String (Exec_ssh_endpoint.to_toml endpoint)
            ] )
      ; "endpoint_path", `String requested_target
      ]
  in
  match patch with
  | None -> file_write_gate_input ~effect_json ~requested_target ~content ~content_source ()
  | Some { old_string; new_string; replace_all } ->
    file_write_gate_input ~effect_json ~requested_target ~content ~old_string ~new_string
      ~replace_all ()
;;

let declared_root_writes ~config ~meta ?continuation_channel ?gate_context ?gate_grant () =
  Keeper_tool_filesystem_remote_write.Authorize_declared_roots
    (fun ~endpoint ~requested_target ~mode ~content_source ~content ~patch ->
      let input =
        declared_root_write_gate_input ~endpoint ~requested_target ~mode ~content_source
          ~content ~patch
      in
      decide_file_write ~config ~meta ?continuation_channel ?gate_context ?gate_grant
        ~requested_target ~input ())
;;

let confined_write_is_keeper_playground
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      confined
  =
  let normalized path =
    Keeper_alerting_path.normalize_path_for_check_stripped path
  in
  String.equal
    (normalized (Keeper_alerting_path.confined_root confined))
    (normalized (Keeper_sandbox.host_root_abs_of_meta ~config meta))
;;
