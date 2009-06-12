% Nitrogen Web Framework for Erlang
% Copyright (c) 2008-2009 Rusty Klophaus
% See MIT-LICENSE for licensing information.

-module (action_async).
-include ("wf.inc").
-compile(export_all).

% Comet and polling/continuations are now handled using Nitrogen's asynchronous
% processing scheme. This allows you to fire up an asynchronous process with the
% #async { fun=AsyncFunction } action.
%
% TERMINOLOGY:

% AsyncFunction - An Erlang function that executes in the background. The function
% generates Actions that are then sent to the browser via the accumulator. In addition
% each AsyncFunction is part of one (and only one) pool. Messages sent to the pool
% are distributed to all AsyncFunction processes within that pool.
%
% Series - A series of requests to a Nitrogen resource. A series consists of 
% the first request plus any postbacks by the same visitor in the same browser
% window.
% 
% Accumulator - There is one accumulator per series. The accumulator holds
% Nitrogen actions generated by AsyncFunctions, and is checked at the end
% of each Nitrogen request for anything that should be sent to the browser.
%
% Pool - A pool is a grouping of AsyncFunctions. Any messages sent to the pool
% are distributed to all processes within the pool. This provides the foundation
% for chat applets and other interactive/multi-user software.
%
% AsyncGuardian - A process that keeps an eye on the AsyncFunction process. When the
% AsyncFunction process ends or dies, the Guardian sends dying_message to pool.
% When the Guardian recieves the die command, it calls exit(Pid, async_die)
% and then sends dying_message to the pool.
%
render_action(Record, Context) -> 
	% This will immediately trigger a postback to event/1 below.
	Actions = #event {
		type=system,
		delay=0,
		delegate=?MODULE,
		postback={spawn_async_function, Record}
	},
	{ok, Actions, Context}.
	
% This clause is the heart of async functions. It handles an
% incoming async postback, looks for any actions in the accumulator,
% and wires the actions, along with an additional event that
% tells the browser to initiate another postback, thus
% forming a loop.
event(start_async, Context) ->
	Page = Context#context.page_context,
	case Page#page_context.async_mode of
		comet ->
			% Start the first comet postback...
			{ok, Actions, Context1} = get_actions_blocking(Context, 20000),
			Event = start_async_event(),
			{ok, _Context2} = wff:wire([Actions, Event], Context1);
			
		{poll, Interval} ->
			% Start the first polling postback...
			{ok, Actions, Context1} = get_actions(Context),
			Event = start_async_event(Interval),
			{ok, _Context2} = wff:wire([Actions, Event], Context1)
	end;
	
% This event is called to start a Nitrogen async function.
% In the process of starting the function, it will create
% an accumulator and a pool if they don't already exist.
event({spawn_async_function, Record}, Context) ->
	% Some values...
	Page = Context#context.page_context,
	SeriesID = Page#page_context.series_id,
	Pool = Record#async.pool,
	Scope = Record#async.scope,

	% Get or start the accumulator process, which is used to hold any Nitrogen Actions 
	% that are generated by async processes.
	{ok, AccumulatorPid, Context1} = get_accumulator_pid(SeriesID, Context),
	
	% Get or start the pool process, which is a distributor that sends Erlang messages
	% to the running async function.
	{ok, PoolPid, Context2} = get_pool_pid(SeriesID, Pool, Scope, Context1), 
	
	% Create a process for the AsyncFunction...
	AsyncFunction = Record#async.function,
	FunctionPid = erlang:spawn(fun() -> AsyncFunction(Context2) end),
	
	% Create a process for the AsyncGuardian...
	DyingMessage = Record#async.dying_message,
	GuardianPid = erlang:spawn(fun() -> guardian_loop(FunctionPid, AccumulatorPid, PoolPid, DyingMessage) end),
	
	% Register the function with the accumulator and the pool.
	AccumulatorPid!{add_guardian, GuardianPid},
	PoolPid!{add_process, FunctionPid},

	{ok, _Context3} = wff:wire(start_async_event(), Context2).


accumulator_loop(Guardians, Actions, Waiting) ->
	receive
		{add_guardian, GuardianPid} ->
			accumulator_loop([GuardianPid|Guardians], Actions, Waiting);
		
		{remove_guardian, GuardianPid} ->
			accumulator_loop(Guardians -- [GuardianPid], Actions, Waiting);
		
		{add_actions, NewActions} ->
			case is_pid(Waiting) andalso is_process_alive(Waiting) of
				true -> 
					Waiting!{actions, [NewActions|Actions]},
					accumulator_loop(Guardians, [], none);
				false ->
					accumulator_loop(Guardians, [NewActions|Actions], none)
			end;
			
		{get_actions_blocking, Pid} when Actions == [] ->
			accumulator_loop(Guardians, [], Pid);
			
		{get_actions_blocking, Pid} when Actions /= [] ->
			Pid!{actions, Actions},
			accumulator_loop(Guardians, [], none);

		{get_actions, Pid} ->
			Pid!{actions, Actions},
			accumulator_loop(Guardians, [], none);
									
		die -> 
			[erlang:exit(GuardianPid, async_die) || GuardianPid <- Guardians];
			
		Other ->
			?PRINT({unhandled_event, Other})
	end.

pool_loop(Processes) -> 
	receive
		{add_process, Pid} -> 
			pool_loop([Pid|Processes]);
			
		{remove_process, Pid} ->
			pool_loop(Processes -- [Pid]);
			
		{send_message, Message} ->
			[Pid!Message || Pid <- Processes],
			pool_loop(Processes);
			
		Other ->
			?PRINT({unhandled_event, Other})
	end.

guardian_loop(FunctionPid, AccumulatorPid, PoolPid, DyingMessage) ->
	erlang:monitor(process, FunctionPid),
	receive
		{'DOWN', _MonitorRef, process, FunctionPid, _Info} ->
			% The AsyncFunction process has died. Communicate dying_message to the
			% pool and exit.
			PoolPid!{send_message, DyingMessage};
			
		{'EXIT', FunctionPid, _Reason} -> 
			% The accumulator has told us to die. Communicate dying_message to the
			% pool, kill the AsyncFunction process, and exit.
			PoolPid!{send_message, DyingMessage},
			erlang:exit(FunctionPid, async_die);
			
		Other ->
			?PRINT({unhandled_event, Other})
	end,
	AccumulatorPid!{remove_guardian, self()}.
			
flush(Context) ->
	Page = Context#context.page_context,
	SeriesID = Page#page_context.series_id,
	{ok, AccumulatorPid, Context1} = process_cabinet_handler:get_set(SeriesID, fun() -> accumulator_loop([], [], none) end, Context),
	AccumulatorPid!{add_actions, Context1#context.queued_actions},
	{ok, Context1#context { queued_actions=[] }}.
	
send(Pool, Message, Context) ->
	inner_send(Pool, local, Message, Context).
	
send_global(Pool, Message, Context) ->
	inner_send(Pool, global, Message, Context).

%%% PRIVATE FUNCTIONS %%%

inner_send(Pool, Scope, Message, Context) ->
	Page = Context#context.page_context,
	SeriesID = Page#page_context.series_id,
	{ok, PoolPid, Context1} = get_pool_pid(SeriesID, Pool, Scope, Context),
	PoolPid!{send_message, Message},
	{ok, Context1}.

% Get actions from accumulator. If there are no actions currently in the
% accumulator, then [] is immediately returned.
get_actions(Context) ->
	Page = Context#context.page_context,
	SeriesID = Page#page_context.series_id,
	{ok, AccumulatorPid, Context1} = process_cabinet_handler:get_set(SeriesID, fun() -> accumulator_loop([], [], none) end, Context),
	Actions = case is_pid(AccumulatorPid) andalso is_process_alive(AccumulatorPid) of
		true -> 
			AccumulatorPid!{get_actions, self()},
			receive
				{actions, X} -> 
					X;
				Other -> 
					?PRINT({unhandled_event, Other})
			end;
		false -> []
	end,
	{ok, Actions, Context1}.
	
% Get actions from accumulator in a blocking fashion. If there are no actions
% currently in the accumulator, then this blocks for up to Timeout milliseconds.
% This works by telling Erlang to send a dummy 'add_actions' command to the accumulator
% that will be executed when the timeout expires.
get_actions_blocking(Context, Timeout) ->
	Page = Context#context.page_context,
	SeriesID = Page#page_context.series_id,
	{ok, AccumulatorPid, Context1} = process_cabinet_handler:get_set(SeriesID, fun() -> accumulator_loop([], [], none) end, Context),
	Actions = case is_pid(AccumulatorPid) andalso is_process_alive(AccumulatorPid) of
		true -> 
			TimerRef = erlang:send_after(Timeout, AccumulatorPid, {add_actions, []}),
			AccumulatorPid!{get_actions_blocking, self()},
			receive 
				{actions, X} -> 
					erlang:cancel_timer(TimerRef),
					X;
					
				Other ->
					?PRINT({unhandled_event, Other})
			end;
		false -> []
	end,
	{ok, Actions, Context1}.

start_async_event() ->
	#event { type=system, delay=0, delegate=?MODULE, postback=start_async }.
	
start_async_event(Interval) ->
	#event { type=system, delay=Interval, delegate=?MODULE, postback=start_async }.
	
% Get the PoolPid. This can either be local or global. By registering an async function
% with a global pool, any messages sent to that pool are sent to all processes in the pool.
% This is useful for multi-user applications.
get_pool_pid(SeriesID, Pool, Scope, Context) ->
	PoolID = case Scope of
		local  -> {Pool, SeriesID};
		global -> {Pool, global}
	end,
	{ok, _Pid, _Context1} = process_cabinet_handler:get_set(PoolID, fun() -> pool_loop([]) end, Context).

% Get the AccumulatorPid. The accumulator stores actions until an async
% postback fetches them and renders them to the page.
get_accumulator_pid(SeriesID, Context) ->
	{ok, _Pid, _Context1} = process_cabinet_handler:get_set(SeriesID, fun() -> accumulator_loop([], [], none) end, Context).