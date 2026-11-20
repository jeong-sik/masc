module Unit = Librarian_unit
module Read_unit = Librarian_read_unit
module Unread = Librarian_unread
module Scan = Private_jsonl_scan
module Objects = Agent_core.Checkpoint_objects
module Chat_types = Keeper_chat_types
module Delivery_identity = Keeper_chat_delivery_identity

module String_set = Set.Make (String)

module Pair_set = Set.Make (struct
  type t = string * string

  let compare (a1, b1) (a2, b2) =
    match String.compare a1 a2 with
    | 0 -> String.compare b1 b2
    | c -> c
  ;;
end)

type stores =
  { session_dir : session:string -> string
  ; base_path : string
  ; keeper_name : string
  }

type read_error =
  | Fault of Unit.input_fault
  | Unread of { detail : string }

type take =
  | Rest_of_unit
  | First_items of Librarian_width.count

type read =
  { unit : Read_unit.t
  ; ends : Librarian_log.within
  }

let ( let* ) = Result.bind

(* One item or one part that is not there, in the unit's order. *)
type entry =
  | Item of Unit.item_name * Read_unit.body
  | Lacking of Unit.missing_part

(* How many more items the read takes. A read of the first k items looks for
   one more, to know whether the unit goes on after them. *)
type budget =
  | Every
  | Taking of int

let spent = function
  | Every -> false
  | Taking left -> left <= 0
;;

let counted budget = function
  | Item _ -> (
    match budget with
    | Every -> Every
    | Taking left -> Taking (left - 1))
  | Lacking (_ : Unit.missing_part) -> budget
;;

(* Where a read starts in one store of one segment. *)
type start =
  | Passed (** Every item of it was read before. *)
  | After of int (** The item at this coordinate was read; the read goes on after it. *)
  | From_first

(* What one store gave: its entries in order, and the budget after them. *)
type part =
  { entries : entry list
  ; budget : budget
  }

let nothing budget = { entries = []; budget }
let is_empty ({ from; until } : Unit.range) = until <= from

(* A store is read as many rows per locked read as the turn log is. *)
let rows_per_read = Keeper_turn_log_store.scan_window_rows

let unread error = Error (Unread { detail = Scan.error_to_string error })

type scan =
  { found : entry list (** Newest first. *)
  ; left : budget
  ; reached : int (** Just past the last row seen. *)
  ; skipping : bool (** The first row is the one read before. *)
  }

(* The rows of [path] that start inside [range], each as [entry] makes it,
   and the part of the range the file does not hold. After an item, the scan
   starts at that item's row and finds where the next row starts by its line
   break; that row is not decoded. A range that does not start a row of the
   file is not held at all. A read whose budget is spent says nothing about
   the rows after: the next read reads them. *)
let byte_rows path (range : Unit.range) start ~budget ~entry ~lacking =
  let first =
    match start with
    | Passed -> None
    | From_first -> Some (range.from, false)
    | After at ->
      if at < range.from then Some (range.from, false)
      else if at < range.until then Some (at, true)
      else None
  in
  match first with
  | None -> Ok (nothing budget)
  | Some (from, (_ : bool)) when is_empty { range with from } -> Ok (nothing budget)
  | Some (from, skipping) ->
    let ended { found; left; reached; skipping = (_ : bool) } =
      let lacking =
        if spent left || reached >= range.until then [] else [ Lacking (lacking { range with from = reached }) ]
      in
      Ok { entries = List.rev found @ lacking; budget = left }
    in
    (match
       Scan.fold_from path ~from ~rows_per_read ~init:{ found = []; left = budget; reached = from; skipping }
         ~f:(fun scan ~at row ->
           if at >= range.until then Scan.Stop scan
           else (
             let reached = at + String.length row + 1 in
             if scan.skipping then Scan.Continue { scan with reached; skipping = false }
             else (
               match entry ~at row with
               | None -> Scan.Continue { scan with reached; skipping = false }
               | Some one ->
                 let scan = { found = one :: scan.found; left = counted scan.left one; reached; skipping = false } in
                 if spent scan.left then Scan.Stop scan else Scan.Continue scan)))
     with
     | Ok (Stopped scan | Reached_end scan) -> ended scan
     | Error (Not_a_row_start { from = (_ : int); length = (_ : int) }) ->
       Ok { entries = [ Lacking (lacking { range with from }) ]; budget }
     | Error (Scan_failed error) -> unread error)
;;

let official_rows path file store range start ~budget =
  let entry ~at row =
    match Keeper_turn_fragments.decode_line row with
    | Ok line -> Some (Item ({ store; at }, Read_unit.Fragment { file; line }))
    | Error (_ : Keeper_turn_fragments.read_error) -> (
      match (file : Keeper_turn_fragments.file) with
      | Main -> Some (Lacking (Undecodable_history_line { offset = at }))
      | Internal -> Some (Lacking (Undecodable_internal_line { offset = at })))
  in
  let lacking range : Unit.missing_part =
    match file with
    | Main -> History_bytes range
    | Internal -> Internal_bytes range
  in
  byte_rows path range start ~budget ~entry ~lacking
;;

let chat_rows ~keep path range start ~budget =
  byte_rows path range start ~budget
    ~entry:(fun ~at row ->
      let parsed = Keeper_chat_store_line_decode.parse_line_decoded ~file_path:path row in
      if keep parsed then Some (Item ({ store = Chat; at }, Read_unit.Chat_row parsed)) else None)
    ~lacking:(fun range -> Unit.Chat_bytes range)
;;

let external_entry ~row text =
  let decoded =
    match Yojson.Safe.from_string text with
    | exception Yojson.Json_error (_ : string) -> None
    | json -> (
      match Keeper_external_attention.event_of_json json with
      | Ok (Recorded item) -> Some item
      | Error (_ : string) -> None)
  in
  match decoded with
  | Some item -> Item ({ store = External; at = row }, Read_unit.External_row item)
  | None -> Lacking (Unit.Undecodable_external_row { row })
;;

(* The external store is counted in rows from its first, so its rows are
   found by counting from there. *)
let external_rows path (range : Unit.range) start ~budget =
  let range =
    match start with
    | Passed -> { range with from = range.until }
    | After row -> { range with from = Int.max range.from (row + 1) }
    | From_first -> range
  in
  if is_empty range then Ok (nothing budget)
  else (
    match
      Scan.fold_from path ~from:0 ~rows_per_read ~init:(0, [], budget)
        ~f:(fun (count, found, left) ~at:(_ : int) text ->
          if count >= range.until then Scan.Stop (count, found, left)
          else if count < range.from then Scan.Continue (count + 1, found, left)
          else (
            let one = external_entry ~row:count text in
            let left = counted left one in
            let scanned = count + 1, one :: found, left in
            if spent left then Scan.Stop scanned else Scan.Continue scanned))
    with
    | Error (Not_a_row_start { from = (_ : int); length = (_ : int) }) ->
      Ok { entries = [ Lacking (External_rows range) ]; budget }
    | Error (Scan_failed error) -> unread error
    | Ok (Stopped (count, found, left) | Reached_end (count, found, left)) ->
      let lacking =
        if spent left || count >= range.until then []
        else [ Lacking (External_rows { from = Int.max range.from count; until = range.until }) ]
      in
      Ok { entries = List.rev found @ lacking; budget = left })
;;

(* The slices take the unit's messages in order, so a message's number is
   [first] and how many messages the slices before it take. A bundle that is
   not stored is the part of its slice the read had not passed. *)
let messages ~line ~session_dir ~first (slices : Keeper_turn_log.slice list) start ~budget =
  let read_object = Keeper_checkpoint_object_store.read ~session_dir in
  let unreadable = Error (Fault (Content_unreadable { line })) in
  let after =
    match start with
    | Passed | From_first -> None
    | After number -> Some number
  in
  let rec walk number found left = function
    | [] -> Ok { entries = List.rev found; budget = left }
    | (_ : Keeper_turn_log.slice list) when spent left -> Ok { entries = List.rev found; budget = left }
    | ({ bundle; skip; take } : Keeper_turn_log.slice) :: rest ->
      let past = number + take in
      let low =
        match after with
        | None -> number
        | Some read -> Int.max number (read + 1)
      in
      if low >= past then walk past found left rest
      else (
        let slice : Keeper_turn_log.slice = { bundle; skip = skip + low - number; take = past - low } in
        match Objects.load_bundle ~read_object bundle with
        | Error (Object_missing (_ : Objects.digest)) -> walk past (Lacking (Bundle slice) :: found) left rest
        | Error
            ( Head_invalid _ | Checkpoint_invalid _ | Object_unreadable _ | Object_digest_mismatch _
            | Bundle_invalid _ | Turn_mismatch _ | Message_invalid _ | Segment_invalid _
            | Header_object_invalid _ ) -> unreadable
        | Ok held ->
          if List.length held < slice.skip + slice.take then unreadable
          else (
            let window =
              List.filteri
                (fun index (_ : Agent_core.Types.message) -> index >= slice.skip && index < slice.skip + slice.take)
                held
            in
            let found, left, (_ : int) =
              List.fold_left
                (fun (found, left, at) message ->
                   if spent left then found, left, at
                   else (
                     let one = Item ({ store = Agent_core; at }, Read_unit.Message message) in
                     one :: found, counted left one, at + 1))
                (found, left, low) window
            in
            walk past found left rest))
  in
  match start with
  | Passed -> Ok (nothing budget)
  | After (_ : int) | From_first -> walk first [] budget slices
;;

(* One segment's stores in the order {!Librarian_unit} gives, each from where
   [starts] says, until the budget is spent. *)
(* The stores a segment's record reads (§5.3): the checkpoint's slices when
   it reads the checkpoint, the main file's range when it reads that file,
   and the internal file's range, which every record reads. *)
let checkpoint_slices : Unread.record -> Keeper_turn_log.slice list option = function
  | Checkpoint { slices; internal = _ } | Every_record { slices; history = _; internal = _ } -> Some slices
  | Official_files { history = _; internal = _ } -> None
;;

let history_range : Unread.record -> Unit.range option = function
  | Official_files { history; internal = _ } | Every_record { slices = _; history; internal = _ } -> Some history
  | Checkpoint { slices = _; internal = _ } -> None
;;

let internal_range : Unread.record -> Unit.range = function
  | Checkpoint { slices = _; internal }
  | Official_files { history = _; internal }
  | Every_record { slices = _; history = _; internal } -> internal
;;

type external_keys =
  { event_ids : String_set.t
  ; delivery_pairs : Pair_set.t
  }

let empty_external_keys = { event_ids = String_set.empty; delivery_pairs = Pair_set.empty }

let add_external_key keys = function
  | Read_unit.External_row item ->
    let event_ids = String_set.add item.event_id keys.event_ids in
    let delivery_pairs =
      match item.external_message with
      | None -> keys.delivery_pairs
      | Some msg_ref ->
        Pair_set.add (item.conversation.conversation_id, msg_ref.message_id) keys.delivery_pairs
    in
    { event_ids; delivery_pairs }
  | Read_unit.Chat_row _ | Read_unit.Message _ | Read_unit.Fragment _ -> keys
;;

let add_entry_external_key keys = function
  | Item ((_ : Unit.item_name), body) -> add_external_key keys body
  | Lacking (_ : Unit.missing_part) -> keys
;;

let external_keys_of_entries entries = List.fold_left add_entry_external_key empty_external_keys entries

type transcript_witnesses =
  { user_texts : String_set.t
  ; assistant_texts : String_set.t
  ; tool_call_ids : String_set.t
  ; tool_observation_names : String_set.t
  }

let empty_witnesses =
  { user_texts = String_set.empty
  ; assistant_texts = String_set.empty
  ; tool_call_ids = String_set.empty
  ; tool_observation_names = String_set.empty
  }
;;

let add_non_empty value set = if String.equal value "" then set else String_set.add value set
let mem_non_empty value set = (not (String.equal value "")) && String_set.mem value set

let is_conversation_user (message : Agent_core.Types.message) =
  match message.origin with
  | Agent_core.Types.Conversation ->
    (match message.role with
     | Agent_core.Types.User -> true
     | Agent_core.Types.System | Assistant | Tool -> false)
  | System_context
  | Historical_system_context
  | Recovery_instruction
  | Tool_result_followup
  | Agent_instruction -> false
;;

let is_conversation_assistant (message : Agent_core.Types.message) =
  match message.origin with
  | Agent_core.Types.Conversation ->
    (match message.role with
     | Agent_core.Types.Assistant -> true
     | Agent_core.Types.System | User | Tool -> false)
  | System_context
  | Historical_system_context
  | Recovery_instruction
  | Tool_result_followup
  | Agent_instruction -> false
;;

let add_message_tool_call_ids acc (message : Agent_core.Types.message) =
  List.fold_left
    (fun ids -> function
      | Agent_core.Types.ToolUse { id; _ } -> add_non_empty id ids
      | Agent_core.Types.ToolResult { tool_use_id; _ } -> add_non_empty tool_use_id ids
      | Agent_core.Types.Text _
      | Agent_core.Types.Thinking _
      | Agent_core.Types.ReasoningDetails _
      | Agent_core.Types.RedactedThinking _
      | Agent_core.Types.Image _
      | Agent_core.Types.Document _
      | Agent_core.Types.Audio _ -> ids)
    acc
    message.Agent_core.Types.content
;;

let add_message_witnesses ~include_user acc (message : Agent_core.Types.message) =
  let text = Agent_core.Types.text_of_content message.content in
  let user_texts =
    if include_user && is_conversation_user message
    then add_non_empty text acc.user_texts
    else acc.user_texts
  in
  let assistant_texts =
    if is_conversation_assistant message
    then add_non_empty text acc.assistant_texts
    else acc.assistant_texts
  in
  let tool_call_ids = add_message_tool_call_ids acc.tool_call_ids message in
  { acc with user_texts; assistant_texts; tool_call_ids }
;;

let add_witnesses acc = function
  | Read_unit.Message message -> add_message_witnesses ~include_user:true acc message
  | Read_unit.Fragment
      { file = Keeper_turn_fragments.Main
      ; line = Keeper_turn_fragments.Fragment (Keeper_turn_fragments.Message { message; _ })
      } -> add_message_witnesses ~include_user:true acc message
  | Read_unit.Fragment
      { file = Keeper_turn_fragments.Internal
      ; line = Keeper_turn_fragments.Fragment (Keeper_turn_fragments.Message { message; _ })
      } -> add_message_witnesses ~include_user:false acc message
  | Read_unit.Fragment
      { file = Keeper_turn_fragments.Main | Keeper_turn_fragments.Internal
      ; line =
          Keeper_turn_fragments.Fragment (Keeper_turn_fragments.Tool_observation { observation; _ })
      } ->
    { acc with
      tool_observation_names = add_non_empty observation.tool_name acc.tool_observation_names
    }
  | Read_unit.Fragment
      { file = Keeper_turn_fragments.Main | Keeper_turn_fragments.Internal
      ; line = Keeper_turn_fragments.Untagged
      }
  | Read_unit.Chat_row _
  | Read_unit.External_row _ -> acc
;;

let add_entry_witnesses acc = function
  | Item ((_ : Unit.item_name), body) -> add_witnesses acc body
  | Lacking (_ : Unit.missing_part) -> acc
;;

let witnesses_of_entries entries = List.fold_left add_entry_witnesses empty_witnesses entries

let matches_external_row external_keys (msg : Chat_types.chat_message) =
  let matches_connector_event =
    match msg.delivery_provenance with
    | Some { delivery_key = Delivery_identity.Connector_message req_id; _ } ->
      String_set.mem (Delivery_identity.Request_id.to_string req_id) external_keys.event_ids
    | None
    | Some
        { delivery_key =
            ( Operation _
            | Operation_checkpoint _
            | Operation_native _
            | Fusion_run _
            | Workspace_message _
            | Approval_lifecycle _
            | Autonomous_turn _ )
        ; _
        } -> false
  in
  let matches_delivery_pair =
    match msg.conversation_id, msg.external_message_id with
    | Some cid, Some mid -> Pair_set.mem (cid, mid) external_keys.delivery_pairs
    | Some (_ : string), None | None, (Some (_ : string) | None) -> false
  in
  matches_connector_event || matches_delivery_pair
;;

(* Delivery keys whose rows originate on the chat lane (e.g. Fusion
   deliberation conclusions via [Fusion_sink.emit], Gate approval lifecycle
   receipts, workspace broadcasts, autonomous turn tool rows) are never
   dropped as transcript mirrors. *)
let is_chat_only_provenance (msg : Chat_types.chat_message) =
  match msg.delivery_provenance with
  | Some
      { delivery_key =
          ( Delivery_identity.Fusion_run _
          | Approval_lifecycle _
          | Autonomous_turn _
          | Workspace_message _ )
      ; _
      } -> true
  | None
  | Some
      { delivery_key =
          ( Operation _
          | Operation_checkpoint _
          | Operation_native _
          | Connector_message _ )
      ; _
      } -> false
;;

(* When the unit transcript carries exact [ToolUse]/[ToolResult] call ids,
   only a chat tool row with a matching [tool_call_id] is dropped so a
   concurrent or different [call_id] stays visible. Official-client
   [Tool_observation] rows carry no [call_id], so match [tool_call_name]
   against [tool_observation_names] only when [tool_call_ids] is empty. *)
let matches_tool_witness witnesses (msg : Chat_types.chat_message) =
  match msg.tool_call_id with
  | Some cid when mem_non_empty cid witnesses.tool_call_ids -> true
  | Some (_ : string) | None ->
    if String_set.is_empty witnesses.tool_call_ids
    then (
      match msg.tool_call_name with
      | Some name -> mem_non_empty name witnesses.tool_observation_names
      | None -> false)
    else false
;;

(* Layer-2 exact-witness chat deduplication on top of Layer-1 records (#53607):
   - Corrupt rows, [Role.System], [Role.Request_failure], and chat-only
     provenance ([Fusion_run], [Approval_lifecycle], [Autonomous_turn],
     [Workspace_message]) always stay.
   - [Role.Assistant] mirror rows drop only when their non-empty text matches a
     [Conversation] [Assistant] message in the unit's transcript.
   - [Role.Tool] mirror rows drop only when [tool_call_id] matches a transcript
     [ToolUse]/[ToolResult] id (or [tool_call_name] matches an official-client
     [Tool_observation] when no [tool_call_id] witnesses exist).
   - [Role.User] drops only when matched by exact [External_row] keys or when
     both [turn_ref] is stamped and its non-empty text matches a [Conversation]
     [User] message in the unit's transcript; unlinked [Operation*]
     accepted-user rows stay conservatively. *)
let keep_chat_row ~witnesses ~external_keys (parsed : Keeper_chat_store_line_decode.parsed_line) =
  match parsed.message with
  | None -> true
  | Some msg ->
    (match msg.role with
     | Chat_types.Role.System | Chat_types.Role.Request_failure -> true
     | Chat_types.Role.Assistant ->
       if is_chat_only_provenance msg
       then true
       else not (mem_non_empty msg.content witnesses.assistant_texts)
     | Chat_types.Role.Tool ->
       if is_chat_only_provenance msg then true else not (matches_tool_witness witnesses msg)
     | Chat_types.Role.User ->
       if matches_external_row external_keys msg
       then false
       else if is_chat_only_provenance msg
       then true
       else if Option.is_some msg.turn_ref && mem_non_empty msg.content witnesses.user_texts
       then false
       else true)
;;

let take_entries budget entries =
  let rec loop acc left = function
    | [] -> { entries = List.rev acc; budget = left }
    | (_ : entry list) when spent left -> { entries = List.rev acc; budget = left }
    | one :: rest ->
      let left = counted left one in
      let acc = one :: acc in
      if spent left then { entries = List.rev acc; budget = left } else loop acc left rest
  in
  loop [] budget entries
;;

(* Preloading [non_chat_starts] runs only while [resume] is still inside [Chat];
   once [resume] moves past [Chat], [has_unread_chat] is [false] and zero
   preloading runs. Within a single [read] call the preloaded entries are reused
   directly by [segment] (so [Rest_of_unit] reads each store strictly once).
   [read] is stateless across [First_items] narrowing calls (#53736), so any
   per-step witness scan is bounded to one unit's non-chat stores while still
   consuming unread chat items. *)
let has_unread_chat (seg : Unread.segment) starts =
  if is_empty seg.chat then false
  else
    List.exists
      (function
        | Unit.Chat, From_first -> true
        | Unit.Chat, After at -> at < seg.chat.until
        | Unit.Chat, Passed
        | (Unit.External | Unit.Agent_core | Unit.History | Unit.Internal), (_ : start) -> false)
      starts
;;

let non_chat_starts =
  List.filter_map
    (function
      | Unit.Chat -> None
      | (Unit.External | Unit.Agent_core | Unit.History | Unit.Internal) as store -> Some (store, From_first))
    Unit.stores
;;

let all_from_first starts =
  List.for_all
    (function
      | (_ : Unit.store), From_first -> true
      | (_ : Unit.store), (Passed | After (_ : int)) -> false)
    starts
;;

let split_chat_and_full_rest = function
  | (Unit.Chat, chat_start) :: rest -> if all_from_first rest then Some chat_start else None
  | ((Unit.External | Unit.Agent_core | Unit.History | Unit.Internal), (_ : start))
    :: (_ : (Unit.store * start) list) -> None
  | [] -> None
;;

let segment
    ?(keep = fun (_ : Keeper_chat_store_line_decode.parsed_line) -> true)
    ?preloaded_non_chat
    stores
    ~line
    ~through:(through : Keeper_turn_log.mark)
    ~first
    (segment : Unread.segment)
    starts
    budget
  =
  let official = stores.session_dir ~session:through.session in
  let chat_path = Keeper_chat_store.chat_path ~base_dir:stores.base_path ~keeper_name:stores.keeper_name in
  let read_store (store : Unit.store) start budget =
    match store with
    | Chat -> chat_rows ~keep chat_path segment.chat start ~budget
    | External ->
      external_rows
        (Keeper_external_attention.attention_path ~base_path:stores.base_path ~keeper_name:stores.keeper_name)
        segment.external_rows start ~budget
    | Agent_core ->
      (match checkpoint_slices segment.record with
       | Some slices ->
         messages ~line ~session_dir:(stores.session_dir ~session:through.trace) ~first slices start ~budget
       | None -> Ok (nothing budget))
    | History ->
      (match history_range segment.record with
       | Some range ->
         official_rows (Keeper_turn_fragments.path ~session_dir:official Main) Main History range start ~budget
       | None -> Ok (nothing budget))
    | Internal ->
      official_rows (Keeper_turn_fragments.path ~session_dir:official Internal) Internal Internal
        (internal_range segment.record) start ~budget
  in
  match preloaded_non_chat, split_chat_and_full_rest starts with
  | Some non_chat_entries, Some chat_start ->
    if spent budget then Ok (nothing budget)
    else
      let* chat_part = chat_rows ~keep chat_path segment.chat chat_start ~budget in
      if spent chat_part.budget then Ok chat_part
      else
        let rest_part = take_entries chat_part.budget non_chat_entries in
        Ok { entries = chat_part.entries @ rest_part.entries; budget = rest_part.budget }
  | None, (_ : start option) | Some (_ : entry list), None ->
    List.fold_left
      (fun read (store, start) ->
         let* { entries; budget } = read in
         if spent budget then read
         else (
           let* part = read_store store start budget in
           Ok { entries = entries @ part.entries; budget = part.budget }))
      (Ok (nothing budget)) starts
;;

let from_first = List.map (fun store -> store, From_first) Unit.stores

(* The stores before the resumed item's store were read, its own goes on
   after the item, the ones after it start at their first row. *)
let resumed (name : Unit.item_name) =
  let rec starts = function
    | [] -> []
    | store :: rest ->
      if Unit.equal_store store name.store
      then (store, After name.at) :: List.map (fun store -> store, From_first) rest
      else (store, Passed) :: starts rest
  in
  starts Unit.stores
;;

let messages_in (slices : Keeper_turn_log.slice list) =
  List.fold_left (fun count ({ take; _ } : Keeper_turn_log.slice) -> count + take) 0 slices
;;

(* A record that does not read the checkpoint is one whose slices take no
   message (§5.3), so it numbers none. *)
let messages_of (record : Unread.record) =
  match checkpoint_slices record with
  | Some slices -> messages_in slices
  | None -> 0
;;

(* Each store's [own] range starts where its [unattributed] range ends, and
   the own messages are numbered after the unattributed ones. *)
let in_own (own : Unread.segment) ~own_first ({ store; at } : Unit.item_name) =
  match store with
  | Chat -> at >= own.chat.from
  | External -> at >= own.external_rows.from
  | Agent_core ->
    (match checkpoint_slices own.record with
     | Some (_ : Keeper_turn_log.slice list) -> at >= own_first
     | None -> false)
  | History ->
    (match history_range own.record with
     | Some range -> at >= range.from
     | None -> false)
  | Internal -> at >= (internal_range own.record).from
;;

let rec through_item count kept = function
  | [] -> None
  | (Lacking (_ : Unit.missing_part) as entry) :: rest -> through_item count (entry :: kept) rest
  | (Item (name, (_ : Read_unit.body)) as entry) :: rest ->
    if Int.equal count 1 then Some (List.rev (entry :: kept), name, rest)
    else through_item (count - 1) (entry :: kept) rest
;;

let is_item = function
  | Item _ -> true
  | Lacking (_ : Unit.missing_part) -> false
;;

(* How many entries the read keeps, and where it ends. The first [k] items
   end the read only when an item follows them: what lies between them and
   that item, missing parts included, is left for the next read. *)
let ending take entries =
  match take with
  | Rest_of_unit -> List.length entries, Librarian_log.Whole
  | First_items count -> (
    match through_item (count :> int) [] entries with
    | Some (kept, name, rest) when List.exists is_item rest -> List.length kept, Librarian_log.Item name
    | Some (_ : entry list * Unit.item_name * entry list) | None -> List.length entries, Librarian_log.Whole)
;;

let first_entries count entries = List.filteri (fun index (_ : entry) -> index < count) entries

let items ~first entries =
  List.filter_map
    (function
      | Item (name, body) -> Some (name, body)
      | Lacking (_ : Unit.missing_part) -> None)
    entries
  |> List.mapi (fun place (name, body) : Read_unit.item -> { index = first + place; name; body })
;;

let missing entries =
  List.filter_map
    (function
      | Lacking part -> Some part
      | Item _ -> None)
    entries
;;

let read stores (span : Unread.span) ~take =
  let budget =
    match take with
    | Rest_of_unit -> Every
    | First_items count -> Taking ((count :> int) + 1)
  in
  let first = span.from.closed_messages in
  let seg_read ?keep ?preloaded_non_chat ~first seg starts budget =
    segment ?keep ?preloaded_non_chat stores ~line:span.line ~through:span.through ~first seg starts budget
  in
  match span.source with
  | Turn { turn; outcome; opened; unattributed; own } ->
    let own_first = first + messages_of unattributed.record in
    let before_starts, own_starts =
      match span.resume with
      | None -> from_first, from_first
      | Some name -> if in_own own ~own_first name then [], resumed name else resumed name, from_first
    in
    let* before_non_chat, after_non_chat, keep =
      if has_unread_chat unattributed before_starts || has_unread_chat own own_starts then
        let* before_nc = seg_read ~first unattributed non_chat_starts Every in
        let* after_nc = seg_read ~first:own_first own non_chat_starts Every in
        let unit_entries = before_nc.entries @ after_nc.entries in
        let external_keys = external_keys_of_entries unit_entries in
        let witnesses = witnesses_of_entries unit_entries in
        Ok (Some before_nc.entries, Some after_nc.entries, keep_chat_row ~witnesses ~external_keys)
      else Ok (None, None, fun (_ : Keeper_chat_store_line_decode.parsed_line) -> true)
    in
    let* before = seg_read ~keep ?preloaded_non_chat:before_non_chat ~first unattributed before_starts budget in
    let* after = seg_read ~keep ?preloaded_non_chat:after_non_chat ~first:own_first own own_starts before.budget in
    let kept, ends = ending take (before.entries @ after.entries) in
    let before = first_entries kept before.entries in
    let after = first_entries (kept - List.length before) after.entries in
    let unattributed = items ~first:0 before in
    Ok
      { unit =
          { line = span.line
          ; at = span.at
          ; kind =
              Turn
                { turn; outcome; opened; unattributed; own = items ~first:(List.length unattributed) after }
          ; missing = missing before @ missing after
          }
      ; ends
      }
  | Announced_reset { cause; segment = held } ->
    let starts =
      match span.resume with
      | None -> from_first
      | Some name -> resumed name
    in
    let* held_non_chat, keep =
      if has_unread_chat held starts then
        let* held_nc = seg_read ~first held non_chat_starts Every in
        let external_keys = external_keys_of_entries held_nc.entries in
        let witnesses = witnesses_of_entries held_nc.entries in
        Ok (Some held_nc.entries, keep_chat_row ~witnesses ~external_keys)
      else Ok (None, fun (_ : Keeper_chat_store_line_decode.parsed_line) -> true)
    in
    let* part = seg_read ~keep ?preloaded_non_chat:held_non_chat ~first held starts budget in
    let kept, ends = ending take part.entries in
    let entries = first_entries kept part.entries in
    Ok
      { unit = { line = span.line; at = span.at; kind = Reset { cause; items = items ~first:0 entries }; missing = missing entries }
      ; ends
      }
;;
