(*
 * Copyright (c) 2015 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)
open LAst

exception ImproperTypeError of string
exception Unimplemented of string

let ident_of_variable (var : LAst.variable) : Ident.t = (* TODO: use unique stamps *)
  Ident.create_normal (Ident.string_to_name (LAst.string_of_variable var)) 0

let trans_variable (var : LAst.variable) : Sil.exp = Sil.Var (ident_of_variable var)

let trans_constant : LAst.constant -> Sil.exp = function
  | Cint i -> Sil.Const (Sil.Cint (Sil.Int.of_int i))
  | Cnull -> Sil.exp_null

let trans_operand : LAst.operand -> Sil.exp = function
  | Var var -> trans_variable var
  | Const const -> trans_constant const

let rec trans_typ : LAst.typ -> Sil.typ = function
  | Tint i -> Sil.Tint Sil.IInt (* TODO: check what size int is needed here *)
  | Tfloat -> Sil.Tfloat Sil.FFloat
  | Tptr tp -> Sil.Tptr (trans_typ tp, Sil.Pk_pointer)
  | Tvector (i, tp)
  | Tarray (i, tp) -> Sil.Tarray (trans_typ tp, Sil.Const (Sil.Cint (Sil.Int.of_int i)))
  | Tlabel -> raise (ImproperTypeError "Tried to generate Sil type from LLVM label type.")
  | Tmetadata -> raise (ImproperTypeError "Tried to generate Sil type from LLVM metadata type.")

let trans_instr (cfg : Cfg.cfg) (pdesc : Cfg.Procdesc.t) : LAst.instr -> Sil.instr list = function
  | Ret None -> []
  | Ret (Some (tp, exp)) ->
      let ret_var = Sil.get_ret_pvar (Cfg.Procdesc.get_proc_name pdesc) in
      [Sil.Set (Sil.Lvar ret_var, trans_typ tp, trans_operand exp, Sil.dummy_location)]
  | Load (var, tp, ptr) ->
      [Sil.Letderef (ident_of_variable var, trans_variable ptr, trans_typ tp, Sil.dummy_location)]
  | Store (op, tp, var) ->
      [Sil.Set (trans_variable var, trans_typ tp, trans_operand op, Sil.dummy_location)]
  | _ -> raise (Unimplemented "Need to translate instruction to SIL.")

(* Update CFG and call graph with new function definition *)
let trans_func_def (cfg : Cfg.cfg) (cg: Cg.t) : LAst.func_def -> unit = function
    FuncDef (func_name, ret_tp_opt, params, instrs) ->
      let (proc_attrs : Sil.proc_attributes) =
        let open Sil in
        { access = Sil.Default;
          exceptions = [];
          is_abstract = false;
          is_bridge_method = false;
          is_objc_instance_method = false;
          is_synthetic_method = false;
          language = Sil.C_CPP;
          func_attributes = [];
          method_annotation = Sil.method_annotation_empty;
          is_generated = false
        } in
      let (procdesc_builder : Cfg.Procdesc.proc_desc_builder) =
        let open Cfg.Procdesc in
        { cfg = cfg;
          name = Procname.from_string_c_fun (LAst.string_of_variable func_name);
          is_defined = true; (** is defined and not just declared *)
          proc_attributes = proc_attrs;
          ret_type = (match ret_tp_opt with
              | None -> Sil.Tvoid
              | Some ret_tp -> trans_typ ret_tp);
          formals = List.map (fun (tp, name) -> (name, trans_typ tp)) params;
          locals = []; (* TODO *)
          captured = [];
          loc = Sil.dummy_location
        } in
      let procdesc = Cfg.Procdesc.create procdesc_builder in
      let procname = Cfg.Procdesc.get_proc_name procdesc in
      let start_kind = Cfg.Node.Start_node procdesc in
      let start_node = Cfg.Node.create cfg Sil.dummy_location start_kind [] procdesc [] in
      let exit_kind = Cfg.Node.Exit_node procdesc in
      let exit_node = Cfg.Node.create cfg Sil.dummy_location exit_kind [] procdesc [] in
      let nodekind_of_instr : LAst.instr -> Cfg.Node.nodekind = function
        | Ret _ | Load _ | Store _ -> Cfg.Node.Stmt_node "method_body"
        | _ -> raise (Unimplemented "Need to get node type for instruction.") in
      let node_of_instr (cfg : Cfg.cfg) (procdesc : Cfg.Procdesc.t) (instr : LAst.instr) : Cfg.Node.t =
        Cfg.Node.create cfg Sil.dummy_location (nodekind_of_instr instr) (trans_instr cfg procdesc instr) procdesc [] in
      let rec link_nodes (start_node : Cfg.Node.t) : Cfg.Node.t list -> unit = function
        (* link all nodes in a chain for now *)
        | [] -> Cfg.Node.set_succs_exn start_node [exit_node] [exit_node]
        | nd :: nds -> Cfg.Node.set_succs_exn start_node [nd] [exit_node]; link_nodes nd nds in
      let nodes = List.map (node_of_instr cfg procdesc) instrs in
      Cfg.Procdesc.set_start_node procdesc start_node;
      Cfg.Procdesc.set_exit_node procdesc exit_node;
      link_nodes start_node nodes;
      Cg.add_node cg procname

let trans_prog : LAst.prog -> Cfg.cfg * Cg.t * Sil.tenv = function
    Prog func_defs ->
      let cfg = Cfg.Node.create_cfg () in
      let cg = Cg.create () in
      let tenv = Sil.create_tenv () in
      List.iter (trans_func_def cfg cg) func_defs;
      (cfg, cg, tenv)
