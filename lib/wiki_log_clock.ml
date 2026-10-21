let local_minute ~year ~month ~day ~hour ~minute =
  match
    Unix.mktime
      { Unix.tm_sec = 0
      ; tm_min = minute
      ; tm_hour = hour
      ; tm_mday = day
      ; tm_mon = month - 1
      ; tm_year = year - 1900
      ; tm_wday = 0
      ; tm_yday = 0
      ; tm_isdst = false
      }
  with
  | seconds, normalized when normalized.Unix.tm_mday = day -> Some seconds
  | _ -> None
  | exception Unix.Unix_error _ -> None
;;
