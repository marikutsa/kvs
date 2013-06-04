-module(store_riak).
-author('Maxim Sokhatsky <maxim@synrc.com>').
-copyright('Synrc Research Center s.r.o.').
-include_lib("kvs/include/config.hrl").
-include_lib("kvs/include/users.hrl").
-include_lib("kvs/include/groups.hrl").
-include_lib("kvs/include/feeds.hrl").
-include_lib("kvs/include/acls.hrl").
-include_lib("kvs/include/invites.hrl").
-include_lib("kvs/include/meetings.hrl").
-include_lib("kvs/include/membership_packages.hrl").
-include_lib("kvs/include/accounts.hrl").
-include_lib("kvs/include/log.hrl").
-include_lib("stdlib/include/qlc.hrl").
-compile(export_all).

delete() -> ok.
start() -> ok.
stop() -> stopped.

initialize() ->
    C = riak:client_connect(node()),
    ets:new(config, [named_table,{keypos,#config.key}]),
    ets:insert(config, #config{ key = "riak_client", value = C}),
    ok.

init_indexes() ->
    C = riak_client(),
    C:set_bucket(key_to_bin(id_seq), [{backend, leveldb_backend}]),
    C:set_bucket(key_to_bin(subscription), [{backend, leveldb_backend}]),
    C:set_bucket(key_to_bin(user), [{backend, leveldb_backend}]),
    C:set_bucket(key_to_bin(group), [{backend, leveldb_backend}]),
    C:set_bucket(key_to_bin(translation), [{backend, leveldb_backend}]),
    C:set_bucket(key_to_bin(group_subscription), [{backend, leveldb_backend}]),
    C:set_bucket(key_to_bin(user_bought_gifts), [{backend, leveldb_backend}]),
    C:set_bucket(key_to_bin(play_record), [{backend, leveldb_backend}]),
    ok.

dir() ->
    C = riak_client(),
    {ok,Buckets} = C:list_buckets(),
    [binary_to_list(X)||X<-Buckets].

riak_clean(Table) when is_list(Table)->
    C = riak_client(),
    {ok,Keys}=C:list_keys(erlang:list_to_binary(Table)),
    [ C:delete(erlang:list_to_binary(Table),Key) || Key <- Keys];
riak_clean(Table) ->
    C = riak_client(),
    [TableStr] = io_lib:format("~p",[Table]),
    {ok,Keys}=C:list_keys(erlang:list_to_binary(TableStr)),
    [ kvs:delete(Table,key_to_bin(Key)) || Key <- Keys].

make_object(T) ->
    Bucket = element(1,T),
    Key = element(2,T),
    Obj1 = riak_object:new(key_to_bin(Bucket), key_to_bin(Key), T),
    Indices = make_indices(T),
    Meta = dict:store(<<"index">>, Indices, dict:new()),
    Obj2 = riak_object:update_metadata(Obj1, Meta),
    error_logger:info_msg("RIAK PUT IDX ~p",[Indices]),
    Obj2.

make_indices(#subscription{who=Who, whom=Whom}) -> [{<<"subs_who_bin">>, key_to_bin(Who)}, {<<"subs_whom_bin">>, key_to_bin(Whom)}];
make_indices(#group_subscription{user_id=UId, group_id=GId}) -> [{<<"group_subs_user_bin">>, key_to_bin(UId)}, {<<"group_subs_group_bin">>, key_to_bin(GId)}];
make_indices(#user_bought_gifts{username=UId}) -> [{<<"user_bought_gifts_username_bin">>, key_to_bin(UId)}];
make_indices(#user{username=UId,zone=Zone}) -> [{<<"user_bin">>, key_to_bin(UId)}];
make_indices(Record) -> [{key_to_bin(atom_to_list(element(1,Record))++"_bin"),key_to_bin(element(2,Record))}].

riak_client() -> [{_,_,{_,C}}] = ets:lookup(config, "riak_client"), C.

put(Records) when is_list(Records) -> lists:foreach(fun riak_put/1, Records);
put(Record) -> store_riak:put([Record]).

riak_put(Record) ->
    Object = make_object(Record),
    Riak = riak_client(),
    Result = Riak:put(Object),
    error_logger:info_msg("RIAK PUT RES ~p",[Result]),
    post_write_hooks(Record, Riak),
    Result.

put_if_none_match(Record) ->
    Object = make_object(Record),
    Riak = riak_client(),
    case Riak:put(Object, [if_none_match]) of
        ok ->
            post_write_hooks(Record, Riak),
            ok;
        Error ->
            Error
    end.

update(Record, Object) ->
    NewObject = make_object(Record),
    NewKey = riak_object:key(NewObject),
    case riak_object:key(Object) of
        NewKey ->
            MetaInfo = riak_object:get_update_metatdata(NewObject),
            UpdObject2 = riak_object:update_value(Object, Record),
            UpdObject3 = riak_object:update_metadata(UpdObject2, MetaInfo),
            Riak = riak_client(),
            case Riak:put(UpdObject3, [if_not_modified]) of
                ok -> post_write_hooks(Record, Riak), ok;
                Error -> Error
            end;
        _ -> {error, keys_not_equal}
    end.

post_write_hooks(R,C) ->
    case element(1,R) of
        user -> case R#user.email of
                    undefined -> nothing;
                    _ -> C:put(make_object({email, R#user.username, R#user.email})) end,
                case R#user.verification_code of
                    undefined -> nothing;
                    _ -> C:put(make_object({code, R#user.username, R#user.verification_code})) end,
                case R#user.facebook_id of
                  undefined -> nothing;
                  _ -> C:put(make_object({facebook, R#user.username, R#user.facebook_id})) end;
        _ -> continue
    end.

get(Tab, Key) ->
    Bucket = key_to_bin(Tab),
    IntKey = key_to_bin(Key),
    riak_get(Bucket, IntKey).

riak_get(Bucket,Key) ->
    C = riak_client(),
    RiakAnswer = C:get(Bucket,Key),
    case RiakAnswer of
        {ok, O} -> {ok,riak_object:get_value(O)};
        X -> X
    end.

get_for_update(Tab, Key) ->
    C = riak_client(),
    case C:get(key_to_bin(Tab), key_to_bin(Key), [{last_write_wins,true},{allow_mult,false}]) of
        {ok, O} -> {ok, riak_object:get_value(O), O};
        Error -> Error
    end.

get_word(Word) -> store_riak:get(ut_word,Word).
get_translation({Lang, Word}) -> store_riak:get(ut_translation, Lang ++ "_" ++ Word).

delete(Keys) when is_list(Keys) -> lists:foreach(fun mnesia:delete_object/1, Keys); % TODO
delete(Keys) -> delete([Keys]).

delete(Tab, Key) ->
    C = riak_client(),
    Bucket = key_to_bin(Tab),
    IntKey = key_to_bin(Key),
    C:delete(Bucket, IntKey).

delete_by_index(Tab, IndexId, IndexVal) ->
    Riak = riak_client(),
    Bucket = key_to_bin(Tab),
    {ok, Keys} = Riak:get_index(Bucket, {eq, IndexId, key_to_bin(IndexVal)}),
    [Riak:delete(Bucket, Key) || Key <- Keys],
    ok.

key_to_bin(Key) ->
    if is_integer(Key) -> erlang:list_to_binary(integer_to_list(Key));
       is_list(Key) -> erlang:list_to_binary(Key);
       is_atom(Key) -> erlang:list_to_binary(erlang:atom_to_list(Key));
       is_binary(Key) -> Key;
       true ->  [ListKey] = io_lib:format("~p", [Key]), erlang:list_to_binary(ListKey)
    end.

select(RecordName, Pred) when is_function(Pred) ->
    All = all(RecordName),
    lists:filter(Pred, All);

select(RecordName, Select) when is_list(Select) ->
    Where = proplists:get_value(where, Select, fun(_)->true end),
    {Position, _Order} = proplists:get_value(order, Select, {1, descending}),
    Limit = proplists:get_value(limit, Select, all),
    Selected = select(RecordName, Where),
    Sorted = lists:keysort(Position, Selected),
    case Limit of
        all -> Sorted;
        {Offset, Amoumt} -> lists:sublist(Sorted, Offset, Amoumt) end.

count(_RecordName) -> erlang:length(all(_RecordName)).

all(RecordName) ->
    Riak = riak_client(),
    [RecordStr] = io_lib:format("~p",[RecordName]),
    RecordBin = erlang:list_to_binary(RecordStr),
    {ok,Keys} = Riak:list_keys(RecordBin),
    Results = [ get_record_from_table({RecordBin, Key, Riak}) || Key <- Keys ],
    [ Object || Object <- Results, Object =/= failure ].

all_by_index(Tab, IndexId, IndexVal) ->
    Riak = riak_client(),
    Bucket = key_to_bin(Tab),
    {ok, Keys} = Riak:get_index(Bucket, {eq, IndexId, key_to_bin(IndexVal)}),
    F = fun(Key, Acc) ->
                case Riak:get(Bucket, Key, []) of
                    {ok, O} -> [riak_object:get_value(O) | Acc];
                    {error, notfound} -> Acc end end,
    lists:foldl(F, [], Keys).

get_record_from_table({RecordBin, Key, Riak}) ->
    case Riak:get(RecordBin, Key) of
        {ok,O} -> riak_object:get_value(O);
        X -> failure end.

next_id(CounterId) -> next_id(CounterId, 1).
next_id(CounterId, Incr) -> next_id(CounterId, 0, Incr).
next_id(CounterId, Default, Incr) ->
    Riak = riak_client(),
    CounterBin = key_to_bin(CounterId),
    {Object, Value, Options} =
        case Riak:get(key_to_bin(id_seq), CounterBin, []) of
            {ok, CurObj} ->
                R = #id_seq{id = CurVal} = riak_object:get_value(CurObj),
                NewVal = CurVal + Incr,
                Obj = riak_object:update_value(CurObj, R#id_seq{id = NewVal}),
                {Obj, NewVal, [if_not_modified]};
            {error, notfound} ->
                NewVal = Default + Incr,
                Obj = riak_object:new(key_to_bin(id_seq), CounterBin, #id_seq{thing = CounterId, id = NewVal}),
                {Obj, NewVal, [if_none_match]} end,
    case Riak:put(Object, Options) of
        ok -> Value;
        {error, _} -> next_id(CounterId, Incr) end.