#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <stdlib.h>

CAMLprim value masc_test_unsetenv(value name)
{
  CAMLparam1(name);
  unsetenv(String_val(name));
  CAMLreturn(Val_unit);
}
