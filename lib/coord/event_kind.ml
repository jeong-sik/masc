module Task = struct
  type t =
    | Created
    | Claimed
    | Started
    | Released
    | Done
    | Cancelled
    | Submit_for_verification
    | Approved
    | Rejected
    | Linked

  let to_string = function
    | Created -> "task.created"
    | Claimed -> "task.claimed"
    | Started -> "task.started"
    | Released -> "task.released"
    | Done -> "task.done"
    | Cancelled -> "task.cancelled"
    | Submit_for_verification -> "task.submit_for_verification"
    | Approved -> "task.approved"
    | Rejected -> "task.rejected"
    | Linked -> "task.linked"
  ;;

  let of_string = function
    | "task.created" -> Some Created
    | "task.claimed" -> Some Claimed
    | "task.started" -> Some Started
    | "task.released" -> Some Released
    | "task.done" -> Some Done
    | "task.cancelled" -> Some Cancelled
    | "task.submit_for_verification" -> Some Submit_for_verification
    | "task.approved" -> Some Approved
    | "task.rejected" -> Some Rejected
    | "task.linked" -> Some Linked
    | _ -> None
  ;;

  let all =
    [ Created
    ; Claimed
    ; Started
    ; Released
    ; Done
    ; Cancelled
    ; Submit_for_verification
    ; Approved
    ; Rejected
    ; Linked
    ]
  ;;
end

module Message = struct
  type t =
    | Broadcast
    | Mentioned

  let to_string = function
    | Broadcast -> "message.broadcast"
    | Mentioned -> "message.mentioned"
  ;;

  let of_string = function
    | "message.broadcast" -> Some Broadcast
    | "message.mentioned" -> Some Mentioned
    | _ -> None
  ;;

  let all = [ Broadcast; Mentioned ]
end

module Board = struct
  type t =
    | Posted
    | Commented
    | Voted
    | Deleted

  let to_string = function
    | Posted -> "board.posted"
    | Commented -> "board.commented"
    | Voted -> "board.voted"
    | Deleted -> "board.deleted"
  ;;

  let of_string = function
    | "board.posted" -> Some Posted
    | "board.commented" -> Some Commented
    | "board.voted" -> Some Voted
    | "board.deleted" -> Some Deleted
    | _ -> None
  ;;

  let all = [ Posted; Commented; Voted; Deleted ]
end
