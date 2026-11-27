type action =
  | Create_request
  | Update_request
  | List_requests
  | Get_request
  | Cancel_request
  | Add_note
  | List_notes
  | Create_lane_act_request
      (** A Lane action has its own pair of tools: the Keeper wake pair takes
          no field of it. *)
  | Update_lane_act_request
[@@deriving enumerate]

type definition =
  { action : action
  ; id : string
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

val definitions : definition list
val schemas : Masc_domain.tool_schema list
val find_definition : string -> definition option
