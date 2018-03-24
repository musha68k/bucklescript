(* Copyright (C) 2018 Authors of BuckleScript
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * In addition to the permissions granted to you by the LGPL, you may combine
 * or link a "work that uses the Library" with a publicly distributed version
 * of this file to produce a combined library or application, then distribute
 * that combined work under the terms of your choosing, with no requirement
 * to comply with the obligations normally placed on you by section 4 of the
 * LGPL version 3 (or the corresponding section of a later version of the LGPL
 * should you choose to use a later version).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA. *)

open Ast_helper

let handle_exp_apply
    (e  : Parsetree.expression)
    (self : Bs_ast_mapper.mapper)
    (fn : Parsetree.expression)
    (args : (Asttypes.label * Parsetree.expression) list)
  =
  let loc = e.pexp_loc in
  begin match fn.pexp_desc with
    | Pexp_apply (
           {pexp_desc =
              Pexp_ident  {txt = Lident "##"  ; loc} ; _},
           [("", obj) ;
            ("", {pexp_desc = Pexp_ident {txt = Lident name;_ } ; _} )
           ])
        ->  (* f##paint 1 2 *)
      {e with pexp_desc = Ast_util.method_apply loc self obj name args }
    | Pexp_apply (
           {pexp_desc =
              Pexp_ident  {txt = Lident "#@"  ; loc} ; _},
           [("", obj) ;
            ("", {pexp_desc = Pexp_ident {txt = Lident name;_ } ; _} )
           ])
        ->  (* f##paint 1 2 *)
      {e with pexp_desc = Ast_util.property_apply loc self obj name args  }
    | Pexp_ident {txt = Lident "|."} ->
      (* a |. f b c [@bs]  --> f a b c [@bs]
      *)
      begin match args with
      |  [ "", obj_arg;
           "", ({pexp_desc = Pexp_apply (fn, args)} as app )
        ] ->
          let obj_arg = self.expr self obj_arg in
          let fn = self.expr self fn in
          let args = Ext_list.map (fun (lab,exp) -> lab, self.expr self exp ) args in
          Bs_ast_invariant.warn_unused_attributes app.pexp_attributes;
          { app
            with pexp_desc = Pexp_apply(fn, ("", obj_arg) :: args);
               pexp_attributes = []
          }
       (* a |. f [@bs]
       *)
      | [ "", obj_arg ;
          "", fn
        ] ->
          begin match Ast_tuple_pattern_flatten.map_open_tuple fn (fun xs attrs ->
          {
              pexp_desc =
                Pexp_tuple (Ext_list.map (fun (e : Parsetree.expression) ->
                  Exp.apply ~loc:e.pexp_loc
                    (self.expr self e )
                    ["", self.expr self obj_arg]
                 ) xs );
              pexp_attributes = attrs;
              pexp_loc = fn.pexp_loc;
            }
          )
          with
          | Some x ->
            x

          | None ->
            Exp.apply ~loc (self.expr self fn) ["", self.expr self obj_arg]
          end
      | _ ->
        Location.raise_errorf ~loc
            "invalid |. syntax "
    end

    | Pexp_ident  {txt = Lident "##" ; loc}
      ->
      begin match args with
        | [("", obj) ;
           ("", {pexp_desc = Pexp_apply(
                {pexp_desc = Pexp_ident {txt = Lident name;_ } ; _},
                args
              ); pexp_attributes = attrs }
           (* we should warn when we discard attributes *)
           )
          ] -> (* f##(paint 1 2 ) *)
          (* gpr#1063 foo##(bar##baz) we should rewrite (bar##baz)
             first  before pattern match.
             currently the pattern match is written in a top down style.
             Another corner case: f##(g a b [@bs])
          *)
          Bs_ast_invariant.warn_unused_attributes attrs ;
          {e with pexp_desc = Ast_util.method_apply loc self obj name args}
        | [("", obj) ;
           ("",
            {pexp_desc = Pexp_ident {txt = Lident name;_ } ; _}
           )  (* f##paint  *)
          ] ->
          { e with pexp_desc =
                     Ast_util.js_property loc (self.expr self obj) name
          }

        | _ ->
          Location.raise_errorf ~loc
            "Js object ## expect syntax like obj##(paint (a,b)) "
      end
    (* we can not use [:=] for precedece cases
       like {[i @@ x##length := 3 ]}
       is parsed as {[ (i @@ x##length) := 3]}
       since we allow user to create Js objects in OCaml, it can be of
       ref type
       {[
         let u = object (self)
           val x = ref 3
           method setX x = self##x := 32
           method getX () = !self##x
         end
       ]}
    *)
    | Pexp_ident {txt = Lident "#=" } ->
      begin match args with
        | ["",
           {pexp_desc =
              Pexp_apply ({pexp_desc = Pexp_ident {txt = Lident "##"}},
                          ["", obj;
                           "", {pexp_desc = Pexp_ident {txt = Lident name}}
                          ]
                         )};
           "", arg
          ] ->
          Exp.constraint_ ~loc
            { e with
              pexp_desc =
                Ast_util.method_apply loc self obj
                  (name ^ Literals.setter_suffix) ["", arg ]  }
            (Ast_literal.type_unit ~loc ())
        | _ -> Bs_ast_mapper.default_mapper.expr self e
      end
    | _ ->
      begin match
          Ext_list.exclude_with_val
            Ast_attributes.is_bs e.pexp_attributes with
      | false, _ -> Bs_ast_mapper.default_mapper.expr self e
      | true, pexp_attributes ->
        {e with pexp_desc = Ast_util.uncurry_fn_apply loc self fn args ;
                pexp_attributes }
      end
  end
