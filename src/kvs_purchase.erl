-module(kvs_purchase).
-include_lib("kvs/include/products.hrl").
-include_lib("kvs/include/purchases.hrl").
-include_lib("kvs/include/log.hrl").
-include_lib("kvs/include/accounts.hrl").
-include_lib("kvs/include/feed_state.hrl").
-compile(export_all).

solvent(UId, ProductId) ->
    {ok, Credit} = kvs_accounts:balance(UId, currency),
    {ok, #product{price = Price}} = kvs:get(product, ProductId),
    Credit >= Price.

buy(UId, ProductId) ->
    {ok, #product{price = Price, name = Name}} = kvs:get(product, ProductId),
    kvs_accounts:transaction(UId, currency, -Price, "Buy " ++ Name ++ " for "++ integer_to_list(Price)),
    kvs:put(#user_product{username=UId, timestamp=now(), product_id = ProductId}).

give(UId, PId) ->
    kvs:put(#user_product{username=UId, timestamp=now(), product_id = PId}).

products(UId) ->
    kvs:all_by_index(user_product, <<"user_bin">>, list_to_binary(UId)).

handle_notice(["kvs_purchase", "user", UId, "buy"] = Route,
    Message, #state{owner = Owner, type =Type} = State) ->
    ?INFO(" queue_action(~p): buy_gift: Owner=~p, Route=~p, Message=~p", [self(), {Type, Owner}, Route, Message]),
    {GId} = Message,
    buy(UId, GId),
    {noreply, State};

handle_notice(["kvs_purchase", "user", UId, "give"] = Route,
    Message, #state{owner = Owner, type =Type} = State) ->
    ?INFO(" queue_action(~p): give_gift: Owner=~p, Route=~p, Message=~p", [self(), {Type, Owner}, Route, Message]),
    {GId} = Message,
    give(UId, GId),
    {noreply, State};

handle_notice(Route, Message, State) -> error_logger:info_msg("Unknown PURCHASE notice").
