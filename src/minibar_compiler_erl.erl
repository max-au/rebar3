%%-------------------------------------------------------------------
%% @author Maxim Fedorov <maximfca@gmail.com>
%% @doc
%% Cleaner replacement for rebar_compiler_erl.
%% @end
%%-------------------------------------------------------------------
-module(minibar_compiler_erl).
-author("maximfca@gmail.com").

%%------------------------------------------------------------------------------
%% API: compiler plugin API exports
-export([
    dependencies/2,
    compile/4,
    context/1,
    clean/2
]).

-spec dependencies(Source :: file:filename_all(), DepOpts :: minibar_compiler:compile_opts()) ->
    {Includes :: [file:filename_all()], ArtDeps :: [module()], Meta :: boolean()}.
dependencies(Source, DepOpts) ->
    OptPTrans = [module_to_erl(Mod) || Mod <- proplists:get_all_values(parse_transform, DepOpts)],
    IncludePath = proplists:get_all_values(i, DepOpts),
    Macros = proplists:get_all_values(d, DepOpts),
    case epp:open(Source, IncludePath, Macros) of
        {ok, Epp} ->
            try
                {Src, Mod, Meta} = parse_file(Epp, {[], [], #{}}),
                %% some OTP files are funny, they explicitly mention file itself... see xmerl_xpath_parse.erl
                FilteredSourceDeps = lists:delete(Source, lists:delete(filename:basename(Source), Src)),
                %% don't cycle parse_transform over itself
                FilteredModDeps = lists:delete(filename:basename(Source), OptPTrans ++ Mod),
                %% to keep compatibility with more existing infra, return only a boolean variable
                BoolMeta = is_map_key(parse_transform, Meta) orelse is_map_key(behaviour, Meta),
                {FilteredSourceDeps, FilteredModDeps, BoolMeta}
            catch
                error:{missing, What, File} ->
                    error({missing, What, Source, File, IncludePath, Macros})
            end;
        {error, Reason} ->
            error({parse_file, Source, Reason})
    end.

%% returns two sets of dependencies:
%%  * source dependency (e.g. include)
%%  * artifact dependency (e.g. behaviour, parse_transform)
%%  * ...and meta-information, map of parse_transform/behaviour etc.
parse_file(Epp, Acc) ->
    case epp:parse_erl_form(Epp) of
        {ok, Form} ->
            parse_file(Epp, parse_form(Form, Acc));
        {error, {_Line, epp, {include, file, Name}}} ->
            error({missing, include, Name});
        {error, {_Line, epp, {include, lib, Path}}} ->
            error({missing, include_lib, Path});
        {eof, _Location} ->
            epp:close(Epp),
            {Src, Mod, Meta} = Acc,
            {lists:usort(Src), lists:usort(Mod), Meta};
        _ ->
            %% skip everything else
            parse_file(Epp, Acc)
    end.

%% Includes
parse_form({attribute, _Line, file, {Path, _Ln}}, {Src, Mod, Meta}) ->
    {[Path | Src], Mod, Meta};
%% Behaviours
parse_form({attribute, _Line, behaviour, Name}, {Src, Mod, Meta}) ->
    {Src, [module_to_erl(Name) | Mod], Meta};
parse_form({attribute, _Line, behavior, Name}, {Src, Mod, Meta}) ->
    {Src, [module_to_erl(Name) | Mod], Meta};
%% Parse transforms
parse_form({attribute, _Line, compile, {parse_transform, {Name, _}}}, {Src, Mod, Meta}) when is_atom(Name) ->
    {Src, [module_to_erl(Name) | Mod], Meta};
parse_form({attribute, _Line, compile, {parse_transform, Name}}, {Src, Mod, Meta}) when is_atom(Name) ->
    {Src, [module_to_erl(Name) | Mod], Meta};
parse_form({attribute, _Line, compile, Attrs}, Acc) when is_list(Attrs) ->
    lists:foldl(fun (Attr, AccIn) -> parse_form({attribute, _Line, compile, Attr}, AccIn) end, Acc, Attrs);
%% remember meta-info to fill in AbsMap
parse_form({attribute, _Line, callback, _}, {Src, Mod, Meta}) ->
    {Src, Mod, Meta#{behaviour => true}};
%% Old style behaviour specification. Don't check if it's exported,
%%  compiler will do that for us
parse_form({function, _Line, behaviour_info, 1, _}, {Src, Mod, Meta}) ->
    {Src, Mod, Meta#{behaviour => true}};
parse_form({function, _Line, behavior_info, 1, _}, {Src, Mod, Meta}) ->
    {Src, Mod, Meta#{behaviour => true}};
%% Parse transform
parse_form({function, _Line, parse_transform, 2, _}, {Src, Mod, Meta}) ->
    {Src, Mod, Meta#{parse_transform => true}};
%% Skip the rest
parse_form(_, Map) ->
    Map.

module_to_erl(Mod) ->
    atom_to_list(Mod) ++ ".erl".

compile(Source, [{_, OutDir}], Config, ErlOpts0) ->
    %% don't cycle parse_transform over itself
    ModName = list_to_atom(filename:basename(Source, ".erl")),
    ErlOpts = lists:delete({parse_transform, ModName}, ErlOpts0),
    case compile:file(Source, [{outdir, OutDir}, return | ErlOpts]) of
        {ok, _Mod} ->
            ok;
        {ok, _Mod, []} ->
            ok;
        {ok, _Mod, Ws} ->
            FormattedWs = format_error_sources(Ws, Config),
            rebar_compiler:ok_tuple(Source, FormattedWs);
        {error, Es, Ws} ->
            error_tuple(Source, Es, Ws, Config, ErlOpts);
        error ->
            error
    end.

format_error_sources(Es, Opts) ->
    [{rebar_compiler:format_error_source(Src, Opts), Desc}
        || {Src, Desc} <- Es].

error_tuple(Module, Es, Ws, AllOpts, Opts) ->
    FormattedEs = format_error_sources(Es, AllOpts),
    FormattedWs = format_error_sources(Ws, AllOpts),
    rebar_compiler:error_tuple(Module, FormattedEs, FormattedWs, Opts).

%% MUST BE GONE - part of "rebar_compiler_erl" compiler plugin.
%%
context(AppInfo) ->
    EbinDir = rebar_app_info:ebin_dir(AppInfo),
    Mappings = [{".beam", EbinDir}],

    OutDir = rebar_app_info:dir(AppInfo),
    SrcDirs = rebar_dir:src_dirs(rebar_app_info:opts(AppInfo), ["src"]),
    ExistingSrcDirs = lists:filter(fun(D) ->
        ec_file:is_dir(filename:join(OutDir, D))
                                   end, SrcDirs),

    RebarOpts = rebar_app_info:opts(AppInfo),
    ErlOpts = rebar_opts:erl_opts(RebarOpts),
    ErlOptIncludes = proplists:get_all_values(i, ErlOpts),
    InclDirs = lists:map(fun(Incl) -> filename:absname(Incl) end, ErlOptIncludes),
    AbsIncl = [filename:join([OutDir, "include"]) | InclDirs],

    PrivIncludes = [{i, filename:join(OutDir, Src)}
        || Src <- rebar_dir:all_src_dirs(RebarOpts, ["src"], [])],
    DepsOut = filename:absname(filename:dirname(rebar_app_info:out_dir(AppInfo))),
    ExternalIncl = [{i, Dir} || Dir <- AbsIncl],
    CompileOpts = compile:env_compiler_options() ++ ExternalIncl ++
        PrivIncludes ++ [return, {i, OutDir}, {i, DepsOut} | ErlOpts],

    #{src_dirs => ExistingSrcDirs,
        include_dirs => AbsIncl,
        src_ext => ".erl",
        out_mappings => Mappings,
        compile_opts => CompileOpts}.

clean(Files, AppInfo) ->
    EbinDir = rebar_app_info:ebin_dir(AppInfo),
    [begin
         Source = filename:basename(File, ".erl"),
         Target = target_base(EbinDir, Source) ++ ".beam",
         file:delete(Target)
     end || File <- Files].

target_base(OutDir, Source) ->
    filename:join(OutDir, filename:basename(Source, ".erl")).
