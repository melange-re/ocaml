(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*               Jeremy Yallop, University of Cambridge                   *)
(*                                                                        *)
(*   Copyright 2017 Jeremy Yallop                                         *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

open Asttypes
open Typedtree
open Types

exception Illegal_expr

module Rec_context =
struct
  type mode =
      Dereferenced
    (** [Dereferenced] indicates that the value (not just the address) of a
        variable is accessed, or that an expression needs to be evaluated
        and accessed. *)

    | Guarded
    (** [Guarded] indicates that the address of a variable is used in a
        guarded context, i.e. under a constructor, or stored in a closure.
        An expression is [Guarded] the address of its value is used in a
        guarded context.*)

    | Delayed
    (** [Delayed] indicates that an expression has its evaluation delayed,
        i.e it is placed in a function or it is lazily evaluated.  A variable
        is delayed it is is placed in such an expression. *)

    | Unused
    (** [Unused] indicates that a variable is not used in an expression. *)

    | Unguarded
    (** [Unguarded] indicates that the address of a variable is used in an
        unguarded context, i.e. not under a constructor. *)

  (* Returns the most conservative mode of the two arguments. *)
  let prec m m' =
    match m, m' with
    | Dereferenced, _
    | _, Dereferenced -> Dereferenced
    | Unguarded, _
    | _, Unguarded -> Unguarded
    | Guarded, _
    | _, Guarded -> Guarded
    | Delayed, _
    | _, Delayed -> Delayed
    | _ -> Unused

  (* If x is used with the mode m in e[x], and e[x] is used with mode
     m' in e'[e[x]], then x is used with mode m'[m] in e'[e[x]]. *)
  let compos m' m = match m', m with
    | Unused, _
    | _, Unused -> Unused
    | Dereferenced, _ -> Dereferenced
    | Delayed, _ -> Delayed
    | m', Unguarded -> m'
    | Unguarded, m
    | Guarded, m -> m

  module Env :
  sig
    type t

    val single : Ident.t -> mode -> t
    (** Create an environment with a single identifier used with a given mode.
    *)

    val empty : t
    (** An environment with no used identifiers. *)

    val find : t -> Ident.t -> mode
    (** Find the mode of an indentifier in an environment.  The default mode is
        Unused. *)

    val unguarded : t -> Ident.t list -> Ident.t list
    (** unguarded e l: the list of all identifiers in e that are unguarded of
        dereferenced in the environment e. *)

    val dependent : t -> Ident.t list -> Ident.t list
    (** unguarded e l: the list of all identifiers in e that are used in e. *)

    val join : t -> t -> t

    val remove : Ident.t -> t -> t
    (* Remove an indentifier from an environment. *)

    val remove_list : Ident.t list -> t -> t
    (* Remove all the identifiers of a list from an environment. *)
  end =
  struct
    module M = Map.Make(Ident)

    (** A "t" maps each rec-bound variable to an access status *)
    type t = mode M.t

    let find (tbl: t) (id: Ident.t) =
      try M.find id tbl with Not_found -> Unused

    let join (x: t) (y: t) =
      M.fold
        (fun (id: Ident.t) (v: mode) (tbl: t) ->
           let v' = find tbl id in
           M.add id (prec v v') tbl)
        x y

    let single id mode = M.add id mode M.empty

    let empty = M.empty

    (*
    let list_matching p t =
      let r = ref [] in
      M.iter (fun id v -> if p v then r := id :: !r) t;
      !r
    *)

    let unguarded x =
      List.filter (fun id -> find x id = Dereferenced || find x id = Unguarded)

    let dependent x =
      List.filter (fun id -> find x id <> Unused)

    let remove = M.remove

    let remove_list l env =
      List.fold_left (fun e x -> M.remove x e) env l
  end
end

open Rec_context

let is_ref : Types.value_description -> bool = function
  | { Types.val_kind =
        Types.Val_prim { Primitive.prim_name = "%makemutable";
                          prim_arity = 1 } } ->
        true
  | _ -> false

(* See the note on abstracted arguments in the documentation for
    Typedtree.Texp_apply *)
let is_abstracted_arg : arg_label * expression option -> bool = function
  | (_, None) -> true
  | (_, Some _) -> false

type sd = Static | Dynamic

let classify_expression : Typedtree.expression -> sd =
  (* We need to keep track of the size of expressions
      bound by local declarations, to be able to predict
      the size of variables. Compare:

        let rec r =
          let y = fun () -> r ()
          in y

      and

        let rec r =
          let y = if Random.bool () then ignore else fun () -> r ()
          in y

    In both cases the final adress of `r` must be known before `y` is compiled,
    and this is only possible if `r` has a statically-known size.

    The first definition can be allowed (`y` has a statically-known
    size) but the second one is unsound (`y` has no statically-known size).
  *)
  let rec classify_expression env e = match e.exp_desc with
    (* binding and variable cases *)
    | Texp_let (rec_flag, vb, e) ->
        let env = classify_value_bindings rec_flag env vb in
        classify_expression env e
    | Texp_ident (path, _, _) ->
        classify_path env path

    (* non-binding cases *)
    | Texp_letmodule (_, _, _, e)
    | Texp_sequence (_, e)
    | Texp_letexception (_, e) ->
        classify_expression env e

    | Texp_construct (_, {cstr_tag = Cstr_unboxed}, [e]) ->
        classify_expression env e
    | Texp_construct _ ->
        Static

    | Texp_record { representation = Record_unboxed _;
                    fields = [| _, Overridden (_,e) |] } ->
        classify_expression env e
    | Texp_record _ ->
        Static

    | Texp_apply ({exp_desc = Texp_ident (_, _, vd)}, _)
      when is_ref vd ->
        Static
    | Texp_apply (_,args)
      when List.exists is_abstracted_arg args ->
        Static
    | Texp_apply _ ->
        Dynamic

    | Texp_for _
    | Texp_constant _
    | Texp_new _
    | Texp_instvar _
    | Texp_tuple _
    | Texp_array _
    | Texp_variant _
    | Texp_setfield _
    | Texp_while _
    | Texp_setinstvar _
    | Texp_pack _
    | Texp_object _
    | Texp_function _
    | Texp_lazy _
    | Texp_unreachable
    | Texp_extension_constructor _ ->
        Static

    | Texp_match _
    | Texp_ifthenelse _
    | Texp_send _
    | Texp_field _
    | Texp_assert _
    | Texp_try _
    | Texp_override _ ->
        Dynamic
  and classify_value_bindings rec_flag env bindings =
    (* We use a non-recursive classification, classifying each
        binding with respect to the old environment
        (before all definitions), even if the bindings are recursive.

        Note: computing a fixpoint in some way would be more
        precise, as the following could be allowed:

          let rec topdef =
            let rec x = y and y = fun () -> topdef ()
            in x
    *)
    ignore rec_flag;
    let old_env = env in
    let add_value_binding env vb =
      match vb.vb_pat.pat_desc with
      | Tpat_var (id, _loc) ->
          let size = classify_expression old_env vb.vb_expr in
          Ident.add id size env
      | _ ->
          (* Note: we don't try to compute any size for complex patterns *)
          env
    in
    List.fold_left add_value_binding env bindings
  and classify_path env = function
    | Path.Pident x ->
        begin
          try Ident.find_same x env
          with Not_found ->
            (* an identifier will be missing from the map if either:
                - it is a non-local identifier
                  (bound outside the letrec-binding we are analyzing)
                - or it is bound by a complex (let p = e in ...) local binding
                - or it is bound within a module (let module M = ... in ...)
                  that we are not traversing for size computation

                For non-local identifiers it might be reasonable (although
                not completely clear) to consider them Static (they have
                already been evaluated), but for the others we must
                under-approximate with Dynamic.

                This could be fixed by a more complete implementation.
            *)
            Dynamic
        end
    | Path.Pdot _ | Path.Papply _ ->
        (* local modules could have such paths to local definitions;
            classify_expression could be extend to compute module
            shapes more precisely *)
        Dynamic
  in classify_expression Ident.empty

let rec expression : mode -> Typedtree.expression -> Env.t =
  fun mode exp -> match exp.exp_desc with
    | Texp_ident (pth, _, _) ->
      path mode pth
    | Texp_let (_rec_flag, bindings, body) ->
      (*
        G1, {x: _, x in V} |- p1: G = e1 in m
        ...
        Gn, {x: _, x in V} |- pn: G = en in m
        G, {pi: msi} |- e: m
        ---
        G1 + ... + Gn + G'|- let (rec)? p1 = e1 and ... and pn = en in e: m

      where V = union(vars(pi)) and G' = G \ V.

      *)
      let env0 = expression mode body in
      let vars = List.fold_left (fun v b -> (pat_bound_idents b.vb_pat) @ v)
                                []
                                bindings
      in
      let env1 = Env.remove_list vars env0 in
      let env2 = list (value_binding env0 vars) mode bindings in
      Env.join env1 env2
    | Texp_letmodule (x, _, mexp, e) ->
      (*a
        G1 |- M: m[mx + Guarded]
        G2, X: mx |- e: m
        -----------------------------------
        G1 + G2 |- let module X = M in e: m
      *)
      let env_0 = expression mode e in
      let mode_x = Env.find env_0 x in
      let m' = compos mode (prec mode_x Guarded) in
      let env_1 = modexp m' mexp in
      Env.join (Env.remove x env_0) env_1
    | Texp_match (e, cases, _) ->
      let env_pat, m_e =
        List.fold_left
          (fun (env, m) c ->
            let (env', m') = case mode c in
            (Env.join env env'), (prec m m'))
          (Env.empty, Unused)
          cases
      in
      let env_e = expression m_e e in
      Env.join env_pat env_e
    | Texp_for (_, _, e1, e2, _, e3) ->
      (*
        G1 |- e1: m[Dereferenced]
        G2 |- e2: m[Dereferenced]
        G3 |- e3: m[Guarded]
        ---
        G1 + G2 + G3 |- for _ = e1 (down)?to e2 do e3 done: m

        e3 is evaluated in the mode m[Guarded] because this expression is
        evaluated but not used.
        Jeremy Yallop notes that e3 is not available for inclusion in another
        value, but I don't understand what it means.
      *)
      let env_1 = expression (compos mode Dereferenced) e1 in
      let env_2 = expression (compos mode Dereferenced) e2 in
      let env_3 = expression (compos mode Guarded) e3 in
      Env.join (Env.join env_1 env_2) env_3
    | Texp_constant _ ->
      Env.empty
    | Texp_new (pth, _, _) ->
      (*
        G |- c: m[Dereferenced]
        -----------------------
        G |- new c: m
      *)
      path (compos mode Dereferenced) pth
    | Texp_instvar (self_path, pth, _inst_var) ->
        Env.join
          (path (compos mode Dereferenced) self_path)
          (path mode pth)
    | Texp_apply ({exp_desc = Texp_ident (_, _, vd)}, [_, Some arg])
      when is_ref vd ->
      (*
        G |- e: m[Guarded]
        ------------------
        G |- ref e: m
      *)
      expression (compos mode Guarded) arg
    | Texp_apply (e, args)  ->
        let arg m (_, eo) = option expression m eo in
        let m' = if List.exists is_abstracted_arg args
          then (* see the comment on Texp_apply in typedtree.mli;
                  the non-abstracted arguments are bound to local
                  variables, which corresponds to a Guarded mode. *)
            compos mode Guarded
          else compos mode Dereferenced
        in
        Env.join (list arg m' args) (expression m' e)
    | Texp_tuple exprs ->
      list expression (compos mode Guarded) exprs
    | Texp_array exprs ->
      let array_mode = match Typeopt.array_kind exp with
        | Lambda.Pfloatarray ->
            (* (flat) float arrays unbox their elements *)
            Dereferenced
        | Lambda.Pgenarray ->
            (* This is counted as a use, because constructing a generic array
               involves inspecting to decide whether to unbox (PR#6939). *)
            Dereferenced
        | Lambda.Paddrarray | Lambda.Pintarray ->
            (* non-generic, non-float arrays act as constructors *)
            Guarded
      in
      list expression (compos mode array_mode) exprs
    | Texp_construct (_, desc, exprs) ->
      let access_constructor =
        match desc.cstr_tag with
        | Cstr_extension (pth, _) ->
          path (compos mode Dereferenced) pth
        | _ -> Env.empty
      in
      let m' = match desc.cstr_tag with
        | Cstr_unboxed ->
          compos mode Unguarded
        | Cstr_constant _ | Cstr_block _ | Cstr_extension _ ->
          compos mode Guarded
      in
      Env.join access_constructor (list expression m' exprs)
    | Texp_variant (_, eo) ->
      (*
        G |- e: m[Guarded]
        ------------------   -----------
        G |- `A e: m         [] |- `A: m
      *)
      option expression (compos mode Guarded) eo
    | Texp_record { fields = es; extended_expression = eo;
                    representation = rep } ->
        let m' = match rep with
          | Record_float -> compos mode Dereferenced
          | Record_unboxed _ -> mode
          | Record_regular | Record_inlined _
          | Record_extension -> compos mode Guarded
        in
        let field m = function
            _, Kept _ -> Env.empty
          | _, Overridden (_, e) -> expression m e
        in
        Env.join (array field m' es)
                 (option expression mode eo)
    | Texp_ifthenelse (cond, ifso, ifnot) ->
      (*
        Gc |- c: m[Dereferenced]
        G1 |- e1: m
        G2 |- e2: m
        ---
        Gc + G1 + G2 |- if c then e1 else e2: m

      Note: `if c then e1 else e2` is treated in the same way as
      `match c with true -> e1 | false -> e2`
      *)
      let env_cond = expression (compos mode Dereferenced) cond in
      let env_ifso = expression mode ifso in
      let env_ifnot = option expression mode ifnot in
      Env.join env_cond (Env.join env_ifso env_ifnot)
    | Texp_setfield (e1, _, _, e2) ->
      (*
        G1 |- e1: m[Dereferenced]
        G2 |- e2: m[Dereferenced] (*TODO: why is this a dereference?*)
        ---
        G1 + G2 |- e1.x <- e2: m
      *)
      let env_1 = expression (compos mode Dereferenced) e1 in
      let env_2 = expression (compos mode Dereferenced) e2 in
      Env.join env_1 env_2
    | Texp_sequence (e1, e2) ->
      (*
        G1 |- e1: m[Guarded]
        G2 |- e2: m
        --------------------
        G1 + G2 |- e1; e2: m

        Note: `e1; e2` is treated in the same way as `let _ = e1 in e2`
      *)
      let env1 = expression (compos mode Guarded) e1 in
      let env2 = expression mode e2 in
      Env.join env1 env2
    | Texp_while (e1, e2) ->
      (*
        G1 |- e1: m[Dereferenced]
        G2 |- e2: m[Guarded]
        ---------------------------------
        G1 + G2 |- while e1 do e2 done: m
      *)
      let env_1 = expression (compos mode Dereferenced) e1 in
      let env_2 = expression (compos mode Guarded) e2 in
      Env.join env_1 env_2
    | Texp_send (e1, _, eo) ->
      (*
        G |- e: m[Dereferenced]
        ---------------------- (plus weird 'eo' option)
        G |- e#x: m
      *)
      Env.join (expression (compos mode Dereferenced) e1)
               (option expression (compos mode Dereferenced) eo)
    | Texp_field (e, _, _) ->
      (*
        G |- e: m[Dereferenced]
        -----------------------
        G |- e.x: m
      *)
      expression (compos mode Dereferenced) e
    | Texp_setinstvar (pth,_,_,e) ->
      (*
        G |- e: m[Dereferenced]  (*TODO: why is this a dereference?*)
        -----------------------
        G |- x <- e: m
      *)
      Env.join
        (path (compos mode Dereferenced) pth)
        (expression (compos mode Dereferenced) e)
    | Texp_letexception ({ext_id}, e) ->
      (* G |- e: m
         ----------------------------
         G |- let exception A in e: m
      *)
      Env.remove ext_id (expression mode e)
    | Texp_assert e ->
      (*
        G |- e: m[Dereferenced]
        -----------------------
        G |- assert e: m

        Note: `assert e` is treated just as if `assert` was a function.
      *)
      expression (compos mode Dereferenced) e
    | Texp_pack mexp ->
      (*
        G |- M: m
        ----------------
        G |- module M: m
      *)
      modexp mode mexp
    | Texp_object (clsstrct, _) ->
      class_structure mode clsstrct
    | Texp_try (e, cases) ->
      (*
        G |- e: m
        G1 |- e1: m
        ...
        Gn |- en: m
        ---
        G + G1 + ... + Gn |- try e with p1 -> e1 | ... | pn -> en: m
      *)
      let case m {Typedtree.c_rhs} = expression m c_rhs in
      Env.join (expression mode e) (list case mode cases)
    | Texp_override (pth, fields) ->
      let field m (_, _, arg) = expression m arg in
      let m' = compos mode Dereferenced in
      Env.join (path m' pth) (list field m' fields)
    | Texp_function { cases } ->
      (* Approximation: function `p1 -> e1, ..., pn -> en` is the same as
         `fun x -> match x with p1 -> e1, ..., pn -> en`.

         The typing of this expression is nearly the same as the typing of
         a `match` expression, the differences are:
         - e1, ..., en are evaluated in the m[Delayed] mode instead of m
         - we don't care about the mode returned by the `case` function.
      *)
      let m = compos mode Delayed in
      list (fun m c -> fst (case m c)) m cases
    | Texp_lazy e ->
      (*
        G |- e:
        ---
        ... |- lazy e: m
      *)
      let m' = begin match Typeopt.classify_lazy_argument e with
        | `Constant_or_function
        | `Identifier _
        | `Float_that_cannot_be_shortcut ->
          mode
        | `Other ->
          compos mode Delayed
        end
      in
      expression m' e
    | Texp_unreachable ->
      (*
        ----------
        [] |- .: m
      *)
      Env.empty
    | Texp_extension_constructor (_lid, pth) ->
      path (compos mode Dereferenced) pth

and option : 'a. (mode -> 'a -> Env.t) -> mode -> 'a option -> Env.t =
  fun f m -> Misc.Stdlib.Option.value_default (f m) ~default:Env.empty
and list : 'a. (mode -> 'a -> Env.t) -> mode -> 'a list -> Env.t =
  fun f m ->
    List.fold_left (fun env item -> Env.join (f m item) env) Env.empty
and array : 'a. (mode -> 'a -> Env.t) -> mode -> 'a array -> Env.t =
  fun f m ->
    Array.fold_left (fun env item -> Env.join (f m item) env) Env.empty

and class_structure : mode -> Typedtree.class_structure -> Env.t =
  fun m cs -> list class_field m cs.cstr_fields

and class_field : mode -> Typedtree.class_field -> Env.t =
  fun m cf -> match cf.cf_desc with
    | Tcf_inherit (_, ce, _super, _inh_vars, _inh_meths) ->
      class_expr (compos m Dereferenced) ce
    | Tcf_val (_lab, _mut, _, cfk, _) ->
      class_field_kind m cfk
    | Tcf_method (_, _, cfk) ->
      class_field_kind m cfk
    | Tcf_constraint _ ->
      Env.empty
    | Tcf_initializer e ->
      expression (compos m Dereferenced) e
    | Tcf_attribute _ ->
      Env.empty

and class_field_kind : mode -> Typedtree.class_field_kind -> Env.t =
  fun m cfk -> match cfk with
    | Tcfk_virtual _ ->
      Env.empty
    | Tcfk_concrete (_, e) ->
      expression (compos m Dereferenced) e

and modexp : mode -> Typedtree.module_expr -> Env.t =
  fun mode mexp -> match mexp.mod_desc with
    | Tmod_ident (pth, _) ->
      path mode pth
    | Tmod_structure s ->
      structure mode s
    | Tmod_functor (_, _, _, e) ->
      modexp (compos mode Delayed) e
    | Tmod_apply (f, p, _) ->
      let m' = compos mode Dereferenced in
      Env.join (modexp m' f) (modexp m' p)
    | Tmod_constraint (mexp, _, _, coe) ->
      let rec coercion k = function
        | Tcoerce_none ->
          k Unguarded
        | Tcoerce_structure _
        | Tcoerce_functor _ ->
          (* These coercions perform a shallow copy of the input module,
             by creating a new module with fields obtained by accessing
             the same fields in the input module. *)
           k Dereferenced
        | Tcoerce_primitive _ ->
          (* This corresponds to 'external' declarations,
             and the coercion ignores its argument *)
          k Unused
        | Tcoerce_alias (pth, coe) ->
          (* Alias coercions ignore their arguments, but they evaluate
             their alias module 'pth' under another coercion. *)
          coercion (fun m -> path (compos mode m) pth) coe
      in
      coercion (fun m -> modexp (compos mode m) mexp) coe
    | Tmod_unpack (e, _) ->
      expression mode e

and path : mode -> Path.t -> Env.t =
  (*
    ------------
    x: m |- x: m

    G |- A: m[Dereferenced]
    -----------------------
    G |- A.x: m

    G1 |- A: m[Dereferenced]
    G2 |- B: m[Dereferenced]
    ------------------------ (as for term application)
    G1 + G2 |- A(B): m
  *)
  fun mode pth -> match pth with
    | Path.Pident x ->
        Env.single x mode
    | Path.Pdot (t, _, _) ->
        path (compos mode Dereferenced) t
    | Path.Papply (f, p) ->
        let m = compos mode Dereferenced in
        Env.join (path m f) (path m p)

and structure : mode -> Typedtree.structure -> Env.t =
  (*
    G1, {x: _, x in vars(G1)} |- item1: G2 + ... + Gn in m
    G2, {x: _, x in vars(G2)} |- item2: G3 + ... + Gn in m
    ...
    Gn, {x: _, x in vars(Gn)} |- itemn: [] in m
    ---
    (G1 + ... + Gn) - V |- struct item1 ... itemn end: m
  *)
  fun m s ->
    List.fold_right (structure_item m) s.str_items Env.empty

and structure_item : mode -> Typedtree.structure_item -> Env.t -> Env.t =
  fun m s env -> match s.str_desc with
    | Tstr_eval (e, _) ->
      (*
        G |- e: m[Guarded]
        G' |- struct {items} end: m
        ------------------------------------
        G + G' |- struct e: m {items} end: m

        The expression `e` is treated in the same way as let _ = e
      *)
      Env.join env (expression (compos m Guarded) e)
    | Tstr_value (_, valbinds) ->
      (* Similar to the `Texp_let` rule. TODO: should I factorize some code?
       * *)
      let vars = List.fold_left (fun v b -> (pat_bound_idents b.vb_pat) @ v)
                                []
                                valbinds
      in
      let env1 = Env.remove_list vars env in
      let env2 = list (value_binding env vars) m valbinds in
      Env.join env1 env2
    | Tstr_module {mb_id; mb_expr} ->
      (*
        G |- M: m[m' + Guarded]
        G', M: m' |- struct {items} end: m
        ---
        G + G' |- struct module M = E {items} end: m

        [Alban] Very similar to the `Texp_letmodule` rule.
        (Again, should I factorize?)

        [Gabriel] Yes, we should have a module_binding function.
      *)
      let m_mode = Env.find env mb_id in
      let m_eval = compos m (prec m_mode Guarded) in
      let env' = modexp m_eval mb_expr in
      Env.join (Env.remove mb_id env) env'
    | Tstr_recmodule mbs ->
      let mb_ids = List.map (fun {mb_id; _} -> mb_id) mbs in
      let module_binding m {mb_id; mb_expr; _} =
        let m_mode = Env.find env mb_id in
        modexp (compos m (prec m_mode Guarded)) mb_expr in
      Env.remove_list mb_ids
        (Env.join (list module_binding m mbs) env)
    | Tstr_primitive _ ->
      env
    | Tstr_type _ ->
      (*
        ---------------
        [] |- type t: m
      *)
      env
    | Tstr_typext {tyext_constructors = exts; _} ->
      let ext_ids = List.map (fun {ext_id = id; _} -> id) exts in
      Env.join
        (list extension_constructor m exts)
        (Env.remove_list ext_ids env)
    | Tstr_exception {tyexn_constructor = ext; _} ->
      Env.join
        (extension_constructor m ext)
        (Env.remove ext.ext_id env)
    | Tstr_modtype _
    | Tstr_class_type _
    | Tstr_attribute _ ->
      env
    | Tstr_open _ ->
      (* TODO: open introduces term/module variables in scope,
         we could/should remove them from the environment.

         See also Texp_open (in exp_extra, outside the normal matching path)
         and Tcl_open. *)
      env
    | Tstr_class classes ->
        let class_ids =
          let class_id ({ci_id_class = id; _}, _) = id in
          List.map class_id classes in
        let class_declaration m ({ci_expr; _}, _) =
          Env.remove_list class_ids (class_expr m ci_expr) in
        Env.join
          (list class_declaration m classes)
          (Env.remove_list class_ids env)
    | Tstr_include { incl_mod = mexp; incl_type = mty; _ } ->
      let included_ids =
        let sigitem_id = function
          | Sig_value (id, _)
          | Sig_type (id, _, _)
          | Sig_typext (id, _, _)
          | Sig_module (id, _, _)
          | Sig_modtype (id, _)
          | Sig_class (id, _, _)
          | Sig_class_type (id, _, _)
            -> id
        in
        List.map sigitem_id mty in
      Env.join (modexp m mexp) (Env.remove_list included_ids env)

and class_expr : mode -> Typedtree.class_expr -> Env.t =
  fun m ce -> match ce.cl_desc with
    | Tcl_ident (pth, _, _) ->
        path (compos m Dereferenced) pth
    | Tcl_structure cs ->
        class_structure m cs
    | Tcl_fun (_, _, args, ce, _) ->
        let ids = List.map fst args in
        Env.remove_list ids (class_expr (compos m Delayed) ce)
    | Tcl_apply (ce, args) ->
        let m' = compos m Dereferenced in
        let arg m (_label, eo) = option expression m eo in
        Env.join (class_expr m' ce) (list arg m' args)
    | Tcl_let (_rec_flag, bindings, _, ce) ->
      (* TODO: factorize with Texp_let *)
      let env0 = class_expr m ce in
      let vars = List.fold_left (fun v b -> (pat_bound_idents b.vb_pat) @ v)
                                []
                                bindings
      in
      let env1 = Env.remove_list vars env0 in
      let env2 = list (value_binding env0 vars) m bindings in
      Env.join env1 env2
    | Tcl_constraint (ce, _, _, _, _) ->
        class_expr m ce
    | Tcl_open (_, _, _, _, ce) ->
        class_expr m ce

and extension_constructor : mode -> Typedtree.extension_constructor -> Env.t =
  fun m ec -> match ec.ext_kind with
    | Text_decl _ ->
      Env.empty
    | Text_rebind (pth, _lid) ->
      path m pth

and case : mode -> Typedtree.case -> Env.t * mode =
  fun m { Typedtree.c_lhs; c_guard; c_rhs } ->
    let env_guard = option expression (compos m Dereferenced) c_guard in
    let env_rhs = expression m c_rhs in
    let env = Env.join env_guard env_rhs in
    let vars = pat_bound_idents c_lhs in
    (Env.remove_list vars env), (pattern env m c_lhs)

and pattern : Env.t -> mode -> pattern -> mode = fun env m pat ->
  (*
    G |- e: m[sum{G(x), x in vars(p)} + mode(p)]
    --------------------------------------------
    G |- p: G = e in m

    where mode(p) = | Dereferenced if p is destructive
                    | Guarded      otherwise
  *)
  let vars = pat_bound_idents pat in
  let uses = List.map (Env.find env) vars in
  let m_pat = if is_destructuring_pattern pat
              then Dereferenced
              else Guarded
  in
  (* The maximal use mode of the variables appearing in c_lhs: *)
  let m_vars = List.fold_left prec Unused uses in
  compos m (prec m_pat m_vars)
(*
and value_bindings :
  rec_flag -> Env.env -> Typedtree.value_binding list -> Env.env * Use.t =
  fun rec_flag env bindings ->
    match rec_flag with
    | Recursive ->
        (* Approximation:
              let rec y =
                let rec x1 = e1
                    and x2 = e2
                  in e
            treated as
              let rec y =
                  let rec x = (e1, e2)[x1:=fst x, x2:=snd x] in
                    e[x1:=fst x, x2:=snd x]
            Further, use the fact that x1,x2 cannot occur unguarded in e1, e2
            to avoid recursive trickiness.
        *)
        let ids, ty =
          List.fold_left
            (fun (pats, tys) {vb_pat=p; vb_expr=e} ->
                (pat_bound_idents p @ pats,
                Use.join (expression env e) tys))
            ([], Use.empty)
            bindings
        in
        (List.fold_left (fun  (env : Env.env) (id : Ident.t) ->
              Ident.add id ty env) Env.empty ids,
          ty)
    | Nonrecursive ->
        List.fold_left
          (fun (env2, ty) binding ->
              let env', ty' = value_binding env binding in
              (Env.join env2 env', Use.join ty ty'))
          (Env.empty, Use.empty)
          bindings
*)

(* value_bindig env vars m bind:
   Get the environment in which this binding must be evaluated.

   The pattern and the parameter `env` are used to determine the mode in
   which the expression must be evaluated.

   `vars` is a list of indentifiers that must be removed from the resulting
   environment. *)
and value_binding : Env.t -> Ident.t list -> mode -> Typedtree.value_binding
                          -> Env.t =
  fun env vars m { vb_pat; vb_expr } ->
    let m' = pattern env m vb_pat in
    let env' = expression m' vb_expr in
    Env.remove_list vars env'

and is_destructuring_pattern : Typedtree.pattern -> bool =
  fun pat -> match pat.pat_desc with
    | Tpat_any -> false
    | Tpat_var (_id, _) -> false
    | Tpat_alias (pat, _, _) ->
        is_destructuring_pattern pat
    | Tpat_constant _ -> true
    | Tpat_tuple _ -> true
    | Tpat_construct (_, _, _) -> true
    | Tpat_variant _ -> true
    | Tpat_record (_, _) -> true
    | Tpat_array _ -> true
    | Tpat_or (l,r,_) ->
        is_destructuring_pattern l || is_destructuring_pattern r
    | Tpat_lazy _ -> true
    | Tpat_exception _ -> false

let is_valid_recursive_expression idlist expr =
  let ty = expression Unguarded expr in
  match Env.unguarded ty idlist, Env.dependent ty idlist,
        classify_expression expr with
  | _ :: _, _, _ (* The expression inspects rec-bound variables *)
  | _, _ :: _, Dynamic -> (* The expression depends on rec-bound variables
                              and its size is unknown *)
      false
  | [], _, Static (* The expression has known size *)
  | [], [], Dynamic -> (* The expression has unknown size,
                          but does not depend on rec-bound variables *)
      true

let is_valid_class_expr idlist ce =
  let rec class_expr : mode -> Typedtree.class_expr -> Env.t =
    fun mode ce -> match ce.cl_desc with
      | Tcl_ident (_, _, _) ->
        (*
          ----------
          [] |- a: m
        *)
        Env.empty
      | Tcl_structure _ ->
        (*
          -----------------------
          [] |- struct ... end: m
        *)
        Env.empty
      | Tcl_fun (_, _, _, _, _) -> Env.empty
        (*
          ---------------------------
          [] |- fun x1 ... xn -> C: m
        *)
      | Tcl_apply (_, _) -> Env.empty
      | Tcl_let (_rec_flag, valbinds, _, ce) ->
        (* TODO factorize *)
        let env0 = class_expr mode ce in
        let vars = List.fold_left (fun v b -> (pat_bound_idents b.vb_pat) @ v)
                                  []
                                  valbinds
        in
        let env1 = Env.remove_list vars env0 in
        let env2 = list (value_binding env0 vars) mode valbinds in
        Env.join env1 env2
      | Tcl_constraint (ce, _, _, _, _) ->
          class_expr mode ce
      | Tcl_open (_, _, _, _, ce) ->
          class_expr mode ce
  in
  match Env.unguarded (class_expr Unguarded ce) idlist with
  | [] -> true
  | _ :: _ -> false
