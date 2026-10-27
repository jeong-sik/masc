(* Weak keys retain neither unowned export data nor turn descriptors. The
   mutex protects only non-yielding weak-table operations across domains. *)
module Issued = Weak.Make (struct
  type t = Keeper_tool_descriptor.t
  let equal left right = left == right
  let hash descriptor = Hashtbl.hash descriptor.Keeper_tool_descriptor.id
end)

let issued = Issued.create 16
module Export_key = struct
  type t = Lane_addon_tool_export.t
  let equal left right = left == right
  let hash export = Hashtbl.hash
      (export.Lane_addon_tool_export.instance_id,export.tool.Mcp_protocol.Mcp_types.name)
end

module Descriptors = Ephemeron.K1.Make (Export_key)
let descriptors : Keeper_tool_descriptor.t Descriptors.t = Descriptors.create 0
let issued_mutex = Mutex.create ()
let with_issued f =
  Mutex.lock issued_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock issued_mutex) f

let is_canonical descriptor =
  with_issued (fun () -> Issued.mem issued descriptor)

(** Dynamic descriptors carry a frozen owner/schema export. Runtime dispatch
    revalidates that generation instead of resolving by a Tool name alone. *)
let make (export : Lane_addon_tool_export.t) : Keeper_tool_descriptor.t =
  let open Keeper_tool_descriptor in
  let tool = export.tool in
  let id = "lane-addon:" ^ Agent_core_sha256.(to_hex (digest_string
    (Yojson.Safe.to_string (`List [`String export.instance_id; `String tool.name])))) in
  let descriptor = { id
  ; capability_id = id
  ; keeper_model_projection = Preferred_public_name
  ; input_schema_source = Descriptor_owned
  ; public_name = tool.name
  ; internal_name = tool.name
  ; description = Option.value ~default:"" tool.description
  ; input_schema = tool.input_schema
  ; model_output_projection = Tool_output.default_model_projection
  ; composable_output = Opaque_output
  ; execution = Ordinary Serial
  ; tool_kind = Atomic_tool
  ; policy = { readonly_of_input = (fun _ -> None); readonly_hint = None;
      cwd_scope = None; polling_read = false; leaves_masc = true }
  ; executor = In_process
  ; backend = Ocaml_runtime
  ; sandbox = No_sandbox
  ; runtime_handler = Tool_lane_addon export
  ; input_translation = Identity Validate_once_before_translation
  ; receipt_labels = ["descriptor_id", id; "capability_id", id;
      "lane_addon_instance_id", export.instance_id; "runtime_handler", "tool_lane_addon"]
  ; eval_tags = []
  ; examples = []
  }

  in
  descriptor

let create export =
  with_issued (fun () ->
    match Descriptors.find_opt descriptors export with
    | Some descriptor -> descriptor
    | None ->
      Descriptors.clean descriptors;
      let descriptor = make export in
      Issued.add issued descriptor;
      Descriptors.add descriptors export descriptor;
      descriptor)
;;
