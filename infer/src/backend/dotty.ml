(*
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

module L = Logging
module F = Format
open Utils

(** {1 Dotty} *)

type kind_of_dotty_prop =
  | Generic_proposition
  | Spec_precondition
  | Spec_postcondition of Prop.normal Prop.t (** the precondition associated with the post *)
  | Lambda_pred of int * int * bool

(* the kind of links between different kinds of nodes*)
type kind_of_links =
  | LinkExpToExp
  | LinkExpToStruct
  | LinkStructToExp
  | LinkStructToStruct
  | LinkToArray
  | LinkArrayToExp
  | LinkArrayToStruct
  | LinkToSSL
  | LinkToDLL

(* coordinate identifies a node using two dimension: id is an numerical identifier of the node,*)
(* lambda identifies in which hpred parameter id lays in*)
type coordinate = {
  id: int;
  lambda: int;
}

(* define a link between two nodes. src_fld/trg_fld define the label of the src/trg field. It is*)
(* useful for having nodes from within a struct and/or to inside a struct *)
type link = {
  kind: kind_of_links;
  src: coordinate;
  src_fld: string;
  trg: coordinate;
  trg_fld: string;
}

(* type of the visualized boxes/nodes in the graph*)
type dotty_node =
  | Dotnil of coordinate (* nil box *)
  (* Dotdangling(coo,e,c): dangling box for expression e at coordinate coo and color c *)
  | Dotdangling of coordinate * Sil.exp * string
  (* Dotpointsto(coo,e,c): basic memory cell box for expression e at coordinate coo and color c *)
  | Dotpointsto of coordinate * Sil.exp * string
  (* Dotstruct(coo,e,l,c): struct box for expression e  with field list l at coordinate coo and color c *)
  | Dotstruct of coordinate * Sil.exp * (Ident.fieldname * Sil.strexp) list * string
  (* Dotarray(coo,e1,e2,l,t,c): array box for expression e1  with field list l at coordinate coo and color c*)
  (* e2 is the size and t is the type *)
  | Dotarray of coordinate * Sil.exp * Sil.exp * (Sil.exp * Sil.strexp) list * Sil.typ * string
  (* Dotlseg(coo,e1,e2,k,h,c): list box from e1 to e2 at coordinate coo and color c*)
  | Dotlseg of coordinate * Sil.exp * Sil.exp * Sil.lseg_kind * Sil.hpred list * string
  (* Dotlseg(coo,e1,e2,e3,e4,k,h,c): doubly linked-list box from with parameters (e1,e2,e3,e4) at coordinate coo and color c*)
  | Dotdllseg of coordinate * Sil.exp * Sil.exp * Sil.exp * Sil.exp * Sil.lseg_kind * Sil.hpred list * string

let mk_coordinate i l = { id = i; lambda = l }

let mk_link k s sf t tf = { kind = k; src = s; src_fld = sf; trg = t; trg_fld = tf }

(* list of dangling boxes*)
let dangling_dotboxes = ref []

(* list of nil boxes*)
let nil_dotboxes = ref []

let exps_neq_zero = ref []

(* list of fields in the structs *)
let fields_structs = ref []
let struct_exp_nodes = ref []

(* general unique counter to assign a different number to boxex,           *)
(* clusters,subgraphs etc.                                                 *)
let dotty_state_count = ref 0

let spec_counter = ref 0
let post_counter = ref 0
let lambda_counter = ref 0
let proposition_counter = ref 0
let target_invisible_arrow_pre = ref 0
let current_pre = ref 0
let spec_id = ref 0
let invisible_arrows = ref false

let print_stack_info = ref false

let exp_is_neq_zero e =
  list_exists (fun e' -> Sil.exp_equal e e') !exps_neq_zero

(* replace a dollar sign in a name with a D. We need this because dotty get confused if there is*)
(* a dollar sign i a label*)
let strip_special_chars s =
  let replace st c c' =
    if String.contains st c then begin
      let idx = String.index st c in
      try
        String.set st idx c';
        st
      with Invalid_argument _ -> L.out "@\n@\n Invalid argument!!! @\n @.@.@."; assert false
    end else st in
  let s0 = replace s '(' 'B' in
  let s1 = replace s0 '$' 'D' in
  let s2 = replace s1 '#' 'H' in
  let s3 = replace s2 '&' 'E' in
  let s4 = replace s3 '@' 'A' in
  let s5 = replace s4 ')' 'B' in
  let s6 = replace s5 '+' 'P' in
  let s7 = replace s6 '-' 'M' in
  s7

let rec strexp_to_string pe coo f se =
  match se with
  | Sil.Eexp (e, inst) -> F.fprintf f "%a" (Sil.pp_exp pe) e
  | Sil.Estruct (ls, _) -> F.fprintf f " STRUCT | { %a } " (struct_to_dotty_str pe coo) ls
  | Sil.Earray(e, idx, _) -> F.fprintf f " ARRAY[%a] | { %a } " (Sil.pp_exp pe) e (get_contents pe coo) idx

and struct_to_dotty_str pe coo f ls : unit =
  match ls with
  | [] -> ()
  | (fn, se)::[]-> F.fprintf f "{ <%s%iL%i> %s: %a } " (Ident.fieldname_to_string fn) coo.id coo.lambda (Ident.fieldname_to_string fn) (strexp_to_string pe coo) se
  | (fn, se):: ls'-> F.fprintf f " { <%s%iL%i> %s: %a } | %a" (Ident.fieldname_to_string fn) coo.id coo.lambda (Ident.fieldname_to_string fn) (strexp_to_string pe coo) se (struct_to_dotty_str pe coo) ls'

and get_contents_sexp pe coo f se =
  match se with
  | Sil.Eexp (e', inst') ->
      F.fprintf f "%a" (Sil.pp_exp pe) e'
  | Sil.Estruct (se', _) ->
      F.fprintf f "| { %a }" (struct_to_dotty_str pe coo) se'
  | Sil.Earray(e', [], _) ->
      F.fprintf f "(ARRAY Size: %a) | { }" (Sil.pp_exp pe) e'
  | Sil.Earray(e', ((idx, a):: linner), _) ->
      F.fprintf f "(ARRAY Size: %a) | { %a: %a | %a }" (Sil.pp_exp pe) e' (Sil.pp_exp pe) idx
        (strexp_to_string pe coo) a (get_contents pe coo) linner

and get_contents_single pe coo f (e, se) =
  let e_no_special_char = strip_special_chars (Sil.exp_to_string e) in
  F.fprintf f "{ <%s> %a : %a }"
    e_no_special_char (Sil.pp_exp pe) e (get_contents_sexp pe coo) se

and get_contents pe coo f = function
  | [] -> ()
  | [idx_se] ->
      F.fprintf f "%a" (get_contents_single pe coo) idx_se
  | idx_se:: l ->
      F.fprintf f "%a | %a" (get_contents_single pe coo) idx_se (get_contents pe coo) l

and get_contents_range_single pe coo f range_se =
  let (e1, e2), se = range_se in
  let e1_no_special_char = strip_special_chars (Sil.exp_to_string e1) in
  F.fprintf f "{ <%s> [%a,%a] : %a }"
    e1_no_special_char (Sil.pp_exp pe) e1 (Sil.pp_exp pe) e2 (get_contents_sexp pe coo) se

and get_contents_range pe coo f = function
  | [] -> ()
  | [range_se] ->
      F.fprintf f "%a" (get_contents_range_single pe coo) range_se
  | range_se:: l ->
      F.fprintf f "%a | %a" (get_contents_range_single pe coo) range_se (get_contents_range pe coo) l

(* true if node is the sorce node of the expression e*)
let is_source_node_of_exp e node =
  match node with
  | Dotpointsto (_, e', _) -> Sil.exp_compare e e' = 0
  | _ -> false

(* given a node returns its coordinates and the expression. Return -1 in case the expressio doesn.t*)
(* make sense for that case *)
let get_coordinate_and_exp dotnode =
  match dotnode with
  | Dotnil(coo) -> (coo, Sil.exp_minus_one)
  | Dotarray (coo, _, _, _, _, _) -> (coo, Sil.exp_minus_one)
  | Dotpointsto (coo, b, _)
  | Dotlseg (coo, b, _, _, _, _)
  | Dotdllseg (coo, b, _, _, _, _, _, _)
  | Dotstruct (coo, b, _, _)
  | Dotdangling(coo, b, _) -> (coo, b)

(* true if a node is of a Dotstruct *)
let is_not_struct node =
  match node with
  | Dotstruct _ -> false
  | _ -> true

(* returns the id field of the coordinate of node *)
let get_coordinate_id node =
  let coo = fst (get_coordinate_and_exp node) in
  coo.id

let rec look_up_for_back_pointer e dotnodes lambda =
  match dotnodes with
  | [] -> []
  | Dotdllseg(coo, _, _, _, e4, _, _, _):: dotnodes' ->
      if Sil.exp_compare e e4 = 0 && lambda = coo.lambda then [coo.id + 1]
      else look_up_for_back_pointer e dotnodes' lambda
  | _:: dotnodes' -> look_up_for_back_pointer e dotnodes' lambda

(* get the nodes corresponding to an expression and a lambda*)
let rec select_nodes_exp_lambda dotnodes e lambda =
  match dotnodes with
  | [] -> []
  | node:: l' ->
      let (coo, e') = get_coordinate_and_exp node in
      if (Sil.exp_compare e e' = 0) && lambda = coo.lambda then node:: select_nodes_exp_lambda l' e lambda
      else select_nodes_exp_lambda l' e lambda

(* look-up the coordinate id in the list of dotnodes those nodes which correspond to expression e*)
(* this is written in this strange way for legacy reason. It should be changed a bit*)
let look_up dotnodes e lambda =
  let r = select_nodes_exp_lambda dotnodes e lambda in
  let r'= list_map get_coordinate_id r in
  r' @ look_up_for_back_pointer e dotnodes lambda

let pp_nesting fmt nesting =
  if nesting > 1 then F.fprintf fmt "%d" nesting

let reset_proposition_counter () = proposition_counter:= 0

let reset_dotty_spec_counter () = spec_counter:= 0

let max_map f l =
  let curr_max = ref 0 in
  list_iter (fun x -> curr_max := max !curr_max (f x)) l;
  ! curr_max

let rec sigma_nesting_level sigma =
  max_map (function
      | Sil.Hpointsto _ -> 0
      | Sil.Hlseg (_, hpara, _, _, _) -> hpara_nesting_level hpara
      | Sil.Hdllseg (_, hpara_dll, _, _, _, _, _) -> hpara_dll_nesting_level hpara_dll) sigma

and hpara_nesting_level hpara =
  1 + sigma_nesting_level hpara.Sil.body

and hpara_dll_nesting_level hpara_dll =
  1 + sigma_nesting_level hpara_dll.Sil.body_dll

let color_to_str c =
  match c with
  | Black -> "black"
  | Blue -> "blue"
  | Green -> "green"
  | Orange -> "orange"
  | Red -> "red"

let make_dangling_boxes pe allocated_nodes (sigma_lambda: (Sil.hpred * int) list) =
  let exp_color hpred (exp : Sil.exp) =
    if pe.pe_cmap_norm (Obj.repr hpred) == Red then Red
    else pe.pe_cmap_norm (Obj.repr exp) in
  let get_rhs_predicate (hpred, lambda) =
    let n = !dotty_state_count in
    incr dotty_state_count;
    let coo = mk_coordinate n lambda in
    (match hpred with
     | Sil.Hpointsto (_, Sil.Eexp (e, inst), _) when not (Sil.exp_equal e Sil.exp_zero) ->
         let e_color_str = color_to_str (exp_color hpred e) in
         [Dotdangling(coo, e, e_color_str)]
     | Sil.Hlseg (k, hpara, _, e2, _) when not (Sil.exp_equal e2 Sil.exp_zero) ->
         let e2_color_str = color_to_str (exp_color hpred e2) in
         [Dotdangling(coo, e2, e2_color_str)]
     | Sil.Hdllseg (k, hpara_dll, e1, e2, e3, e4, elist) ->
         let e2_color_str = color_to_str (exp_color hpred e2) in
         let e3_color_str = color_to_str (exp_color hpred e3) in
         let ll = if not (Sil.exp_equal e2 Sil.exp_zero) then
             [Dotdangling(coo, e2, e2_color_str)]
           else [] in
         if not (Sil.exp_equal e3 Sil.exp_zero) then Dotdangling(coo, e3, e3_color_str):: ll
         else ll
     | Sil.Hpointsto (_, _, _)
     | _ -> [] (* arrays and struct do not give danglings*)
    ) in
  let is_allocated d =
    match d with
    | Dotdangling(_, e, _) ->
        list_exists (fun a -> match a with
            | Dotpointsto(_, e', _)
            | Dotarray(_, _, e', _, _, _)
            | Dotlseg(_, e', _, _, _, _)
            | Dotdllseg(_, e', _, _, _, _, _, _) -> Sil.exp_equal e e'
            | _ -> false
          ) allocated_nodes
    | _ -> false (*this should never happen since d must be a dangling node *) in
  let rec filter_duplicate l seen_exp =
    match l with
    | [] -> []
    | Dotdangling(coo, e, color):: l' ->
        if (list_exists (Sil.exp_equal e) seen_exp) then filter_duplicate l' seen_exp
        else Dotdangling(coo, e, color):: filter_duplicate l' (e:: seen_exp)
    | box:: l' -> box:: filter_duplicate l' seen_exp in (* this case cannot happen*)
  let rec subtract_allocated candidate_dangling =
    match candidate_dangling with
    | [] -> []
    | d:: candidates ->
        if (is_allocated d) then subtract_allocated candidates
        else d:: subtract_allocated candidates in
  let candidate_dangling = list_flatten (list_map get_rhs_predicate sigma_lambda) in
  let candidate_dangling = filter_duplicate candidate_dangling [] in
  let dangling = subtract_allocated candidate_dangling in
  dangling_dotboxes:= dangling

let rec dotty_mk_node pe sigma =
  let n = !dotty_state_count in
  incr dotty_state_count;
  let do_hpred_lambda exp_color = function
    | (Sil.Hpointsto (e, Sil.Earray(e', l, _), Sil.Sizeof(Sil.Tarray(t, s), _)), lambda) ->
        incr dotty_state_count;  (* increment once more n+1 is the box for the array *)
        let e_color_str = color_to_str (exp_color e) in
        let e_color_str'= color_to_str (exp_color e') in
        [Dotpointsto((mk_coordinate n lambda), e, e_color_str); Dotarray((mk_coordinate (n + 1) lambda), e, e', l, t, e_color_str')]
    | (Sil.Hpointsto (e, Sil.Estruct (l, _), _), lambda) ->
        incr dotty_state_count;  (* increment once more n+1 is the box for the struct *)
        let e_color_str = color_to_str (exp_color e) in
        (*      [Dotpointsto((mk_coordinate n lambda), e, l, true, e_color_str)] *)
        [Dotpointsto((mk_coordinate n lambda), e, e_color_str); Dotstruct((mk_coordinate (n + 1) lambda), e, l, e_color_str);]
    | (Sil.Hpointsto (e, _, _), lambda) ->
        let e_color_str = color_to_str (exp_color e) in
        if list_mem Sil.exp_equal e !struct_exp_nodes then [] else
          [Dotpointsto((mk_coordinate n lambda), e, e_color_str)]
    | (Sil.Hlseg (k, hpara, e1, e2, elist), lambda) ->
        incr dotty_state_count; (* increment once more n+1 is the box for last element of the list *)
        let eq_color_str = color_to_str (exp_color e1) in
        [Dotlseg((mk_coordinate n lambda), e1, e2, k, hpara.Sil.body, eq_color_str)]
    | (Sil.Hdllseg (k, hpara_dll, e1, e2, e3, e4, elist), lambda) ->
        let e1_color_str = color_to_str (exp_color e1) in
        incr dotty_state_count;  (* increment once more n+1 is the box for e4 *)
        [Dotdllseg((mk_coordinate n lambda), e1, e2, e3, e4, k, hpara_dll.Sil.body_dll, e1_color_str)] in
  match sigma with
  | [] -> []
  | (hpred, lambda) :: sigma' ->
      let exp_color (exp : Sil.exp) =
        if pe.pe_cmap_norm (Obj.repr hpred) == Red then Red
        else pe.pe_cmap_norm (Obj.repr exp) in
      do_hpred_lambda exp_color (hpred, lambda) @ dotty_mk_node pe sigma'

let set_exps_neq_zero pi =
  let f = function
    | Sil.Aneq (e, Sil.Const (Sil.Cint i)) when Sil.Int.iszero i -> exps_neq_zero := e :: !exps_neq_zero
    | _ -> () in
  exps_neq_zero := [];
  list_iter f pi

let box_dangling e =
  let entry_e = list_filter (fun b -> match b with
      | Dotdangling(_, e', _) -> Sil.exp_equal e e' | _ -> false ) !dangling_dotboxes in
  match entry_e with
  |[] -> None
  | Dotdangling(coo, _, _):: _ -> Some coo.id
  | _ -> None (* NOTE: this cannot be possible since entry_e can be composed only by Dotdangling, see def of entry_e*)

let rec get_color_exp dot_nodes e =
  match dot_nodes with
  | [] ->""
  | Dotnil(_):: l' -> get_color_exp l' e
  | Dotpointsto(_, e', c):: l'
  | Dotdangling(_, e', c):: l'
  | Dotarray(_, _, e', _, _, c):: l'
  | Dotlseg(_, e', _, _, _, c):: l'
  | Dotstruct(_, e', _, c):: l'
  | Dotdllseg(_, e', _, _, _, _, _, c):: l' -> if (Sil.exp_equal e e') then c else get_color_exp l' e

(* construct a Dotnil and returns it's id *)
let make_nil_node lambda =
  let n = !dotty_state_count in
  incr dotty_state_count;
  nil_dotboxes:= Dotnil(mk_coordinate n lambda)::!nil_dotboxes;
  n

let compute_fields_struct sigma =
  fields_structs:=[];
  let rec do_strexp se in_struct =
    match se with
    | Sil.Eexp (e, inst) -> if in_struct then fields_structs:= e ::!fields_structs else ()
    | Sil.Estruct (l, _) -> list_iter (fun e -> do_strexp e true) (snd (list_split l))
    | Sil.Earray (_, l, _) -> list_iter (fun e -> do_strexp e false) (snd (list_split l)) in
  let rec fs s =
    match s with
    | [] -> ()
    | Sil.Hpointsto(_, se, _):: s' -> do_strexp se false; fs s'
    | _:: s' -> fs s' in
  fs sigma

let compute_struct_exp_nodes sigma =
  struct_exp_nodes:=[];
  let rec sen s =
    match s with
    | [] -> ()
    | Sil.Hpointsto(e, Sil.Estruct _, _):: s' -> struct_exp_nodes:= e::!struct_exp_nodes; sen s'
    | _:: s' -> sen s' in
  sen sigma

(* returns the expression of a node*)
let get_node_exp n = snd (get_coordinate_and_exp n)

let is_nil e prop =
  (Sil.exp_equal e Sil.exp_zero) || (Prover.check_equal prop e Sil.exp_zero)

(* compute a list of (kind of link, field name, coo.id target, name_target) *)
let rec compute_target_struct_fields dotnodes list_fld p f lambda =
  let find_target_one_fld (fn, se) =
    match se with
    | Sil.Eexp (e, inst) ->
        if is_nil e p then begin
          let n'= make_nil_node lambda in
          [(LinkStructToExp, Ident.fieldname_to_string fn, n',"")]
        end else
          let nodes_e = select_nodes_exp_lambda dotnodes e lambda in
          (match nodes_e with
           | [] ->
               (match box_dangling e with
                | None -> []
                | Some n' -> [(LinkStructToExp, Ident.fieldname_to_string fn, n',"")]
               )
           | [node] | [Dotpointsto _ ; node] | [node; Dotpointsto _] ->
               let n = get_coordinate_id node in
               if list_mem Sil.exp_equal e !struct_exp_nodes then begin
                 let e_no_special_char = strip_special_chars (Sil.exp_to_string e) in
                 [(LinkStructToStruct, Ident.fieldname_to_string fn, n, e_no_special_char)]
               end else
                 [(LinkStructToExp, Ident.fieldname_to_string fn, n,"")]
           | _ -> (* by construction there must be at most 2 nodes for an expression*)
               L.out "@\n Too many nodes! Error! @\n@.@."; assert false
          )
    | Sil.Estruct (l, _) -> [] (* inner struct are printed by print_struc function *)
    | Sil.Earray _ ->[] (* inner arrays are printed by print_array function *)

  in
  match list_fld with
  | [] -> []
  | a:: list_fld' ->
      let targets_a = find_target_one_fld a in
      targets_a @ compute_target_struct_fields dotnodes list_fld' p f lambda

(* compute a list of (kind of link, field name, coo.id target, name_target) *)
let rec compute_target_array_elements dotnodes list_elements p f lambda =
  let find_target_one_element (idx, se) =
    match se with
    | Sil.Eexp (e, inst) ->
        if is_nil e p then begin
          let n'= make_nil_node lambda in
          [(LinkArrayToExp, Sil.exp_to_string idx, n',"")]
        end else
          let nodes_e = select_nodes_exp_lambda dotnodes e lambda in
          (match nodes_e with
           | [] ->
               (match box_dangling e with
                | None -> []
                | Some n' -> [(LinkArrayToExp, Sil.exp_to_string idx, n',"")]
               )
           | [node] | [Dotpointsto _ ; node] | [node; Dotpointsto _] ->
               let n = get_coordinate_id node in
               if list_mem Sil.exp_equal e !struct_exp_nodes then begin
                 let e_no_special_char = strip_special_chars (Sil.exp_to_string e) in
                 [(LinkArrayToStruct, Sil.exp_to_string idx, n, e_no_special_char)]
               end else
                 [(LinkArrayToExp, Sil.exp_to_string idx, n,"")]
           | _ -> (* by construction there must be at most 2 nodes for an expression*)
               L.out "@\n Too many nodes! Error! @\n@.@."; assert false
          )
    | Sil.Estruct (l, _) -> [] (* inner struct are printed by print_struc function *)
    | Sil.Earray _ ->[] (* inner arrays are printed by print_array function *)
  in
  match list_elements with
  | [] -> []
  | a:: list_ele' ->
      let targets_a = find_target_one_element a in
      targets_a @ compute_target_array_elements dotnodes list_ele' p f lambda

let compute_target_from_eexp dotnodes e p f lambda =
  if is_nil e p then
    let n'= make_nil_node lambda in
    [(LinkExpToExp, n', "")]
  else
    let nodes_e = select_nodes_exp_lambda dotnodes e lambda in
    let nodes_e_no_struct = list_filter is_not_struct nodes_e in
    let trg = list_map get_coordinate_id nodes_e_no_struct in
    (match trg with
     | [] ->
         (match box_dangling e with
          | None -> []
          | Some n -> [(LinkExpToExp, n, "")]
         )
     | _ -> list_map (fun n -> (LinkExpToExp, n, "")) trg
    )

(* build the set of edges between nodes *)
let rec dotty_mk_set_links dotnodes sigma p f =
  let make_links_for_arrays e lie lambda sigma' = (* used for both Earray and ENarray*)
    let src = look_up dotnodes e lambda in
    match src with
    | [] -> assert false
    | n:: nl ->
        let target_list = compute_target_array_elements dotnodes lie p f lambda in
        (* below it's n+1 because n is the address, n+1 is the actual array node*)
        let ff n = list_map (fun (k, lab_src, m, lab_trg) -> mk_link k (mk_coordinate (n + 1) lambda) (strip_special_chars lab_src) (mk_coordinate m lambda) (strip_special_chars lab_trg)) target_list in
        let links_from_elements = list_flatten (list_map ff (n:: nl)) in

        let trg_label = strip_special_chars (Sil.exp_to_string e) in
        let lnk = mk_link (LinkToArray) (mk_coordinate n lambda) "" (mk_coordinate (n + 1) lambda) trg_label in
        lnk:: links_from_elements @ dotty_mk_set_links dotnodes sigma' p f in
  match sigma with
  | [] -> []
  | (Sil.Hpointsto (e, Sil.Earray(_, lie, _), _), lambda):: sigma' ->
      make_links_for_arrays e lie lambda sigma'
  | (Sil.Hpointsto (e, Sil.Estruct (lfld, _), t), lambda):: sigma' ->
      let src = look_up dotnodes e lambda in
      (match src with
       | [] -> assert false
       | nl ->
           (* L.out "@\n@\n List of nl= "; list_iter (L.out " %i ") nl; L.out "@.@.@."; *)
           let target_list = compute_target_struct_fields dotnodes lfld p f lambda in
           let ff n = list_map (fun (k, lab_src, m, lab_trg) -> mk_link k (mk_coordinate n lambda) lab_src (mk_coordinate m lambda) lab_trg) target_list in
           let nodes_e = select_nodes_exp_lambda dotnodes e lambda in
           let address_struct_id =
             try get_coordinate_id (list_hd (list_filter (is_source_node_of_exp e) nodes_e))
             with exn when exn_not_timeout exn -> (* L.out "@\n@\n PROBLEMS!!!!!!!!!!@.@.@."; *) assert false in
           (* we need to exclude the address node from the sorce of fields. no fields should start from there*)
           let nl'= list_filter (fun id -> address_struct_id != id) nl in
           let links_from_fields = list_flatten (list_map ff nl') in

           let trg_label = strip_special_chars (Sil.exp_to_string e) in
           let lnk_from_address_struct = mk_link (LinkExpToStruct) (mk_coordinate address_struct_id lambda) "" (mk_coordinate (address_struct_id + 1) lambda) trg_label in
           lnk_from_address_struct:: links_from_fields @ dotty_mk_set_links dotnodes sigma' p f
      )

  | (Sil.Hpointsto (e, Sil.Eexp (e', inst'), t), lambda):: sigma' ->
      let src = look_up dotnodes e lambda in
      (match src with
       | [] -> assert false
       | nl ->
           let target_list = compute_target_from_eexp dotnodes e' p f lambda in
           let ff n = list_map (fun (k, m, lab_target) -> mk_link k (mk_coordinate n lambda) "" (mk_coordinate m lambda) (strip_special_chars lab_target)) target_list in
           let ll = list_flatten (list_map ff nl) in
           ll @ dotty_mk_set_links dotnodes sigma' p f
      )

  | (Sil.Hlseg (_, pred, e1, e2, elist), lambda):: sigma' ->
      let src = look_up dotnodes e1 lambda in
      (match src with
       | [] -> assert false
       | n:: _ ->
           let (_, m, lab) = list_hd (compute_target_from_eexp dotnodes e2 p f lambda) in
           let lnk = mk_link LinkToSSL (mk_coordinate (n + 1) lambda) "" (mk_coordinate m lambda) lab in
           lnk:: dotty_mk_set_links dotnodes sigma' p f
      )
  | (Sil.Hdllseg (_, pred, e1, e2, e3, e4, elist), lambda):: sigma' ->
      let src = look_up dotnodes e1 lambda in
      (match src with
       | [] -> assert false
       | n:: _ -> (* n is e1's box  and n+1 is e4's box *)
           let targetF = look_up dotnodes e3 lambda in
           let target_Flink = (match targetF with
               | [] -> []
               | m:: _ -> [mk_link LinkToDLL (mk_coordinate (n + 1) lambda) "" (mk_coordinate m lambda) ""]
             ) in
           let targetB = look_up dotnodes e2 lambda in
           let target_Blink = (match targetB with
               | [] -> []
               | m:: _ -> [mk_link LinkToDLL (mk_coordinate n lambda) "" (mk_coordinate m lambda) ""]
             ) in
           target_Blink @ target_Flink @ dotty_mk_set_links dotnodes sigma' p f
      )

let print_kind f kind =
  incr dotty_state_count;
  match kind with
  | Spec_precondition ->
      incr dotty_state_count;
      current_pre:=!dotty_state_count;
      F.fprintf f "\n PRE%iL0 [label=\"PRE %i \",  style=filled, color= yellow]\n" !dotty_state_count !spec_counter;
      print_stack_info:= true;
  | Spec_postcondition pre ->
      F.fprintf f "\n POST%iL0 [label=\"POST %i \",  style=filled, color= yellow]\n" !dotty_state_count !post_counter;
      print_stack_info:= true;
  | Generic_proposition ->
      F.fprintf f "\n HEAP%iL0 [label=\"HEAP %i \",  style=filled, color= yellow]\n" !dotty_state_count !proposition_counter
  | Lambda_pred (no, lev, array) ->
      match array with
      | false ->
          F.fprintf f "style=dashed; color=blue \n state%iL%i [label=\"INTERNAL STRUCTURE %i \",  style=filled, color= lightblue]\n" !dotty_state_count !lambda_counter !lambda_counter ;
          F.fprintf f "state%iL%i -> state%iL%i [color=\"lightblue \"  arrowhead=none] \n" !dotty_state_count !lambda_counter no lev;
      | true ->
          F.fprintf f "style=dashed; color=blue \n state%iL%i [label=\"INTERNAL STRUCTURE %i \",  style=filled, color= lightblue]\n" !dotty_state_count !lambda_counter !lambda_counter ;
          (* F.fprintf f "state%iL%i -> struct%iL%i:%s [color=\"lightblue \"  arrowhead=none] \n" !dotty_state_count !lambda_counter no lev lab;*)

          incr dotty_state_count

(* print a link between two noeds in the graph *)
let dotty_pp_link f link =
  let n1 = link.src.id in
  let lambda1 = link.src.lambda in
  let n2 = link.trg.id in
  let lambda2 = link.trg.lambda in
  let src_fld = link.src_fld in
  let trg_fld = link.trg_fld in
  match n2, link.kind with
  | 0, _ ->
      F.fprintf f "state%iL%i -> state%iL%i[label=\"%s DANG\", color= red];\n" n1 lambda1 n2 lambda2 src_fld
  | _, LinkToArray ->
      F.fprintf f "state%iL%i -> struct%iL%i:%s%iL%i[label=\"\"]\n" n1 lambda1 n2 lambda2 trg_fld n2 lambda2
  | _, LinkExpToStruct ->
      F.fprintf f "state%iL%i -> struct%iL%i:%s%iL%i[label=\"\"]\n" n1 lambda1 n2 lambda2 trg_fld n2 lambda2
  | _, LinkStructToExp ->
      F.fprintf f "struct%iL%i:%s%iL%i -> state%iL%i[label=\"\"]\n" n1 lambda1 src_fld n1 lambda1 n2 lambda2
  | _, LinkStructToStruct ->
      F.fprintf f "struct%iL%i:%s%iL%i -> struct%iL%i:%s%iL%i[label=\"\"]\n" n1 lambda1 src_fld n1 lambda1 n2 lambda2 trg_fld n2 lambda2
  | _, LinkArrayToExp ->
      F.fprintf f "struct%iL%i:%s -> state%iL%i[label=\"\"]\n" n1 lambda1 src_fld n2 lambda2
  | _, LinkArrayToStruct ->
      F.fprintf f "struct%iL%i:%s -> struct%iL%i[label=\"\"]\n" n1 lambda1 src_fld n2 lambda2
  | _, _ -> F.fprintf f "state%iL%i -> state%iL%i[label=\"%s\"];\n" n1 lambda1 n2 lambda2 src_fld

(* given the list of nodes and links get rid of spec nodes that are not pointed to by anybody*)
let filter_useless_spec_dollar_box (nodes: dotty_node list) (links: link list) =
  let tmp_nodes = ref nodes in
  let tmp_links = ref links in
  let remove_links_from ln = list_filter (fun n' -> not (list_mem Pervasives.(=) n' ln)) !tmp_links in
  let remove_node n ns =
    list_filter (fun n' -> match n' with
        | Dotpointsto _ -> (get_coordinate_id n')!= (get_coordinate_id n)
        | _ -> true
      ) ns in
  let rec boxes_pointed_by n lns =
    match lns with
    | [] -> []
    | l:: ln' -> let n_id = get_coordinate_id n in
        if l.src.id = n_id && l.src_fld ="" then (
          (*L.out "@\n Found link (%i,%i)" l.src.id l.trg.id;*)
          l:: boxes_pointed_by n ln'
        )
        else boxes_pointed_by n ln' in
  let rec boxes_pointing_at n lns =
    match lns with
    | [] -> []
    | l:: ln' -> let n_id = get_coordinate_id n in
        if l.trg.id = n_id && l.trg_fld ="" then (
          (*L.out "@\n Found link (%i,%i)" l.src.id l.trg.id;*)
          l:: boxes_pointing_at n ln' )
        else boxes_pointing_at n ln' in
  let is_spec_variable = function
    | Sil.Var id ->
        Ident.is_normal id && Ident.name_equal (Ident.get_name id) Ident.name_spec
    | _ -> false in
  let handle_one_node node =
    match node with
    | Dotpointsto _ ->
        let e = get_node_exp node in
        if is_spec_variable e then begin
          (*L.out "@\n Found a spec expression = %s @.@." (Sil.exp_to_string e); *)
          let links_from_node = boxes_pointed_by node links in
          let links_to_node = boxes_pointing_at node links in
          (* L.out "@\n Size of links_from=%i links_to=%i @.@." (list_length links_from_node) (list_length links_to_node); *)
          if links_to_node =[] then begin
            tmp_links:= remove_links_from links_from_node ;
            tmp_nodes:= remove_node node !tmp_nodes;
          end
        end
    | _ -> () in
  list_iter handle_one_node nodes;
  (!tmp_nodes,!tmp_links)

(* print a struct node *)
let rec print_struct f pe e l coo c =
  let n = coo.id in
  let lambda = coo.lambda in
  let e_no_special_char = strip_special_chars (Sil.exp_to_string e) in
  F.fprintf f "subgraph structs_%iL%i {\n" n lambda ;
  F.fprintf f " node [shape=record]; \n struct%iL%i [label=\"{<%s%iL%i> STRUCT: %a } | %a\" ] fontcolor=%s\n" n lambda e_no_special_char n lambda (Sil.pp_exp pe) e (struct_to_dotty_str pe coo) l c;
  F.fprintf f "}\n"

and print_array f pe e1 e2 l ty coo c =
  let n = coo.id in
  let lambda = coo.lambda in
  let e_no_special_char = strip_special_chars (Sil.exp_to_string e1) in
  F.fprintf f "subgraph structs_%iL%i {\n" n lambda ;
  F.fprintf f " node [shape=record]; \n struct%iL%i [label=\"{<%s%iL%i> ARRAY| SIZE: %a } | %a\" ] fontcolor=%s\n" n lambda e_no_special_char n lambda (Sil.pp_exp pe) e2 (get_contents pe coo) l c;
  F.fprintf f "}\n"

and print_sll f pe nesting k e1 e2 coo =
  let n = coo.id in
  let lambda = coo.lambda in
  let n' = !dotty_state_count in
  incr dotty_state_count;
  begin
    match k with
    | Sil.Lseg_NE -> F.fprintf f "subgraph cluster_%iL%i { style=filled; color=lightgrey; node [style=filled,color=white];  label=\"list NE\";" n' lambda  (*pp_nesting nesting*)
    | Sil.Lseg_PE -> F.fprintf f "subgraph cluster_%iL%i { style=filled; color=lightgrey; node [style=filled,color=white];  label=\"list PE\";" n' lambda (*pp_nesting nesting *)
  end;
  F.fprintf f "state%iL%i [label=\"%a\"]\n" n lambda (Sil.pp_exp pe) e1;
  let n' = !dotty_state_count in
  incr dotty_state_count;
  F.fprintf f "state%iL%i [label=\"... \" style=filled color=lightgrey] \n" n' lambda ;
  F.fprintf f "state%iL%i -> state%iL%i [label=\" \"] \n" n lambda n' lambda ;
  F.fprintf f "state%iL%i [label=\" \"] \n" (n + 1) lambda ;
  F.fprintf f "state%iL%i -> state%iL%i [label=\" \"] }" n' lambda (n + 1) lambda ;
  incr lambda_counter;
  pp_dotty f (Lambda_pred(n + 1, lambda, false)) (Prop.normalize (Prop.from_sigma nesting))

and print_dll f pe nesting k e1 e2 e3 e4 coo =
  let n = coo.id in
  let lambda = coo.lambda in
  let n' = !dotty_state_count in
  incr dotty_state_count;
  begin
    match k with
    | Sil.Lseg_NE -> F.fprintf f "subgraph cluster_%iL%i { style=filled; color=lightgrey; node [style=filled,color=white];  label=\"doubly-linked list NE\";" n' lambda  (*pp_nesting nesting *)
    | Sil.Lseg_PE -> F.fprintf f "subgraph cluster_%iL%i { style=filled; color=lightgrey; node [style=filled,color=white];  label=\"doubly-linked list PE\";" n' lambda (*pp_nesting nesting *)
  end;
  F.fprintf f "state%iL%i [label=\"%a\"]\n" n lambda (Sil.pp_exp pe) e1;
  let n' = !dotty_state_count in
  incr dotty_state_count;
  F.fprintf f "state%iL%i [label=\"... \" style=filled color=lightgrey] \n" n' lambda;
  F.fprintf f "state%iL%i -> state%iL%i [label=\" \"]\n" n lambda n' lambda;
  F.fprintf f "state%iL%i -> state%iL%i [label=\" \"]\n" n' lambda n lambda;
  F.fprintf f "state%iL%i [label=\"%a\"]\n" (n + 1) lambda (Sil.pp_exp pe) e4;
  F.fprintf f "state%iL%i -> state%iL%i [label=\" \"]\n" (n + 1) lambda n' lambda;
  F.fprintf f "state%iL%i -> state%iL%i [label=\" \"]}\n" n' lambda (n + 1) lambda ;
  incr lambda_counter;
  pp_dotty f (Lambda_pred(n', lambda, false)) (Prop.normalize (Prop.from_sigma nesting))

and dotty_pp_state f pe dotnode =
  let dotty_exp coo e c is_dangling =
    let n = coo.id in
    let lambda = coo.lambda in
    if is_dangling then
      F.fprintf f "state%iL%i [label=\"%a \", color=red, style=dashed, fontcolor=%s]\n" n lambda (Sil.pp_exp pe) e c
    else
      F.fprintf f "state%iL%i [label=\"%a\" fontcolor=%s]\n" n lambda (Sil.pp_exp pe) e c in
  match dotnode with
  | Dotnil coo -> F.fprintf f "state%iL%i [label=\"NIL \", color=green, style=filled]\n" coo.id coo.lambda
  | Dotdangling(coo, e, c) -> dotty_exp coo e c true
  | Dotpointsto(coo, e1, c) -> dotty_exp coo e1 c false
  | Dotstruct(coo, e1, l, c) -> print_struct f pe e1 l coo c
  | Dotarray(coo, e1, e2, l, ty, c) -> print_array f pe e1 e2 l ty coo c
  | Dotlseg(coo, e1, e2, Sil.Lseg_NE, nesting, c) ->
      print_sll f pe nesting Sil.Lseg_NE e1 e2 coo
  | Dotlseg(coo, e1, e2, Sil.Lseg_PE, nesting, c) ->
      print_sll f pe nesting Sil.Lseg_PE e1 e2 coo
  | Dotdllseg(coo, e1, e2, e3, e4, Sil.Lseg_NE, nesting, c) ->
      print_dll f pe nesting Sil.Lseg_NE e1 e2 e3 e4 coo
  | Dotdllseg(coo, e1, e2, e3, e4, Sil.Lseg_PE, nesting, c) ->
      print_dll f pe nesting Sil.Lseg_PE e1 e2 e3 e4 coo

(* Build the graph data structure to be printed *)
and build_visual_graph f pe p =
  let sigma = Prop.get_sigma p in
  compute_fields_struct sigma;
  compute_struct_exp_nodes sigma;
  (* L.out "@\n@\n Computed fields structs: ";
     list_iter (fun e -> L.out " %a " (Sil.pp_exp pe) e) !fields_structs;
     L.out "@\n@.";
     L.out "@\n@\n Computed exp structs nodes: ";
     list_iter (fun e -> L.out " %a " (Sil.pp_exp pe) e) !struct_exp_nodes;
     L.out "@\n@."; *)
  let sigma_lambda = list_map (fun hp -> (hp,!lambda_counter)) sigma in
  let nodes = (dotty_mk_node pe) sigma_lambda in
  make_dangling_boxes pe nodes sigma_lambda;
  let links = dotty_mk_set_links nodes sigma_lambda p f in
  filter_useless_spec_dollar_box nodes links

and display_pure_info f pe prop =
  let print_invisible_objects () =
    for j = 1 to 4 do
      F.fprintf f "  inv_%i%i [style=invis]\n" !spec_counter j;
      F.fprintf f "  inv_%i%i%i [style=invis]\n" !spec_counter j j;
      F.fprintf f "  inv_%i%i%i%i [style=invis]\n" !spec_counter j j j;
    done;
    for j = 1 to 4 do
      F.fprintf f "  state_pi_%i -> inv_%i%i [style=invis]\n" !proposition_counter !spec_counter j;
      F.fprintf f "  inv_%i%i -> inv_%i%i%i [style=invis]\n" !spec_counter j !spec_counter j j;
      F.fprintf f "  inv_%i%i%i -> inv_%i%i%i%i [style=invis]\n" !spec_counter j j !spec_counter j j j;
    done in
  let pure = Prop.get_pure prop in
  F.fprintf f "subgraph {\n";
  F.fprintf f " node [shape=box]; \n state_pi_%i [label=\"STACK \\n\\n %a\" color=orange style=filled]\n" !proposition_counter (Prop.pp_pi pe) pure;
  if !invisible_arrows then print_invisible_objects ();
  F.fprintf f "}\n"

(** Pretty print a proposition in dotty format. *)
and pp_dotty f kind (_prop: Prop.normal Prop.t) =
  incr proposition_counter;
  let pe, prop = match kind with
    | Spec_postcondition pre ->
        target_invisible_arrow_pre:=!proposition_counter;
        let diff = Propgraph.compute_diff Black (Propgraph.from_prop pre) (Propgraph.from_prop _prop) in
        let cmap_norm = Propgraph.diff_get_colormap false diff in
        let cmap_foot = Propgraph.diff_get_colormap true diff in
        let pe = { (Prop.prop_update_obj_sub pe_text pre) with pe_cmap_norm = cmap_norm; pe_cmap_foot = cmap_foot } in
        let pre_stack = fst (Prop.sigma_get_stack_nonstack true (Prop.get_sigma pre)) in (* add stack vars from pre *)
        let prop = Prop.replace_sigma (pre_stack @ Prop.get_sigma _prop) _prop in
        pe, Prop.normalize prop
    | _ ->
        let pe = Prop.prop_update_obj_sub pe_text _prop in
        pe, _prop in
  dangling_dotboxes := [];
  nil_dotboxes :=[];
  set_exps_neq_zero (Prop.get_pi prop);
  incr dotty_state_count;
  F.fprintf f "\n subgraph cluster_prop_%i { color=black \n" !proposition_counter;
  print_kind f kind;
  if !print_stack_info then begin
    display_pure_info f pe prop;
    print_stack_info:= false
  end;
  (* F.fprintf f "\n subgraph cluster_%i { color=black \n" !dotty_state_count; *)
  let (nodes, links) = build_visual_graph f pe prop in
  list_iter (dotty_pp_state f pe) (nodes@ !dangling_dotboxes @ !nil_dotboxes);
  list_iter (dotty_pp_link f) links;
  (* F.fprintf f "\n } \n"; *)
  F.fprintf f "\n } \n"

let pp_dotty_one_spec f pre posts =
  post_counter := 0;
  incr spec_counter;
  incr proposition_counter;
  incr dotty_state_count;
  F.fprintf f "\n subgraph cluster_%i { color=blue \n" !dotty_state_count;
  incr dotty_state_count;
  F.fprintf f "\n state%iL0 [label=\"SPEC %i \",  style=filled, color= lightblue]\n" !dotty_state_count !spec_counter;
  spec_id:=!dotty_state_count;
  invisible_arrows:= true;
  pp_dotty f (Spec_precondition) pre;
  invisible_arrows:= false;
  list_iter (fun (po, path) -> incr post_counter ; pp_dotty f (Spec_postcondition pre) po;
              for j = 1 to 4 do
                F.fprintf f "  inv_%i%i%i%i -> state_pi_%i [style=invis]\n" !spec_counter j j j !target_invisible_arrow_pre;
              done
            ) posts;
  F.fprintf f "\n } \n"

(* this is used to print a list of proposition when considered in a path of nodes *)
let pp_dotty_prop_list_in_path f plist prev_n curr_n =
  try
    incr proposition_counter;
    incr dotty_state_count;
    F.fprintf f "\n subgraph cluster_%i { color=blue \n" !dotty_state_count;
    incr dotty_state_count;
    F.fprintf f "\n state%iN [label=\"NODE %i \",  style=filled, color= lightblue]\n" curr_n curr_n;
    list_iter (fun po -> incr proposition_counter ; pp_dotty f (Generic_proposition) po) plist;
    if prev_n <> - 1 then F.fprintf f "\n state%iN ->state%iN\n" prev_n curr_n;
    F.fprintf f "\n } \n"
  with exn when exn_not_timeout exn ->
    ()

(* create a dotty file with a single proposition *)
let dotty_prop_to_dotty_file fname prop =
  try
    let out_dot = open_out fname in
    let fmt_dot = Format.formatter_of_out_channel out_dot in
    reset_proposition_counter ();
    Format.fprintf fmt_dot "@\n@\n@\ndigraph main { \nnode [shape=box]; @\n";
    Format.fprintf fmt_dot "@\n compound = true; @\n";
    pp_dotty fmt_dot Generic_proposition prop;
    Format.fprintf fmt_dot "@\n}";
    close_out out_dot
  with exn when exn_not_timeout exn ->
    ()

(* this is used only to print a list of prop parsed with the external parser. Basically deprecated.*)
let pp_proplist_parsed2dotty_file filename plist =
  try
    let pp_list f plist =
      reset_proposition_counter ();
      F.fprintf f "\n\n\ndigraph main { \nnode [shape=box];\n";
      F.fprintf f "\n compound = true; \n";
      F.fprintf f "\n /* size=\"12,7\"; ratio=fill;*/ \n";
      ignore (list_map (pp_dotty f Generic_proposition) plist);
      F.fprintf f "\n}" in
    let outc = open_out filename in
    let fmt = F.formatter_of_out_channel outc in
    F.fprintf fmt "#### Dotty version:  ####@.%a@.@." pp_list plist;
    close_out outc
  with exn when exn_not_timeout exn ->
    ()

(********** START of Print interprocedural cfgs in dotty format  *)
(********** Print control flow graph (in dot form) for fundec to *)
(* channel. You have to compute an interprocedural cfg first               *)

let pp_cfgnodename fmt (n : Cfg.Node.t) =
  F.fprintf fmt "%d" (Cfg.Node.get_id n)

let pp_etlist fmt etl =
  list_iter (fun (id, ty) ->
      Format.fprintf fmt " %s:%a" id (Sil.pp_typ_full pe_text) ty) etl

let pp_local_list fmt etl =
  list_iter (fun (id, ty) ->
      Format.fprintf fmt " %a:%a" Mangled.pp id (Sil.pp_typ_full pe_text) ty) etl

let pp_cfgnodelabel fmt (n : Cfg.Node.t) =
  let pp_label fmt n =
    match Cfg.Node.get_kind n with
    | Cfg.Node.Start_node (pdesc) ->
        let gen = if (Cfg.Procdesc.get_attributes pdesc).Sil.is_generated then " (generated)" else "" in
        (* let def = if Cfg.Procdesc.is_defined pdesc then "defined" else "declared" in *)
        (* Format.fprintf fmt "Start %a (%s)" pp_id (Procname.to_string (Cfg.Procdesc.get_proc_name pdesc)) def *)
        Format.fprintf fmt "Start %s%s\\nFormals: %a\\nLocals: %a"
          (Procname.to_string (Cfg.Procdesc.get_proc_name pdesc))
          gen
          pp_etlist (Cfg.Procdesc.get_formals pdesc)
          pp_local_list (Cfg.Procdesc.get_locals pdesc);
        if list_length (Cfg.Procdesc.get_captured pdesc) <> 0 then
          Format.fprintf fmt "\\nCaptured: %a"
            pp_local_list (Cfg.Procdesc.get_captured pdesc)
    | Cfg.Node.Exit_node (pdesc) ->
        Format.fprintf fmt "Exit %s" (Procname.to_string (Cfg.Procdesc.get_proc_name pdesc))
    | Cfg.Node.Join_node ->
        Format.fprintf fmt "+"
    | Cfg.Node.Prune_node (is_true_branch, ik, s) -> Format.fprintf fmt "Prune (%b branch)" is_true_branch
    | Cfg.Node.Stmt_node s -> Format.fprintf fmt " %s" s
    | Cfg.Node.Skip_node s -> Format.fprintf fmt "Skip %s" s in
  let instr_string i =
    let pp f () = Sil.pp_instr pe_text f i in
    let str = pp_to_string pp () in
    Escape.escape_dotty str in
  let pp_instrs fmt instrs =
    list_iter (fun i -> F.fprintf fmt " %s\\n " (instr_string i)) instrs in
  let instrs = Cfg.Node.get_instrs n in
  F.fprintf fmt "%d: %a \\n  %a" (Cfg.Node.get_id n) pp_label n pp_instrs instrs

let pp_cfgnodeshape fmt (n: Cfg.Node.t) =
  match Cfg.Node.get_kind n with
  | Cfg.Node.Start_node _ | Cfg.Node.Exit_node _ -> F.fprintf fmt "color=yellow style=filled"
  | Cfg.Node.Prune_node _ -> F.fprintf fmt "shape=\"invhouse\""
  | Cfg.Node.Skip_node _ -> F.fprintf fmt "color=\"gray\""
  | Cfg.Node.Stmt_node _ -> F.fprintf fmt "shape=\"box\""
  | _ -> F.fprintf fmt ""

(*
let pp_cfgedge fmt src dest =
F.fprintf fmt "%a -> %a"
pp_cfgnodename src
pp_cfgnodename dest
*)

let pp_cfgnode fmt (n: Cfg.Node.t) =
  F.fprintf fmt "%a [label=\"%a\" %a]\n\t\n" pp_cfgnodename n pp_cfgnodelabel n pp_cfgnodeshape n;
  let print_edge n1 n2 is_exn =
    let color = if is_exn then "[color=\"red\" ]" else "" in
    match Cfg.Node.get_kind n2 with
    | Cfg.Node.Exit_node _ when is_exn = true -> (* don't print exception edges to the exit node *)
        ()
    | _ ->
        F.fprintf fmt "\n\t %d -> %d %s;" (Cfg.Node.get_id n1) (Cfg.Node.get_id n2) color in
  list_iter (fun n' -> print_edge n n' false) (Cfg.Node.get_succs n);
  list_iter (fun n' -> print_edge n n' true) (Cfg.Node.get_exn n)

(* * print control flow graph (in dot form) for fundec to channel let      *)
(* print_cfg_channel (chan : out_channel) (fd : fundec) = let pnode (s:    *)
(* stmt) = fprintf chan "%a@\n" d_cfgnode s in forallStmts pnode fd *      *)
(* Print control flow graph (in dot form) for fundec to file let           *)
(* print_cfg_filename (filename : string) (fd : fundec) = let chan =       *)
(* open_out filename in begin print_cfg_channel chan fd; close_out chan;   *)
(* end                                                                     *)

(* Print the extra information related to the inteprocedural aspect, ie.,  *)
(* special node, and call / return edges                                   *)
let print_icfg fmt cfg =
  let print_node node =
    let loc = Cfg.Node.get_loc node in
    if (!Config.dotty_cfg_libs || DB.source_file_equal loc.Sil.file !DB.current_source) then
      F.fprintf fmt "%a\n" pp_cfgnode node in
  list_iter print_node (Cfg.Node.get_all_nodes cfg)

let print_edges fmt edges =
  let count = ref 0 in
  let print_edge (n1, n2) =
    incr count;
    F.fprintf fmt "%a -> %a [color=\"red\" label=\"%d\" fontcolor=\"green\"];" pp_cfgnodename n1 pp_cfgnodename n2 !count in
  list_iter print_edge edges

let print_icfg_dotty cfg (extra_edges : (Cfg.Node.t * Cfg.Node.t) list) =
  let chan = open_out (DB.filename_to_string (DB.Results_dir.path_to_filename DB.Results_dir.Abs_source_dir [!Config.dotty_output])) in
  let fmt = Format.formatter_of_out_channel chan in
  F.fprintf fmt "digraph iCFG {\n";
  print_icfg fmt cfg;
  print_edges fmt extra_edges;
  F.fprintf fmt "}\n";
  close_out chan

let store_icfg_to_file filename cfg =
  let chan = open_out ((Filename.chop_extension filename)^".dot") in
  let fmt = Format.formatter_of_out_channel chan in
  F.fprintf fmt "digraph iCFG {\n";
  print_icfg fmt cfg;
  F.fprintf fmt "}\n";
  close_out chan

(********** END of Printing dotty files ***********)

(** Dotty printing for specs *)
let pp_speclist_dotty f (splist: Prop.normal Specs.spec list) =
  let pp_simple_saved = !Config.pp_simple in
  Config.pp_simple := true;
  reset_proposition_counter ();
  reset_dotty_spec_counter ();
  F.fprintf f "@\n@\n\ndigraph main { \nnode [shape=box]; @\n";
  F.fprintf f "@\n compound = true; @\n";
  (*  F.fprintf f "\n size=\"12,7\"; ratio=fill; \n"; *)
  list_iter (fun s -> pp_dotty_one_spec f (Specs.Jprop.to_prop s.Specs.pre) s.Specs.posts) splist;
  F.fprintf f "@\n}";
  Config.pp_simple := pp_simple_saved

let pp_speclist_to_file (filename : DB.filename) spec_list =
  let pp_simple_saved = !Config.pp_simple in
  Config.pp_simple := true;
  let outc = open_out (DB.filename_to_string (DB.filename_add_suffix filename ".dot")) in
  let fmt = F.formatter_of_out_channel outc in
  let () = F.fprintf fmt "#### Dotty version:  ####@\n%a@\n@\n" pp_speclist_dotty spec_list in
  close_out outc;
  Config.pp_simple := pp_simple_saved

let pp_speclist_dotty_file (filename : DB.filename) spec_list =
  try pp_speclist_to_file filename spec_list
  with exn when exn_not_timeout exn ->
    ()

(**********************************************************************)
(* Code prodicing a xml version of a graph                            *)
(**********************************************************************)

(* each node has an unique integer identifier *)
type visual_heap_node =
  | VH_dangling of int * Sil.exp
  | VH_pointsto of int * Sil.exp * Sil.strexp * Sil.exp (* VH_pointsto(id,address,content,type) *)
  | VH_lseg of int * Sil.exp * Sil.exp * Sil.lseg_kind (*VH_lseg(id,address,content last cell, kind) *)
  (*VH_dllseg(id, address, content first cell, content last cell, address last cell, kind) *)
  | VH_dllseg of int * Sil.exp * Sil.exp * Sil.exp * Sil.exp * Sil.lseg_kind

(* an edge is a pair of node identifiers*)
type visual_heap_edge = {
  src: int;
  trg: int;
  lab: string
}

let mk_visual_heap_edge s t l = { src = s; trg = t; lab = l }

(* a visual heap has an integer identifier, a set of nodes and a set of edges*)
type visual_heap =
  | VH of int * visual_heap_node list * visual_heap_edge list

(* set of visual heaps used to represent a proposition. In general, since we have high-order *)
(* lists a proposition is not a single visual heap but a set of it. The parameter of a high-order*)
(* list is visualized with a distinct visual heap. Similarly for the parameter in new arrays*)
type visual_proposition = visual_heap list

(* used to generate unique identifier for all the nodes in the set of visual graphs used to *)
(* represent a proposition*)
let global_node_counter = ref 0

let working_list = ref []

let set_dangling_nodes = ref []

(* convert an exp into a string which is xml friendly, ie. special character are replaced by*)
(* the proper xml way to visualize them*)
let exp_to_xml_string e =
  pp_to_string (Sil.pp_exp (pe_html Black)) e

(* convert an atom into an xml-friendly string without special characters *)
let atom_to_xml_string a =
  pp_to_string (Sil.pp_atom (pe_html Black)) a

(* return the dangling node corresponding to an expression it exists or None *)
let exp_dangling_node e =
  let entry_e = list_filter (fun b -> match b with
      | VH_dangling(_, e') -> Sil.exp_equal e e' | _ -> false ) !set_dangling_nodes in
  match entry_e with
  |[] -> None
  | VH_dangling(n, e') :: _ -> Some (VH_dangling(n, e'))
  | _ -> None (* NOTE: this cannot be possible since entry_e can be composed only by VH_dangling, see def of entry_e*)

(* make nodes and when it finds a list records in the working list         *)
(* to do (n, prop) where n is the integer identifier of the list node.     *)
(* This allow to keep the connection between the list node and the graph   *)
(* that displays its contents.                                             *)
let rec make_visual_heap_nodes sigma =
  let n = !global_node_counter in
  incr global_node_counter;
  match sigma with
  | [] -> []
  | Sil.Hpointsto (e, se, t):: sigma' ->
      VH_pointsto(n, e, se, t):: make_visual_heap_nodes sigma'
  | Sil.Hlseg (k, hpara, e1, e2, elist):: sigma' ->
      working_list:= (n, hpara.Sil.body)::!working_list;
      VH_lseg(n, e1, e2, k):: make_visual_heap_nodes sigma'
  | Sil.Hdllseg (k, hpara_dll, e1, e2, e3, e4, elist):: sigma'->
      working_list:= (n, hpara_dll.Sil.body_dll)::!working_list;
      VH_dllseg(n, e1, e2, e3, e4, k):: make_visual_heap_nodes sigma'

(* given a node returns its id and address*)
let get_node_id_and_addr node =
  match node with
  | VH_dangling(n, e)
  | VH_pointsto(n, e, _, _)
  | VH_lseg(n, e, _ , _)
  | VH_dllseg(n, e, _, _, _, _) -> (n, e)

(* return node's id*)
let get_node_id node = fst (get_node_id_and_addr node)

(* return node's address*)
let get_node_addr node = snd (get_node_id_and_addr node)

(* return the nodes corresponding to an address given by an expression *)
let rec select_node_at_address nodes e =
  match nodes with
  | [] -> None
  | n:: l' ->
      let e' = get_node_addr n in
      if (Sil.exp_compare e e' = 0) then Some n
      else select_node_at_address l' e

(* look-up the ids in the list of nodes corresponding to expression e*)
(* let look_up_nodes_ids nodes e =
   list_map get_node_id (select_nodes_exp nodes e) *)

(* create a list of dangling nodes *)
let make_set_dangling_nodes allocated_nodes (sigma: Sil.hpred list) =
  let make_new_dangling e =
    let n = !global_node_counter in
    incr global_node_counter;
    VH_dangling(n, e) in
  let get_rhs_predicate hpred =
    (match hpred with
     | Sil.Hpointsto (_, Sil.Eexp (e, inst), _) when not (Sil.exp_equal e Sil.exp_zero) -> [e]
     | Sil.Hlseg (_, _, _, e2, _) when not (Sil.exp_equal e2 Sil.exp_zero) -> [e2]
     | Sil.Hdllseg (_, _, e1, e2, e3, _, _) ->
         if (Sil.exp_equal e2 Sil.exp_zero) then
           if (Sil.exp_equal e3 Sil.exp_zero) then []
           else [e3]
         else [e2; e3]
     | Sil.Hpointsto (_, _, _)
     | _ -> [] (* arrays and struct do not give danglings. CHECK THIS!*)
    ) in
  let is_not_allocated e =
    let allocated = list_exists (fun a -> match a with
        | VH_pointsto(_, e', _, _)
        | VH_lseg(_, e', _ , _)
        | VH_dllseg(_, e', _, _, _, _) -> Sil.exp_equal e e'
        | _ -> false ) allocated_nodes in
    not allocated in
  let rec filter_duplicate l seen_exp =
    match l with
    | [] -> []
    | e:: l' ->
        if (list_exists (Sil.exp_equal e) seen_exp) then filter_duplicate l' seen_exp
        else e:: filter_duplicate l' (e:: seen_exp) in
  let rhs_exp_list = list_flatten (list_map get_rhs_predicate sigma) in
  let candidate_dangling_exps = filter_duplicate rhs_exp_list [] in
  let dangling_exps = list_filter is_not_allocated candidate_dangling_exps in  (* get rid of allocated ones*)
  list_map make_new_dangling dangling_exps

(* return a list of pairs (n,field_lab) where n is a target node*)
(* corresponding to se and is going to be used a target for and edge*)
(* field_lab is the name of the field which points to n (if any)*)
let rec compute_target_nodes_from_sexp nodes se prop field_lab =
  match se with
  | Sil.Eexp (e, inst) when is_nil e prop -> [] (* Nil is not represented by a node, it's just a value which should be printed*)
  | Sil.Eexp (e, inst) ->
      let e_node = select_node_at_address nodes e in
      (match e_node with
       | None ->
           (match exp_dangling_node e with
            | None -> []
            | Some dang_node -> [(dang_node, field_lab)]
           )
       | Some n -> [(n, field_lab)]
      )
  | Sil.Estruct (lfld, inst) ->
      (match lfld with
       | [] -> []
       | (fn, se2):: l' ->
           compute_target_nodes_from_sexp nodes se2 prop (Ident.fieldname_to_string fn) @
           compute_target_nodes_from_sexp nodes (Sil.Estruct (l', inst)) prop ""
      )
  | Sil.Earray(size, lie, inst) ->
      (match lie with
       | [] -> []
       | (idx, se2):: l' ->
           let lab ="["^exp_to_xml_string idx^"]" in
           compute_target_nodes_from_sexp nodes se2 prop lab @
           compute_target_nodes_from_sexp nodes (Sil.Earray(size, l', inst)) prop ""
      )


(* build the set of edges between nodes *)
let rec make_visual_heap_edges nodes sigma prop =
  let combine_source_target_label n (m, lab) =
    mk_visual_heap_edge (get_node_id n) (get_node_id m) lab in
  match sigma with
  | [] -> []
  | Sil.Hpointsto (e, se, t):: sigma' ->
      let e_node = select_node_at_address nodes e in
      (match e_node with
       | None -> assert false
       | Some n ->
           let target_nodes = compute_target_nodes_from_sexp nodes se prop "" in
           let ll = list_map (combine_source_target_label n) target_nodes in
           ll @ make_visual_heap_edges nodes sigma' prop
      )
  | Sil.Hlseg (_, pred, e1, e2, elist):: sigma' ->
      let e1_node = select_node_at_address nodes e1 in
      (match e1_node with
       | None -> assert false
       | Some n ->
           let target_nodes = compute_target_nodes_from_sexp nodes (Sil.Eexp (e2, Sil.inst_none)) prop "" in
           let ll = list_map (combine_source_target_label n) target_nodes in
           ll @ make_visual_heap_edges nodes sigma' prop
      )

  | Sil.Hdllseg (_, pred, e1, e2, e3, e4, elist):: sigma' ->
      let e1_node = select_node_at_address nodes e1 in
      (match e1_node with
       | None -> assert false
       | Some n ->
           let target_nodesF = compute_target_nodes_from_sexp nodes (Sil.Eexp (e3, Sil.inst_none)) prop "" in
           let target_nodesB = compute_target_nodes_from_sexp nodes (Sil.Eexp (e2, Sil.inst_none)) prop "" in
           let llF = list_map (combine_source_target_label n) target_nodesF in
           let llB = list_map (combine_source_target_label n) target_nodesB in
           llF @ llB @ make_visual_heap_edges nodes sigma' prop
      )

(* from a prop generate and return visual proposition *)
let prop_to_set_of_visual_heaps prop =
  let result = ref [] in
  working_list:=[(!global_node_counter, Prop.get_sigma prop)];
  incr global_node_counter;
  while (!working_list!=[]) do
    set_dangling_nodes:=[];
    let (n, h) = list_hd !working_list in
    working_list:= list_tl !working_list;
    let nodes = make_visual_heap_nodes h in
    set_dangling_nodes:= make_set_dangling_nodes nodes h;
    let edges = make_visual_heap_edges nodes h prop in
    result:= !result @ [(n, nodes @ !set_dangling_nodes, edges)];
  done;
  !result

let rec pointsto_contents_to_xml (co: Sil.strexp) : Io_infer.Xml.node =
  match co with
  | Sil.Eexp (e, inst) ->
      Io_infer.Xml.create_tree "cell" [("content-value", exp_to_xml_string e)] []
  | Sil.Estruct (fel, _) ->
      let f (fld, exp) = Io_infer.Xml.create_tree "struct-field" [("id", Ident.fieldname_to_string fld)] [(pointsto_contents_to_xml exp)] in
      Io_infer.Xml.create_tree "struct" [] (list_map f fel)
  | Sil.Earray (size, nel, _) ->
      let f (e, se) = Io_infer.Xml.create_tree "array-element" [("index", exp_to_xml_string e)] [pointsto_contents_to_xml se] in
      Io_infer.Xml.create_tree "array" [("size", exp_to_xml_string size)] (list_map f nel)

(* Convert an atom to xml in a light version. Namely, the expressions are not fully blown-up into *)
(* xml tree but visualized as strings *)
let atom_to_xml_light (a: Sil.atom) : Io_infer.Xml.node =
  let kind_info = match a with
    | Sil.Aeq _ when Prop.atom_is_inequality a ->
        "inequality"
    | Sil.Aeq _ ->
        "equality"
    | Sil.Aneq _ ->
        "disequality" in
  Io_infer.Xml.create_tree "stack-variable" [("type", kind_info); ("instance", atom_to_xml_string a)] []

let xml_pure_info prop =
  let pure = Prop.get_pure prop in
  let xml_atom_list = list_map atom_to_xml_light pure in
  Io_infer.Xml.create_tree "stack" [] xml_atom_list

(** Return a string describing the kind of a pointsto address *)
let pointsto_addr_kind = function
  | Sil.Lvar pv ->
      if Sil.pvar_is_global pv
      then "global"
      else if Sil.pvar_is_local pv && Mangled.equal (Sil.pvar_get_name pv) Ident.name_return
      then "return"
      else if Sil.pvar_is_local pv
      then "parameter"
      else "other"
  | _ -> "other"

let heap_node_to_xml node =
  match node with
  | VH_dangling(id, addr) ->
      let atts =[("id", string_of_int id); ("address", exp_to_xml_string addr); ("node-type","dangling"); ("memory-type", pointsto_addr_kind addr)] in
      Io_infer.Xml.create_tree "node" atts []
  | VH_pointsto(id, addr, cont, t) ->
      let atts =[("id", string_of_int id); ("address", exp_to_xml_string addr); ("node-type","allocated"); ("memory-type", pointsto_addr_kind addr)] in
      let contents = pointsto_contents_to_xml cont in
      Io_infer.Xml.create_tree "node" atts [contents]
  | VH_lseg(id, addr, cont, Sil.Lseg_NE) ->
      let atts =[("id", string_of_int id); ("address", exp_to_xml_string addr); ("node-type","single linked list"); ("list-type","non-empty"); ("memory-type", "other")] in
      Io_infer.Xml.create_tree "node" atts []
  | VH_lseg(id, addr, cont, Sil.Lseg_PE) ->
      let atts =[("id", string_of_int id); ("address", exp_to_xml_string addr); ("node-type","single linked list"); ("list-type","possibly empty"); ("memory-type", "other")] in
      Io_infer.Xml.create_tree "node" atts []
  | VH_dllseg(id, addr1, cont1, cont2, addr2, k) ->
      let contents1 = pointsto_contents_to_xml (Sil.Eexp (cont1, Sil.inst_none)) in
      let contents2 = pointsto_contents_to_xml (Sil.Eexp (cont2, Sil.inst_none)) in
      let atts =[("id", string_of_int id); ("addr-first", exp_to_xml_string addr1); ("addr-last", exp_to_xml_string addr2); ("node-type","double linked list"); ("memory-type", "other") ] in
      Io_infer.Xml.create_tree "node" atts [contents1 ; contents2]

let heap_edge_to_xml edge =
  let atts =[("source", string_of_int edge.src); ("target", string_of_int edge.trg); ("label", edge.lab) ] in
  Io_infer.Xml.create_tree "edge" atts []

let visual_heap_to_xml heap =
  let (n, nodes, edges) = heap in
  let xml_heap_nodes = list_map heap_node_to_xml nodes in
  let xml_heap_edges = list_map heap_edge_to_xml edges in
  Io_infer.Xml.create_tree "heap" [("id", string_of_int n)] (xml_heap_nodes @ xml_heap_edges)

(** convert a proposition to xml with the given tag and id *)
let prop_to_xml prop tag_name id =
  let visual_heaps = prop_to_set_of_visual_heaps prop in
  let xml_visual_heaps = list_map visual_heap_to_xml visual_heaps in
  let xml_pure_part = xml_pure_info prop in
  let xml_graph = Io_infer.Xml.create_tree tag_name [("id", string_of_int id)] (xml_visual_heaps @ [xml_pure_part]) in
  xml_graph

(** reset the counter used for node and heap identifiers *)
let reset_node_counter () =
  global_node_counter := 0

let print_specs_xml signature specs loc fmt =
  reset_node_counter ();
  let do_one_spec pre posts n =
    let add_stack_to_prop _prop =
      let pre_stack = fst (Prop.sigma_get_stack_nonstack true (Prop.get_sigma pre)) in (* add stack vars from pre *)
      let _prop' = Prop.replace_sigma (pre_stack @ Prop.get_sigma _prop) _prop in
      Prop.normalize _prop' in
    let jj = ref 0 in
    let xml_pre = prop_to_xml pre "precondition" !jj in
    let xml_spec = xml_pre:: (list_map (fun (po, path) -> jj:=!jj + 1; prop_to_xml (add_stack_to_prop po) "postcondition" !jj) posts) in
    Io_infer.Xml.create_tree "specification" [("id", string_of_int n)] xml_spec in
  let j = ref 0 in
  let list_of_specs_xml =
    list_map
      (fun s ->
         j:=!j + 1;
         do_one_spec (Specs.Jprop.to_prop s.Specs.pre) s.Specs.posts !j)
      specs in
  let xml_specifications = Io_infer.Xml.create_tree "specifications" [] list_of_specs_xml in
  let xml_signature = Io_infer.Xml.create_tree "signature" [("name", signature)] [] in
  let proc_summary = Io_infer.Xml.create_tree "procedure" [("file", DB.source_file_to_string loc.Sil.file); ("line", string_of_int loc.Sil.line)] [xml_signature; xml_specifications] in
  Io_infer.Xml.pp_document true fmt proc_summary
