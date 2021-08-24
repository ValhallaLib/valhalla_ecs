module vecs.query;

import vecs.entity;
import vecs.entitymanager;

import std.format : format;
import std.meta : All = allSatisfy;
import std.meta : Not = templateNot;
import std.meta : ApplyRight, Filter;
import std.traits : hasUDA;

private enum QueryRule;

/// Include entities with Args
@QueryRule struct With(Args...) if (Args.length) {}

/// Ignore entities with Args
@QueryRule struct Without(Args...) if (Args.length) {}

/// Select entities with Args
struct Select(Args...) if (Args.length) {}

// TODO: documentation
// TODO: unittests
template Query(EntityManagerT, Select, Rules...)
{
	static assert(is(EntityManagerT == E!Fun, alias E = .EntityManagerT, Fun),
		"Type (%s) must be a valid 'vecs.entitymanager.EntityManagerT' type".format(EntityManagerT.stringof)
	);


	enum CanGetAttrs(alias T) = __traits(compiles, __traits(getAttributes, T));
	version(unittest) static assert( CanGetAttrs!EntityManagerT);
	version(unittest) static assert(!CanGetAttrs!uint);


	// stops ugly error messages with non symbols
	static assert(!RulesCompile.length,
		"Rules %s must symbols".format(RulesCompile.stringof)
	);

	alias RulesCompile = Filter!(Not!CanGetAttrs, Rules);


	static assert(All!(QueryRules, Rules),
		"Types %s are not valid Rules".format(Filter!(Not!QueryRules, Rules).stringof)
	);

	alias QueryRules = ApplyRight!(hasUDA, QueryRule);


	static assert(is(Select == S!Args, alias S = .Select, Args...),
		"Type (%s) must be a valid 'vecs.query.Select' type".format(Select.stringof)
	);


	struct Query
	{
		Entity[] entities;
	}
}
