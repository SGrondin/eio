module Fiber_context = Eio.Private.Fiber_context
module Lf_queue = Eio_utils.Lf_queue

exception Deadlock_detected

(* The scheduler could just return [unit], but this is clearer. *)
type exit = Exit_scheduler

type t = {
  (* Suspended fibers waiting to run again.
     [Lf_queue] is like [Stdlib.Queue], but is thread-safe (lock-free) and
     allows pushing items to the head too, which we need. *)
  run_q : (unit -> exit) Lf_queue.t;
}

(* Resume the next runnable fiber, if any. *)
let schedule t : exit =
  match Lf_queue.pop t.run_q with
  | Some f -> f ()
  | None -> Exit_scheduler      (* Finished (or deadlocked) *)

type _ Effect.t += Suspend_until_stable : (('a -> 'a) -> 'a) -> 'a Effect.t

let yield_until_stable () = Effect.perform (Suspend_until_stable (fun _ -> ()))

(* Run [main] in an Eio main loop. *)
let run main =
  let t = { run_q = Lf_queue.create () } in
  let rec fork ~new_fiber:fiber fn =
    (* Create a new fiber and run [fn] in it. *)
    Effect.Deep.match_with fn ()
      { retc = (fun () -> Fiber_context.destroy fiber; schedule t);
        exnc = (fun ex ->
            let bt = Printexc.get_raw_backtrace () in
            Fiber_context.destroy fiber;
            Printexc.raise_with_backtrace ex bt
          );
        effc = fun (type a) (e : a Effect.t) : ((a, exit) Effect.Deep.continuation -> exit) option ->
          match e with
          | Eio.Private.Effects.Suspend f -> Some (fun k ->
              (* Ask [f] to register whatever callbacks are needed to resume the fiber.
                 e.g. it might register a callback with a promise, for when that's resolved. *)
              f fiber (fun result ->
                  (* The fiber is ready to run again. Add it to the queue. *)
                  Lf_queue.push t.run_q (fun () ->
                      (* Resume the fiber. *)
                      Fiber_context.clear_cancel_fn fiber;
                      match result with
                      | Ok v -> Effect.Deep.continue k v
                      | Error ex -> Effect.Deep.discontinue k ex
                    )
                );
              (* Switch to the next runnable fiber while this one's blocked. *)
              schedule t
            )
          | Suspend_until_stable f ->
            Some (fun k ->
              let Exit_scheduler = schedule t in
              let result = f Fun.id in
              Fiber_context.clear_cancel_fn fiber;
              Effect.Deep.continue k result
            )
          | Eio.Private.Effects.Fork (new_fiber, f) -> Some (fun k ->
              (* Arrange for the forking fiber to run immediately after the new one. *)
              Lf_queue.push_head t.run_q (Effect.Deep.continue k);
              (* Create and run the new fiber (using fiber context [new_fiber]). *)
              fork ~new_fiber f
            )
          | Eio.Private.Effects.Get_context -> Some (fun k ->
              Effect.Deep.continue k fiber
            )
          | _ -> None
      }
  in
  let new_fiber = Fiber_context.make_root () in
  let result = ref None in
  let Exit_scheduler =
    Domain_local_await.using
      ~prepare_for_await:Eio.Private.Dla.prepare_for_await
      ~while_running:(fun () ->
        fork ~new_fiber (fun () -> result := Some (main ()))) in
  match !result with
  | None -> raise Deadlock_detected
  | Some x -> x
