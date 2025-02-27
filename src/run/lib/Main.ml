(*
   Entrypoint for a standalone parser-dumper, to be called by generated
   parsers.
*)

open Printf
open Cmdliner

type input_kind =
  | Source_file
  | Json_file of string

type config = {
  source_file: string;
  input_kind: input_kind;
  txt_stat: string option;
  json_error_log: string option;
}

(*
   Different classes of errors, useful for parsing stats.
*)
module Exit = struct
  let any_error = 1
  let bad_command_line = 10
  let external_parsing_error = 11
  let internal_parsing_error = 12
end

let source_file_term =
  let info =
    Arg.info []
      ~docv:"SRC_FILE"
      ~doc:"$(docv) specifies the path to the source file to be parsed."
  in
  Arg.required (Arg.pos 0 Arg.(some string) None info)

let input_json_term =
  let info =
    Arg.info []
      ~docv:"JSON_INPUT_FILE"
      ~doc:"$(docv) specifies a pre-parsed CST in the JSON format
            produced by tree-sitter. This input will be used directly
            instead of parsing the source file, which must still be
            specified on the command line for error reporting."
  in
  Arg.value (Arg.pos 1 Arg.(some string) None info)

let txt_stat_term =
  let info =
    Arg.info ["txt-stat"]
      ~docv:"FILE"
      ~doc:"$(docv) specifies a file to which the number of total
            lines (A), the number of unparsable lines (B), and the
            number of errors (C) is written in the format 'A B C'."
  in
  Arg.value (Arg.opt Arg.(some string) None info)

let json_error_log_term =
  let info =
    Arg.info ["json-error-log"; "e"]
      ~docv:"FILE"
      ~doc:"$(docv) specifies a file to which parsing errors should be
            appended. The format consists of one json object per line,
            and is otherwise left unspecified for now."
  in
  Arg.value (Arg.opt Arg.(some string) None info)

let cmdline_term =
  let combine source_file input_json txt_stat json_error_log =
    let input_kind =
      match input_json with
      | None -> Source_file
      | Some json_file -> Json_file json_file
    in
    { source_file; input_kind; txt_stat; json_error_log }
  in
  Term.(const combine
        $ source_file_term
        $ input_json_term
        $ txt_stat_term
        $ json_error_log_term
       )

let doc ~lang =
  sprintf "parse a %s file with tree-sitter and ocaml-tree-sitter" lang

let man ~lang = [
  `S Manpage.s_description;
  `P (sprintf "\
Parse a %s file and dump the resulting parse tree (CST) in a
human-readable format for inspection purposes. This is a test program
meant to evaluate the quality of tree-sitter parsers and the recovery
of the full CST by ocaml-tree-sitter."
        lang);
  `S Manpage.s_bugs;
  `P "Check out bug reports at
      https://github.com/returntocorp/ocaml-tree-sitter/issues.";
]

let parse_command_line ~lang =
  let info =
    Term.info
      ~doc:(doc ~lang)
      ~man:(man ~lang)
      ("parse-" ^ lang)
  in
  match Term.eval (cmdline_term, info) with
  | `Error _ -> exit Exit.bad_command_line
  | `Version | `Help -> exit 0
  | `Ok config -> config

let use_color () =
  !ANSITerminal.isatty Unix.stderr

let safe_run f =
  Printexc.record_backtrace true;
  try f ()
  with e ->
    let trace = Printexc.get_backtrace () in
    flush stdout;
    let msg, exit_code, show_trace =
      match e with
      | Tree_sitter_error.Error err ->
          let msg = Tree_sitter_error.to_string ~color:(use_color ()) err in
          let exit_code =
            match err.kind with
            | External -> Exit.external_parsing_error
            | Internal -> Exit.internal_parsing_error
          in
          msg, exit_code, false
      | Failure msg ->
          msg, Exit.any_error, true
      | e ->
          let msg = sprintf "exception %s" (Printexc.to_string e) in
          msg, Exit.any_error, true
    in
    (if show_trace then
       eprintf "Error: %s\n%s\n"
         msg
         trace
     else
       eprintf "Error: %s\n" msg
    );
    eprintf "\nexit %i\n" exit_code;
    flush stderr;
    exit exit_code

let print_error err =
  eprintf "Error: %s\n"
    (Tree_sitter_error.to_string ~color:(use_color ()) err)

let print_errors errors =
  List.iter print_error errors

(*
   Obtain tree-sitter's CST either by parsing the source code
   or loading it from a json file.
*)
let load_input_tree ~parse_source_file conf =
  let src_file = conf.source_file in
  match conf.input_kind with
  | Source_file ->
      parse_source_file src_file
  | Json_file json_file ->
      Tree_sitter_parsing.load_json_file ~src_file ~json_file

let parse_and_dump
    ~parse_source_file
    ~parse_input_tree
    ~dump_tree
    conf =
  let input_tree = load_input_tree ~parse_source_file conf in
  Tree_sitter_parsing.print input_tree;
  let res : _ Parsing_result.t = parse_input_tree input_tree in
  let some_success =
    match res.program with
    | Some matched_tree ->
        dump_tree matched_tree;
        true
    | None ->
        false
  in
  let errors = res.errors in
  let stat = res.stat in
  (match conf.txt_stat with
   | Some out_file -> Parsing_result.export_stat ~out_file stat
   | None -> ()
  );
  (match conf.json_error_log with
   | Some err_log -> Tree_sitter_error.log_json_errors err_log errors
   | None -> ()
  );
  let lines = stat.total_line_count in
  let err_lines = stat.error_line_count in
  let success_ratio =
    if lines > 0 then float (lines - err_lines) /. float lines
    else 1.
  in
  print_errors errors;
  printf "\
total lines: %i
error lines: %i
error count: %i
success: %.2f%%
"
    stat.total_line_count
    stat.error_line_count
    stat.error_count
    (100. *. success_ratio);

  let success = some_success && errors = [] in
  let exit_code =
    if success then 0
    else Exit.external_parsing_error
  in
  exit_code

let run ~lang ~parse_source_file ~parse_input_tree ~dump_tree =
  let conf = parse_command_line ~lang in
  safe_run (fun () ->
    let suggested_exit_code =
      parse_and_dump
        ~parse_source_file
        ~parse_input_tree
        ~dump_tree
        conf
    in
    exit suggested_exit_code
  )
