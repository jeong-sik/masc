type response =
  { status : int
  ; headers : (string * string) list
  ; body : string
  }

type get = url:string -> headers:(string * string) list -> (response, string) result
type post = url:string -> headers:(string * string) list -> body:string -> (response, string) result
