(** Model-facing text for the tool loop, installed by the host.

    agent_core is config-free by layering: it cannot read
    [config/prompts/agent_core.md] itself. The host (MASC prompt init)
    renders the managed templates and installs the text here once at
    startup; {!current} returns the last installed value.

    The defaults are the last-resort copy of the same sentences so that
    agent_core's own tests and standalone consumers behave identically
    without any host wiring. The byte-for-byte contract is pinned by the
    host-side parity check, not by this module. *)

type t =
  { unknown_tool_not_found : requested:string -> string
  ; unknown_tool_not_found_no_tools : requested:string -> string
  ; unknown_tool_closest_registered : name:string -> string
  ; unknown_tool_extra_characters : prefix:string -> string
  ; unknown_tool_not_bare_with_closest : name:string -> string
  ; unknown_tool_not_bare : string
  ; handoff_description : name:string -> description:string -> string
  ; handoff_prompt_param_description : string
  ; agent_tool_prompt_param_description : string
  }

let defaults =
  { unknown_tool_not_found =
      (fun ~requested -> Printf.sprintf "Tool not found: %s" requested)
  ; unknown_tool_not_found_no_tools =
      (fun ~requested ->
        Printf.sprintf "Tool not found: %s. No tools are registered" requested)
  ; unknown_tool_closest_registered =
      (fun ~name -> Printf.sprintf "Closest registered name: %s." name)
  ; unknown_tool_extra_characters =
      (fun ~prefix ->
        Printf.sprintf
          "The name carries extra characters after %S; send the tool name alone and put \
           arguments in the input object."
          prefix)
  ; unknown_tool_not_bare_with_closest =
      (fun ~name ->
        Printf.sprintf
          "The name is not a bare identifier (closest registered name: %s); send the \
           registered tool name alone and put arguments in the input object."
          name)
  ; unknown_tool_not_bare =
      "The name is not a bare identifier; send the registered tool name alone and put \
       arguments in the input object."
  ; handoff_description =
      (fun ~name ~description -> Printf.sprintf "Hand off to %s: %s" name description)
  ; handoff_prompt_param_description = "Instructions for the sub-agent"
  ; agent_tool_prompt_param_description = "The prompt to send to the agent"
  }
;;

let installed : t Atomic.t = Atomic.make defaults

(** Install the host-rendered text. Called once from the host's prompt init;
    a later call replaces the earlier value. *)
let configure t = Atomic.set installed t

(** The currently installed text, [defaults] until the host configures. *)
let current () = Atomic.get installed
