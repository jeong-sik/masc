open Masc_tui_core
open Masc_tui_protocol

type t
type attempt
type phase

val empty : t
val find : epoch:Epoch.t -> workspace:Wire_work.expected_workspace -> Wire_discord_reply.target -> t -> attempt option
val next_request : target:Wire_discord_reply.target -> content:string -> attempt option -> Wire_discord_reply.request option
val submit : epoch:Epoch.t -> workspace:Wire_work.expected_workspace -> Wire_discord_reply.request -> t -> t
val observe : epoch:Epoch.t -> workspace:Wire_work.expected_workspace -> Wire_discord_reply.request -> (Wire_discord_reply.state, [ `Absent | `Unobserved of Say.t | `Rejected of Say.t ]) result -> t -> t option
val target_of_form : Nav.inline_action_kind -> (Wire_discord_reply.target * Wire_work.expected_workspace) option
val can_compose : attempt option -> bool
val phase : attempt -> phase
val status : phase -> [ `Delivered | `Failed | `Pending ] * Say.t
val rejected_content : attempt option -> string option
