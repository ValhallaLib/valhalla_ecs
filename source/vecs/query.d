module vecs.query;

import vecs.entity;
import vecs.entitymanager;

import std.format : format;
import std.meta : All = allSatisfy;
import std.meta : Not = templateNot;
import std.meta : ApplyRight, Filter;
import std.traits : hasUDA;

private enum QueryRule;

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


	struct Query
	{
		Entity[] entities;
	}
}
