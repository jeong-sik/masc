(** TRPG Slot Implementation

    @since 2.68.0
*)

(** {1 Slot Type Classification} *)

type slot_category =
  | Rule
  | World
  | Narrative
  | Metrics

let string_of_slot_category = function
  | Rule -> "rule"
  | World -> "world"
  | Narrative -> "narrative"
  | Metrics -> "metrics"

let slot_category_of_string = function
  | "rule" -> Ok Rule
  | "world" -> Ok World
  | "narrative" -> Ok Narrative
  | "metrics" -> Ok Metrics
  | s -> Error ("Unknown slot_category: " ^ s)

type slot_info = {
  slot_id : string;
  category : slot_category;
  version : string;
  description : string;
}

let slot_info_to_yojson { slot_id; category; version; description } =
  `Assoc [
    ("slot_id", `String slot_id);
    ("category", `String (string_of_slot_category category));
    ("version", `String version);
    ("description", `String description);
  ]

let slot_info_of_yojson json =
  let open Yojson.Safe.Util in
  let slot_id = json |> member "slot_id" |> to_string in
  let category =
    json |> member "category" |> to_string |> slot_category_of_string
    |> Result.map_error (fun e -> "Invalid category: " ^ e)
  in
  let version = json |> member "version" |> to_string in
  let description = json |> member "description" |> to_string in
  Result.map (fun category ->
    { slot_id; category; version; description }
  ) category

(** {1 Core Slot Signature} *)

module type TRPG_SLOT = sig
  val slot_info : slot_info
  val init_state : config:Yojson.Safe.t -> Yojson.Safe.t
  val apply_event : state:Yojson.Safe.t -> event:Engine_event.t -> Yojson.Safe.t
  val derive_state : state:Yojson.Safe.t -> Yojson.Safe.t
end

module type TRPG_SLOT_ASYNC = sig
  include TRPG_SLOT
  val init_state_async :
    config:Yojson.Safe.t ->
    sw:Eio.Switch.t ->
    on_result:(Yojson.Safe.t -> unit) ->
    unit
end

(** {1 Slot Registry Implementation} *)

module Registry : sig
  val register : (module TRPG_SLOT) -> unit
  val register_async : (module TRPG_SLOT_ASYNC) -> unit
  val find : slot_id:string -> (module TRPG_SLOT) option
  val list_all : unit -> slot_info list
  val list_by_category : slot_category -> slot_info list
  val clear : unit -> unit
end = struct
  module SlotTable = Hashtbl.Make (struct
    type t = string
    let hash = Hashtbl.hash
    let equal = String.equal
  end)

  (* Store both sync and async slots; async flag tracked separately *)
  let slots : (module TRPG_SLOT) SlotTable.t = SlotTable.create 16

  let is_async : bool SlotTable.t = SlotTable.create 16

  let register (module Slot : TRPG_SLOT) =
    SlotTable.add slots Slot.(slot_info.slot_id) (module Slot);
    SlotTable.remove is_async Slot.(slot_info.slot_id)

  let register_async (module Slot : TRPG_SLOT_ASYNC) =
    SlotTable.add slots Slot.(slot_info.slot_id) (module Slot : TRPG_SLOT);
    SlotTable.add is_async Slot.(slot_info.slot_id) true

  let find ~slot_id =
    try Some (SlotTable.find slots slot_id)
    with Not_found -> None

  let list_all () =
    SlotTable.fold
      (fun _slot_id (module Slot : TRPG_SLOT) acc ->
        Slot.slot_info :: acc
      )
      slots
      []
    |> List.sort (fun a b ->
        String.compare a.slot_id b.slot_id
      )

  let list_by_category category =
    list_all ()
    |> List.filter (fun info -> info.category = category)

  let clear () =
    SlotTable.clear slots;
    SlotTable.clear is_async
end

(** {1 Legacy Compatibility} *)

module type S = sig
  val id : string
  val init_state : config:Yojson.Safe.t -> Yojson.Safe.t
  val apply_event : state:Yojson.Safe.t -> event:Engine_event.t -> Yojson.Safe.t
  val derive_state : state:Yojson.Safe.t -> Yojson.Safe.t
end

module Lift_legacy (Legacy : S) = struct
  let slot_info = {
    slot_id = Legacy.id;
    category = Rule;  (* Legacy modules are rule slots by default *)
    version = "1.0.0";
    description = "Legacy rule slot";
  }

  let init_state = Legacy.init_state
  let apply_event = Legacy.apply_event
  let derive_state = Legacy.derive_state
end
