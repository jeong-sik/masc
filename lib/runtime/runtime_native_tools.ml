type posture =
  | Native_none
  | Native_read
  | Native_full

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
   honor degrades to the safest strictly-weaker posture the client can
   still run, instead of failing the whole runtime call. [full] under a
   non-yolo approval mode becomes [read] (effects stay behind the gate);
   [none] on a client without a disable switch becomes [read] (the
   client's own default). Both keep the turn alive and are reported via
   a typed event, not silently. *)
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
