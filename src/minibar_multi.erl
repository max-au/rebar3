%%-------------------------------------------------------------------
%% @author Maxim Fedorov <maximfca@gmail.com>
%% @doc
%% Boilerplate for concurrency-related primitives:
%%  * run: execute series of (potentially) dependent tasks. For every task
%%                an identifier is supplied, and a list of dependencies,
%%                that must be complete before starting the task, and
%%                whether the task needs results of those.
%%
%% Examples:
%%  * simple concurrent run (completes in ~10 ms)
%%    multi:run(#{
%%        1 => {fun timer:sleep/1, [10]},
%%        2 => {fun timer:sleep/1, [5]}
%%    }).
%%
%% @end
%%-------------------------------------------------------------------
-module(minibar_multi).
-author("maximfca@gmail.com").

%% API
-export([
    run/1,
    run/2
]).

%%------------------------------------------------------------------------------
%% Types

%% Task identifier: any term.
-type task_id() :: term().

%% Results returned
-type result() :: #{task_id() => term()}.

%% Task callback:
-type task_callback() ::
    fun(() -> term()) |                     %% fun()
    fun((task_id()) -> term()) |            %% fun(Id)
    fun((task_id(), result()) -> term()) |  %% fun(Id, DepsRet) - never called for callback-only tasks
    {fun((...) -> term()), [term()]}.       %% fun(Id, DepsRet, Args) or fun(Id, Args) for tasks with callback-only

%% Task and its dependencies
%% If dependencies are not specified, callback does not get DepsRet argument
-type task() :: task_callback() |
    {
        DependsOn :: [task_id()],
        Callback :: task_callback()
    }.

%% Task map supplied to run
-type tasks_map() :: #{task_id() => task()}.

-export_type([
    task_id/0,
    tasks_map/0
]).

%%------------------------------------------------------------------------------
%% API

-spec run(tasks_map()) ->
    {ok, result()} | {error, Partial :: result(), Reason :: term()}.
run(Tasks) ->
    Concurrency = min(map_size(Tasks), erlang:system_info(schedulers)),
    run(Tasks, Concurrency).

-spec run(tasks_map(), pos_integer()) ->
    {ok, result()} | {error, Partial :: result(), Reason :: term()}.
run(Tasks, Concurrency) ->
    %% topo-sort tasks
    DAG = digraph:new([acyclic, private]),
    [Id = digraph:add_vertex(DAG, Id) || Id <- maps:keys(Tasks)],
    [[_|_] = digraph:add_edge(DAG, Dep, Id) || {Id, {Deps, _Fun}} <- maps:to_list(Tasks), is_list(Deps), Dep <- Deps],
    Order = digraph_utils:topsort(DAG),
    digraph:delete(DAG),
    execute_impl(Tasks, Order, #{}, Concurrency, #{}).

%%------------------------------------------------------------------------------
%% Internal implementation

%% ensure tail-recursiveness!
execute_impl(_Tasks, [], Workers, _Concurrency, Out) when map_size(Workers) =:= 0 ->
    %% all done
    {ok, Out};
execute_impl(Tasks, [], Workers, Concurrency, Out) ->
    %% no jobs left, but workers are still busy
    wait_job_response(Tasks, [], Workers, Concurrency, Out);
execute_impl(Tasks, Order, Workers, Concurrency, Out) when map_size(Workers) >= Concurrency ->
    %% maximum concurrency reached, wait for a worker to respond
    wait_job_response(Tasks, Order, Workers, Concurrency, Out);
execute_impl(Tasks, [V | Tail] = Order, Workers, Concurrency, Out) ->
    %% find if any dependency hasn't been satisfied yet
    case maps:get(V, Tasks) of
        {Deps, UserCb} when is_list(Deps) ->
            case lists:any(fun (Dep) -> not is_map_key(Dep, Out) end, Deps) of
                true ->
                    %% no luck, blocked by some dependency that hasn't finished yet
                    wait_job_response(Tasks, Order, Workers, Concurrency, Out);
                false ->
                    %% spawn worker to do some Fun
                    {Pid, MRef} = spawn_task(UserCb, self(), V, Deps, Out),
                    execute_impl(Tasks, Tail, Workers#{Pid => MRef}, Concurrency, Out)
            end;
        UserCb ->
            {Pid, MRef} = spawn_task(UserCb, self(), V, [], undefined),
            execute_impl(Tasks, Tail, Workers#{Pid => MRef}, Concurrency, Out)
    end.

wait_job_response(Tasks, Order, Workers, Concurrency, Out) ->
    receive
        {ok, Worker, Source, Result} ->
            demonitor(maps:get(Worker, Workers), [flush]),
            execute_impl(Tasks, Order, maps:remove(Worker, Workers), Concurrency, Out#{Source => Result});
        {'DOWN', _MRef, process, _Worker, Reason}->
            %% kill all workers and fail
            [exit(W, kill) || W <- maps:keys(Workers)],
            {error, Out, Reason}
    end.

%% handling all kinds of callback syntax definitions
spawn_task(UserCb, Self, V, _Deps, _Out) when is_function(UserCb, 0) ->
    spawn_monitor(fun () -> Self ! {ok, self(), V, UserCb()} end);
%% fun(Id) - both dep/nodep
spawn_task(UserCb, Self, V, _Deps, _Out) when is_function(UserCb, 1) ->
    spawn_monitor(fun () -> Self ! {ok, self(), V, UserCb(V)} end);
%% no-dep callback: fun(Id, Arg1, Arg2)
spawn_task({Fun, Args}, Self, V, [], undefined) ->
    spawn_monitor(fun () -> Self ! {ok, self(), V, erlang:apply(Fun, [V | Args])} end);
%% dep callback, with deps results requested
spawn_task(UserCb, Self, V, Deps, Out) when is_function(UserCb, 2) ->
    Res = maps:with(Deps, Out),
    spawn_monitor(fun () -> Self ! {ok, self(), V, UserCb(V, Res)} end);
%% dep callback, with deps results and additional args
spawn_task({Fun, Args}, Self, V, Deps, Out) when is_list(Args) ->
    Res = maps:with(Deps, Out),
    spawn_monitor(fun () -> Self ! {ok, self(), V, erlang:apply(Fun, [V, Res | Args])} end);
spawn_task(Cb, _, _, _, _) ->
    error({unsupported_callback, Cb}).
