type posture =
  | Native_none
  | Native_read
  | Native_full

type observation =
  { call_id : string option
  ; tool_name : string option
  }

let stream_content_type = "native_tool_use"

let to_string = function
  | Native_none -> "none"
  | Native_read -> "read"
  | Native_full -> "full"
;;

let of_string = function
  | "none" -> Some Native_none
  | "read" -> Some Native_read
  | "full" -> Some Native_full
  | _ -> None
;;

let valid_posture_strings = [ "none"; "read"; "full" ]
let claude_code_default = Native_none
let codex_default = Native_read
let antigravity_default = Native_read

(* WebFetch/WebSearch observe no local state but do reach the network, so
   they stay out of the read set until the RFC widens it deliberately. *)
let claude_code_read_tool_names = [ "Read"; "Glob"; "Grep" ]

(* RFC-0390 admission review: a declared posture that admission cannot
   honor resolves to the posture the client actually runs, instead of
   failing the whole runtime call. [full] under a non-yolo approval mode
   becomes [read] (effects stay behind the gate) — a true downgrade,
   reported per turn because the approval mode is turn state. [none] on
   a client without a disable switch becomes [read] (the client's own
   floor: its built-ins keep running no matter what we pass) — this is
   NOT a downgrade but a static contradiction (profile says [none],
   runtime.toml assigned a runtime that cannot honor it), so the event
   is reported once per process, not per turn (#30408 review). *)
let degrade_on_admission ~posture ~none_supported () =
  match (posture, none_supported) with
  | Native_full, _ -> Native_read
  | Native_none, false -> Native_read
  | posture, _ -> posture
;;

let claude_code_tools_arg = function
  | Native_none -> ""
  | Native_read -> String.concat "," claude_code_read_tool_names
  | Native_full -> "default"
;;
