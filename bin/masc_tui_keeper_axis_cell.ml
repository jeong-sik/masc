type tone =
  | Quiet
  | Attention
  | Failure

type t =
  { text : string
  ; tone : tone
  }
