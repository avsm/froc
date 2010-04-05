(*
 * This file is part of froc, a library for functional reactive programming
 * Copyright (C) 2009 Jacob Donham
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

module Dlist = Froc_dlist
module TS = Froc_timestamp

let debug = ref ignore

let set_debug f =
  debug := f;
  TS.set_debug f

type 'a result = Value of 'a | Fail of exn

type 'a t = {
  id : int;
  eq : 'a -> 'a -> bool;
  mutable state : 'a result;
  mutable deps : ('a result -> unit) Dlist.t;
}

type reader = {
  read : unit -> unit;
  start : TS.t;
  finish : TS.t;
}

(*
module PQ = Pqueue.Make(struct
  type t = reader
  let compare t1 t2 = TS.compare t1.start t2.start
end)
*)

module PQ : sig
  type elt = reader
  type t
  val empty : t
  val is_empty : t -> bool
  val add : elt -> t -> t
  val find_min : t -> elt
  val remove_min : t -> t
end =
struct
  type elt = reader
  type t = elt Dlist.t
  let empty = Dlist.empty ()
  let is_empty t = t.Dlist.prev == t && t.Dlist.next == t
  let add elt d =
    let rec loop t =
      if t == d || TS.compare elt.start t.Dlist.data.start = -1
      then ignore (Dlist.add_before t elt)
      else loop t.Dlist.next in
    loop d.Dlist.next;
    d
  let find_min t =
    if is_empty t
    then raise Not_found
    else t.Dlist.next.Dlist.data
  let remove_min t =
    if is_empty t
    then ()
    else Dlist.remove t.Dlist.next;
    t
end

let pq = ref (PQ.empty)

let init () =
  TS.init ();
  pq := PQ.empty

let next_id =
  let next_id = ref 1 in
  fun () -> let id = !next_id in incr next_id; id

let total_eq v1 v2 = try compare v1 v2 = 0 with _ -> false

exception Unset

let make
    ?(eq = total_eq)
    ?(result = Fail Unset)
    () = {
  id = next_id ();
  eq = eq;
  state = result;
  deps = Dlist.empty ();
}

let return ?eq v = make ?eq ~result:(Value v) ()
let fail e = make ~result:(Fail e) ()

let handle_exn = ref raise
let set_exn_handler h = handle_exn := h

let write_result t r =
  let eq =
    match t.state, r with
      | Value v1, Value v2 -> t.eq v1 v2
      | Fail e1, Fail e2 -> e1 == e2 (* XXX ? *)
      | _ -> false in
  if not eq
  then begin
    t.state <- r;
    Dlist.iter (fun f -> try f r with e -> !handle_exn e) t.deps
  end

let write t v = write_result t (Value v)
let write_exn t e = write_result t (Fail e)

let read_result t = t.state

let read t =
  match t.state with
    | Value v -> v
    | Fail e -> raise e

let add_dep ts t dep =
  let dl = Dlist.add_after t.deps dep in
  let cancel () = Dlist.remove dl in
  TS.add_cleanup ts cancel

let enqueue e _ = pq := PQ.add e !pq

let add_reader t read =
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  add_dep start t (enqueue r)

let notify t f =
  add_dep (TS.tick ()) t f

let cleanup f =
  TS.set_cleanup (TS.tick ()) f

let connect t t' =
  let f _ = write_result t t'.state in
  f ();
  notify t' f

let never _ _ = false

let bind_gen assign ?eq f t =
  let res = make ?eq () in
  add_reader t (fun () ->
    match t.state with
      | Fail e -> write_exn res e
      | Value v -> try assign res (f v) with e -> write_exn res e);
  res

let bind t f = bind_gen connect ~eq:never f t
let (>>=) = bind
let lift ?eq f = bind_gen write ?eq f
let blift t ?eq f = lift ?eq f t

let try_bind_gen assign f ?eq succ err =
  let t = try f () with e -> fail e in
  let res = make ?eq () in
  add_reader t (fun () ->
    try assign res (match t.state with Value v -> succ v | Fail e -> err e)
    with e -> write_exn res e);
  res

let try_bind f succ err = try_bind_gen connect f ~eq:never succ err
let try_bind_lift f ?eq succ err = try_bind_gen write f ?eq succ err

let catch_gen assign f ?eq err =
  let t = try f () with e -> fail e in
  let res = make ?eq () in
  add_reader t (fun () ->
    match t.state with
      | Value v -> write_result res t.state
      | Fail e -> try assign res (err e) with e -> write_exn res e);
  res

let catch f err = catch_gen connect f ~eq:never err
let catch_lift f ?eq err = catch_gen write f ?eq err

let propagate () =
  let rec prop () =
    if not (PQ.is_empty !pq)
    then
      begin
        let r = PQ.find_min !pq in
        pq := PQ.remove_min !pq;
        if not (TS.is_spliced_out r.start)
        then
          begin
            TS.splice_out r.start r.finish;
            TS.set_now r.start;
            r.read ();
          end;
        prop ()
      end in
  let now' = TS.get_now () in
  prop ();
  TS.set_now now'

let bind2_gen assign ?eq f t1 t2 =
  let res = make ?eq () in
  let read () =
    match t1.state, t2.state with
      | Fail e, _
      | _, Fail e -> write_exn res e
      | Value v1, Value v2 ->
          try assign res (f v1 v2)
          with e -> write_exn res e in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  add_dep start t1 (enqueue r);
  add_dep start t2 (enqueue r);
  res

let bind2 t1 t2 f = bind2_gen connect ~eq:never f t1 t2
let lift2 ?eq f = bind2_gen write ?eq f
let blift2 t1 t2 ?eq f = lift2 ?eq f t1 t2

let bind3_gen assign ?eq f t1 t2 t3 =
  let res = make ?eq () in
  let read () =
    match t1.state, t2.state, t3.state with
      | Fail e, _, _
      | _, Fail e, _
      | _, _, Fail e -> write_exn res e
      | Value v1, Value v2, Value v3 ->
          try assign res (f v1 v2 v3)
          with e -> write_exn res e in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  add_dep start t1 (enqueue r);
  add_dep start t2 (enqueue r);
  add_dep start t3 (enqueue r);
  res

let bind3 t1 t2 t3 f = bind3_gen connect ~eq:never f t1 t2 t3
let lift3 ?eq f = bind3_gen write ?eq f
let blift3 t1 t2 t3 ?eq f = lift3 ?eq f t1 t2 t3

let bind4_gen assign ?eq f t1 t2 t3 t4 =
  let res = make ?eq () in
  let read () =
    match t1.state, t2.state, t3.state, t4.state with
      | Fail e, _, _, _
      | _, Fail e, _, _
      | _, _, Fail e, _
      | _, _, _, Fail e -> write_exn res e
      | Value v1, Value v2, Value v3, Value v4 ->
          try assign res (f v1 v2 v3 v4)
          with e -> write_exn res e in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  add_dep start t1 (enqueue r);
  add_dep start t2 (enqueue r);
  add_dep start t3 (enqueue r);
  add_dep start t4 (enqueue r);
  res

let bind4 t1 t2 t3 t4 f = bind4_gen connect ~eq:never f t1 t2 t3 t4
let lift4 ?eq f = bind4_gen write ?eq f
let blift4 t1 t2 t3 t4 ?eq f = lift4 ?eq f t1 t2 t3 t4

let bind5_gen assign ?eq f t1 t2 t3 t4 t5 =
  let res = make ?eq () in
  let read () =
    match t1.state, t2.state, t3.state, t4.state, t5.state with
      | Fail e, _, _, _, _
      | _, Fail e, _, _, _
      | _, _, Fail e, _, _
      | _, _, _, Fail e, _
      | _, _, _, _, Fail e -> write_exn res e
      | Value v1, Value v2, Value v3, Value v4, Value v5 ->
          try assign res (f v1 v2 v3 v4 v5)
          with e -> write_exn res e in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  add_dep start t1 (enqueue r);
  add_dep start t2 (enqueue r);
  add_dep start t3 (enqueue r);
  add_dep start t4 (enqueue r);
  add_dep start t5 (enqueue r);
  res

let bind5 t1 t2 t3 t4 t5 f = bind5_gen connect ~eq:never f t1 t2 t3 t4 t5
let lift5 ?eq f = bind5_gen write ?eq f
let blift5 t1 t2 t3 t4 t5 ?eq f = lift5 ?eq f t1 t2 t3 t4 t5

let bind6_gen assign ?eq f t1 t2 t3 t4 t5 t6 =
  let res = make ?eq () in
  let read () =
    match t1.state, t2.state, t3.state, t4.state, t5.state, t6.state with
      | Fail e, _, _, _, _, _
      | _, Fail e, _, _, _, _
      | _, _, Fail e, _, _, _
      | _, _, _, Fail e, _, _
      | _, _, _, _, Fail e, _
      | _, _, _, _, _, Fail e -> write_exn res e
      | Value v1, Value v2, Value v3, Value v4, Value v5, Value v6 ->
          try assign res (f v1 v2 v3 v4 v5 v6)
          with e -> write_exn res e in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  add_dep start t1 (enqueue r);
  add_dep start t2 (enqueue r);
  add_dep start t3 (enqueue r);
  add_dep start t4 (enqueue r);
  add_dep start t5 (enqueue r);
  add_dep start t6 (enqueue r);
  res

let bind6 t1 t2 t3 t4 t5 t6 f = bind6_gen connect ~eq:never f t1 t2 t3 t4 t5 t6
let lift6 ?eq f = bind6_gen write ?eq f
let blift6 t1 t2 t3 t4 t5 t6 ?eq f = lift6 ?eq f t1 t2 t3 t4 t5 t6

let bind7_gen assign ?eq f t1 t2 t3 t4 t5 t6 t7 =
  let res = make ?eq () in
  let read () =
    match t1.state, t2.state, t3.state, t4.state, t5.state, t6.state, t7.state with
      | Fail e, _, _, _, _, _, _
      | _, Fail e, _, _, _, _, _
      | _, _, Fail e, _, _, _, _
      | _, _, _, Fail e, _, _, _
      | _, _, _, _, Fail e, _, _
      | _, _, _, _, _, Fail e, _
      | _, _, _, _, _, _, Fail e -> write_exn res e
      | Value v1, Value v2, Value v3, Value v4, Value v5, Value v6, Value v7 ->
          try assign res (f v1 v2 v3 v4 v5 v6 v7)
          with e -> write_exn res e in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  add_dep start t1 (enqueue r);
  add_dep start t2 (enqueue r);
  add_dep start t3 (enqueue r);
  add_dep start t4 (enqueue r);
  add_dep start t5 (enqueue r);
  add_dep start t6 (enqueue r);
  add_dep start t7 (enqueue r);
  res

let bind7 t1 t2 t3 t4 t5 t6 t7 f = bind7_gen connect ~eq:never f t1 t2 t3 t4 t5 t6 t7
let lift7 ?eq f = bind7_gen write ?eq f
let blift7 t1 t2 t3 t4 t5 t6 t7 ?eq f = lift7 ?eq f t1 t2 t3 t4 t5 t6 t7

let bindN_gen assign ?eq f ts =
  let res = make ?eq () in
  let read () =
    try
      let vs =
        List.map
          (fun t -> match t.state with Value v -> v | Fail e -> raise e)
          ts in
      assign res (f vs)
    with e -> write_exn res e in
  let start = TS.tick () in
  read ();
  let r = { read = read; start = start; finish = TS.tick () } in
  List.iter (fun t -> add_dep start t (enqueue r)) ts;
  res

let bindN ts f = bindN_gen connect ~eq:never f ts
let liftN ?eq f = bindN_gen write ?eq f
let bliftN ts ?eq f = liftN ?eq f ts
