(***********************************************************************)
(*                                                                     *)
(*                           Objective Caml                            *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* $Id$ *)

(* Detection of partial matches and unused match cases. *)

open Misc
open Asttypes
open Types
open Typedtree

(*************************************)
(* Utilities for building patterns   *)
(*************************************)

let make_pat desc ty tenv =
  {pat_desc = desc; pat_loc = Location.none;
   pat_type = ty ; pat_env = tenv }

let omega = make_pat Tpat_any Ctype.none Env.empty

let rec omegas i =
  if i <= 0 then [] else omega :: omegas (i-1)

let omega_list l = List.map (fun _ -> omega) l

(***********************)
(* Compatibility check *)
(***********************)

(* p and q compatible means, there exists V that matches both *)

let is_absent tag row =
  let row = Btype.row_repr row in
  let field =
    try Btype.row_field_repr (List.assoc tag row.row_fields)
    with Not_found -> Rabsent
  in field = Rabsent

let sort_fields args =
  Sort.list
    (fun (lbl1,_) (lbl2,_) -> lbl1.lbl_pos <= lbl2.lbl_pos)
    args

let records_args l1 l2 =
  let l1 = sort_fields l1
  and l2 = sort_fields l2 in
  let rec combine r1 r2 l1 l2 = match l1,l2 with
  | [],[] -> r1,r2
  | [],(_,p2)::rem2 -> combine (omega::r1) (p2::r2) [] rem2
  | (_,p1)::rem1,[] -> combine (p1::r1) (omega::r2) rem1 []
  | (lbl1,p1)::rem1, (lbl2,p2)::rem2 ->
      if lbl1.lbl_pos < lbl2.lbl_pos then
        combine (p1::r1) (omega::r2) rem1 l2
      else if lbl1.lbl_pos > lbl2.lbl_pos then
        combine (omega::r1) (p2::r2) l1 rem2
      else (* same label on both sides *)
        combine (p1::r1) (p2::r2) rem1 rem2 in
  combine [] [] l1 l2


let rec compat p q =
  match p.pat_desc,q.pat_desc with
  | Tpat_alias (p,_),_      -> compat p q
  | _,Tpat_alias (q,_)      -> compat p q
  | (Tpat_any|Tpat_var _),_ -> true
  | _,(Tpat_any|Tpat_var _) -> true
  | Tpat_or (p1,p2,_),_     -> compat p1 q || compat p2 q
  | _,Tpat_or (q1,q2,_)     -> compat p q1 || compat p q2    
  | Tpat_constant c1, Tpat_constant c2 -> c1=c2
  | Tpat_tuple ps, Tpat_tuple qs -> compats ps qs
  | Tpat_construct (c1,ps1), Tpat_construct (c2,ps2) ->
      c1.cstr_tag = c2.cstr_tag && compats ps1 ps2
  | Tpat_variant(l1,Some p1, r1), Tpat_variant(l2,Some p2,_) ->
      l1=l2 && not (is_absent l1 r1) && compat p1 p2
  | Tpat_variant (l1,None,r1), Tpat_variant(l2,None,_) ->
      l1 = l2 && not (is_absent l1 r1)
  | Tpat_variant (_, None, _), Tpat_variant (_,Some _, _) -> false
  | Tpat_variant (_, Some _, _), Tpat_variant (_, None, _) -> false
  | Tpat_record l1,Tpat_record l2 ->
      let ps,qs = records_args l1 l2 in
      compats ps qs
  | Tpat_array ps, Tpat_array qs ->
      List.length ps = List.length qs &&
      compats ps qs
  | _,_  ->
      assert false
        
and compats ps qs = match ps,qs with
| [], [] -> true
| p::ps, q::qs -> compat p q && compats ps qs
| _,_    -> assert false

(****************************************)
(* Utilities for retrieving constructor *)
(* and record label names               *)
(****************************************)

exception Empty (* Empty pattern *)

let get_type_path ty tenv =
  let ty = Ctype.repr (Ctype.expand_head tenv ty) in
  match ty.desc with
  | Tconstr (path,_,_) -> path
  | _ -> fatal_error "Parmatch.get_type_path"

let get_type_descr ty tenv =
  match (Ctype.repr ty).desc with
  | Tconstr (path,_,_) -> Env.find_type path tenv
  | _ -> fatal_error "Parmatch.get_type_descr"

let rec get_constr tag ty tenv =
  match get_type_descr ty tenv with
  | {type_kind=Type_variant(constr_list, priv)} ->
      Datarepr.find_constr_by_tag tag constr_list
  | {type_manifest = Some _} ->
      get_constr tag (Ctype.expand_head_once tenv ty) tenv
  | _ -> fatal_error "Parmatch.get_constr"

let find_label lbl lbls =
  try
    let name,_,_ = List.nth lbls lbl.lbl_pos in
    name
  with Failure "nth" -> "*Unkown label*"

let rec get_record_labels ty tenv =
  match get_type_descr ty tenv with
  | {type_kind = Type_record(lbls, rep, priv)} -> lbls
  | {type_manifest = Some _} ->
      get_record_labels (Ctype.expand_head_once tenv ty) tenv
  | _ -> fatal_error "Parmatch.get_record_labels"


(*************************************)
(* Values as patterns pretty printer *)
(*************************************)

open Format
;;

let get_constr_name tag ty tenv  = match tag with
| Cstr_exception path -> Path.name path
| _ ->
  try
    let name,_ = get_constr tag ty tenv in name
  with
  | Datarepr.Constr_not_found -> "*Unknown constructor*"

let is_cons tag v  = match get_constr_name tag v.pat_type v.pat_env with
| "::" -> true
| _ -> false

  
let rec pretty_val ppf v = match v.pat_desc with
  | Tpat_any -> fprintf ppf "_"
  | Tpat_var x -> Ident.print ppf x
  | Tpat_constant (Const_int i) -> fprintf ppf "%d" i
  | Tpat_constant (Const_char c) -> fprintf ppf "%C" c
  | Tpat_constant (Const_string s) -> fprintf ppf "%S" s
  | Tpat_constant (Const_float f) -> fprintf ppf "%s" f
  | Tpat_constant (Const_int32 i) -> fprintf ppf "%ldl" i
  | Tpat_constant (Const_int64 i) -> fprintf ppf "%LdL" i
  | Tpat_constant (Const_nativeint i) -> fprintf ppf "%ndn" i
  | Tpat_tuple vs ->
      fprintf ppf "@[(%a)@]" (pretty_vals ",") vs
  | Tpat_construct ({cstr_tag=tag},[]) ->
      let name = get_constr_name tag v.pat_type v.pat_env in
      fprintf ppf "%s" name
  | Tpat_construct ({cstr_tag=tag},[w]) ->
      let name = get_constr_name tag v.pat_type v.pat_env in
      fprintf ppf "@[<2>%s@ %a@]" name pretty_arg w
  | Tpat_construct ({cstr_tag=tag},vs) ->
      let name = get_constr_name tag v.pat_type v.pat_env in
      begin match (name, vs) with
        ("::", [v1;v2]) ->
          fprintf ppf "@[%a::@,%a@]" pretty_car v1 pretty_cdr v2
      |  _ ->
          fprintf ppf "@[<2>%s@ @[(%a)@]@]" name (pretty_vals ",") vs
      end
  | Tpat_variant (l, None, _) ->
      fprintf ppf "`%s" l
  | Tpat_variant (l, Some w, _) ->
      fprintf ppf "@[<2>`%s@ %a@]" l pretty_arg w
  | Tpat_record lvs ->
      fprintf ppf "@[{%a}@]"
        (pretty_lvals (get_record_labels v.pat_type v.pat_env))
        (List.filter
           (function
             | (_,{pat_desc=Tpat_any}) -> false (* do not show lbl=_ *)
             | _ -> true) lvs)
  | Tpat_array vs ->
      fprintf ppf "@[[| %a |]@]" (pretty_vals " ;") vs
  | Tpat_alias (v,x) ->
      fprintf ppf "@[(%a@ as %a)@]" pretty_val v Ident.print x
  | Tpat_or (v,w,_)    ->
      fprintf ppf "@[(%a|@,%a)@]" pretty_or v pretty_or w

and pretty_car ppf v = match v.pat_desc with
| Tpat_construct ({cstr_tag=tag}, [_ ; _])
    when is_cons tag v ->
      fprintf ppf "(%a)" pretty_val v
| _ -> pretty_val ppf v

and pretty_cdr ppf v = match v.pat_desc with
| Tpat_construct ({cstr_tag=tag}, [v1 ; v2])
    when is_cons tag v ->
      fprintf ppf "%a::@,%a" pretty_car v1 pretty_cdr v2
| _ -> pretty_val ppf v

and pretty_arg ppf v = match v.pat_desc with
| Tpat_construct (_,_::_) -> fprintf ppf "(%a)" pretty_val v
|  _ -> pretty_val ppf v

and pretty_or ppf v = match v.pat_desc with
| Tpat_or (v,w,_) ->
    fprintf ppf "%a|@,%a" pretty_or v pretty_or w
| _ -> pretty_val ppf v

and pretty_vals sep ppf = function
  | [] -> ()
  | [v] -> pretty_val ppf v
  | v::vs ->
      fprintf ppf "%a%s@ %a" pretty_val v sep (pretty_vals sep) vs

and pretty_lvals lbls ppf = function
  | [] -> ()
  | [lbl,v] ->
      let name = find_label lbl lbls in
      fprintf ppf "%s=%a" name pretty_val v
  | (lbl,v)::rest ->
      let name = find_label lbl lbls in
      fprintf ppf "%s=%a;@ %a" name pretty_val v (pretty_lvals lbls) rest

let top_pretty ppf v =
  fprintf ppf "@[%a@]@?" pretty_val v


let prerr_pat v =
  top_pretty str_formatter v ;
  prerr_string (flush_str_formatter ())
  

(****************************)
(* Utilities for matching   *)
(****************************)

(* Check top matching *)
let simple_match p1 p2 = 
  match p1.pat_desc, p2.pat_desc with
  | Tpat_construct(c1, _), Tpat_construct(c2, _) ->
      c1.cstr_tag = c2.cstr_tag
  | Tpat_variant(l1, _, _), Tpat_variant(l2, _, _) ->
      l1 = l2
  | Tpat_constant(Const_float s1), Tpat_constant(Const_float s2) ->
      float_of_string s1 = float_of_string s2
  | Tpat_constant(c1), Tpat_constant(c2) -> c1 = c2
  | Tpat_tuple _, Tpat_tuple _ -> true
  | Tpat_record _ , Tpat_record _ -> true
  | Tpat_array p1s, Tpat_array p2s -> List.length p1s = List.length p2s
  | _, (Tpat_any | Tpat_var(_)) -> true
  | _, _ -> false




(* extract record fields as a whole *)
let record_arg p = match p.pat_desc with
| Tpat_any -> []
| Tpat_record args -> args
| _ -> fatal_error "Parmatch.as_record"


(* Raise Not_found when pos is not present in arg *)


let get_field pos arg =
  let _,p = List.find (fun (lbl,_) -> pos = lbl.lbl_pos) arg in
  p


let extract_fields omegas arg =
  List.map
    (fun (lbl,_) ->
      try
        get_field lbl.lbl_pos arg
      with Not_found -> omega)
    omegas



let sort_record p = match p.pat_desc with
| Tpat_record args ->
    make_pat
      (Tpat_record (sort_fields args))
      p.pat_type p.pat_env
| _ -> p

let all_record_args lbls = match lbls with
| ({lbl_all=lbl_all},_)::_ ->
    let t =
      Array.map
        (fun lbl -> lbl,omega) lbl_all in
    List.iter
      (fun ((lbl,_) as x) ->  t.(lbl.lbl_pos) <- x)
      lbls ;
    Array.to_list t
|  _ -> fatal_error "Parmatch.all_record_args"


(* Build argument list when p2 >= p1, where p1 is a simple pattern *)
let rec simple_match_args p1 p2 = match p2.pat_desc with
| Tpat_alias (p2,_) -> simple_match_args p1 p2
| Tpat_construct(cstr, args) -> args
| Tpat_variant(lab, Some arg, _) -> [arg]
| Tpat_tuple(args)  -> args
| Tpat_record(args) ->  extract_fields (record_arg p1) args
| Tpat_array(args) -> args
| (Tpat_any | Tpat_var(_)) ->
    begin match p1.pat_desc with
      Tpat_construct(_, args) -> omega_list args
    | Tpat_variant(_, Some _, _) -> [omega]
    | Tpat_tuple(args) -> omega_list args
    | Tpat_record(args) ->  omega_list args
    | Tpat_array(args) ->  omega_list args
    | _ -> []
    end
| _ -> []

(*
  Normalize a pattern ->
   all arguments are omega (simple pattern) and no more variables
*)

let rec normalize_pat q = match q.pat_desc with
  | Tpat_any | Tpat_constant _ -> q
  | Tpat_var _ -> make_pat Tpat_any q.pat_type q.pat_env
  | Tpat_alias (p,_) -> normalize_pat p
  | Tpat_tuple (args) ->
      make_pat (Tpat_tuple (omega_list args)) q.pat_type q.pat_env
  | Tpat_construct  (c,args) ->
      make_pat (Tpat_construct (c,omega_list args)) q.pat_type q.pat_env
  | Tpat_variant (l, arg, row) ->
      make_pat (Tpat_variant (l, may_map (fun _ -> omega) arg, row))
        q.pat_type q.pat_env
  | Tpat_array (args) ->
      make_pat (Tpat_array (omega_list args))  q.pat_type q.pat_env
  | Tpat_record (largs) ->
      make_pat (Tpat_record (List.map (fun (lbl,_) -> lbl,omega) largs))
        q.pat_type q.pat_env
  | Tpat_or _ -> fatal_error "Parmatch.normalize_pat"


(*
  Build normalized (cf. supra) discriminating pattern,
  in the non-data type case
*)

let discr_pat q pss =

  let rec acc_pat acc pss = match pss with
    ({pat_desc = Tpat_alias (p,_)}::ps)::pss -> 
        acc_pat acc ((p::ps)::pss)
  | ({pat_desc = Tpat_or (p1,p2,_)}::ps)::pss ->
        acc_pat acc ((p1::ps)::(p2::ps)::pss)
  | ({pat_desc = (Tpat_any | Tpat_var _)}::_)::pss ->
        acc_pat acc pss
  | (({pat_desc = Tpat_tuple _} as p)::_)::_ -> normalize_pat p
  | (({pat_desc = Tpat_record largs} as p)::_)::pss ->
      let new_omegas =
        List.fold_left
          (fun r (lbl,_) ->
            try
              let _ = get_field lbl.lbl_pos r in
              r
            with Not_found ->
              (lbl,omega)::r)
          (record_arg acc)
          largs in
      acc_pat
        (make_pat (Tpat_record new_omegas) p.pat_type p.pat_env)
        pss
  | _ -> acc in

  match normalize_pat q with
  | {pat_desc= (Tpat_any | Tpat_record _)} as q ->
      sort_record (acc_pat q pss)
  | q -> q

(*
   In case a matching value is found, set actual arguments
   of the matching pattern.
*)

let rec read_args xs r = match xs,r with
| [],_ -> [],r
| _::xs, arg::rest ->
   let args,rest = read_args xs rest in
   arg::args,rest
| _,_ ->
    fatal_error "Parmatch.read_args"

let set_args q r = match q with
| {pat_desc = Tpat_tuple omegas} ->
    let args,rest = read_args omegas r in
    make_pat (Tpat_tuple args) q.pat_type q.pat_env::rest
| {pat_desc = Tpat_record omegas} ->
    let args,rest = read_args omegas r in
    make_pat
      (Tpat_record
         (List.map2 (fun (lbl,_) arg -> lbl,arg) omegas args))
      q.pat_type q.pat_env::
    rest
| {pat_desc = Tpat_construct (c,omegas)} ->
    let args,rest = read_args omegas r in
    make_pat
      (Tpat_construct (c,args)) q.pat_type q.pat_env::
    rest
| {pat_desc = Tpat_variant (l, omega, row)} ->
    let arg, rest =
      match omega, r with
        Some _, a::r -> Some a, r
      | None, r -> None, r
      | _ -> assert false
    in
    make_pat
      (Tpat_variant (l, arg, row)) q.pat_type q.pat_env::
    rest
| {pat_desc = Tpat_array omegas} ->
    let args,rest = read_args omegas r in
    make_pat
      (Tpat_array args) q.pat_type q.pat_env::
    rest
| {pat_desc=Tpat_constant _|Tpat_any} ->
    q::r (* case any is used in matching.ml *)
| _ -> fatal_error "Parmatch.set_args"


(* filter pss acording to pattern q *)
let filter_one q pss =
  let rec filter_rec = function
      ({pat_desc = Tpat_alias(p,_)}::ps)::pss -> 
        filter_rec ((p::ps)::pss)
    | ({pat_desc = Tpat_or(p1,p2,_)}::ps)::pss ->
        filter_rec ((p1::ps)::(p2::ps)::pss)
    | (p::ps)::pss ->
        if simple_match q p
        then (simple_match_args q p @ ps) :: filter_rec pss
        else filter_rec pss
    | _ -> [] in
  filter_rec pss

(*
  Filter pss in the ``extra case''. This applies :
  - According to an extra constructor (datatype case, non-complete signature).
  - Acordinng to anything (all-variables case).
*)
let filter_extra pss =
  let rec filter_rec = function
      ({pat_desc = Tpat_alias(p,_)}::ps)::pss -> 
        filter_rec ((p::ps)::pss)
    | ({pat_desc = Tpat_or(p1,p2,_)}::ps)::pss ->
        filter_rec ((p1::ps)::(p2::ps)::pss)
    | ({pat_desc = (Tpat_any | Tpat_var(_))} :: qs) :: pss ->
        qs :: filter_rec pss
    | _::pss  -> filter_rec pss
    | [] -> [] in
  filter_rec pss

(* 
  Pattern p0 is the discriminating pattern,
  returns [(q0,pss0) ; ... ; (qn,pssn)]
  where the qi's are simple patterns and the pssi's are
  matched matrices.

  NOTES
   * (qi,[]) is impossible.
   * In the case when matching is useless (all-variable case),
     returns []
*)

let filter_all pat0 pss =

  let rec insert q qs env =
    match env with
      [] ->
        let q0 = normalize_pat q in
        [q0, [simple_match_args q0 q @ qs]]
    | ((q0,pss) as c)::env ->
        if simple_match q0 q
        then (q0, ((simple_match_args q0 q @ qs) :: pss)) :: env
        else c :: insert q qs env in

  let rec filter_rec env = function
    ({pat_desc = Tpat_alias(p,_)}::ps)::pss ->
      filter_rec env ((p::ps)::pss)
  | ({pat_desc = Tpat_or(p1,p2,_)}::ps)::pss ->
      filter_rec env ((p1::ps)::(p2::ps)::pss)
  | ({pat_desc = (Tpat_any | Tpat_var(_))}::_)::pss ->
      filter_rec env pss
  | (p::ps)::pss ->
      filter_rec (insert p ps env) pss
  | _ -> env

  and filter_omega env = function
    ({pat_desc = Tpat_alias(p,_)}::ps)::pss ->
      filter_omega env ((p::ps)::pss)
  | ({pat_desc = Tpat_or(p1,p2,_)}::ps)::pss ->
      filter_omega env ((p1::ps)::(p2::ps)::pss)
  | ({pat_desc = (Tpat_any | Tpat_var(_))}::ps)::pss ->
      filter_omega
        (List.map (fun (q,qss) -> (q,(simple_match_args q omega @ ps) :: qss)) env)
        pss
  | _::pss -> filter_omega env pss
  | [] -> env in
        
  filter_omega
    (filter_rec
      (match pat0.pat_desc with
        (Tpat_record(_) | Tpat_tuple(_)) -> [pat0,[]]
      | _ -> [])
      pss)
    pss

let close_variant env row =
  let row = Btype.row_repr row in
  let nm =
    List.fold_left
      (fun nm (tag,f) ->
        match Btype.row_field_repr f with
        | Reither(_, _, false, e) ->
            (* m=false means that this tag is not explicitly matched *)
            Btype.set_row_field e Rabsent;
            None
        | Rabsent | Reither (_, _, true, _) | Rpresent _ -> nm)
      row.row_name row.row_fields in
  if not row.row_closed || nm != row.row_name then begin
    (* this unification cannot fail *)
    Ctype.unify env row.row_more
      (Btype.newgenty
         (Tvariant {row with row_fields = []; row_more = Btype.newgenvar();
                    row_closed = true; row_name = nm}))
  end

(*
  Check whether the first column of env makes up a complete signature or
  not.
*)      

let full_match tdefs closing env =  match env with
| ({pat_desc = Tpat_construct ({cstr_tag=Cstr_exception _},_)},_)::_ ->
    false
| ({pat_desc = Tpat_construct(c,_)},_) :: _ ->
    List.length env = c.cstr_consts + c.cstr_nonconsts
| ({pat_desc = Tpat_variant(_,_,row)},_) :: _ ->
    let fields =
      List.map
        (function ({pat_desc = Tpat_variant (tag, _, _)}, _) -> tag
          | _ -> assert false)
        env
    in
    let row = Btype.row_repr row in
    if closing && not row.row_fixed then begin
      (* force=true, we are called from check_partial, and must close *)
      let ok =
        List.for_all
          (fun (tag,f) ->
            match Btype.row_field_repr f with
              Rabsent | Reither(_, _, false, _) -> true
            | Reither (_, _, true, _)
                (* m=true, do not discard matched tags, rather warn *)
            | Rpresent _ -> List.mem tag fields)
          row.row_fields in
      begin match tdefs with None -> ()
      | Some env -> close_variant env row
      end;
      ok
    end else
      row.row_closed &&
      List.for_all
        (fun (tag,f) ->
          Btype.row_field_repr f = Rabsent || List.mem tag fields)
        row.row_fields
| ({pat_desc = Tpat_constant(Const_char _)},_) :: _ ->
    List.length env = 256
| ({pat_desc = Tpat_constant(_)},_) :: _ -> false
| ({pat_desc = Tpat_tuple(_)},_) :: _ -> true
| ({pat_desc = Tpat_record(_)},_) :: _ -> true
| ({pat_desc = Tpat_array(_)},_) :: _ -> false
| _ -> fatal_error "Parmatch.full_match"

let extendable_match env = match env with
| ({pat_desc = Tpat_construct ({cstr_tag=Cstr_exception _},_)},_)::_ -> false
| ({pat_desc = Tpat_construct(c,_)} as p,_) :: _ ->
    let path = get_type_path p.pat_type p.pat_env in
    not
      (Path.same path Predef.path_bool ||
      Path.same path Predef.path_list ||
      Path.same path Predef.path_option)
| _ -> false


(* complement constructor tags *)
let complete_tags nconsts nconstrs tags =
  let seen_const = Array.create nconsts false
  and seen_constr = Array.create nconstrs false in
  List.iter
    (function
      | Cstr_constant i -> seen_const.(i) <- true
      | Cstr_block i -> seen_constr.(i) <- true
      | _  -> assert false)
    tags ;
  let r = ref [] in
  for i = 0 to nconsts-1 do
    if not seen_const.(i) then
      r := Cstr_constant i :: !r
  done ;
  for i = 0 to nconstrs-1 do
    if not seen_constr.(i) then
      r := Cstr_block i :: !r
  done ;  
  !r

(* build a pattern from a constructor list *)
let pat_of_constr ex_pat cstr =
 {ex_pat with pat_desc = Tpat_construct (cstr,omegas cstr.cstr_arity)}
    
let rec pat_of_constrs ex_pat = function
| [] -> raise Empty
| [cstr] -> pat_of_constr ex_pat cstr
| cstr::rem ->    
    {ex_pat with
    pat_desc=
      Tpat_or
        (pat_of_constr ex_pat cstr,
         pat_of_constrs ex_pat rem, None)}

(* Sends back a pattern that complements constructor tags all_tag *)
let complete_constrs p all_tags = match p.pat_desc with
| Tpat_construct (c,_) ->
    begin try
      let not_tags = complete_tags  c.cstr_consts c.cstr_nonconsts all_tags in
      List.map
        (fun tag ->
          let _,targs = get_constr tag p.pat_type p.pat_env in
          {c with
      cstr_tag = tag ;
      cstr_args = targs ;
      cstr_arity = List.length targs})
        not_tags
with
| Datarepr.Constr_not_found ->
    fatal_error "Parmatch.complete_constr: constr_not_found"
    end
| _ -> fatal_error "Parmatch.complete_constr"


(* Auxiliary for build_other *)

let build_other_constant proj make first next p env =
  let all = List.map (fun (p, _) -> proj p.pat_desc) env in
  let rec try_const i =
    if List.mem i all
    then try_const (next i)
    else make_pat (make i) p.pat_type p.pat_env
  in try_const first

(*
  Builds a pattern that is incompatible with all patterns in
  in the first column of env
*)

let build_other env =  match env with
| ({pat_desc = Tpat_construct ({cstr_tag=Cstr_exception _} as c,_)},_) as p
  ::_ ->
    make_pat
      (Tpat_construct
         ({c with
           cstr_tag=(Cstr_exception
            (Path.Pident (Ident.create "*exception*")))},
          []))
      Ctype.none Env.empty
| ({pat_desc = Tpat_construct (_,_)} as p,_) :: _ ->
      let get_tag = function
        | {pat_desc = Tpat_construct (c,_)} -> c.cstr_tag
        | _ -> fatal_error "Parmatch.get_tag" in
      let all_tags =  List.map (fun (p,_) -> get_tag p) env in
      pat_of_constrs p (complete_constrs p all_tags)
| ({pat_desc = Tpat_variant(_,_,row)} as p,_) :: _ ->
    let tags =
      List.map
        (function ({pat_desc = Tpat_variant (tag, _, _)}, _) -> tag
                | _ -> assert false)
        env
    in
    let row = Btype.row_repr row in
    let make_other_pat tag const =
      let arg = if const then None else Some omega in
      make_pat (Tpat_variant(tag, arg, row)) p.pat_type p.pat_env in
    begin match
      List.fold_left
        (fun others (tag,f) ->
          if List.mem tag tags then others else
          match Btype.row_field_repr f with
            Rabsent (* | Reither _ *) -> others
          (* This one is called after erasing pattern info *)
          | Reither (c, _, _, _) -> make_other_pat tag c :: others
          | Rpresent arg -> make_other_pat tag (arg = None) :: others)
        [] row.row_fields
    with
      [] ->
        make_other_pat "AnyExtraTag" true
    | pat::other_pats ->
        List.fold_left
          (fun p_res pat ->
            make_pat (Tpat_or (pat, p_res, None)) p.pat_type p.pat_env)
          pat other_pats
    end
| ({pat_desc = Tpat_constant(Const_char _)} as p,_) :: _ ->
    let all_chars =
      List.map
        (fun (p,_) -> match p.pat_desc with
        | Tpat_constant (Const_char c) -> c
        | _ -> assert false)
        env in
    
    let rec find_other i imax =
      if i > imax then raise Not_found
      else
        let ci = Char.chr i in
        if List.mem ci all_chars then
          find_other (i+1) imax
        else
          make_pat (Tpat_constant (Const_char ci)) p.pat_type p.pat_env in
    let rec try_chars = function
      | [] -> omega
      | (c1,c2) :: rest ->
          try
            find_other (Char.code c1) (Char.code c2)
          with
          | Not_found -> try_chars rest in

    try_chars
      [ 'a', 'z' ; 'A', 'Z' ; '0', '9' ;
        ' ', '~' ; Char.chr 0 , Char.chr 255]

| ({pat_desc=(Tpat_constant (Const_int _))} as p,_) :: _ ->
    build_other_constant
      (function Tpat_constant(Const_int i) -> i | _ -> assert false)
      (function i -> Tpat_constant(Const_int i))
      0 succ p env
| ({pat_desc=(Tpat_constant (Const_int32 _))} as p,_) :: _ ->
    build_other_constant
      (function Tpat_constant(Const_int32 i) -> i | _ -> assert false)
      (function i -> Tpat_constant(Const_int32 i))
      0l Int32.succ p env
| ({pat_desc=(Tpat_constant (Const_int64 _))} as p,_) :: _ ->
    build_other_constant
      (function Tpat_constant(Const_int64 i) -> i | _ -> assert false)
      (function i -> Tpat_constant(Const_int64 i))
      0L Int64.succ p env
| ({pat_desc=(Tpat_constant (Const_nativeint _))} as p,_) :: _ ->
    build_other_constant
      (function Tpat_constant(Const_nativeint i) -> i | _ -> assert false)
      (function i -> Tpat_constant(Const_nativeint i))
      0n Nativeint.succ p env
| ({pat_desc=(Tpat_constant (Const_string _))} as p,_) :: _ ->
    build_other_constant
      (function Tpat_constant(Const_string s) -> String.length s
              | _ -> assert false)
      (function i -> Tpat_constant(Const_string(String.make i '*')))
      0 succ p env
| ({pat_desc=(Tpat_constant (Const_float _))} as p,_) :: _ ->
    build_other_constant
      (function Tpat_constant(Const_float f) -> float_of_string f
              | _ -> assert false)
      (function f -> Tpat_constant(Const_float (string_of_float f)))
      0.0 (fun f -> f +. 1.0) p env

| ({pat_desc = Tpat_array args} as p,_)::_ ->
    let all_lengths =
      List.map
        (fun (p,_) -> match p.pat_desc with
        | Tpat_array args -> List.length args
        | _ -> assert false)
        env in
    let rec try_arrays l =
      if List.mem l all_lengths then try_arrays (l+1)
      else
        make_pat
          (Tpat_array (omegas l))
          p.pat_type p.pat_env in
    try_arrays 0
| [] -> omega
| _ -> omega  

(*
  Core function :
  Is the last row of pattern matrix pss + qs satisfiable ?
  That is :
    Does there exists at least one value vector, es such that :
     1- for all ps in pss ps # es (ps and es are not compatible)
     2- qs <= es                  (es matches qs)
  NOTE:
   satisfiable assumes that any pattern has at least one
   matching value (see first case)
   quid of << absent >> variants ??

*)

let rec has_instance p = match p.pat_desc with
  | Tpat_variant (l,_,r) when is_absent l r -> false
  | Tpat_any | Tpat_var _ | Tpat_constant _ | Tpat_variant (_,None,_) -> true
  | Tpat_alias (p,_) | Tpat_variant (_,Some p,_) -> has_instance p
  | Tpat_or (p1,p2,_) -> has_instance p1 || has_instance p2
  | Tpat_construct (_,ps) | Tpat_tuple ps | Tpat_array ps -> has_instances ps
  | Tpat_record lps -> has_instances (List.map snd lps)
      
and has_instances = function
  | [] -> true
  | q::rem -> has_instance q && has_instances rem
  
let rec satisfiable pss qs = match pss with
| [] -> has_instances qs 
| _  ->
    match qs with
    | [] -> false
    | {pat_desc = Tpat_or(q1,q2,_)}::qs -> 
        satisfiable pss (q1::qs) || satisfiable pss (q2::qs)
    | {pat_desc = Tpat_alias(q,_)}::qs ->
          satisfiable pss (q::qs)
    | {pat_desc = (Tpat_any | Tpat_var(_))}::qs ->
        let q0 = discr_pat omega pss in
        begin match filter_all q0 pss with
          (* first column of pss is made of variables only *)
        | [] -> satisfiable (filter_extra pss) qs
        | constrs  ->
            (not (full_match None false constrs) &&
             satisfiable (filter_extra pss) qs) ||
             List.exists
               (fun (p,pss) -> satisfiable pss (simple_match_args p omega @ qs))
               constrs
        end
    | {pat_desc=Tpat_variant (l,_,r)}::_ when is_absent l r -> false
    | q::qs ->
        let q0 = discr_pat q pss in
        satisfiable (filter_one q0 pss) (simple_match_args q0 q @ qs)

(*
  Like satisfiable, looking for a matching value with an extra constructor.
  That is, look for the situation where adding one constructor
  would NOT yield a non-exhaustive matching.
  *)

let relevant_location loc r = match r with
  | None -> None
  | Some rloc ->
      if rloc = Location.none then
        Some loc
      else
        r
        
let rec satisfiable_extra some pss qs = match qs with
| [] -> if pss = [] then some else None
| {pat_desc = Tpat_or(q1,q2,_)}::qs ->
    let r1 = satisfiable_extra some pss (q1::qs) in
    begin match r1 with
    | Some _ -> r1
    | None -> satisfiable_extra some pss (q2::qs)
    end
| {pat_desc = Tpat_alias(q,_)}::qs ->
    satisfiable_extra some pss (q::qs)
| {pat_desc = (Tpat_any | Tpat_var(_))} as q::qs ->
    let q0 = discr_pat omega pss in
    let r =
      match filter_all q0 pss with
          (* first column of pss is made of variables only *)
      | [] -> satisfiable_extra some (filter_extra pss) qs
      | constrs ->
          if extendable_match constrs then
            let rloc =
              satisfiable_extra (Some q.pat_loc) (filter_extra pss) qs in
            match rloc with
            | Some loc -> rloc
            | None -> try_many_extra some qs constrs
          else
            try_many_extra some qs constrs in
    relevant_location q.pat_loc r
| q::qs ->
    let q0 = discr_pat q pss in
    relevant_location
      q.pat_loc
      (satisfiable_extra
         some (filter_one q0 pss) (simple_match_args q0 q @ qs))

and try_many_extra some qs = function
  | [] -> None
  | (p,pss)::rem ->
      let rloc = satisfiable_extra some pss (simple_match_args p omega @ qs) in
      match rloc with
      | Some _ -> rloc
      | None -> try_many_extra some qs rem


(*
  Now another satisfiable function that additionally
  supplies an example of a matching value.

  This function should be called for exhaustiveness check only.
  It impacts variant typing
*)

type 'a result = 
  | Rnone           (* No matching value *)
  | Rsome of 'a     (* This matching value *)

let rec try_many variants f = function
  | [] -> Rnone
  | x::rest ->
      begin match f x with
      | Rnone -> try_many variants f rest
      | r ->
          if variants then ignore (try_many variants f rest);
          r
      end

let rec exhaust variants tdefs pss n = match pss with
| []    ->  Rsome (omegas n)
| []::_ ->  Rnone
| pss   ->
    let q0 = discr_pat omega pss in
    begin match filter_all q0 pss with
          (* first column of pss is made of variables only *)
    | [] ->
        begin match exhaust variants tdefs (filter_extra pss) (n-1) with
        | Rsome r -> Rsome (q0::r)
        | r -> r
      end
    | constrs ->          
        let try_non_omega (p,pss) =
          match
            exhaust variants tdefs pss
              (List.length (simple_match_args p omega) + n - 1)
          with
          | Rsome r -> Rsome (set_args p r)
          | r       -> r in
        if full_match None false constrs
        then try_many variants try_non_omega constrs
        else
          (*
             D = filter_extra pss is the default matrix
             as it is included in pss, one can avoid
             recursive calls on specialized matrices,
             Essentially :
             * D exhaustive => pss exhaustive
             * D non-exhaustive => we have a non-filtered value
          *)
          let r =  exhaust variants tdefs (filter_extra pss) (n-1) in
           (* but we try all constructors anyway, for variant typing ! *)
           (* Note: it may impact dramatically on cost *)
          if variants then
            ignore (try_many variants try_non_omega constrs) ;
          match r with
          | Rnone -> Rnone
          | Rsome r ->
              try
                Rsome (build_other constrs::r)
              with
      (* cannot occur, since constructors don't make a full signature *)
              | Empty -> fatal_error "Parmatch.exhaust"
    end

let rec pressure_variants tdefs = function
  | []    -> false
  | []::_ -> true
  | pss   ->
      let q0 = discr_pat omega pss in
      begin match filter_all q0 pss with
        [] -> pressure_variants tdefs (filter_extra pss)
      | constrs ->   
          let try_non_omega (p,pss) = pressure_variants tdefs pss in
          let sub = List.map try_non_omega constrs in
          let ok = List.for_all (fun x -> x) sub in
          if full_match None false constrs then ok else
          begin
            if tdefs <> None && full_match None true constrs then
              ok && pressure_variants None (filter_extra pss)
            else
              pressure_variants tdefs (filter_extra pss)
          end ||
          full_match tdefs true constrs && ok
      end

(*
let rec pressure_variants tdefs pss =
  if pss = [] || List.hd pss = [] then () else
  let fstcol, pss' =
    List.split (List.map (function p::ps -> [p], ps | [] -> assert false) pss)
  in
  if filter_extra fstcol = [] then begin
    let q0 = discr_pat omega fstcol in
    match filter_all q0 pss with
      [] -> ()
    | constrs ->
        ignore (full_match tdefs true constrs);
        List.iter (fun (q,qss) -> pressure_variants tdefs qss) constrs
  end;
  pressure_variants tdefs pss'
*)    

(* Yet another satisfiable fonction *)

(*
   This time every_satisfiable pss qs checks the
   utility of every expansion of qs.
   Expansion means expansion of or-patterns inside qs
*)

type answer =
  | Used                                (* Useful pattern *)
  | Unused                              (* Useless pattern *)
  | Upartial of Typedtree.pattern list  (* Neither, with list of useless pattern *)


let pretty_pat p =
  top_pretty Format.str_formatter p ;
  prerr_string (Format.flush_str_formatter ())

type matrix = pattern list list

let pretty_line ps =
  List.iter
    (fun p ->
      top_pretty Format.str_formatter p ;
      prerr_string " <" ;
      prerr_string (Format.flush_str_formatter ()) ;
      prerr_string ">")
    ps

let pretty_matrix pss =
  prerr_endline "begin matrix" ;
  List.iter
    (fun ps ->
      pretty_line ps ;
      prerr_endline "")
    pss ;
  prerr_endline "end matrix"
  
(* this row type enable column processing inside the matrix 
    - left  ->  elements not to be processed,
    - right ->  elements to be processed
*)
type 'a row = {no_ors : 'a list ; ors : 'a list ; active : 'a list}


let pretty_row {ors=ors ; no_ors=no_ors; active=active} =
  pretty_line ors ; prerr_string " *" ;
  pretty_line no_ors ; prerr_string " *" ;
  pretty_line active

let pretty_rows rs =
  prerr_endline "begin matrix" ;
  List.iter
    (fun r ->
      pretty_row r ;
      prerr_endline "")
    rs ;
  prerr_endline "end matrix"

(* Initial build *)
let make_row ps = {ors=[] ; no_ors=[]; active=ps}

let make_rows pss = List.map make_row pss


(* Useful to detect and expand  or pats inside as pats *)
let rec unalias p = match p.pat_desc with
| Tpat_alias (p,_) -> unalias p
| _ -> p


let is_var p = match (unalias p).pat_desc with
| Tpat_any|Tpat_var _ -> true
| _                   -> false

let is_var_column rs =
  List.for_all
    (fun r -> match r.active with
    | p::_ -> is_var p
    | []   -> assert false)
    rs

(* Standard or-args for left-to-right matching *)
let rec or_args p = match p.pat_desc with
| Tpat_or (p1,p2,_) -> p1,p2
| Tpat_alias (p,_)  -> or_args p
| _                 -> assert false

(* Just remove current column *)
let remove r = match r.active with
| _::rem -> {r with active=rem}
| []     -> assert false

let remove_column rs = List.map remove rs
    
(* Current column has been processed *)
let push_no_or r = match r.active with
| p::rem -> { r with no_ors = p::r.no_ors ; active=rem}
| [] -> assert false

let push_or r = match r.active with
| p::rem -> { r with ors = p::r.ors ; active=rem}
| [] -> assert false

let push_or_column rs = List.map push_or rs
and push_no_or_column rs = List.map push_no_or rs

(* Those are adaptations of the previous homonymous functions that
   work on the current column, instead of the first column
*)

let discr_pat q rs = 
  discr_pat q (List.map (fun r -> r.active) rs)

let filter_one q rs =
  let rec filter_rec rs = match rs with
  | [] -> []
  | r::rem ->
      match r.active with
      | [] -> assert false
      | {pat_desc = Tpat_alias(p,_)}::ps ->
          filter_rec ({r with active = p::ps}::rem)
      | {pat_desc = Tpat_or(p1,p2,_)}::ps ->
          filter_rec
            ({r with active = p1::ps}::
             {r with active = p2::ps}::
             rem)
      | p::ps ->
          if simple_match q p then
            {r with active=simple_match_args q p @ ps} :: filter_rec rem
          else
            filter_rec rem in
  filter_rec rs


(* Back to normal matrices *)
let make_vector r = r.no_ors

let make_matrix rs = List.map make_vector rs


(* Standard union on answers *)
let union_res r1 r2 = match r1, r2 with
| (Unused,_)
| (_, Unused) -> Unused
| Used,_    -> r2
| _, Used   -> r1
| Upartial u1, Upartial u2 -> Upartial (u1@u2)

(* propose or pats for expansion *)
let extract_elements qs =
  let rec do_rec seen = function
    | [] -> []
    | q::rem ->
        {no_ors= List.rev_append seen rem @ qs.no_ors ;
        ors=[] ;
        active = [q]}::
        do_rec (q::seen) rem in
  do_rec [] qs.ors

(* idem for matrices *)
let transpose rs = match rs with
| [] -> assert false
| r::rem ->
    let i = List.map (fun x -> [x]) r in
    List.fold_left
      (List.map2 (fun r x -> x::r))
      i rem

let extract_columns pss qs = match pss with
| [] -> List.map (fun _ -> []) qs.ors
| _  ->
  let rows = List.map extract_elements pss in
  transpose rows

(* Core function
   The idea is to first look for or patterns (recursive case), then
   check or-patterns argument usefulness (terminal case)
*)

let rec every_satisfiables pss qs = match qs.active with
| []     ->
    (* qs is now partitionned,  check usefulness *)
    begin match qs.ors with
    | [] -> (* no or-patterns *)
        if satisfiable (make_matrix pss) (make_vector qs) then
          Used
        else
          Unused
    | _  -> (* n or-patterns -> 2n expansions *)
        List.fold_right2
          (fun pss qs r -> match r with
          | Unused -> Unused
          | _ ->
              match qs.active with
              | [q] ->
                  let q1,q2 = or_args q in
                  let r_loc = every_both pss qs q1 q2 in
                  union_res r r_loc
              | _   -> assert false)
          (extract_columns pss qs) (extract_elements qs)
          Used
    end
| q::rem ->
    let uq = unalias q in
    begin match uq.pat_desc with
    | Tpat_any | Tpat_var _ ->
        if is_var_column pss then
(* forget about ``all-variable''  columns now *)
          every_satisfiables (remove_column pss) (remove qs)
        else
(* otherwise this is direct food for satisfiable *)
          every_satisfiables (push_no_or_column pss) (push_no_or qs)
    | Tpat_or (q1,q2,_) ->
        if
          q1.pat_loc.Location.loc_ghost &&
          q2.pat_loc.Location.loc_ghost
        then
(* syntactically generated or-pats should not be expanded *)
          every_satisfiables (push_no_or_column pss) (push_no_or qs)
        else 
(* this is a real or-pattern *)
          every_satisfiables (push_or_column pss) (push_or qs)
    | Tpat_variant (l,_,r) when is_absent l r -> (* Ah Jacques... *)
        Unused
    | _ ->
(* standard case, filter matrix *)
        let q0 = discr_pat q pss in
        every_satisfiables
          (filter_one q0 pss)
          {qs with active=simple_match_args q0 q @ rem}
    end

(*
  This function ``every_both'' performs the usefulness check
  of or-pat q1|q2.
  The trick is to call every_satisfied twice with
  current active columns restricted to q1 and q2,
  That way,
  - others orpats in qs.ors will not get expanded.
  - all matching work performed on qs.no_ors is not performed again.
  *)
and every_both pss qs q1 q2 =
  let qs1 = {qs with active=[q1]}
  and qs2 =  {qs with active=[q2]} in
  let r1 = every_satisfiables pss qs1
  and r2 =  every_satisfiables (if compat q1 q2 then qs1::pss else pss) qs2 in
  match r1 with
  | Unused ->
      begin match r2 with
      | Unused -> Unused
      | Used   -> Upartial [q1]
      | Upartial u2 -> Upartial (q1::u2)
      end
  | Used ->
      begin match r2 with
      | Unused -> Upartial [q2]
      | _      -> r2
      end
  | Upartial u1 ->
      begin match r2 with
      | Unused -> Upartial (u1@[q2])
      | Used   -> r1
      | Upartial u2 -> Upartial (u1 @ u2)
      end

  


(* le_pat p q  means, forall V,  V matches q implies V matches p *)
let rec le_pat p q =
  match (p.pat_desc, q.pat_desc) with
  | (Tpat_var _|Tpat_any),_ -> true
(* Absent variants have no instance *)
  | _, Tpat_variant (l,_,row)  when is_absent l row -> true
  | Tpat_alias(p,_), _ -> le_pat p q
  | _, Tpat_alias(q,_) -> le_pat p q
  | _, Tpat_or(q1,q2,_) -> le_pat p q1 && le_pat p q2
  | Tpat_constant(c1), Tpat_constant(c2) -> c1 = c2
  | Tpat_construct(c1,ps), Tpat_construct(c2,qs) ->
      c1.cstr_tag = c2.cstr_tag && le_pats ps qs
  | Tpat_variant(l1,Some p1,_), Tpat_variant(l2,Some p2,_) ->
      (l1 = l2 && le_pat p1 p2)
  | Tpat_variant(l1,None,r1), Tpat_variant(l2,None,_) ->
      l1 = l2
  | Tpat_tuple(ps), Tpat_tuple(qs) -> le_pats ps qs
  | Tpat_record l1, Tpat_record l2 ->
      let ps,qs = records_args l1 l2 in
      le_pats ps qs
  | Tpat_array(ps), Tpat_array(qs) ->
      List.length ps = List.length qs && le_pats ps qs
(* In all other cases, enumeration is performed *)
  | _,_  ->
      not (satisfiable [[p]] [q])

        
and le_pats ps qs =
  match ps,qs with
    p::ps, q::qs -> le_pat p q && le_pats ps qs
  | _, _         -> true

let get_mins le ps =
  let rec select_rec r = function
      [] -> r
    | p::ps ->
        if List.exists (fun p0 -> le p0 p) ps
        then select_rec r ps
        else select_rec (p::r) ps in
  select_rec [] (select_rec [] ps)

let rec flatten_or_pat pat =
  match pat.pat_desc with
    Tpat_or (p1, p2, _) -> flatten_or_pat p1 @ flatten_or_pat p2
  | Tpat_alias (p, _) -> flatten_or_pat p
  | _ -> [pat]

(* Remove redundant cases from or-patterns *)
let rec simplify_or_pat pat =
  match pat.pat_desc with
    Tpat_or (p1, p2, e) ->
      let pats = flatten_or_pat pat in
      let pats = List.map simplify_or_pat pats in
      let pats' = get_mins le_pat pats in
      List.fold_left
        (fun orpat p -> {pat with pat_desc = Tpat_or (orpat, p, e)})
        (List.hd pats') (List.tl pats')
  | pd ->
      let pd' = map_pattern_desc simplify_or_pat pat.pat_desc in
      if pd == pd' then pat
      else {pat with pat_desc = pd'}


(*
  lub p q is a pattern that matches all values matched by p and q
  may raise Empty, when p and q and not compatible
*)

let rec lub p q = match p.pat_desc,q.pat_desc with
| Tpat_alias (p,_),_      -> lub p q
| _,Tpat_alias (q,_)      -> lub p q
| (Tpat_any|Tpat_var _),_ -> q
| _,(Tpat_any|Tpat_var _) -> p
| Tpat_or (p1,p2,_),_     -> orlub p1 p2 q
| _,Tpat_or (q1,q2,_)     -> orlub q1 q2 p (* Thanks god, lub is commutative *)
| Tpat_constant c1, Tpat_constant c2 when c1=c2 -> p
| Tpat_tuple ps, Tpat_tuple qs ->
    let rs = lubs ps qs in
    make_pat (Tpat_tuple rs) p.pat_type p.pat_env
| Tpat_construct (c1,ps1), Tpat_construct (c2,ps2)
      when  c1.cstr_tag = c2.cstr_tag  ->
        let rs = lubs ps1 ps2 in
        make_pat (Tpat_construct (c1,rs)) p.pat_type p.pat_env
| Tpat_variant(l1,Some p1,row), Tpat_variant(l2,Some p2,_)
          when  l1=l2 && not (is_absent l1 row) ->
            let r=lub p1 p2 in
            make_pat (Tpat_variant (l1,Some r,row)) p.pat_type p.pat_env
| Tpat_variant (l1,None,row), Tpat_variant(l2,None,_)
              when l1 = l2 && not (is_absent l1 row) -> p
| Tpat_record l1,Tpat_record l2 ->
    let rs = record_lubs l1 l2 in
    make_pat (Tpat_record rs) p.pat_type p.pat_env
| Tpat_array ps, Tpat_array qs
      when List.length ps = List.length qs ->
        let rs = lubs ps qs in
        make_pat (Tpat_array rs) p.pat_type p.pat_env
| _,_  ->
    raise Empty

and orlub p1 p2 q =
  try    
    let r1 = lub p1 q in
    try
      {q with pat_desc=(Tpat_or (r1,lub p2 q,None))}
  with
  | Empty -> r1
with
| Empty -> lub p2 q

and record_lubs l1 l2 =
  let l1 = sort_fields l1 and l2 = sort_fields l2 in
  let rec lub_rec l1 l2 = match l1,l2 with
  | [],_ -> l2
  | _,[] -> l1
  | (lbl1,p1)::rem1, (lbl2,p2)::rem2 ->
      if lbl1.lbl_pos < lbl2.lbl_pos then
        (lbl1,p1)::lub_rec rem1 l2
      else if lbl2.lbl_pos < lbl1.lbl_pos  then
        (lbl2,p2)::lub_rec l1 rem2
      else
        (lbl1,lub p1 p2)::lub_rec rem1 rem2 in
  lub_rec l1 l2
    
and lubs ps qs = match ps,qs with
| p::ps, q::qs -> lub p q :: lubs ps qs
| _,_ -> []
      
      
(******************************)
(* Entry points               *)
(*    - Partial match         *)
(*    - Unused match case     *)
(******************************)


(*
  A small cvs commit/commit discussion....
  JG: 
  Exhaustiveness of matching MUST be checked, even
  when the warning is excluded explicitely by user.
  LM: 
  Why such a strange thing ? 
  JG:
  Because the typing of variants depends on it.
  LM:    
  Ok, note that by contrast, unused clause check still can be avoided at
  user request.
  *)
(*
  Build up a working pattern matrix.
   - Forget about guarded patterns
*)

let has_guard act =   match act.exp_desc with
| Texp_when(_, _) -> true
| _ -> false


let rec initial_matrix = function
    [] -> []
  | (pat, act) :: rem ->
      if has_guard act
      then
        initial_matrix rem
      else
        [pat] :: initial_matrix rem

(*
   All the following ``*_all'' functions
   check whether a given value [v] is matched by some row in pss.
   They are used to whether the exhaustiveness exemple is
   matched by a guarded clause
*)
  

exception NoGuard

let rec initial_all no_guard = function
  | [] ->
      if no_guard then
        raise NoGuard
      else
        []
  | (pat, act) :: rem ->
      ([pat], pat.pat_loc) :: initial_all (no_guard && not (has_guard act)) rem


let rec do_filter_var = function
  | (_::ps,loc)::rem -> (ps,loc)::do_filter_var rem
  | _ -> []

let do_filter_one q pss =
  let rec filter_rec = function
    | ({pat_desc = Tpat_alias(p,_)}::ps,loc)::pss -> 
        filter_rec ((p::ps,loc)::pss)
    | ({pat_desc = Tpat_or(p1,p2,_)}::ps,loc)::pss ->
        filter_rec ((p1::ps,loc)::(p2::ps,loc)::pss)
    | (p::ps,loc)::pss ->
        if simple_match q p
        then (simple_match_args q p @ ps, loc) :: filter_rec pss
        else filter_rec pss
    | _ -> [] in
  filter_rec pss

let rec do_match pss qs = match qs with
| [] ->
    begin match pss  with
    | ([],loc)::_ -> Some loc
    | _ -> None
    end
| q::qs -> match q with
  | {pat_desc = Tpat_or (q1,q2,_)} ->
      begin match do_match pss (q1::qs) with
      | None -> do_match pss (q2::qs)
      | r -> r
      end
  | {pat_desc = Tpat_any} ->
      do_match (do_filter_var pss) qs
  | _ ->
      let q0 = normalize_pat q in
      do_match (do_filter_one q0 pss) (simple_match_args q0 q @ qs)

        
let check_partial_all v casel =
  try
    let pss = initial_all true casel in
    do_match pss [v]
  with
  | NoGuard -> None

(* look for variants *)
let rec look_variant p = match p.pat_desc with
  | Tpat_variant (_,_,_) -> true
  | Tpat_any | Tpat_var _ | Tpat_constant _ -> false
  | Tpat_alias (p,_)  -> look_variant p
  | Tpat_or (p1,p2,_) -> look_variant p1 || look_variant p2
  | Tpat_construct (_,ps) | Tpat_tuple ps | Tpat_array ps -> look_variants ps
  | Tpat_record lps -> look_variants (List.map snd lps)
      
and look_variants = function
  | [] -> false
  | q::rem -> look_variant q || look_variants rem


let check_partial tdefs loc casel =
  ignore (pressure_variants (Some tdefs) (List.map (fun (p,e) -> [p]) casel));
  let variant_inside = false
      (* List.exists (fun (p,_) -> look_variant p) casel *) in
  let pss = initial_matrix casel in
  (* let pss = List.map (List.map simplify_or_pat) pss in *)
  let pss = get_mins le_pats pss in
  match pss with
  | [] ->
        (*
          This can occur
          - For empty matches generated by ocamlp4 (no warning)
          - when all patterns have guards (then, casel <> [])
          (specific warning)
          Then match MUST be considered non-exhaustive,
          otherwise compilation of PM is broken.
          *)
      begin match casel with
      | [] -> ()
      | _  ->
          Location.prerr_warning loc
            (Warnings.Other
               "Bad style, all clauses in this pattern-matching are guarded.")
      end ;
      Partial
  | ps::_  ->      
      begin match exhaust variant_inside tdefs pss (List.length ps) with
      | Rnone -> Total
      | Rsome [v] ->
          let errmsg =
            try
              let buf = Buffer.create 16 in
              let fmt = formatter_of_buffer buf in
              top_pretty fmt v;
              begin match check_partial_all v casel with
              | None -> ()
              | Some _ ->
                  (* This is ``Some l'', where l is the location of
                     a possibly matching clause.
                     I forget about l, because printing two locations
                     is a pain in the top-level *)                  
                  Buffer.add_string buf
                    "\n(However, some guarded clause may match this value.)"
              end ;
              Buffer.contents buf
            with _ ->
              "" in          
          Location.prerr_warning loc (Warnings.Partial_match errmsg) ;
          Partial
      | _ ->
          fatal_error "Parmatch.check_partial"
      end


let location_of_clause = function
    pat :: _ -> pat.pat_loc
  | _ -> fatal_error "Parmatch.location_of_clause"

let seen_pat q pss = [q]::pss

(* Extra check
    Will this clause match if someone adds a constructor somewhere
*)

let warn_fragile () = Warnings.is_active (Warnings.Fragile_pat "")

let check_used_extra pss qs =
  if warn_fragile () then begin
    match satisfiable_extra None pss qs with
    | Some location ->
        Location.prerr_warning
          location
          (Warnings.Fragile_pat "")
    | None -> ()
  end

  
  
let check_unused tdefs casel =
  if Warnings.is_active Warnings.Unused_match then
    let rec do_rec pref = function
      | [] -> ()
      | (q,act as clause)::rem ->
          let qs = [q] in
            begin try
              let pss = get_mins le_pats (List.filter (compats qs) pref) in
              let r = every_satisfiables (make_rows pss) (make_row qs) in
              match r with
              | Unused ->
                  Location.prerr_warning
                    (location_of_clause qs) Warnings.Unused_match
              | Upartial ps ->
                  List.iter
                    (fun p ->
                      Location.prerr_warning
                        p.pat_loc Warnings.Unused_pat)
                    ps
              | Used ->
                  check_used_extra pss qs
            with e -> (* useless ? *)
              Location.prerr_warning (location_of_clause qs)
                (Warnings.Other "Fatal Error in Parmatch.check_unused") ;
              raise e
            end ;
                   
          if has_guard act then
            do_rec pref rem
          else
            do_rec (seen_pat q pref) rem in



    do_rec [] casel
