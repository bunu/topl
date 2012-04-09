(* modules *) (* {{{ *)
open Debug
open Format
open Util.Operators

module B = BaristaLibrary
module BC = BaristaLibrary.Coder
module BD = BaristaLibrary.Descriptor
module BH = BaristaLibrary.HighTypes
module BU = BaristaLibrary.Utils
module PA = PropAst
module U = Util

(* }}} *)
(* globals *) (* {{{ *)
let out_dir = ref "out"

(* }}} *)
(* used to communicate between conversion and instrumentation *) (* {{{ *)
type method_ =  (* TODO: Use [PropAst.event_tag] instead? *)
  { method_name : string
  ; method_arity : int }

(* }}} *)
(* representation of automata in Java *) (* {{{ *)

(*
  The instrumenter has three phases:
    - convert the automaton to an intermediate representation
    - instrument the bytecode
    - emit the Java representation of the automaton
  A pattern like "c.m()" in the property matches method m in all classes that
  extend c (including c itself). For efficiency, the Java automaton does not
  know anything about inheritance. While the bytecode is instrumented all the
  methods m in classes extending c get unique identifiers and the pattern
  "c.m()" is mapped to the set of those identifiers.

  The (first) conversion
    - goes from edge list to adjacency list
    - glues all input properties into one
    - changes the vertex representation from strings to integers
    - changes automaton variable representation from strings to integers
    - normalizes method patterns (by processing "using prefix", ... )
    - collects all patterns
  During printing a bit more processing is needed to go to the Java
  representation, but only very simple stuff.
 *)

(* shorthands for old types, those that come from prop.mly *)
type property = (string, string) PA.t
type tag_guard = PA.pattern PA.tag_guard

(* shorthands for new types, those used in Java *)
type tag = int
type vertex = int
type variable = int
type value = string (* Java literal *)

type transition =
  { steps : (PA.pattern, variable, value) PA.label list
  ; target : vertex }

type vertex_data =
  { vertex_property : property
  ; vertex_name : PA.vertex
  ; outgoing_transitions : transition list }

type automaton =
  { vertices : vertex_data array
  ; observables : (property, tag_guard) Hashtbl.t
  ; pattern_tags : (tag_guard, tag list) Hashtbl.t
  (* The keys of [pattern_tags] are filled in during the initial conversion,
    but the values (the tag list) is filled in while the code is being
    instrumented. *)
  ; event_names : (int, string) Hashtbl.t }

let check_automaton x =
  let rec is_decreasing x = function
    | [] -> true
    | y :: ys -> x >= y && is_decreasing y ys in
  let ok _ v = assert (is_decreasing max_int v) in
  Hashtbl.iter ok x.pattern_tags

(* }}} *)
(* small functions that help handling automata *) (* {{{ *)
let to_ints xs =
  let h = Hashtbl.create 101 in
  let c = ref (-1) in
  let f x = if not (Hashtbl.mem h x) then (incr c; Hashtbl.add h x !c) in
  List.iter f xs; h

let inverse_index f h =
  let r = Array.make (Hashtbl.length h) None in
  let one k v = assert (r.(v) = None); r.(v) <- Some (f k) in
  Hashtbl.iter one h;
  Array.map U.from_some r

let get_properties x =
  x.vertices >> Array.map (fun v -> v.vertex_property) >> Array.to_list

let get_vertices p =
  let f acc t = t.PA.source :: t.PA.target :: acc in
  "start" :: "error" :: List.fold_left f [] p.PA.transitions

(* }}} *)
(* pretty printing to Java *) (* {{{ *)

let array_foldi f z xs =
  let r = ref z in
  for i = 0 to Array.length xs - 1 do r := f !r i xs.(i) done;
  !r

let starts x =
  let f ks k = function
    | {vertex_name="start";_} -> k :: ks
    | _ -> ks in
  array_foldi f [] x.vertices

(* TODO(rgrig): Escape properly. *)
let mk_java_string_literal s =
  Printf.sprintf "\"%s\"" s

let errors x =
  let f = function
    | {vertex_name="error"; vertex_property={PA.message=e;_};_} ->
        mk_java_string_literal e
    | _ -> "null" in
  x.vertices >> Array.map f >> Array.to_list

let rec pp_v_list pe ppf = function
  | [] -> ()
  | [x] -> fprintf ppf "@\n%a" pe x
  | x :: xs -> fprintf ppf "@\n%a,%a" pe x (pp_v_list pe) xs

let pp_int f x = fprintf f "%d" x
let pp_string f x = fprintf f "%s" x
let pp_string_as_int ios f s = pp_int f (Hashtbl.find ios s)
let pp_string_literal ios f s =
  pp_string_as_int ios f (mk_java_string_literal s)
let pp_list pe f x =
  fprintf f "@[<2>%d@ %a@]" (List.length x) (U.pp_list " " pe) x
let pp_array pe f x = pp_list pe f (Array.to_list x)

let pp_value_guard ioc f = function
  | PA.Variable (v, i) -> fprintf f "0 %d %d" i v
  | PA.Constant (c, i) -> fprintf f "1 %d %a" i (pp_string_as_int ioc) c

let pp_pattern tags f p =
  fprintf f "%a" (pp_list pp_int) (Hashtbl.find tags p)

let pp_condition ioc = pp_list (pp_value_guard ioc)

let pp_assignment f (x, i) =
  fprintf f "%d %d" x i

let pp_guard tags ioc f { PA.tag_guard = p; PA.value_guards = cs } =
  fprintf f "%a %a" (pp_pattern tags) p (pp_condition ioc) cs

let pp_action = pp_list pp_assignment

let pp_step tags ioc f { PA.guard = g; PA.action = a } =
  fprintf f "%a %a" (pp_guard tags ioc) g pp_action a

let pp_transition tags ioc f { steps = ss; target = t } =
  fprintf f "%a %d" (pp_list (pp_step tags ioc)) ss t

let pp_vertex tags ioc f v =
  fprintf f "%a %a"
    (pp_string_literal ioc) v.vertex_name
    (pp_list (pp_transition tags ioc)) v.outgoing_transitions

let list_of_hash h =
  let r = ref [] in
  for i = Hashtbl.length h - 1 downto 0 do
    r := Hashtbl.find h i :: !r
  done;
  !r

let pp_automaton ioc f x =
  let obs_p p = Hashtbl.find x.pattern_tags (Hashtbl.find x.observables p) in
  let iop = to_ints (get_properties x) in
  let poi = inverse_index (fun p -> p) iop in
  let pov =
    Array.map (fun v -> Hashtbl.find iop v.vertex_property) x.vertices in
  let obs_tags = Array.to_list (Array.map obs_p poi) in
  fprintf f "%a@\n" (pp_list pp_int) (starts x);
  fprintf f "%a@\n" (pp_list (pp_string_as_int ioc)) (errors x);
  fprintf f "%a@\n" (pp_array (pp_vertex x.pattern_tags ioc)) x.vertices;
  fprintf f "%a@\n" (pp_array pp_int) pov;
  fprintf f "%a@\n" (pp_list (pp_list pp_int)) obs_tags;
  fprintf f "%a@\n"
    (pp_list (pp_string_literal ioc)) (list_of_hash x.event_names)

let index_constants p =
  let r = Hashtbl.create 0 in (* maps constants to their index *)
  let i = ref (-1) in
  let add c = if not (Hashtbl.mem r c) then Hashtbl.add r c (incr i; !i) in
  let add_js s = add (mk_java_string_literal s) in
  let value_guard = function PA.Constant (c, _) -> add c | _ -> () in
  let event_guard g = List.iter value_guard g.PA.value_guards in
  let label l = event_guard l.PA.guard in
  let transition t = List.iter label t.steps in
  let vertex_data v =
    add_js v.vertex_name; List.iter transition v.outgoing_transitions in
  Array.iter vertex_data p.vertices;
  U.hashtbl_fold_values (fun en () -> add_js en) p.event_names ();
  List.iter add (errors p);
  r

let pp_constants j constants =
  let constants = Array.to_list constants in
  fprintf j "@[";
  fprintf j "package topl;@\n";
  fprintf j "@[<2>public class Property {";
  fprintf j "@\n@[<2>public static final Object[] constants =@ ";
  fprintf j   "new Object[]{%a@]};" (pp_v_list pp_string) constants;
  fprintf j "@\n@[<2>public static final Checker checker =@ ";
  fprintf j   "Checker.Parser.checker(\"topl\" + java.io.File.separator + \"Property.text\",@ constants);@]";
  fprintf j "@\n@[static { checker.checkerEnabled = true; }@]";
  fprintf j "@]@\n}@]"

let generate_checkers out_dir p =
  check_automaton p;
  let (/) = Filename.concat in
  U.cp_r (Config.src_dir/"topl") out_dir;
  let topl_dir = out_dir/"topl" in
  U.mkdir_p topl_dir;
  let o n =
    let c = open_out (topl_dir/("Property." ^ n)) in
    let f = formatter_of_out_channel c in
    (c, f) in
  let (jc, j), (tc, t) = o "java", o "text" in
  let ioc = index_constants p in
  let coi = inverse_index (fun x -> x) ioc in
  fprintf j "@[%a@." pp_constants coi;
  fprintf t "@[%a@." (pp_automaton ioc) p;
  List.iter close_out_noerr [jc; tc];
  ignore (Sys.command
    (Printf.sprintf
      "javac -sourcepath %s %s"
      (U.command_escape out_dir)
      (U.command_escape (topl_dir/"Property.java"))))

(* }}} *)
(* conversion to Java representation *) (* {{{ *)

let index_for_var ifv v =
  try
    Hashtbl.find ifv v
  with Not_found ->
    let i = Hashtbl.length ifv in
      Hashtbl.replace ifv v i; i

let transform_tag_guard ptags tg =
  Hashtbl.replace ptags tg []; tg

let transform_value_guard ifv = function
  | PA.Variable (v, i) -> PA.Variable (index_for_var ifv v, i)
  | PA.Constant (c, i) -> PA.Constant (c, i)

let transform_guard ifv ptags {PA.tag_guard=tg; PA.value_guards=vgs} =
  { PA.tag_guard = transform_tag_guard ptags tg
  ; PA.value_guards = List.map (transform_value_guard ifv) vgs }

let transform_condition ifv (store_var, event_index) =
  let store_index = index_for_var ifv store_var in
    (store_index, event_index)

let transform_action ifv a = List.map (transform_condition ifv) a

let transform_label ifv ptags {PA.guard=g; PA.action=a} =
  { PA.guard = transform_guard ifv ptags g
  ; PA.action = transform_action ifv a }

let transform_properties ps =
  let vs p = p >> get_vertices >> List.map (fun v -> (p, v)) in
  let iov = to_ints (ps >>= vs) in
  let mk_vd (p, v) =
    { vertex_property = p
    ; vertex_name = v
    ; outgoing_transitions = [] } in
  let full_p =
    { vertices = inverse_index mk_vd iov
    ; observables = Hashtbl.create 0
    ; pattern_tags = Hashtbl.create 0
    ; event_names = Hashtbl.create 0 } in
  let add_obs_tags p =
    let obs_tag =
      { PA.event_type = None
      ; PA.method_name = p.PA.observable
      ; PA.method_arity = (0, None) } in
    Hashtbl.replace full_p.pattern_tags obs_tag [];
    Hashtbl.replace full_p.observables p obs_tag in
  List.iter add_obs_tags ps;
  let add_transition vi t =
    let vs = full_p.vertices in
    let ts = vs.(vi).outgoing_transitions in
    vs.(vi) <- { vs.(vi) with outgoing_transitions = t :: ts } in
  let ifv = Hashtbl.create 0 in (* variable, string -> integer *)
  let pe p {PA.source=s;PA.target=t;PA.labels=ls} =
    let s = Hashtbl.find iov (p, s) in
    let t = Hashtbl.find iov (p, t) in
    let ls = List.map (transform_label ifv full_p.pattern_tags) ls in
    add_transition s {steps=ls; target=t} in
  List.iter (fun p -> List.iter (pe p) p.PA.transitions) ps;
  full_p

(* }}} *)
(* bytecode instrumentation *) (* {{{ *)

let utf8 = B.Utils.UTF8.of_string
let utf8_for_class x = B.Name.make_for_class_from_external (utf8 x)
let utf8_for_field x = B.Name.make_for_field (utf8 x)
let utf8_for_method x = B.Name.make_for_method (utf8 x)
let java_lang_Object = utf8_for_class "java.lang.Object"
let out = utf8_for_field "out"
let println = utf8_for_method "println"
let event = utf8_for_class "topl.Checker$Event"
let init = utf8_for_method "<init>"
let property = utf8_for_class "topl.Property"
let property_checker = utf8_for_field "checker"
let checker = utf8_for_class "topl.Checker"
let check = utf8_for_method "check"

(* helpers for handling bytecode of methods *) (* {{{ *)
let bm_parameters c =
  let rec tag_from k = function
    | [] -> []
    | x :: xs -> (k, x) :: tag_from (succ k) xs in
  function
    | BH.RegularMethod m -> tag_from 0
        ((if List.mem `Static m.BH.rm_flags then [] else [`Class c])
        @ fst m.BH.rm_descriptor)
    | BH.InitMethod m -> tag_from 1 m.BH.im_descriptor
    | BH.ClinitMethod _ -> []

let bm_return c = function
  | BH.RegularMethod m -> snd m.BH.rm_descriptor
  | BH.InitMethod _ -> `Class c
  | BH.ClinitMethod _ -> `Void

let bm_name = function
  | BH.RegularMethod r ->
      B.Utils.UTF8.to_string (B.Name.utf8_for_method r.BH.rm_name)
  | BH.InitMethod _ -> "<init>"
  | BH.ClinitMethod _ -> "<clinit>"

let bm_attributes = function
  | BH.RegularMethod m -> m.BH.rm_attributes
  | BH.InitMethod m -> m.BH.im_attributes
  | BH.ClinitMethod m -> m.BH.cm_attributes

let bm_locals_count m =
  let rec f = function
    | [] -> -12436 (* to cause a crash if used later *)
    | `Code c :: _ ->
        succ
          (try fst (BU.IntMap.max_binding c.BH.cv_type_of_local)
          with Not_found -> -1)
    | _ :: xs -> f xs in
  f (bm_attributes m)

let bm_is_init = function
  | BH.InitMethod _ -> true
  | _ -> false

let bm_map_attributes f = function
  | BH.RegularMethod r ->
      BH.RegularMethod { r with BH.rm_attributes = f r.BH.rm_attributes }
  | BH.InitMethod c ->
      BH.InitMethod { c with BH.im_attributes = f c.BH.im_attributes }
  | BH.ClinitMethod i ->
      BH.ClinitMethod { i with BH.cm_attributes = f i.BH.cm_attributes }

(* }}} *)

(* bytecode generating helpers *) (* {{{ *)
let bc_ldc_int i =
  [ BH.LDC (`Int (Int32.of_int i)) ]

let bc_new_object_array size = List.concat
  [ bc_ldc_int size
  ; [ BH.ANEWARRAY (`Class_or_interface java_lang_Object) ] ]

let bc_box = function
  | `Class _ | `Array _ -> []
  | t ->
      let c = utf8_for_class ("java.lang." ^ (match t with
        | `Boolean -> "Boolean"
        | `Byte -> "Byte"
        | `Char -> "Character"
        | `Double -> "Double"
        | `Float -> "Float"
        | `Int -> "Integer"
        | `Long -> "Long"
        | `Short -> "Short"
        | _ -> failwith "foo"))
        in
      [BH.INVOKESTATIC (`Methodref
          (`Class_or_interface c,
	  utf8_for_method "valueOf",
          ([t], `Class c)))]

let bc_load i = function
  | `Class _ | `Array _ -> [BH.ALOAD i]
  | `Boolean -> [BH.ILOAD i]
  | `Byte -> [BH.ILOAD i]
  | `Char -> [BH.ILOAD i]
  | `Double -> [BH.DLOAD i]
  | `Float -> [BH.FLOAD i]
  | `Int -> [BH.ILOAD i]
  | `Long -> [BH.LLOAD i]
  | `Short -> [BH.ILOAD i]
  | `Void -> []

let bc_store i = function
  | `Class _ | `Array _ -> [BH.ASTORE i]
  | `Boolean -> [BH.ISTORE i]
  | `Byte -> [BH.ISTORE i]
  | `Char -> [BH.ISTORE i]
  | `Double -> [BH.DSTORE i]
  | `Float -> [BH.FSTORE i]
  | `Int -> [BH.ISTORE i]
  | `Long -> [BH.LSTORE i]
  | `Short -> [BH.ISTORE i]
  | `Void -> []

let bc_dup t =
  [ if BD.size t = 2 then BH.DUP2 else BH.DUP ]

let bc_array_set l a t =
  let t = match t with
    | #BD.for_parameter as t' -> t'
    | _ -> failwith "INTERNAL: trying to record a void" in
  List.concat
    [ [ BH.DUP ]
    ; bc_ldc_int a
    ; bc_load l t
    ; bc_box t
    ; [ BH.AASTORE ] ]

let bc_new_event id = List.concat
  [ [ BH.NEW event
    ; BH.DUP_X1
    ; BH.SWAP ]
  ; bc_ldc_int id
  ; [ BH.SWAP
    ; BH.INVOKESPECIAL (`Methodref (`Class_or_interface
        event, init, ([`Int; `Array (`Class java_lang_Object)], `Void) )) ] ]

let bc_call_checker =
  [ BH.GETSTATIC (`Fieldref (property, property_checker, `Class checker))
  ; BH.SWAP
  ; BH.INVOKEVIRTUAL (`Methodref (`Class_or_interface
      checker, check, ([`Class event], `Void) )) ]

let bc_emit id values = match id with
  | None -> []
  | Some id ->
      let rec set j acc = function
        | (i, t) :: ts -> set (succ i) (bc_array_set i j t :: acc) ts
        | [] -> List.concat acc in
      List.concat
        [ bc_new_object_array (List.length values)
        ; set 0 [] values
        ; bc_new_event id
        ; bc_call_checker ]

(* }}} *)

let does_method_match
  ({ method_name=mn; method_arity=ma }, mt)
  { PA.event_type=t; PA.method_name=re; PA.method_arity=(amin, amax) }
=
  let bamin = amin <= ma in
  let bamax = U.option true ((<=) ma) amax in
  let bt = U.option true ((=) mt) t in
  let bn = PA.pattern_matches re mn in
  let r = bamin && bamax  && bt && bn in
  if log_mm then begin
    printf "@\n@[<2>%s " (if r then "✓" else "✗");
    printf "(%a, %s, %d)@ matches (%a, %s, [%d..%a])@ gives (%b, %b, (%b,%b))@]"
      PA.pp_event_type mt mn ma
      (U.pp_option PA.pp_event_type) t
      re.PA.p_string
      amin
      (U.pp_option U.pp_int) amax
      bt bn bamin bamax
  end;
  r

let get_tag x =
  let cnt = ref (-1) in
  fun t (mns, ma) mn ->
    let en = (* event name *)
      fprintf str_formatter "%a_%s" PA.pp_event_type t mn;
      flush_str_formatter () in
    let fp p acc =
      let cm mn = does_method_match ({method_name=mn; method_arity=ma}, t) p in
      if List.exists cm mns then p :: acc else acc in
    if U.hashtbl_fold_values fp x.observables [] <> [] then begin
      match U.hashtbl_fold_keys fp x.pattern_tags [] with
        | [] -> None
        | ps ->
            incr cnt;
            let at p =
              let ts = Hashtbl.find x.pattern_tags p in
              (* printf "added tag %d\n" !cnt; *)
              Hashtbl.replace x.pattern_tags p (!cnt :: ts);
              Hashtbl.replace x.event_names !cnt en in
            List.iter at ps;
            Some !cnt
    end else None

let put_labels_on =
  List.map (fun x -> (BC.fresh_label (), x))

let rec bc_at_return return_code = function
  | [] -> []
  | ((_, BH.ARETURN) as r) :: xs
  | ((_, BH.DRETURN) as r) :: xs
  | ((_, BH.FRETURN) as r) :: xs
  | ((_, BH.IRETURN) as r) :: xs
  | ((_, BH.LRETURN) as r) :: xs
  | ((_, BH.RETURN) as r) :: xs ->
      put_labels_on return_code
        @ (r :: (bc_at_return return_code xs))
  (* do not instrument RET or WIDERET *)
  | x :: xs -> x :: (bc_at_return return_code xs)

let bc_at_call xs lys =
  put_labels_on xs @ lys

let instrument_code is_init call_id return_id arguments return locals code =
  let if_ b xs = if b then List.concat xs else [] in
  let has = (<>) None in
  let instrument_call = bc_at_call (List.concat
    [ if_ (is_init && has return_id)
      [ bc_load 0 return
      ; bc_store locals return ]
    ; bc_emit call_id arguments ]) in
  let instrument_return = bc_at_return (if_ (has return_id)
    [ if_ (not is_init && return <> `Void)
      [ bc_dup return
      ; bc_store locals return ]
    ; bc_emit return_id (if_ (return <> `Void) [[(locals, return)]]) ]) in
  instrument_call (instrument_return code)

let rec get_ancestors h c =
  let cs = Hashtbl.create 0 in
  let rec ga c =
    if not (Hashtbl.mem cs c) then begin
      Hashtbl.add cs c ();
      let parents = try Hashtbl.find h c with Not_found -> [] in
      List.iter ga parents
    end in
  ga c;
  U.hashtbl_fold_keys (fun c cs -> c :: cs) cs []

let get_overrides h c m =
  let ancestors = get_ancestors h c in
  let uts = B.Utils.UTF8.to_string in
  let cts c = uts (B.Name.external_utf8_for_class c) in
  let qualify c =  (cts c) ^ "." ^ m.method_name in
  (List.map qualify ancestors, m.method_arity)

let instrument_method get_tag h c m =
  let method_name = bm_name m in
  let arguments = bm_parameters c m in
  let method_arity = List.length arguments in
  let overrides = get_overrides h c {method_name; method_arity} in
  let ic = instrument_code
    (bm_is_init m)
    (get_tag PA.Call overrides method_name)
    (get_tag PA.Return overrides method_name)
    arguments
    (bm_return c m)
    (bm_locals_count m) in
  let ia xs =
    (* NOTE: Uses, but doesn't update cv_type_of_local. *)
    let f = function
      | `Code c -> `Code { c with BH.cv_code = ic c.BH.cv_code }
      | a -> a in
    List.map f xs in
  bm_map_attributes ia m

let pp_class f c =
  let n = B.Name.internal_utf8_for_class c.BH.c_name in
  fprintf f "@[%s@]" (B.Utils.UTF8.to_string n)

let instrument_class get_tag h c =
  if log_cp then printf "@\n@[<2>begin instrument %a" pp_class c;
  let instrumented_methods =
    List.map (instrument_method get_tag h c.BH.c_name) c.BH.c_methods in
  if log_cp then printf "@]@\nend instrument %a@\n" pp_class c;
  {c with BH.c_methods = instrumented_methods}

let compute_inheritance in_dir =
  let h = Hashtbl.create 0 in
  let record_class c =
    let parents = match c.BH.c_extends with
      | None -> c.BH.c_implements
      | Some e -> e :: c.BH.c_implements in
    Hashtbl.replace h c.BH.c_name parents
  in
  ClassMapper.iter in_dir record_class;
  h

(* }}} *)
(* main *) (* {{{ *)

let read_properties fs =
  fs >> List.map Helper.parse >>= List.map (fun x -> x.PA.ast)

exception Bad_arguments of string

let check_work_directory d =
  let e = Bad_arguments ("Bad work directory: " ^ d) in
  try
    let here = Unix.getcwd () in
    let dir = Filename.concat here d in
    let here, dir = (U.normalize_path here, U.normalize_path dir) in
    if U.is_prefix dir here then raise e
  with Not_found -> raise e

let () =
  printf "@[";
  let usage = Printf.sprintf
    "usage: %s -i <dir> [-o <dir>] <topls>" Sys.argv.(0) in
  try
    let fs = ref [] in
    let in_dir = ref None in
    let out_dir = ref None in
    let set_dir r v = match !r with
      | Some _ -> raise (Bad_arguments "Repeated argument.")
      | None -> r := Some v in
    Arg.parse
      [ "-i", Arg.String (set_dir in_dir), "input directory"
      ; "-o", Arg.String (set_dir out_dir), "output directory" ]
      (fun x -> fs := x :: !fs)
      usage;
    if !in_dir = None then raise (Bad_arguments "Missing input directory.");
    if !out_dir = None then out_dir := !in_dir;
    let in_dir, out_dir = U.from_some !in_dir, U.from_some !out_dir in
    let tmp_dir = U.temp_path "toplc_" in
    List.iter check_work_directory [in_dir; out_dir; tmp_dir];
    let ps = read_properties !fs in
    let h = compute_inheritance in_dir in
    let p = transform_properties ps in
    ClassMapper.map in_dir tmp_dir (instrument_class (get_tag p) h);
    generate_checkers tmp_dir p;
    U.rm_r out_dir;
    U.rename tmp_dir out_dir;
    printf "@."
  with
    | Bad_arguments m
    | Helper.Parsing_failed m
(*     | Sys_error m *)
        -> eprintf "@[ERROR: %s@." m; printf "@."

(* }}} *)
