% Nitrogen Web Framework for Erlang
% Copyright (c) 2008-2009 Rusty Klophaus
% See MIT-LICENSE for licensing information.

-module (session_handler).
-export ([
	behaviour_info/1, get_value/2, get_value/3, set_value/3, clear_value/2, clear_all/1
]).



% get(Key, DefaultValue, Context, State, Key, DefaultValue) -> {ok, Value, NewContext, NewState}.
% Retrieve a value from the storage area.
get_value(Key, Context) ->
	_Value = get_value(Key, undefined, Context).
	
% get(Key, DefaultValue, Context, State, Key, DefaultValue) -> {ok, Value, NewContext, NewState}.
% Retrieve a value from the storage area.
get_value(Key, DefaultValue, Context) ->
	_Value = wf_context:apply(session, get_value, [Key, DefaultValue], Context).
	
% set_value(Key, Value, Context, State) -> {ok, NewContext, NewState}.
% Put a value into the storage area.
set_value(Key, Value, Context) ->
	{ok, _NewContext} = wf_context:apply(session, set_value, [Key, Value], Context).

% clear_value(Key, Context, State) -> {ok, NewContext, NewState}.
% Remove a value from the storage area.
clear_value(Key, Context) ->
	{ok, _NewContext} = wf_context:apply(session, clear_value, [Key], Context).

% clear_all(Context, State) -> {ok, NewContext, NewState}.
% Clear all values from the storage area.
clear_all(Context) ->
	{ok, _NewContext} = wf_context:apply(session, clear_all, Context).



behaviour_info(callbacks) -> [
	{init, 2},      
	{finish, 2},
	{get_value, 4},       
	{set_value, 4},
	{clear_value, 3},
	{clear_all, 2}
];
behaviour_info(_) -> undefined.