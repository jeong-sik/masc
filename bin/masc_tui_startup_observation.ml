type stop_reason =
  | User_input_ready | Replies_ready | Deadline_reached
  | Read_returned_no_byte | Byte_cap_reached
type failure = Raised | Interrupted
type worker_outcome =
  | Captured of {reason:stop_reason; bytes_read:int; replies:Masc_tui_terminal_probe.observation}
  | Capture_failed of {failure:failure; bytes_read:int}
type caller_outcome = Returned_to_caller | Call_failed of failure
type input_kind = Key | Paste | Pointer
type event =
  | Dispatched
  | Worker_started
  | Capture_finished of worker_outcome
  | Caller_observed of caller_outcome
  | Decoder_installed
  | Capabilities_applied of Masc_tui_terminal_probe.observation
  | First_input_decoded of input_kind
  | First_input_received of input_kind
type t = {
  pid:int; dispatched_ns:int64;
  worker_started_ns:int64 option;
  capture_finished:(int64 * worker_outcome) option;
  caller_observed:(int64 * caller_outcome) option;
  decoder_installed_ns:int64 option;
  capabilities_applied:(int64 * Masc_tui_terminal_probe.observation) option;
  first_input_decoded:(int64 * input_kind) option;
  first_input_received:(int64 * input_kind) option;
}
let create ~pid ~dispatched_ns =
  {pid;dispatched_ns;worker_started_ns=None;capture_finished=None;caller_observed=None;
   decoder_installed_ns=None;capabilities_applied=None;first_input_decoded=None;first_input_received=None}

let record t ~at_ns event = match event with
  | Dispatched -> t,true
  | Worker_started -> (match t.worker_started_ns with
      | None -> {t with worker_started_ns=Some at_ns},true | Some _ -> t,false)
  | Capture_finished outcome -> (match t.capture_finished with
      | None -> {t with capture_finished=Some (at_ns,outcome)},true | Some _ -> t,false)
  | Caller_observed outcome -> (match t.caller_observed with
      | None -> {t with caller_observed=Some (at_ns,outcome)},true | Some _ -> t,false)
  | Decoder_installed -> (match t.decoder_installed_ns with
      | None -> {t with decoder_installed_ns=Some at_ns},true | Some _ -> t,false)
  | Capabilities_applied replies -> (match t.capabilities_applied with
      | Some (_,previous) when previous == replies -> t,false
      | Some _ | None -> {t with capabilities_applied=Some (at_ns,replies)},true)
  | First_input_decoded kind -> (match t.first_input_decoded with
      | None -> {t with first_input_decoded=Some (at_ns,kind)},true | Some _ -> t,false)
  | First_input_received kind -> (match t.first_input_decoded,t.first_input_received with
      | Some (_,decoded),None when decoded=kind ->
        {t with first_input_received=Some (at_ns,kind)},true
      | (Some _ | None),(Some _ | None) -> t,false)

let ns value = `String (Int64.to_string value)
let optional f = function Some value -> f value | None -> `Null
let failure_name = function Raised -> "raised" | Interrupted -> "interrupted"
let kind_name = function Key -> "key" | Paste -> "paste" | Pointer -> "pointer"
let reason_name = function
  | User_input_ready -> "input_ready" | Replies_ready -> "replies_ready"
  | Deadline_reached -> "deadline_reached" | Read_returned_no_byte -> "read_returned_no_byte"
  | Byte_cap_reached -> "byte_cap_reached"
let replies_json (replies : Masc_tui_terminal_probe.observation) = `Assoc [
  "palette_known",`Bool (Option.is_some replies.palette);
  "theme_mode",(match replies.theme_mode with None -> `Null
    | Some Masc_tui_terminal_palette.Dark -> `String "dark" | Some Light -> `String "light");
  "graphics",(match replies.graphics with None -> `String "unknown"
    | Some Masc_tui_graphics.Supported -> `String "supported" | Some (Refused _) -> `String "refused");
  "cell_pixels",optional (fun (width,height) -> `Assoc ["width",`Int width;"height",`Int height]) replies.cell_pixels]
let worker_json = function
  | Captured {reason;bytes_read;replies} -> `Assoc ["outcome",`String "captured";
      "reason",`String (reason_name reason);"bytes_read",`Int bytes_read;"replies",replies_json replies]
  | Capture_failed {failure;bytes_read} -> `Assoc ["outcome",`String (failure_name failure);"bytes_read",`Int bytes_read]
let caller_json = function Returned_to_caller -> `String "returned"
  | Call_failed failure -> `String (failure_name failure)
let timed f (at,value) = `Assoc ["at_ns",ns at;"value",f value]
let elapsed start finish = match start,finish with
  | Some start,Some finish -> ns (Int64.sub finish start)
  | None,_ | _,None -> `Null
let fields t ~at_ns = [
  "pid",`Int t.pid;"dispatched_ns",ns t.dispatched_ns;"observed_ns",ns at_ns;
  "worker_started_ns",optional ns t.worker_started_ns;
  "capture_finished",optional (timed worker_json) t.capture_finished;
  "caller_observed",optional (timed caller_json) t.caller_observed;
  "decoder_installed_ns",optional ns t.decoder_installed_ns;
  "capabilities_applied",optional (timed replies_json) t.capabilities_applied;
  "first_input_decoded",optional (timed (fun kind -> `String (kind_name kind))) t.first_input_decoded;
  "first_input_received",optional (timed (fun kind -> `String (kind_name kind))) t.first_input_received;
  "dispatch_to_worker_ns",elapsed (Some t.dispatched_ns) t.worker_started_ns;
  "capture_elapsed_ns",elapsed t.worker_started_ns (Option.map fst t.capture_finished);
  "dispatch_to_caller_ns",elapsed (Some t.dispatched_ns) (Option.map fst t.caller_observed);
  "capture_to_caller_ns",(match t.caller_observed with
    | Some (at,Returned_to_caller) -> elapsed (Option.map fst t.capture_finished) (Some at)
    | Some (_,Call_failed _) | None -> `Null);
  "dispatch_to_decoder_installed_ns",elapsed (Some t.dispatched_ns) t.decoder_installed_ns;
  "dispatch_to_first_input_decoded_ns",elapsed (Some t.dispatched_ns) (Option.map fst t.first_input_decoded);
  "dispatch_to_first_input_received_ns",elapsed (Some t.dispatched_ns) (Option.map fst t.first_input_received);
  "decoded_to_received_ns",elapsed (Option.map fst t.first_input_decoded) (Option.map fst t.first_input_received)]
let event_json t ~at_ns event =
  let phase = match event with
    | Dispatched -> "dispatched" | Worker_started -> "worker_started" | Capture_finished _ -> "capture_finished"
    | Caller_observed _ -> "caller_observed" | Decoder_installed -> "handed_off"
    | Capabilities_applied _ -> "capabilities_applied"
    | First_input_decoded _ -> "first_input_decoded" | First_input_received _ -> "first_input_received" in
  `Assoc (("phase",`String phase)::fields t ~at_ns)
let snapshot_json t ~at_ns = `Assoc (("phase",`String "snapshot")::fields t ~at_ns)
