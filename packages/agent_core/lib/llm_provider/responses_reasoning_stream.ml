module Parts = Map.Make(Int)
type part = { chunks_rev : string list; nonblank : bool }
type text = { parts : part Parts.t; has_nonblank : bool }
type t = { summary : text; full : text; opaque : Yojson.Safe.t option }
type update = Unchanged | Append of string | Replace of string | Redact of string
let no_text = {parts=Parts.empty;has_nonblank=false}
let empty = {summary=no_text;full=no_text;opaque=None}
let part_text part = String.concat "" (List.rev part.chunks_rev)
let text_value text = Parts.bindings text.parts |> List.map(fun(_,part)->part_text part) |> String.concat "\n"
let channel_text state = function Responses_reasoning.Summary -> state.summary | Full -> state.full
let set_channel state channel text = match channel with
  | Responses_reasoning.Summary -> {state with summary=text}
  | Full -> {state with full=text}
let selected state = if state.full.has_nonblank then Some Responses_reasoning.Full
  else if state.summary.has_nonblank then Some Summary else None
let changed before after = match selected before,selected after with
  | None,None -> Unchanged
  | None,Some channel -> Append(text_value(channel_text after channel))
  | Some old,Some channel ->
    let value=text_value(channel_text after channel) in
    if old=channel && text_value(channel_text before old)=value then Unchanged
    else Replace value
  | Some _,None -> Replace ""
let nonblank value = not(Api_common.string_is_blank value)
let delta state ~channel ~part value =
  if part<0 then Error "responses_replay:negative_reasoning_part"
  else match state.opaque with
  | Some _ -> Error "responses_replay:plaintext_after_opaque"
  | None ->
    let current=channel_text state channel in
    let previous=Parts.find_opt part current.parts in
    let fragment=match previous with None->{chunks_rev=[value];nonblank=nonblank value}
      | Some previous->{chunks_rev=value::previous.chunks_rev;nonblank=previous.nonblank || nonblank value} in
    let after=set_channel state channel {parts=Parts.add part fragment current.parts
      ;has_nonblank=current.has_nonblank || fragment.nonblank} in
    let update=match selected state,selected after with
      | Some old,Some now when old=now && now=channel ->
        (match Parts.max_binding_opt current.parts with
         | Some(last,_) when part=last -> Append value
         | Some(last,_) when part>last -> Append("\n"^value)
         | Some _ | None -> changed state after)
      | Some old,Some now when old=now -> Unchanged
      | (None|Some _),(None|Some _) -> changed state after in
    Ok(after,update)
let merge_part current index snapshot =
  match Parts.find_opt index current with
  | Some previous when not(String.starts_with ~prefix:(part_text previous) snapshot) ->
    Error "responses_replay:reasoning_snapshot_conflict"
  | Some _ | None ->
    Ok(Parts.add index {chunks_rev=[snapshot];nonblank=nonblank snapshot} current)
let part_done state ~channel ~part snapshot =
  if part<0 then Error "responses_replay:negative_reasoning_part"
  else match state.opaque with
  | Some _ -> Error "responses_replay:plaintext_after_opaque"
  | None ->
    let current=channel_text state channel in
    Result.map(fun parts->
      let next=set_channel state channel {parts;has_nonblank=current.has_nonblank || nonblank snapshot} in
      next,changed state next) (merge_part current.parts part snapshot)
let merge_channel current = function
  | None -> Ok current
  | Some snapshots ->
    if Parts.exists(fun index part->part.nonblank && not(List.mem_assoc index snapshots))current.parts
    then Error "responses_replay:missing_reasoning_part"
    else
      let rec merge parts = function
        | [] -> Ok {parts;has_nonblank=Parts.exists(fun _ part->part.nonblank)parts}
        | (index,snapshot)::rest -> Result.bind(merge_part parts index snapshot)(fun parts->merge parts rest)
      in merge current.parts snapshots
let item state incoming = match state.opaque,incoming with
  | Some original,Responses_reasoning.Opaque raw ->
    if Yojson.Safe.equal original raw then Ok(state,Unchanged)
    else Error "responses_replay:conflicting_reasoning_item"
  | None,Responses_reasoning.Opaque raw ->
    Ok({state with opaque=Some raw},Redact(Yojson.Safe.to_string raw))
  | Some _,Responses_reasoning.Plaintext channels ->
    (match Responses_reasoning.selected channels with
     | None -> Ok(state,Unchanged)
     | Some _ -> Error "responses_replay:plaintext_after_opaque")
  | None,Responses_reasoning.Plaintext channels ->
    Result.bind(merge_channel state.summary channels.summary)(fun summary->
      Result.map(fun full->let next={state with full;summary}in next,changed state next)
        (merge_channel state.full channels.full))
