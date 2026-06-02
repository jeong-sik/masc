(** Shared shell safety helpers.

    [Shell_command_gate] is the authoritative command gate.  This
    module keeps only the shared pieces that still have live callers:
    destructive command taxonomy and stable command hashes for observer
    logs. *)

type destructive_class =
  | Recursive_delete
  | Sql_destructive
  | Forced_git_mutation
  | Privilege_escalation
  | Filesystem_format
  | Device_write
  | Process_signal
  | System_control

let destructive_class_to_string = function
  | Recursive_delete -> "recursive_delete"
  | Sql_destructive -> "sql_destructive"
  | Forced_git_mutation -> "forced_git_mutation"
  | Privilege_escalation -> "privilege_escalation"
  | Filesystem_format -> "filesystem_format"
  | Device_write -> "device_write"
  | Process_signal -> "process_signal"
  | System_control -> "system_control"
;;

type destructive_pattern =
  { class_ : destructive_class
  ; pattern : string
  ; description : string
  }

let destructive_patterns : destructive_pattern list =
  [ { class_ = Recursive_delete
    ; pattern = "rm -rf"
    ; description = "recursive forced deletion"
    }
  ; { class_ = Recursive_delete
    ; pattern = "rm -r"
    ; description = "recursive deletion"
    }
  ; { class_ = Recursive_delete
    ; pattern = "rmdir"
    ; description = "directory removal"
    }
  ; { class_ = Sql_destructive
    ; pattern = "drop table"
    ; description = "SQL table drop"
    }
  ; { class_ = Sql_destructive
    ; pattern = "drop database"
    ; description = "SQL database drop"
    }
  ; { class_ = Sql_destructive
    ; pattern = "truncate table"
    ; description = "SQL table truncate"
    }
  ; { class_ = Sql_destructive
    ; pattern = "delete from"
    ; description = "SQL bulk delete"
    }
  ; { class_ = Forced_git_mutation
    ; pattern = "git push --force"
    ; description = "force push"
    }
  ; { class_ = Forced_git_mutation
    ; pattern = "git push -f"
    ; description = "force push"
    }
  ; { class_ = Forced_git_mutation
    ; pattern = "git reset --hard"
    ; description = "hard reset"
    }
  ; { class_ = Forced_git_mutation
    ; pattern = "git clean -f"
    ; description = "forced clean"
    }
  ; { class_ = Privilege_escalation
    ; pattern = "chmod 777"
    ; description = "world-writable permissions"
    }
  ; { class_ = Filesystem_format
    ; pattern = "mkfs"
    ; description = "filesystem format"
    }
  ; { class_ = Device_write
    ; pattern = "> /dev/"
    ; description = "device write"
    }
  ; { class_ = Device_write
    ; pattern = "dd if="
    ; description = "raw disk operation"
    }
  ; { class_ = Process_signal
    ; pattern = "kill -9"
    ; description = "forced process kill"
    }
  ; { class_ = Process_signal
    ; pattern = "pkill"
    ; description = "pattern-based process kill"
    }
  ; { class_ = System_control
    ; pattern = "shutdown"
    ; description = "system shutdown"
    }
  ; { class_ = System_control
    ; pattern = "reboot"
    ; description = "system reboot"
    }
  ]
;;

let contains_sub_ci s sub =
  if sub = "" then true else String_util.contains_substring_ci s sub
;;

let classify_destructive cmd : (destructive_class * string) option =
  List.find_map
    (fun { class_; pattern; description = _ } ->
       if contains_sub_ci cmd pattern then Some (class_, pattern) else None)
    destructive_patterns
;;

let cmd_hash_for_log (cmd : string) : string =
  let hex = Digest.to_hex (Digest.string cmd) in
  if String.length hex >= 12 then String.sub hex 0 12 else hex
;;
