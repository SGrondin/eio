open Eio.Std

let n_domains = 4
let n_rounds = 100
let n_procs_per_round_per_domain = 100 / n_domains

let run_in_domain mgr =
  Switch.run @@ fun sw ->
  let _echo n = Eio.Process.parse_out mgr Eio.Buf_read.line ["sh"; "-c"; "sleep 0.2 && echo " ^ string_of_int n] in
  let _echo2 n =
    let pipe1_r, pipe1_w = Eio_unix.pipe sw in
    let fd flow = Eio_unix.Resource.fd flow in
    let read_all pipe =
      let r = Eio.Buf_read.of_flow pipe ~max_size:1024 in
      Eio.Buf_read.take_all r
    in
    let child = Eio_posix.Low_level.Process.spawn ~sw [
      Eio_posix.Low_level.Process.Fork_action.inherit_fds [
        1, fd pipe1_w, `Blocking;
      ];
      Eio_posix.Low_level.Process.Fork_action.execve
        "/bin/sh"
        ~argv:[| "sh"; "-c"; "sleep 0.2 && printf " ^ string_of_int n |]
        ~env:[||]
    ]
    in
    Eio.Flow.close pipe1_w;
    let s = read_all pipe1_r in
    match Promise.await (Eio_posix.Low_level.Process.exit_status child) with
    | WEXITED _ -> s
    | WSIGNALED x ->
      failwith (Format.asprintf "WSIGNALED %a" Fmt.Dump.signal x)
    | WSTOPPED x -> failwith (Format.sprintf "WSTOPPED %d" x)
  in
  for j = 1 to n_procs_per_round_per_domain do
    Fiber.fork ~sw (fun () ->
        let result = _echo2 j in
        assert (int_of_string result = j);
        (* traceln "OK: %d" j *)
      )
  done

let main ~dm mgr =
  let t0 = Unix.gettimeofday () in
  for i = 1 to n_rounds do
    Switch.run (fun sw ->
        for _ = 1 to n_domains - 1 do
          Fiber.fork ~sw (fun () -> Eio.Domain_manager.run dm (fun () -> run_in_domain mgr))
        done;
        Fiber.fork ~sw (fun () -> run_in_domain mgr);
      );
    if true then traceln "Finished round %d/%d" i n_rounds
  done;
  let t1 = Unix.gettimeofday () in
  let n_procs = n_rounds * n_procs_per_round_per_domain * n_domains in
  traceln "Finished process stress test: ran %d processes in %.2fs (using %d domains)" n_procs (t1 -. t0) n_domains

let () =
  Eio_main.run @@ fun env ->
  main ~dm:env#domain_mgr env#process_mgr
