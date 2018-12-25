-module(boot_stats).
-behavior(erllambda).

-export([handle/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(REPORT_RE,
        "REPORT\\s+RequestId:\\s+\\S+\\s+"
        "(?:Init Duration:\\s+(?<init>(\\d+(?:\\.\\d+)?)))?.*"
        "(?:Duration:\\s+(?<duration>(?1))).*"
        "(?:Billed Duration:\\s+(?<billed>(?1))).*"
        "(?:Memory Size:\\s+(?<memory_max>(?1))).*"
        "(?:Max Memory Used:\\s+(?<memory_used>(?1)))").

%%---------------------------------------------------------------------------
-spec handle(Event :: map(), Context :: map()) ->
    ok | {ok, iolist() | map()} | {error, iolist()}.
%%%---------------------------------------------------------------------------
%% @doc Handle lambda invocation
%%
handle(#{<<"Records">> := Records}, Context) ->
    AWSConfig = erllambda:config(),
    #{<<"MODE">> := Mode, <<"TABLE_NAME">> := TableName} = Context,
    process_records(Records, Mode, TableName, AWSConfig).

process_records([Record | Records], Mode, TableName, AWSConfig) ->
    Stats = parse_record(Record),
    report_stats(Stats, Mode, TableName, AWSConfig),
    process_records(Records, Mode, TableName, AWSConfig);
process_records([], _Mode, _TableName, _AWSConfig) ->
    ok.

parse_record(#{<<"kinesis">> := #{<<"data">> := Data}}) ->
    CWBody = zlib:gunzip(base64:decode(Data)),
    parse_cw_message(jsone:decode(CWBody)).

parse_cw_message(#{<<"messageType">> := <<"DATA_MESSAGE">>,
                   <<"logEvents">>   := LogEvents}) ->
    parse_log_events(LogEvents);
parse_cw_message(_) ->
    [].

parse_log_events(LogEvents) ->
    lists:filtermap(fun parse_log_event/1, LogEvents).

parse_log_event(#{<<"message">> := Message} = LogEvent) ->
    MatchPattern = re_pattern(),
    case re:run(Message, MatchPattern, [{capture, all_names, binary}]) of
        {match, Values} ->
            {namelist, Names} = re:inspect(MatchPattern, namelist),
            Stats = [{Name, binary_to_number(Value)}
                     || {Name, Value} <- lists:zip(Names, Values), Value /= <<>>],
            Keys = [<<"id">>, <<"timestamp">>],
            List = maps:to_list(maps:with(Keys, LogEvent)),
            {true, List ++ Stats};
        nomatch ->
            false
    end.

binary_to_number(Binary) ->
    try
        binary_to_float(Binary)
    catch
        _:_ ->
            binary_to_integer(Binary)
    end.

re_pattern() ->
    case application:get_env(boot_stats, re_pattern) of
        {ok, Pattern} ->
            Pattern;
        undefined ->
            {ok, Pattern} = re:compile(?REPORT_RE),
            application:set_env(boot_stats, re_pattern, Pattern),
            Pattern
    end.

report_stats([] = _Stats, _Mode, _TableName, _AWSConfig) ->
    ok;
report_stats(Stats0, Mode, TableName, AWSConfig) ->
    Stats = [[{<<"mode">>, Mode} | Item] || Item <- Stats0],
    ok = erlcloud_ddb_util:put_all(TableName, Stats, [], AWSConfig).

%%====================================================================
%% Test Functions
%%====================================================================
-ifdef(TEST).

make_log_message(LogEvents) ->
    #{<<"messageType">> => <<"DATA_MESSAGE">>,
      <<"logEvents">> => LogEvents}.

make_kinesis_record(LogEvents) ->
    LogMessage = make_log_message(LogEvents),
    Body = jsone:encode(LogMessage),
    Data = base64:encode(zlib:gzip(Body)),
    #{<<"kinesis">> =>
          #{<<"data">> => Data}}.

process_records_test_() ->
    {setup,
     fun() ->
             Modules = [erlcloud_ddb_util],
             meck:new(Modules, [no_link]),
             meck:expect(erlcloud_ddb_util, put_all, 4, ok),
             Modules
     end,
     fun meck:unload/1,
     {foreach,
      fun reset_ddb_history/0,
      [
       {"do not put stats for lines w/o stats data",
        assert_put([],
                   [make_kinesis_record(
                      [#{<<"id">>        => <<"1">>,
                         <<"timestamp">> => 1545335884699,
                         <<"message">>   => <<"creating necessary erllambda run dirs\n">>}])],
                   <<"interactive">>, <<"stats">>, aws_config)},
       {"put stats for non cool boot",
        assert_put([[[{<<"mode">>,         <<"interactive">>},
                      {<<"id">>,           <<"1">>},
                      {<<"timestamp">>,    1545335884699},
                      {<<"billed">>,       100},
                      {<<"duration">>,     94.13},
                      {<<"memory_max">>,   256},
                      {<<"memory_used">>,  50}]]],
                   [make_kinesis_record(
                      [#{<<"id">>        => <<"1">>,
                         <<"timestamp">> => 1545335884699,
                         <<"message">>   => <<"REPORT RequestId: a14281a9-0491-11e9-948b-754ac39022de\tDuration: 94.13 ms\tBilled Duration: 100 ms \tMemory Size: 256 MB\tMax Memory Used: 50 MB\t\n">>}])],
                   <<"interactive">>, <<"stats">>, aws_config)},
       {"put stats for cool boot",
        assert_put([[[{<<"mode">>,        <<"interactive">>},
                      {<<"id">>,          <<"1">>},
                      {<<"timestamp">>,   1545335884699},
                      {<<"billed">>,      600},
                      {<<"duration">>,    88.78},
                      {<<"init">>,        451.52},
                      {<<"memory_max">>,  256},
                      {<<"memory_used">>, 49}]]],
                   [make_kinesis_record(
                      [#{<<"id">>        => <<"1">>,
                         <<"timestamp">> => 1545335884699,
                         <<"message">>   => <<"REPORT RequestId: 8fc6cbdc-0491-11e9-86bf-cb4e21669311\tInit Duration: 451.52 ms\tDuration: 88.78 ms\tBilled Duration: 600 ms \tMemory Size: 256 MB\tMax Memory Used: 49 MB\t\n">>}])],
                   <<"interactive">>, <<"stats">>, aws_config)},
       {"put multiple items",
        assert_put([[[{<<"mode">>,        <<"interactive">>},
                      {<<"id">>,          <<"1">>},
                      {<<"timestamp">>,   1545335884699},
                      {<<"billed">>,      600},
                      {<<"duration">>,    88.78},
                      {<<"init">>,        451.52},
                      {<<"memory_max">>,  256},
                      {<<"memory_used">>, 49}],
                     [{<<"mode">>,        <<"interactive">>},
                      {<<"id">>,          <<"3">>},
                      {<<"timestamp">>,   1545335884699},
                      {<<"billed">>,      100},
                      {<<"duration">>,    94.13},
                      {<<"memory_max">>,  256},
                      {<<"memory_used">>, 50}]]],
                   [make_kinesis_record(
                      [#{<<"id">>        => <<"1">>,
                         <<"timestamp">> => 1545335884699,
                         <<"message">>   => <<"REPORT RequestId: 8fc6cbdc-0491-11e9-86bf-cb4e21669311\tInit Duration: 451.52 ms\tDuration: 88.78 ms\tBilled Duration: 600 ms \tMemory Size: 256 MB\tMax Memory Used: 49 MB\t\n">>},
                       #{<<"id">>        => <<"2">>,
                         <<"timestamp">> => 1545335884699,
                         <<"message">>   => <<"Invoke Next path 1545335885108 http://127.0.0.1:9001/2018-06-01/runtime/invocation/next\n">>}
                       #{<<"id">>        => <<"3">>,
                         <<"timestamp">> => 1545335884699,
                         <<"message">>   => <<"REPORT RequestId: a14281a9-0491-11e9-948b-754ac39022de\tDuration: 94.13 ms\tBilled Duration: 100 ms \tMemory Size: 256 MB\tMax Memory Used: 50 MB\t\n">>}]),
                    make_kinesis_record([]),
                    make_kinesis_record(
                      [#{<<"id">>        => <<"3">>,
                         <<"timestamp">> => 1545335884699,
                         <<"message">>   => <<"creating necessary erllambda run dirs\n">>}])],
                   <<"interactive">>, <<"stats">>, aws_config)}
      ]}}.

assert_put(Expected, Records, Mode, TableName, Config) ->
    fun() ->
            process_records(Records, Mode, TableName, Config),
            ?assertEqual(Expected, put_items_history())
    end.

reset_ddb_history() ->
    meck:reset(erlcloud_ddb_util).

put_items_history() ->
    [Item
     || {_Pid, {_Module, put_all, [_Table, Item, _Opts, _Config]}, _Result}
            <- meck:history(erlcloud_ddb_util)].

-endif.
