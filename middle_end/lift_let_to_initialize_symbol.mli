(**************************************************************************)
(*                                                                        *)
(*                                OCaml                                   *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2016 OCamlPro SAS                                    *)
(*   Copyright 2014--2016 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file ../LICENSE.       *)
(*                                                                        *)
(**************************************************************************)

(** Lift toplevel [Let]-expressions to Flambda [program] constructions such
    that the results of evaluation of such expressions may be accessed
    directly, through symbols, rather than through closures.  The
    [Let]-expressions typically come from the compilation of modules (using
    the bytecode strategy) in [Translmod].

    This means of compilation supercedes the old "transl_store_" methodology
    for native code.

    An [Initialize_symbol] construction generated by this pass may be
    subsequently rewritten to [Let_symbol] if it is discovered that the
    initializer is in fact constant.  (See [Initialize_symbol_to_let_symbol].)

    The [program] constructions generated by this pass will be joined by
    others that arise from the lifting of constants (see [Lift_constants]).
*)
val lift
   : backend:(module Backend_intf.S)
  -> Flambda.program
  -> Flambda.program
