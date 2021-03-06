(*
 * This file is part of froc, a library for functional reactive programming
 * Copyright (C) 2009-2010 Jacob Donham
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 * License along with this library; if not, write to the Free
 * Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
 * MA 02111-1307, USA
 *)

IFDEF OCAMLJS
THEN
open Ocamljs.Inline
ENDIF

module Dlist = Froc_dlist
module TS = Froc_timestamp

let debug = ref ignore

let set_debug f =
  debug := f;
  TS.set_debug f

let handle_exn = ref raise
let set_exn_handler h = handle_exn := h

type +'a result = Value of 'a | Fail of exn

type 'a changeable = {
  id : int;
  eq : 'a -> 'a -> bool;
  mutable state : 'a result;
  mutable deps : ('a result -> unit) Dlist.t;
}

type 'a repr = Constant of int * 'a result | Changeable of 'a changeable

type +'a t
type -'a u

external t_of_repr : 'a repr -> 'a t = "%identity"
external repr_of_t : 'a t -> 'a repr = "%identity"
external u_of_changeable : 'a changeable -> 'a u = "%identity"
external changeable_of_u : 'a u -> 'a changeable = "%identity"

let total_eq v1 v2 = try compare v1 v2 = 0 with _ -> false

let hash t =
  match repr_of_t t with
    | Constant (id, _) -> id
    | Changeable c -> c.id

exception Unset

let next_id =
  let next_id = ref 1 in
  fun () -> let id = !next_id in incr next_id; id

let unset = Fail Unset

let make_changeable
    ?(eq = total_eq)
    ?(result = unset)
    () =
  let c = {
    id = next_id ();
    eq = eq;
    state = result;
    deps = Dlist.empty ();
  } in
  t_of_repr (Changeable c), u_of_changeable c

let make_constant result = t_of_repr (Constant (next_id (), result))

let changeable ?eq v = make_changeable ?eq ~result:(Value v) ()
let return v = make_constant (Value v)
let fail e = make_constant (Fail e)

let is_constant t =
  match repr_of_t t with Constant _ -> true | _ -> false

let clear u =
  let c = changeable_of_u u in
  c.state <- unset

let write_result u r =
  let c = changeable_of_u u in
  let eq =
    match c.state, r with
      | Value v1, Value v2 -> c.eq v1 v2
      | Fail e1, Fail e2 -> e1 == e2 (* XXX ? *)
      | _ -> false in
  if not eq
  then begin
    c.state <- r;
    Dlist.iter (fun f -> f r) c.deps
  end

let write_result_no_eq u r =
  let c = changeable_of_u u in
  c.state <- r;
  Dlist.iter (fun f -> f r) c.deps

let write u v = write_result u (Value v)
let write_exn u e = write_result u (Fail e)

let read_result t =
  match repr_of_t t with
    | Constant (_, r) -> r
    | Changeable c -> c.state

let read t =
  match read_result t with
    | Value v -> v
    | Fail e -> raise e

type cancel = unit -> unit
let make_cancel f = f
let no_cancel = ignore
let cancel c = c ()

let add_dep_cancel ts t dep =
  let cancel =
    match repr_of_t t with
      | Constant _ -> no_cancel
      | Changeable c ->
          let dl = Dlist.add_after c.deps dep in
          make_cancel (fun () -> Dlist.remove dl) in
  TS.add_cleanup ts cancel;
  cancel

let add_dep ts t dep = let _ = add_dep_cancel ts t dep in ()

type reader = {
  read : unit -> unit;
  start : TS.t;
  finish : TS.t;
}

module PQ : sig
  type t
  val make : unit -> t
  val is_empty : t -> bool
  val add : t -> reader -> unit
  val find_min : t -> reader
  val remove_min : t -> unit
end =
struct
  (* derived from module H in react.ml, Copyright Daniel C. Bünzli. *)

  type t = { mutable arr : reader array; mutable len : int }

  let make () = { arr = [||]; len = 0; }

  let is_empty t = t.len = 0

  let size t = t.len

  let compare_down h i i' =
    let t1 = (Array.unsafe_get h.arr i).start in
    let t2 = (Array.unsafe_get h.arr i').start in
    match TS.is_spliced_out t1, TS.is_spliced_out t2 with
      | true, true -> 0
      | true, false -> -1
      | false, true -> 1
      | _ -> TS.compare t1 t2

  let swap h i i' =
    let t = Array.unsafe_get h.arr i in
    Array.unsafe_set h.arr i (Array.unsafe_get h.arr i');
    Array.unsafe_set h.arr i' t

  let rem_last h = let l = h.len - 1 in (h.len <- l; Array.unsafe_set h.arr l (Obj.magic None))

  let rec down h i =
    let last = size h - 1 in
    let start = 2 * i in
    let l = start + 1 in                                (* left child index. *) 
    let r = start + 2 in                               (* right child index. *)
    if l > last then () (* no child, stop *) else
    let child =                                  (* index of smallest child. *)
      if r > last then l else (if compare_down h l r < 0 then l else r)
    in
    if compare_down h i child > 0 then (swap h i child; down h child)

  let up h i =
    let rec aux h i last_spliced_out =
      if i = 0 then (if last_spliced_out then down h 0) else
      let p = (i - 1) / 2 in                                (* parent index. *)
      let t1 = (Array.unsafe_get h.arr i).start in
      let t2 = (Array.unsafe_get h.arr p).start in
      match TS.is_spliced_out t1, TS.is_spliced_out t2 with
        | false, false ->
            if TS.compare t1 t2 < 0 then (swap h i p; aux h p false) else
              (if last_spliced_out then down h i)
        | false, true ->
            swap h i p; aux h p true
        | true, _ -> assert false
    in
    aux h i false

  let grow h =
    let len = 2 * h.len + 1 in
    IFDEF OCAMLJS
    THEN
      << $h.arr$.length = $len$; >>
    ELSE
      let arr' = Array.make len (Obj.magic None) in
      Array.blit h.arr 0 arr' 0 h.len;
      h.arr <- arr'
    ENDIF

  let add h n =
    if h.len = Array.length h.arr then grow h;
    Array.unsafe_set h.arr h.len n;
    h.len <- h.len + 1;
    up h (size h - 1)

  let rec remove_min h = 
    let s = size h in
    if s = 0 then () else
    if s > 1 then 
      (Array.unsafe_set h.arr 0 (Array.unsafe_get h.arr (s - 1)); rem_last h; down h 0)
    else
      rem_last h

  let find_min h =
    if is_empty h
    then raise Not_found
    else Array.unsafe_get h.arr 0
end

let pq = ref (PQ.make ())

let init () =
  TS.init ();
  pq := PQ.make ()

let enqueue e = PQ.add !pq e

let read_now ?(now=true) read =
  if now then read
  else
    let notify = ref false in
    fun () -> if not !notify then notify := true else read ()

let add_reader_cancel ?now t read =
  let read = read_now ?now read in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  let dep _ = enqueue r in
  add_dep_cancel start t dep

let add_reader ?now t read = let _ = add_reader_cancel ?now t read in ()

let connect_cancel u t' =
  write_result u (read_result t');
  add_dep_cancel (TS.tick ()) t' (write_result_no_eq u)

let connect u t' =
  write_result u (read_result t');
  add_dep (TS.tick ()) t' (write_result_no_eq u)

let notify_result_cancel ?now t f =
  add_reader_cancel ?now t begin fun () ->
    try f (read_result t) with e -> !handle_exn e
  end

let notify_result ?now t f = let _ = notify_result_cancel ?now t f in ()

let notify_cancel ?now t f =
  notify_result_cancel ?now t (function Fail _ -> () | Value v -> f v)

let notify ?now t f =
  notify_result ?now t (function Fail _ -> () | Value v -> f v)

let cleanup f =
  TS.add_cleanup (TS.tick ()) f

external identity : 'a -> 'a = "%identity"

let bind_gen ?eq return assign f t =
  match repr_of_t t with
    | Constant (_, Fail e) -> fail e
    | Constant (_, Value v) -> (try return (f v) with e -> fail e)
    | _ ->
        let rt, ru = make_changeable ?eq () in
        add_reader t begin fun () ->
          match read_result t with
            | Fail e -> write_exn ru e
            | Value v -> try assign ru (f v) with e -> write_exn ru e
        end;
        rt

let bind ?eq t f = bind_gen ?eq identity connect f t
let (>>=) t f = bind t f
let lift ?eq f = bind_gen ?eq return write f
let blift ?eq t f = lift ?eq f t

let try_bind_gen ?eq return assign f succ err =
  let t = try f () with e -> fail e in
  match repr_of_t t with
    | Constant (_, Fail e) -> (try return (err e) with e -> fail e)
    | Constant (_, Value v) -> (try return (succ v) with e -> fail e)
    | _ ->
        let rt, ru = make_changeable ?eq () in
        add_reader t begin fun () ->
          try assign ru (match read_result t with Value v -> succ v | Fail e -> err e)
          with e -> write_exn ru e
        end;
        rt

let try_bind ?eq f succ err = try_bind_gen ?eq identity connect f succ err
let try_bind_lift ?eq f succ err = try_bind_gen ?eq return write f succ err

let catch_gen ?eq return assign f err =
  let t = try f () with e -> fail e in
  match repr_of_t t with
    | Constant (_, Fail e) -> (try return (err e) with e -> fail e)
    | Constant (_, Value _) -> t
    | _ ->
        let rt, ru = make_changeable ?eq () in
        add_reader t begin fun () ->
          match read_result t with
            | Value _ as r -> write_result ru r
            | Fail e -> try assign ru (err e) with e -> write_exn ru e
        end;
        rt

let catch ?eq f err = catch_gen ?eq identity connect f err
let catch_lift ?eq f err = catch_gen return write ?eq f err

let finish = Stack.create ()

let rec prop ?until () =
  if not (PQ.is_empty !pq)
  then
    let r = PQ.find_min !pq in
    if TS.is_spliced_out r.start
    then begin PQ.remove_min !pq; prop ?until () end
    else
      match until with
        | Some until when TS.compare r.start until = 1 -> ()
        | _ ->
            PQ.remove_min !pq;
            TS.set_now r.start;
            Stack.push r.finish finish;
            r.read ();
            ignore (Stack.pop finish);
            TS.splice_out (TS.get_now ()) r.finish;
            prop ?until ()

let propagate () =
  let now' = TS.get_now () in
  prop ();
  TS.set_now now'

type 'a memo = {
  m_result : 'a result;
  m_start : TS.t;
  m_finish : TS.t;
}

let memo ?size ?hash ?eq () =
  let h = Froc_hashtbl.create ?size ?hash ?eq () in
  fun f k ->
    let result =
      try
        if Stack.is_empty finish then raise Not_found;
        let ok m =
          TS.compare (TS.get_now ()) m.m_start = -1 &&
          TS.compare m.m_finish (Stack.top finish) = -1 in
        let m = Froc_hashtbl.find h k ok in
        TS.splice_out (TS.get_now ()) m.m_start;
        prop ~until:m.m_finish ();
        TS.set_now m.m_finish;
        m.m_result
      with Not_found ->
        let start = TS.tick () in
        let result = try Value (f k) with e -> Fail e in
        let finish = TS.tick () in
        let m = { m_result = result; m_start = start; m_finish = finish } in
        Froc_hashtbl.add h k m;
        let cancel () = Froc_hashtbl.remove h k (fun m' -> m' == m) in
        TS.add_cleanup finish cancel;
        result in
    match result with Value v -> v | Fail e -> raise e

let add_reader2 ?now t1 t2 read =
  let read = read_now ?now read in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  let dep _ = enqueue r in
  add_dep start t1 dep;
  add_dep start t2 dep

let bind2_gen ?eq return assign f t1 t2 =
  match repr_of_t t1, repr_of_t t2 with
    | Constant (_, Fail e), _
    | _, Constant (_, Fail e) -> fail e
    | Constant (_, Value v1), Constant (_, Value v2) -> (try return (f v1 v2) with e -> fail e)
    | _ ->
        let rt, ru = make_changeable ?eq () in
        add_reader2 t1 t2 begin fun () ->
          match read_result t1, read_result t2 with
            | Fail e, _
            | _, Fail e -> write_exn ru e
            | Value v1, Value v2 -> try assign ru (f v1 v2) with e -> write_exn ru e
        end;
        rt

let bind2 ?eq t1 t2 f = bind2_gen ?eq identity connect f t1 t2
let lift2 ?eq f = bind2_gen ?eq return write f
let blift2 ?eq t1 t2 f = lift2 ?eq f t1 t2

let add_reader3 ?now t1 t2 t3 read =
  let read = read_now ?now read in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  let dep _ = enqueue r in
  add_dep start t1 dep;
  add_dep start t2 dep;
  add_dep start t3 dep

let bind3_gen ?eq return assign f t1 t2 t3 =
  match repr_of_t t1, repr_of_t t2, repr_of_t t3 with
    | Constant (_, Fail e), _, _
    | _, Constant (_, Fail e), _
    | _, _, Constant (_, Fail e) -> fail e
    | Constant (_, Value v1), Constant (_, Value v2), Constant (_, Value v3) -> (try return (f v1 v2 v3) with e -> fail e)
    | _ ->
        let rt, ru = make_changeable ?eq () in
        add_reader3 t1 t2 t3 begin fun () ->
          match read_result t1, read_result t2, read_result t3 with
            | Fail e, _, _
            | _, Fail e, _
            | _, _, Fail e -> write_exn ru e
            | Value v1, Value v2, Value v3 -> try assign ru (f v1 v2 v3) with e -> write_exn ru e
        end;
        rt

let bind3 ?eq t1 t2 t3 f = bind3_gen ?eq identity connect f t1 t2 t3
let lift3 ?eq f = bind3_gen ?eq return write f
let blift3 ?eq t1 t2 t3 f = lift3 ?eq f t1 t2 t3

let add_reader4 ?now t1 t2 t3 t4 read =
  let read = read_now ?now read in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  let dep _ = enqueue r in
  add_dep start t1 dep;
  add_dep start t2 dep;
  add_dep start t3 dep;
  add_dep start t4 dep

let bind4_gen ?eq return assign f t1 t2 t3 t4 =
  match repr_of_t t1, repr_of_t t2, repr_of_t t3, repr_of_t t4 with
    | Constant (_, Fail e), _, _, _
    | _, Constant (_, Fail e), _, _
    | _, _, Constant (_, Fail e), _
    | _, _, _, Constant (_, Fail e) -> fail e
    | Constant (_, Value v1), Constant (_, Value v2), Constant (_, Value v3), Constant (_, Value v4) ->
        (try return (f v1 v2 v3 v4) with e -> fail e)
    | _ ->
        let rt, ru = make_changeable ?eq () in
        add_reader4 t1 t2 t3 t4 begin fun () ->
          match read_result t1, read_result t2, read_result t3, read_result t4 with
            | Fail e, _, _, _
            | _, Fail e, _, _
            | _, _, Fail e, _
            | _, _, _, Fail e -> write_exn ru e
            | Value v1, Value v2, Value v3, Value v4 ->
                try assign ru (f v1 v2 v3 v4)
                with e -> write_exn ru e
        end;
        rt

let bind4 ?eq t1 t2 t3 t4 f = bind4_gen ?eq identity connect f t1 t2 t3 t4
let lift4 ?eq f = bind4_gen ?eq return write f
let blift4 ?eq t1 t2 t3 t4 f = lift4 ?eq f t1 t2 t3 t4

let add_reader5 ?now t1 t2 t3 t4 t5 read =
  let read = read_now ?now read in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  let dep _ = enqueue r in
  add_dep start t1 dep;
  add_dep start t2 dep;
  add_dep start t3 dep;
  add_dep start t4 dep;
  add_dep start t5 dep

let bind5_gen ?eq return assign f t1 t2 t3 t4 t5 =
  match repr_of_t t1, repr_of_t t2, repr_of_t t3, repr_of_t t4, repr_of_t t5 with
    | Constant (_, Fail e), _, _, _, _
    | _, Constant (_, Fail e), _, _, _
    | _, _, Constant (_, Fail e), _, _
    | _, _, _, Constant (_, Fail e), _
    | _, _, _, _, Constant (_, Fail e) -> fail e
    | Constant (_, Value v1), Constant (_, Value v2), Constant (_, Value v3), Constant (_, Value v4), Constant (_, Value v5) ->
        (try return (f v1 v2 v3 v4 v5) with e -> fail e)
    | _ ->
        let rt, ru = make_changeable ?eq () in
        add_reader5 t1 t2 t3 t4 t5 begin fun () ->
          match read_result t1, read_result t2, read_result t3, read_result t4, read_result t5 with
            | Fail e, _, _, _, _
            | _, Fail e, _, _, _
            | _, _, Fail e, _, _
            | _, _, _, Fail e, _
            | _, _, _, _, Fail e -> write_exn ru e
            | Value v1, Value v2, Value v3, Value v4, Value v5 ->
                try assign ru (f v1 v2 v3 v4 v5)
                with e -> write_exn ru e
        end;
        rt

let bind5 ?eq t1 t2 t3 t4 t5 f = bind5_gen ?eq identity connect f t1 t2 t3 t4 t5
let lift5 ?eq f = bind5_gen ?eq return write f
let blift5 ?eq t1 t2 t3 t4 t5 f = lift5 ?eq f t1 t2 t3 t4 t5

let add_reader6 ?now t1 t2 t3 t4 t5 t6 read =
  let read = read_now ?now read in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  let dep _ = enqueue r in
  add_dep start t1 dep;
  add_dep start t2 dep;
  add_dep start t3 dep;
  add_dep start t4 dep;
  add_dep start t5 dep;
  add_dep start t6 dep

let bind6_gen ?eq return assign f t1 t2 t3 t4 t5 t6 =
  match repr_of_t t1, repr_of_t t2, repr_of_t t3, repr_of_t t4, repr_of_t t5, repr_of_t t6 with
    | Constant (_, Fail e), _, _, _, _, _
    | _, Constant (_, Fail e), _, _, _, _
    | _, _, Constant (_, Fail e), _, _, _
    | _, _, _, Constant (_, Fail e), _, _
    | _, _, _, _, Constant (_, Fail e), _
    | _, _, _, _, _, Constant (_, Fail e) -> fail e
    | Constant (_, Value v1), Constant (_, Value v2), Constant (_, Value v3), Constant (_, Value v4), Constant (_, Value v5),
        Constant (_, Value v6) ->
        (try return (f v1 v2 v3 v4 v5 v6) with e -> fail e)
    | _ ->
        let rt, ru = make_changeable ?eq () in
        add_reader6 t1 t2 t3 t4 t5 t6 begin fun () ->
          match read_result t1, read_result t2, read_result t3, read_result t4, read_result t5, read_result t6 with
            | Fail e, _, _, _, _, _
            | _, Fail e, _, _, _, _
            | _, _, Fail e, _, _, _
            | _, _, _, Fail e, _, _
            | _, _, _, _, Fail e, _
            | _, _, _, _, _, Fail e -> write_exn ru e
            | Value v1, Value v2, Value v3, Value v4, Value v5, Value v6 ->
                try assign ru (f v1 v2 v3 v4 v5 v6)
                with e -> write_exn ru e
        end;
        rt

let bind6 ?eq t1 t2 t3 t4 t5 t6 f = bind6_gen ?eq identity connect f t1 t2 t3 t4 t5 t6
let lift6 ?eq f = bind6_gen ?eq return write f
let blift6 ?eq t1 t2 t3 t4 t5 t6 f = lift6 ?eq f t1 t2 t3 t4 t5 t6

let add_reader7 ?now t1 t2 t3 t4 t5 t6 t7 read =
  let read = read_now ?now read in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  let dep _ = enqueue r in
  add_dep start t1 dep;
  add_dep start t2 dep;
  add_dep start t3 dep;
  add_dep start t4 dep;
  add_dep start t5 dep;
  add_dep start t6 dep;
  add_dep start t7 dep

let bind7_gen ?eq return assign f t1 t2 t3 t4 t5 t6 t7 =
  match repr_of_t t1, repr_of_t t2, repr_of_t t3, repr_of_t t4, repr_of_t t5, repr_of_t t6, repr_of_t t7 with
    | Constant (_, Fail e), _, _, _, _, _, _
    | _, Constant (_, Fail e), _, _, _, _, _
    | _, _, Constant (_, Fail e), _, _, _, _
    | _, _, _, Constant (_, Fail e), _, _, _
    | _, _, _, _, Constant (_, Fail e), _, _
    | _, _, _, _, _, Constant (_, Fail e), _
    | _, _, _, _, _, _, Constant (_, Fail e) -> fail e
    | Constant (_, Value v1), Constant (_, Value v2), Constant (_, Value v3), Constant (_, Value v4), Constant (_, Value v5),
        Constant (_, Value v6), Constant (_, Value v7) ->
        (try return (f v1 v2 v3 v4 v5 v6 v7) with e -> fail e)
    | _ ->
        let rt, ru = make_changeable ?eq () in
        add_reader7 t1 t2 t3 t4 t5 t6 t7 begin fun () ->
          match read_result t1, read_result t2, read_result t3, read_result t4, read_result t5, read_result t6, read_result t7 with
            | Fail e, _, _, _, _, _, _
            | _, Fail e, _, _, _, _, _
            | _, _, Fail e, _, _, _, _
            | _, _, _, Fail e, _, _, _
            | _, _, _, _, Fail e, _, _
            | _, _, _, _, _, Fail e, _
            | _, _, _, _, _, _, Fail e -> write_exn ru e
            | Value v1, Value v2, Value v3, Value v4, Value v5, Value v6, Value v7 ->
                try assign ru (f v1 v2 v3 v4 v5 v6 v7)
                with e -> write_exn ru e
        end;
        rt

let bind7 ?eq t1 t2 t3 t4 t5 t6 t7 f = bind7_gen ?eq identity connect f t1 t2 t3 t4 t5 t6 t7
let lift7 ?eq f = bind7_gen ?eq return write f
let blift7 ?eq t1 t2 t3 t4 t5 t6 t7 f = lift7 ?eq f t1 t2 t3 t4 t5 t6 t7

let add_readerN ?now ts read =
  let read = read_now ?now read in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  let dep _ = enqueue r in
  List.iter (fun t -> add_dep start t dep) ts

let bindN_gen ?eq return assign f ts =
  let rec loop vs = function
    | [] -> (try return (f (List.rev vs)) with e -> fail e)
    | h :: t ->
        match repr_of_t h with
          | Constant (_, Fail e) -> fail e
          | Constant (_, Value v) -> loop (v :: vs) t
          | _ ->
              let rt, ru = make_changeable ?eq () in
              add_readerN ts begin fun () ->
                try
                  let vs = List.map read ts in
                  assign ru (f vs)
                with e -> write_exn ru e
              end;
              rt in
  loop [] ts

let bindN ?eq ts f = bindN_gen ?eq identity connect f ts
let liftN ?eq f = bindN_gen ?eq return write f
let bliftN ?eq ts f = liftN ?eq f ts
