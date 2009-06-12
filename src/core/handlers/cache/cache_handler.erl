% Nitrogen Web Framework for Erlang
% Copyright (c) 2008-2009 Rusty Klophaus
% See MIT-LICENSE for licensing information.

-module (cache_handler).
-export ([
	behaviour_info/1, get_set/4, clear/2, clear_all/1
]).



% get_set(Key, Function, TTL, Context, State) -> {ok, Value, NewContext, NewState}
% Return the cache value associated with Key. If it is not found,
% then run the Function, store the resulting value in cache under
% Key, and return the value.
get_set(Key, Function, TTL, Context) -> 
	{ok, _Value, _NewContext} = wf_context:apply(cache, get_set, [Key, Function, TTL], Context).

% clear(Key, Context, State) -> {ok, NewContext, NewState}
% Remove a value from cache.
clear(Key, Context) ->	
	{ok, _NewContext} = wf_context:apply(cache, clear, [Key], Context).
	
% clear_all(Context, State) -> {ok, NewContext, NewState}
% Clear all values from cache.
clear_all(Context) -> 
	{ok, _NewContext} = wf_context:apply(cache, clear_all, Context).



behaviour_info(callbacks) -> [
	{init, 2},      
	{finish, 2},
	{get_set, 5}, 
	{clear, 3},
	{clear_all, 2}
];
behaviour_info(_) -> undefined.
