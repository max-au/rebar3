%%-------------------------------------------------------------------
%% @author Maxim Fedorov <maximfca@gmail.com>
%% @doc
%% Fast build engine, utilising all available schedulers to achieve
%%  as much concurrency as possible.
%% It is supposed to work with rebar3 build system, so it deliberately
%%  omits multi-compilers steps. Even though it's really easy to
%%  support xrl -> erl -> beam, it is not implemented, to provide
%%  forwards/backwards compatibility with existing compiler plugins.
%% @end
%%-------------------------------------------------------------------
-module(minibar_compiler).
-author("maximfca@gmail.com").

%%------------------------------------------------------------------------------
%% API
-export([
    analyse/3,
    compile/3,
    analyse_and_compile/3,
    save/2,
    load/1
]).

%% Storing file_info
-include_lib("kernel/include/file.hrl").

%% Compiler options - generic map, as specific options
%%  are defined by compiler plugin.
-type compile_opts() :: map().

%% Information stored about a single source file
%% Negligible performance boost may be achieved if it's
%%  changed to a tuple.
-record (source, {
    %% Source file stat
    stat :: #file_info{},
    %% Source dependencies, e.g. include files
    %% set to 'undefined' for non-source files (e.g. includes)
    source_deps  :: undefined | [file:filename_all()],
    %% Artifact dependencies (behaviours, parse transforms)
    artifact_deps :: undefined | [file:filename_all()],
    %% Whether this source can be a dependency of another (e.g. parse_transform, behaviour)
    meta :: boolean(),
    %% Artifacts produced from this source, with their file_info
    artifacts :: undefined | [{file:filename_all(), #file_info{}}],
    %% Compile/analyse context for this file
    %%  stored for subsequent compiler run, but also used to
    %%  detect whether recompilation is needed due to options
    %%  changed.
    compile_opts :: compile_opts(),
    %% whether file requires recompilation (boolean for source files),
    needs_compile = true :: boolean()
}).

-type source() :: #source{}.

%% Dependencies map (supposedly, acyclic DAG)
-type dependency_map() :: #{file:filename_all() => source()}.

%% Maps project files into absolute paths to these files
-type abs_map() :: #{file:filename_all() => file:filename_all()}.

%% Application name (rebar3-enforced)
-type app_name() :: atom() | string().

-ifdef(DLOG_ENABLED).
%% Debugging features (enabled only for test profile)
%% Log table contains tuples, with file name being the key.
%%  For every file, it's possible to figure out entire compilation flow,
%%  which has 4 steps:
%%   * find: find file in the directory and compare with cached information,
%%        for source files:
%%           * true - needs compile (because artifact is dirty)
%%           * false - does not need compile
%%           * changed - needs compile because source is changed,
%%           * not_cached - needs compile because no cached info was available
%%        for dependencies (file that triggered is also added):
%%           * cached - found dependency in cache (keep need_compile status)
%%           * added - dependency was not in cache, adding with 'dirty' status
%%           * missing - no dependency file found on disk (probably EPP lies to us)
%%           * changed - file changed, setting dirty flag
%%   * need: dependency verification pass, for every file set to
%%           * true - will recompile this source/dep
%%           * false - won't recompile this source/dep
%%           * dependency - will recompile because of dependency change
%%           * ignore - not a source file, don't touch need_compile status
%%   * compile: compilation result
%%           * clean - file did not need compilation
%%           * not_source - not a source, does not need compilation
%%           * ok|warning|error|skipped - corresponding source file compile status
%%   * update: update DAG with info about compiled files
%%           * skipped - file was skipped when compiling
%%           * ok, artifacts - produced some artifacts (with fileinfo)
-define(DLOG(File, Step, Result), true = ets:insert(minibar_log, {File, Step, Result})).
-define(DLOG(File, Step, Result, Data), true = ets:insert(minibar_log, {File, Step, Result, Data})).
-define(DCLOG(File, Condition, Step, Result), Condition andalso (true = ets:insert(minibar_log, {File, Step, Result}))).
-else.
-define(DLOG(_File, _Step, _Result), ok).
-define(DLOG(_File, _Step, _Result, _Data), ok).
-define(DCLOG(_File, _Condition, _Step, _Result), ok).
-endif.

%% Compilation context (enforced by rebar3 compatibility)
-type app_context() :: #{
    src_dirs     => [file:filename_all()],          % mandatory
    include_dirs => [file:filename_all()],          % mandatory
    src_ext      => string(),                       % mandatory
    out_mappings => [{string(), file:filename()}],  % mandatory
    %% added fields, breaking rebar3 compatibility
    base_dir     => file:filename_all(),
    compiler     => module(),
    compile_opts => term()                     % optional?
}.

-type app_context_map() :: #{app_name() => app_context()}.

%% Bump version when any type definition changes
-define(DEPS_MAP_VSN, 1).
-record(minibar_compiler_state, {
    vsn = ?DEPS_MAP_VSN :: pos_integer(),
    apps = #{} :: app_context_map(),
    map = #{} :: dependency_map()
}).

-type state() :: #minibar_compiler_state{}.

%% Analysis, taking advantage of Erlang concurrency, and multi library.
%% Returns AbsMap - map of project files onto absolute paths/names,
%%  and an actual dependency map (DAG).
-spec analyse(CompilerMod :: module(), State :: state(),
    Apps :: app_context_map()) -> {abs_map(), state()} | {error, term()}.
analyse(CompilerMod, #minibar_compiler_state{map = OldMap, apps = OldApps}, Apps) ->
    Tasks = maps:map(
        fun (App, Ctx) ->
            %% for apps that have changed build options, cache is not use
            NewCtx = Ctx#{compiler => CompilerMod},
            case maps:find(App, OldApps) of
                error ->
                    {fun find_deps/3, [#{}, NewCtx]};
                {ok, NewCtx} ->
                    {fun find_deps/3, [OldMap, NewCtx]};
                {ok, _ChangedCtx} ->
                    %% for apps that have changed build options, cache is not used
                    %% ct:pal("~s: discarding: ~n~p~n~n~p", [App, NewCtx, _ChangedCtx]),
                    {fun find_deps/3, [#{}, NewCtx]}
            end
        end, Apps),
    %% analysis is disk-limited, so spin up more processes than schedulers
    %%  currently multiplier is hardcoded, but really, it can be calculated
    %%  from dirty I/O scheduler utilisation, and DIO runqueue length
    Concurrency = erlang:system_info(schedulers) * 12,
    case minibar_multi:run(Tasks, Concurrency) of
        {ok, ResultMap} ->
            %% have to serialise here, because otherwise AbsMap
            %%  that maps module from one app to module in another app won't work
            {AbsMaps, DepsMaps} = lists:unzip(maps:values(ResultMap)),
            AbsMap = lists:foldl(fun maps:merge/2, #{}, AbsMaps),
            {AbsMap, #minibar_compiler_state{apps = Apps,
                map = merge_dependency_maps(OldMap, DepsMaps)}};
        {error, _PartialMap, Reason} ->
            {error, Reason}
    end.

%% Compiles supplied DAG
-spec compile(CompilerMod :: module(), abs_map(), state()) ->
    {ok, state()} | {error, state(), Reason :: term()}.
compile(CompilerMod, AbsMap, #minibar_compiler_state{map = DepMap0} = State) ->
    DepMap1 = resolve_artifact_deps(AbsMap, DepMap0),
    DepMap = detect_changed(DepMap1),
    %% every file is a task, that has dependencies on some other tasks
    Tasks = maps:map(
        fun (_File, #source{needs_compile = false, artifacts = OldArtifacts}) ->
                %% _File does not need to be compiled (no matter source or not)
                {[], fun (_Clean) -> ?DLOG(_Clean, compile, clean), OldArtifacts end};
            (_File, #source{source_deps = undefined, artifact_deps = undefined, artifacts = undefined}) ->
                %% does not produce any artifacts - no need to be compiled
                {[], fun (_NotSrc) -> ?DLOG(_NotSrc, compile, not_source), undefined end};
            (_File, #source{compile_opts = Opts, source_deps = SrcDeps,
                artifact_deps = ArtDeps, artifacts = Artifacts}) ->
                %% source file, producing some artifacts, and needs to be compiled
                {ArtNames, _} = lists:unzip(Artifacts),
                {SrcDeps ++ ArtDeps, {fun compile_one/5, [CompilerMod, ArtNames, Opts]}}
        end, DepMap),
    %% run tasks concurrently
    case minibar_multi:run(Tasks) of
        {ok, Success} ->
            {ok, State#minibar_compiler_state{map = update_deps_map(Success, DepMap0)}};
        {error, Success, Reason} ->
            {error, State#minibar_compiler_state{map = update_deps_map(Success, DepMap0)}, Reason}
    end.

%% Analyses application paths and compiles, returning DAG to be cached for later usage.
%% Even if compilation fals, DAG can still be saved.
-spec analyse_and_compile(CompilerMod :: module(),  State :: state(),
    app_context_map()) -> {ok, state()} | {error, state(), term()}.
analyse_and_compile(CompilerMod, State, Apps) ->
    case analyse(CompilerMod, State, Apps) of
        {error, Reason} ->
            {error, State, Reason};
        {AbsMap, NewState} ->
            case compile(CompilerMod, AbsMap, NewState) of
                {ok, LastState} = Ret ->
                    remove_stale_artifacts(LastState, State),
                    Ret;
                {error, LastState, _Reason} = Ret ->
                    remove_stale_artifacts(LastState, State),
                    Ret
            end
    end.

-spec save(file:filename_all(), state()) ->
    ok | {error, file:posix() | badarg | terminated | system_limit}.
save(FileName, State) ->
    BinMap = term_to_binary(State),
    file:write_file(FileName, BinMap).

-spec load(file:filename_all()) -> state().
load(FileName) ->
    case file:read_file(FileName) of
        {ok, Bin} ->
            case binary_to_term(Bin) of
                #minibar_compiler_state{vsn = ?DEPS_MAP_VSN} = State ->
                    State;
                #minibar_compiler_state{vsn = _AnotherVersion} ->
                    %% error({version, AnotherVersion});
                    #minibar_compiler_state{};
                _Other ->
                    %% error({corrupt, Other})
                    #minibar_compiler_state{}
            end;
        _Reason ->
            %% error(_Reason),
            #minibar_compiler_state{}
    end.

%%------------------------------------------------------------------------------
%% Internal implementation

%% Finds all files of a directory, and creates a map of all files with all
%%  dependencies. Has no side effects - to unlock concurrency!
%% Uses previous dependency map as a cache, to avoid re-parsing a file
%%  when source file attributes haven't changed.

%% Essentially, this is "map" function of map-reduce algorithm.
%% "reduce" step does nothing but merges AbsMap together, giving
%%  full map of modules that can be dependencies of other modules,
%%  and include files that are source dependencies.

%% File name map: short file name to absolute file name
%% Used only for files that return "behaviour" or "parse_transform"
%%  metadata.

-spec find_deps(app_name(), Cache :: dependency_map(), app_context()) ->
    {abs_map(), dependency_map()}.
find_deps(_AppName, Cache, #{src_dirs := SrcDirs} = Context) ->
    %% pick up context: generate output directory
    find_files_impl(Cache, Context, SrcDirs, {#{}, #{}}).

%%------------------------------------------------------------------------------
%% Even more internal implementation

find_files_impl(_Cache, _Context, [], Acc) ->
    Acc;
find_files_impl(Cache, #{base_dir := BaseDir} = Context, [{SrcDir, Recursive} | Tail], Acc) ->
    NextDir = filename:join(BaseDir, SrcDir),
    find_files_impl(Cache, Context, Tail,
        scan_dir(Cache, Context, NextDir, Recursive, Acc)).

%% Scans a single directory, potentially recursively
scan_dir(Cache, Context, Dir, Recursive, Acc) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            scan_files(Cache, Context, Files, Dir, Recursive, Acc);
        {error, _Reason}  ->
            Acc
    end.

%% Scans file of a directory
scan_files(_Cache, _Context, [], _Dir, _Recursive, Acc) ->
    Acc;
scan_files(Cache, #{src_ext := Ext} = Context, [File | Tail], Dir, Recursive, Acc) ->
    FileName = filename:join(Dir, File),
    case file_info(FileName) of
        {ok, #file_info{type = directory}} when Recursive ->
            scan_files(Cache, Context, Tail, Dir, Recursive,
                scan_dir(Cache, Context, FileName, Recursive, Acc));
        {ok, #file_info{type = directory}} ->
            scan_files(Cache, Context, Tail, Dir, Recursive, Acc);
        {ok, #file_info{type = regular} = FileInfo} ->
            case filename:extension(File) of
                Ext ->
                    scan_files(Cache, Context, Tail, Dir, Recursive,
                        pick_file(Cache, Context, File, FileName, FileInfo, Acc));
                _Other ->
                    scan_files(Cache, Context, Tail, Dir, Recursive, Acc)
            end;
        {error, _Reason} ->
            scan_files(Cache, Context, Tail, Dir, Recursive, Acc)
    end.

%% Picks one file, and adds the file with the list of dependencies to the
%%  accumulator. Dependencies may be fetched from the cache, and if there is
%%  cache miss, dependencies are analysed using plugin-provided API.
pick_file(Cache, Context, File, FileName, #file_info{mtime = MTime} = FileInfo, {AbsMap, DepMap}) ->
    case maps:find(FileName, Cache) of
        %% More attributes to consider: size, inode, file mode, owner uid and gid
        {ok, #source{stat = #file_info{mtime = MTime}} = Source} ->
            %% cached file hasn't changed since last run, but let's check artifacts
            Dirty = is_dirty(Source#source.artifacts),
            ?DLOG(FileName, find, Dirty),
            {
                pick_abs_map(Source#source.meta, File, FileName, AbsMap),
                DepMap#{FileName => Source#source{needs_compile = Dirty}}
            };
        _Other ->
            %% does not matter if it's not cached or stale, we need to get a list
            %%  of this file dependencies, and put the file as 'changed' into
            %%  dependency map
            ?DCLOG(FileName, _Other =:= error, find, not_cached),
            ?DCLOG(FileName, is_tuple(_Other) andalso element(1, _Other) =:= ok, find, changed),
            DepsOpts = maps:get(compile_opts, Context, []),
            CompilerMod = maps:get(compiler, Context),
            SrcExt = maps:get(src_ext, Context),
            Artifacts = [
                {filename:join(Out, filename:basename(FileName, SrcExt) ++ Ext), #file_info{}}
                || {Ext, Out} <- maps:get(out_mappings, Context)
            ],
            %% compatibility >>>
            Source =
                case dependencies(CompilerMod, FileName, DepsOpts) of
                    {SrcDep, ArtDep, Meta} ->
                        #source{stat = FileInfo, meta = Meta,
                            compile_opts = DepsOpts,
                            source_deps = SrcDep, artifact_deps = ArtDep,
                            artifacts = Artifacts};
                    Dependencies ->
                        %% split up sources into includes and
                        %%  artifact dependencies, and always set meta
                        %% If dependency has the same extension, it is ArtifactDep,
                        %%  otherwise it's SrcDep
                        {SrcDep, ArtDep} = lists:partition(
                            fun(Dep) -> filename:extension(Dep) /= SrcExt
                            end, Dependencies),
                        #source{stat = FileInfo, meta = true,
                            compile_opts = DepsOpts,
                            source_deps = SrcDep, artifact_deps = ArtDep,
                            artifacts = Artifacts}
                end,
            %% compatibility code end <<<
            %% add this file to dependency map, and probably AbsMap too
            {
                pick_abs_map(Source#source.meta, File, FileName, AbsMap),
                DepMap#{FileName => Source}
            }
    end.

%% Safe call to dependencies - for rebar3 compatibility
dependencies(CompilerMod, FileName, DepsOpts) ->
    try
        CompilerMod:dependencies(FileName, DepsOpts)
    catch error:undef ->
        CompilerMod:dependencies(FileName, [], DepsOpts)
    end.

%% Adds file to AbsMap, if Meta-info for the file allows
pick_abs_map(true, File, FileName, AbsMap) ->
    AbsMap#{File => FileName};
pick_abs_map(false, _File, _FileName, AbsMap) ->
    AbsMap.

%% If mtime for an artifact has changed, source file is dirty
is_dirty(Artifacts) ->
    lists:any(
        fun ({FileName, #file_info{mtime = OldMtime}}) ->
            case file_info(FileName) of
                {ok, #file_info{mtime = OldMtime}} ->
                    false;
                _ ->
                    true
            end
        end,
        Artifacts).

%% Post-processing: resolve artifact_deps into actual absolute file
%%  names for this project.
-spec merge_dependency_maps(Cache :: dependency_map(), [dependency_map()]) -> dependency_map().
merge_dependency_maps(Cache, DepsMaps) ->
    lists:foldl(
        fun (DepsMapIn, OuterAcc) ->
            maps:fold(
                fun (File, #source{stat = #file_info{mtime = MTime}} = Source, DepsAcc) ->
                    %% Here "File" is a source (not include)
                    case maps:find(File, DepsAcc) of
                        error ->
                            %% this is expected: we're adding file for current application
                            process_and_merge(Cache, File, Source, DepsAcc);
                        {ok, #source{stat = #file_info{mtime = MTime}}} ->
                            %% this is less expected, but happens when one application requires
                            %%  behaviour, and comes first, then implementation comes - and it
                            %%  should replace forward declaration
                            process_and_merge(Cache, File, Source, DepsAcc);
                        {ok, Source} ->
                            %% already in the cache (pulled from dependency cache)
                            DepsAcc;
                        {ok, DifferSource} ->
                            error({file_info_changed, File, Source, DifferSource})
                    end
                end, OuterAcc, DepsMapIn)
        end, #{}, DepsMaps).

%% processed dependencies, merging missing includes
process_and_merge(Cache, File, #source{source_deps = SrcDep} = Source, DepsAcc) ->
    %% discover all includes, and for newly discovered, add to "potentially compile" list
    {SourceDeps, NewDepsAcc} = lists:foldl(
        fun (AbsDep, {AbsAcc, NewDeps}) when is_map_key(AbsDep, NewDeps) ->
                %% dependency is already in DepMap
                {[AbsDep | AbsAcc], NewDeps};
            (AbsDep, {AbsAcc, NewDeps}) ->
                %% this AbsDep is just discovered - need to add to DAG
                {[AbsDep | AbsAcc], merge_include(Cache, File, AbsDep, NewDeps)}
        end, {[], DepsAcc}, SrcDep),
    maps:put(File, Source#source{source_deps = lists:reverse(SourceDeps)}, NewDepsAcc).

%% Checks that dependency (included file) exists, and caches information
%%  about include file (also checks if it's changed)
merge_include(Cache, _File, Dep, Acc) ->
    case file_info(Dep) of
        {ok, #file_info{type = regular, mtime = MTime} = FileInfo} ->
            case maps:find(Dep, Cache) of
                {ok, #source{stat = #file_info{mtime = MTime}} = Source} ->
                    %% must be the same file as before, TODO: compare more attributes
                    ?DLOG(Dep, find, cached, _File),
                    Acc#{Dep => Source};
                error ->
                    %% dependency was not in the cache, let's insert it in,
                    %%  it cannot have any meta, or src, or module dependencies,
                    %%  or any artifacts produced, and it starts as dirty (needs_compile)
                    ?DLOG(Dep, find, added, _File),
                    Acc#{Dep => #source{stat = FileInfo}};
                {ok, _OldInfo} ->
                    %% included file has changed
                    ?DLOG(Dep, find, changed, _File),
                    Acc#{Dep => #source{stat = FileInfo}}
            end;
        _ ->
            %% TODO: technically it's a way to implement erl -> yrl dependencies
            ?DLOG(Dep, find, missing, _File),
            %% This file isn't considered dirty - it does not even exist!
            Acc#{Dep => #source{stat = #file_info{}, needs_compile = false}}
            % error({not_exist, Dep}),
    end.

%% Propagates 'dirty' state of dependencies onto project files
detect_changed(DepMap) ->
    maps:map(
        fun (_File, #source{artifacts = undefined, source_deps = undefined, artifact_deps = undefined} = Source) ->
                %% "includes": short-circuit here, because transitive includes have been flattened
                ?DLOG(_File, need, ignore),
                Source;
            (_File, #source{needs_compile = false, source_deps = SrcDeps, artifact_deps = ArtDeps} = Source) ->
                %% see if any dependency is dirty
                Dirty = lists:any(
                    fun (Dep) ->
                        #source{needs_compile = DirtyDep} = maps:get(Dep, DepMap),
                        ?DLOG(_File, need, dependency, DirtyDep),
                        DirtyDep
                    end, SrcDeps ++ ArtDeps),
                Source#source{needs_compile = Dirty};
            (_File, Source) ->
                ?DLOG(_File, need, Source#source.needs_compile),
                Source
        end,
        DepMap
    ).

%% Resolves all artifact dependencies.
%%  Drops artifact dependencies that are outside of the
%% Yes, it can be made concurrent.
resolve_artifact_deps(AbsMap, DepMap) ->
    maps:map(
        fun (_File, #source{artifact_deps = undefined} = Source) ->
            %% this dependency isn't going to be compiled anyway
            Source;
            (_File, #source{artifact_deps = ArtDep} = Source) ->
            ResolvedDeps = lists:foldl(
                fun (ModName, ArtAcc) ->
                    case maps:find(ModName, AbsMap) of
                        {ok, AbsPath} ->
                            [AbsPath | ArtAcc];
                        error ->
                            %% ct:pal("~s: missing dependency on ~s", [File, ModName]),
                            %% error({dependency_missing, File, ModName})
                            ArtAcc
                    end
                end, [], ArtDep),
            Source#source{artifact_deps = ResolvedDeps}
        end,
        DepMap).

file_info(FileName) ->
    prim_file:read_file_info(FileName).

unwrap_file_info(FileName) ->
    case file_info(FileName) of
        {ok, Info} ->
            Info;
        {error, _} ->
            #file_info{}
    end.

%% updated compile state: for files that were compiled, set dirty to false
update_deps_map(Success, DepMap) ->
    maps:fold(
        fun (_Source, skipped, DepAcc) ->
                ?DLOG(_Source, update, skipped),
                DepAcc;
            (Source, Artifacts, DepAcc) when is_list(Artifacts); Artifacts =:= undefined ->
                ?DLOG(Source, update, ok, Artifacts),
                Item = maps:get(Source, DepAcc),
                maps:put(Source, Item#source{artifacts = Artifacts, needs_compile = false}, DepAcc)
        end, DepMap, Success).

%% prunes artifacts for sources that no longer present in state
remove_stale_artifacts(#minibar_compiler_state{map = New}, #minibar_compiler_state{map = Old}) ->
    Deleted = maps:keys(Old) -- maps:keys(New),
    [delete_artifacts(maps:get(Del, Old)) || Del <- Deleted],
    ok.

delete_artifacts(#source{artifacts = Artifacts}) when is_list(Artifacts) ->
    [file:delete(Art) || {Art, _FI} <- Artifacts];
delete_artifacts(_) ->
    ok.

%% Again, rebar3 compatibility
report(Messages) ->
    rebar_base_compiler:report(Messages).

compile_one(Source, _DepRet, CompilerMod, Artifacts, CompileOpts) ->
    %% compatibility... oh well
    OutDirs = [{filename:extension(A), filename:dirname(A)} || A <- Artifacts],
    %%
    case CompilerMod:compile(Source, OutDirs, dict:new(), CompileOpts) of
        ok ->
            ?DLOG(Source, compile, ok),
            [{FileName, unwrap_file_info(FileName)} || FileName <- Artifacts];
        {ok, Warnings} ->
            ?DLOG(Source, compile, warning, Warnings),
            report(Warnings),
            [{FileName, unwrap_file_info(FileName)} || FileName <- Artifacts];
        skipped ->
            ?DLOG(Source, compile, skipped),
            skipped;
        Error ->
            ?DLOG(Source, compile, error, Error),
            error(Error)
    end.
