#include <caml/mlvalues.h>
#include <stdlib.h>

CAMLprim value masc_test_unsetenv(value name)
{
  unsetenv(String_val(name));
  return Val_unit;
}
