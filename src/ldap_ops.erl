%% @author Oleg Smirnov <oleg.smirnov@gmail.com>
%% @doc LDAP Operations

-module(ldap_ops).

-behaviour(gen_server).

-export([start_link/0, dispatch/5]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-include("LDAP.hrl").

-define(COLL, "root").

start_link() ->
    gen_server:start_link(?MODULE, [], []).

init(_) ->
    {ok, {}}.

dispatch(Pid, ProtocolOp, MessageID, BindDN, From) ->
    gen_server:cast(Pid, {ProtocolOp, MessageID, BindDN, From}).

rdn(DN) ->
    lists:reverse(DN).

bind(BindDN, {simple, Password}) ->
    Filter = {equalityMatch, 
	      {'AttributeValueAssertion', "userPassword", Password}},
    search(BindDN, BindDN, baseObject, 1, Filter, []);
bind(_BindDN,_Creds) ->
    authMethodNotSupported.

bind_reply(_From, BindResult,_MessageID) when is_atom(BindResult) ->
    BindResult;
bind_reply(_From, [],_MessageID) ->
    invalidCredentials;
bind_reply(From, [BindResult],_MessageID) when is_list(BindResult) ->
    BindDN = bitstring_to_list(object_get("dn", BindResult)),
    ldap_fsm:set_bind(From, BindDN),
    success.

search(undefined,_BaseObject,_Scope,_SizeLimit,_Filter,_Attributes) ->
    insufficientAccessRights;
search(_BindDN, BaseObject, Scope, SizeLimit, Filter, Attributes) ->
    ScopeFilter = ldap_filter:scope(BaseObject, Scope),
    EntryFilter = ldap_filter:filter(Filter),
    FieldsOption = ldap_filter:fields(Attributes),
    LimitOption = ldap_filter:limit(SizeLimit),
    emongo:find_all(eds, ?COLL, 
		    ScopeFilter ++ EntryFilter,
		    FieldsOption ++ LimitOption).

search_reply(_From, SearchResult,_MessageID) when is_atom(SearchResult) ->
    SearchResult;
search_reply(From, [Item|Result], MessageID) ->
    Attrs = lists:flatten(
	      lists:map(fun(I) -> 
				item_to_attribute(I) 
			end, Item)),
    {value, {_, "dn", [DN]}, PartialAttrs} = lists:keytake("dn", 2, Attrs),
    Entry = {'SearchResultEntry', DN, PartialAttrs},
    ldap_fsm:reply(From, {{searchResEntry, Entry}, MessageID}),
    search_reply(From, Result, MessageID);
search_reply(_From, [],_MessageID) ->
    success.

object_modify(Key, NewValue, Entry) when is_list(Key) ->
    object_modify(list_to_bitstring(Key), NewValue, Entry);
object_modify(Key, NewValue, Entry) when is_bitstring(Key),
					 is_list(NewValue) ->
    object_modify(Key, list_to_bitstring(NewValue), Entry);
object_modify(Key, NewValue, Entry) when is_bitstring(Key),
					 is_bitstring(NewValue) ->
    lists:keyreplace(Key, 1, Entry, {Key, NewValue}).

object_get(Key, Entry) when is_list(Key) ->
    object_get(list_to_bitstring(Key), Entry);
object_get(Key, Entry) when is_bitstring(Key) ->
    element(2, lists:keyfind(Key, 1, Entry)).

modify_dn(_BindDN, DN, NewRDN,_DeleteOldRDN) ->
    case emongo:find_one(eds, ?COLL, [{"_rdn", rdn(DN)}]) of
	[] -> noSuchObject;
	[Entry] ->
	    OldDN = bitstring_to_list(object_get(<<"dn">>, Entry)),
	    BaseDN = lists:dropwhile(fun(C) -> C =/= $, end, OldDN),
	    NewDN = NewRDN ++ BaseDN,	   
	    ModDN = object_modify(<<"dn">>, NewDN, Entry),
	    NewEntry = object_modify(<<"_rdn">>, rdn(NewDN), ModDN),
	    [Res] = emongo:update_sync(eds, ?COLL, [{<<"_rdn">>, rdn(DN)}], NewEntry, false),
	    case lists:keyfind(<<"err">>, 1, Res) of
		{<<"err">>, undefined} -> success;
		_Else -> protocolError
	    end
    end.	
		
item_to_attribute({_Name, {oid, _}}) ->
    [];
item_to_attribute({<<"_rdn">>,_}) ->
    [];
item_to_attribute({Name, Value}) when is_bitstring(Name),
				      is_bitstring(Value) ->
    {'PartialAttribute', 
     bitstring_to_list(Name), 
     [bitstring_to_list(Value)]};
item_to_attribute({Name, {array, Value}}) when is_bitstring(Name), 
					       is_list(Value) ->
    lists:map(fun(V) -> 
		      {'PartialAttribute', 
		       bitstring_to_list(Name),
		       [bitstring_to_list(V)]}
	      end, Value).

handle_cast({{bindRequest, Options}, MessageID,_BindDN, From}, State) ->
    {'BindRequest',_, BindDN, Creds} = Options,
    BindResult = bind(BindDN, Creds),
    Result = bind_reply(From, BindResult, MessageID),
    Response = #'BindResponse'{resultCode = Result, matchedDN = "", diagnosticMessage = ""},
    ldap_fsm:reply(From, {{bindResponse, Response}, MessageID}),
    {stop, normal, State};

handle_cast({{searchRequest, Options}, MessageID, BindDN, From}, State) ->
    {'SearchRequest', BaseObject, Scope,_, SizeLimit,_,_, Filter, Attributes} = Options,
    SearchResult = search(BindDN, BaseObject, Scope, SizeLimit, Filter, Attributes),
    Result = search_reply(From, SearchResult, MessageID),
    Response = #'LDAPResult'{resultCode = Result, matchedDN = "", diagnosticMessage = ""},
    ldap_fsm:reply(From, {{searchResDone, Response}, MessageID}),
    {stop, normal, State};

handle_cast({{modifyRequest, Options},_BindDN,_From}, State) ->
    io:format("-> ~p~n", [Options]),
    {stop, normal, State};

handle_cast({{addRequest, Options},_BindDN,_From}, State) ->
    {'AddRequest'} = Options,
    {stop, normal, State};

handle_cast({{modDNRequest, Options}, MessageID, BindDN, From}, State) ->
    {'ModifyDNRequest', DN, NewRDN, DeleteOldRDN,_} = Options,
    Result = modify_dn(BindDN, DN, NewRDN, DeleteOldRDN),
    Response = #'LDAPResult'{resultCode = Result, matchedDN = "", diagnosticMessage = ""},
    ldap_fsm:reply(From, {{modDNResponse, Response}, MessageID}),    
    {stop, normal, State};

handle_cast(Request, State) ->
    {stop, {unknown_cast, Request}, State}.

handle_call(Request,_From, State) ->
    {stop, {unknown_call, Request}, State}.

handle_info({'EXIT',_, Reason}, State) ->
    {stop, Reason, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason,_State) ->
    ok.

code_change(_OldVsn, State,_Extra) ->
    {ok, State}.
