/*
 * bgui_varargs.c
 *
 * Variadic wrapper functions for BGUI library calls.
 * These must be real (non-inlined) functions so that the &tag1 trick
 * works correctly — GCC's m68k ABI places all args contiguously on
 * the stack for real function calls, but not when inlining.
 */

#include <proto/bgui.h>
#include <intuition/classes.h>
#include <utility/tagitem.h>

Object *BGUI_NewObject(ULONG num, Tag tag1, ...)
{
  return BGUI_NewObjectA(num, (struct TagItem *) &tag1);
}

ULONG BGUI_DoGadgetMethod(Object *obj, struct Window *win,
  struct Requester *req, ULONG methodID, ...)
{
  return BGUI_DoGadgetMethodA(obj, win, req, (Msg) &methodID);
}
