open Lwt.Infix
open Result

module Metrics = struct
  open Prometheus

  let namespace = "DataKit"

  let push_duration_seconds =
    let help = "Time spent auto-pushing branches to remote" in
    Summary.v ~help ~namespace ~subsystem:"git" "push_duration_seconds"
end

let src = Logs.Src.create "Datakit" ~doc:"Datakit 9p server"
module Log = (val Logs.src_log src : Logs.LOG)

let quiet_9p () =
  let srcs = Logs.Src.list () in
  List.iter (fun src ->
      if Logs.Src.name src = "fs9p" then Logs.Src.set_level src (Some Logs.Info)
    ) srcs

let quiet_git () =
  let srcs = Logs.Src.list () in
  List.iter (fun src ->
      if Logs.Src.name src = "git.value" || Logs.Src.name src = "git.memory"
      then Logs.Src.set_level src (Some Logs.Info)
    ) srcs

let quiet_irmin () =
  let srcs = Logs.Src.list () in
  List.iter (fun src ->
      if Logs.Src.name src = "irmin.bc"
      || Logs.Src.name src = "irmin.commit"
      || Logs.Src.name src = "irmin.node"
      then Logs.Src.set_level src (Some Logs.Info)
    ) srcs

let quiet () =
  quiet_9p ();
  quiet_git ();
  quiet_irmin ()

(* Hyper-V socket applications use well-known GUIDs. This is ours: *)
let serviceid = "C378280D-DA14-42C8-A24E-0DE92A1028E2"

let error fmt = Printf.ksprintf (fun s ->
    Log.err (fun l -> l  "error: %s" s);
    Error (`Msg s)
  ) fmt

let max_chunk_size = Int32.of_int (100 * 1024)

let make_task msg =
  let date = Int64.of_float (Unix.gettimeofday ()) in
  Irmin.Task.create ~date ~owner:"datakit <datakit@docker.com>" msg

(* FIXME: this is a bit ridiculous *)
module Contents_string = struct
  open Irmin.Contents.String
  type t = string
  let equal = equal
  let compare = compare
  let hash = hash
  let to_json = to_json
  let of_json = of_json
  let size_of = size_of
  let write = write
  let read = read
  let merge _ = merge []
  module Path = Ivfs_tree.Path
end
module Git_fs_store = struct
  open Irmin
  open Datakit_io
  module Store =
    Irmin_git.FS(Sync)(Zlib)(Lock)(FS)
      (Contents_string)(Ref.String)(Hash.SHA1)
  type t = Store.Repo.t
  module Filesystem = Ivfs.Make(Store)
  let listener = lazy (
    Irmin.Private.Watch.set_listen_dir_hook Irmin_watcher.hook
  )

  let repo path =
    let config = Irmin_git.config ~root:path ~bare:true () in
    Store.Repo.create config

  let connect path =
    Lazy.force listener;
    Log.debug (fun l -> l "Using Git-format store %s" path);
    repo path >|= fun repo ->
    fun () -> Filesystem.create make_task repo
end

module In_memory_store = struct
  open Irmin
  open Datakit_io
  module Store = Irmin_git.Memory
      (Sync)(Zlib)(Contents_string)(Ref.String) (Hash.SHA1)
  type t = Store.Repo.t
  module Filesystem = Ivfs.Make(Store)

  let repo () =
    let config = Irmin_mem.config () in
    Store.Repo.create config

  let connect () =
    Log.debug (fun l ->
        l "Using in-memory store (use --git for a disk-backed store)");
    repo () >|= fun repo ->
    fun () -> Filesystem.create make_task repo
end

let set_signal_if_supported signal handler =
  try
    Sys.set_signal signal handler
  with Invalid_argument _ ->
    ()

module Date = struct
  let pretty d =
    let tm = Unix.localtime (Int64.to_float d) in
    Printf.sprintf "%02d:%02d:%02d"
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
end

module HTTP = Irmin_http_server.Make(Cohttp_lwt_unix.Server)(Date)

let http_server uri git =
  let timeout = 3600 in
  let uri = match Uri.host uri with
    | None   -> Uri.with_host uri (Some "localhost")
    | Some _ -> uri in
  let port, uri = match Uri.port uri with
    | None   -> 8080, Uri.with_port uri (Some 8080)
    | Some p -> p, uri in
  let mode = `TCP (`Port port) in
  Logs.info (fun f -> f "daemon: %s" (Uri.to_string uri));
  Printf.printf "Server starting on port %d.\n%!" port;
  begin match git with
    | None -> (* in-memory store *)
      let module HTTP = HTTP(In_memory_store.Store) in
      In_memory_store.repo () >>= fun repo ->
      In_memory_store.Store.master make_task repo >|= fun t ->
      HTTP.http_spec (t "HTTP server for the in-memory store")
    | Some path -> (* on-disk store *)
      let module HTTP = HTTP(Git_fs_store.Store) in
      Git_fs_store.repo path >>= fun repo ->
      Git_fs_store.Store.master make_task repo >|= fun t ->
      HTTP.http_spec (t "HTTP server for the on-disk store")
  end >>= fun spec ->
  Cohttp_lwt_unix.Server.create ~timeout ~mode spec

let () =
  Lwt.async_exception_hook := (fun exn ->
      Logs.err (fun m -> m "Unhandled exception: %a" Fmt.exn exn)
    )

let start ~listen_9p ~listen_http prometheus git =
  quiet ();
  set_signal_if_supported Sys.sigpipe Sys.Signal_ignore;
  set_signal_if_supported Sys.sigterm (Sys.Signal_handle (fun _ ->
      (* On Win32 we receive this signal on every failed Hyper-V
         socket connection *)
      if Sys.os_type <> "Win32" then begin
        Log.debug (fun l -> l "Caught SIGTERM, will exit");
        exit 1
      end
    ));
  set_signal_if_supported Sys.sigint (Sys.Signal_handle (fun _ ->
      Log.debug (fun l -> l "Caught SIGINT, will exit");
      exit 1
    ));
  Log.app (fun l ->
      l "Starting %s %s ..." (Filename.basename Sys.argv.(0)) Version.v
    );
  let prometheus_threads = Prometheus_unix.serve prometheus in
  let serve_http = match listen_http with
    | None     -> []
    | Some uri -> [http_server (Uri.of_string uri) git]
  in
  let serve_9p =
    begin match git with
      | None      -> In_memory_store.connect ()
      | Some path -> Git_fs_store.connect path
    end >|= fun make_root ->
    List.map (fun addr ->
        Datakit_conduit.accept_forever ~make_root ~serviceid addr
      ) listen_9p
  in
  serve_9p >>= fun serve_9p ->
  Lwt.choose (serve_http @ serve_9p @ prometheus_threads)

let exec ~name cmd =
  Lwt_process.exec cmd >|= function
  | Unix.WEXITED 0   -> ()
  | Unix.WEXITED i   ->
    Log.err (fun l -> l "%s exited with code %d" name i)
  | Unix. WSIGNALED i ->
    Log.err (fun l -> l "%s killed by signal %d)" name i)
  | Unix.WSTOPPED i  ->
    Log.err (fun l -> l "%s stopped by signal %d" name i)

let start () listen_9p listen_http prometheus git auto_push =
  let start () = start ~listen_9p ~listen_http prometheus git in
  Lwt_main.run begin
    match auto_push with
    | None        -> start ()
    | Some remote ->
      Log.info (fun l -> l "Auto-push to %s enabled" remote);
      let watch () = match git with
        | None      ->
          In_memory_store.repo () >>= fun repo ->
          In_memory_store.Store.Repo.watch_branches repo (fun _ _ ->
              Lwt.fail_with "TOTO"
            )
        | Some path ->
          Lazy.force Git_fs_store.listener;
          let push br =
            Log.info (fun l -> l "Pushing %s to %s:%s" path remote br);
            Lwt.catch
              (fun () ->
                 let cmd = ("", [| "git"; "-C"; path; "push"; "--force"; "--"; remote; br |]) in
                 let name = Fmt.strf "auto-push to %s" remote in
                 let t0 = Unix.gettimeofday () in
                 exec ~name cmd >|= fun () ->
                 let t1 = Unix.gettimeofday () in
                 Prometheus.Summary.observe Metrics.push_duration_seconds (t1 -. t0)
              )
              (fun ex ->
                 Log.err (fun l -> l "git push failed: %s" (Printexc.to_string ex));
                 Lwt.return ()
              )
          in
          Git_fs_store.repo path >>= fun repo ->
          Git_fs_store.Store.Repo.watch_branches repo (fun br _ -> push br)
      in
      watch () >>= fun unwatch ->
      start () >>= fun () ->
      unwatch ()
  end

open Cmdliner

let env_docs = "ENVIRONMENT VARIABLES"
let listen_options = "LISTEN OPTIONS"
let git_options = "GIT OPTIONS"

let endpoint port = Datakit_conduit.(parse ~default_tcp_port:port, pp)

let setup_log =
  let env =
    Arg.env_var ~docs:env_docs
      ~doc:"Be more or less verbose. See $(b,--verbose)."
      "DATAKIT_VERBOSE"
  in
  Term.(const Datakit_log.setup $ Fmt_cli.style_renderer ()
        $ Datakit_log.log_destination $ Logs_cli.level ~env ()
        $ Datakit_log.log_clock)

let git =
  let docs = git_options in
  let doc =
    Arg.info ~docs ~doc:"The path of an existing Git repository to serve"
      ["git"]
  in
  Arg.(value & opt (some string) None doc)

let auto_push =
  let docs = git_options in
  let doc =
    Arg.info ~doc:"Auto-push the local repository to a remote source."
      ~docs ~docv:"URL" ["auto-push"]
  in
  Arg.(value & opt (some string) None doc)

let listen_9p =
  let docs = listen_options in
  let doc =
    Arg.info ~docs ~doc:
      "A comma-separated list of URLs to listen on for 9p connections, on \
       the form file:///var/tmp/foo or tcp://host:port or \
       \\\\\\\\.\\\\pipe\\\\foo or hyperv-connect://vmid/serviceid or \
       hyperv-accept://vmid/serviceid"
      ["url"; "listen-9p"]
  in
  Arg.(value & opt (list (endpoint 5640)) [ `Tcp ("127.0.0.1", 5640) ] doc)

let listen_http =
  let docs = listen_options in
  let doc =
    Arg.info ~docs ~doc:
      "An URL to listen on for HTTP connection, on of the form \
       port or host:port"
      ["listen-http"]
  in
  Arg.(value & opt (some string) None doc)

let term =
  let doc = "A git-like database with a 9p interface." in
  let man = [
    `S "DESCRIPTION";
    `P "$(tname) is a Git-like database with a 9p interface.";
  ] in
  Term.(pure start $ setup_log $ listen_9p $ listen_http $ Prometheus_unix.opts
        $ git $ auto_push),
  Term.info (Filename.basename Sys.argv.(0)) ~version:Version.v ~doc ~man

let () = match Term.eval term with
  | `Error _ -> exit 1
  | _        -> ()
