module vecs.query;

import vecs.entity;
import vecs.entitymanager;
import vecs.storage;

import std.format : format;
import std.meta : All = allSatisfy;
import std.meta : IndexOf = staticIndexOf;
import std.meta : Map = staticMap;
import std.meta : Not = templateNot;
import std.meta : AliasSeq, ApplyRight, Filter;
import std.traits : hasUDA, TemplateArgsOf, TemplateOf;
import std.typecons : Tuple, tuple;

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


	/*
	Get all indices of a Rule in Rules

	given: AliasSeq!(With!(...), Without!(...), With!(...), With!(...))
	yield: AliasSeq!(0, 2, 3)
	*/
	template RulePositions(alias Rule, size_t offset = 0)
	{
		enum i = IndexOf!(Rule, Map!(TemplateOf, Rules[offset .. $]));
		static if (i >= 0)
			alias RulePositions = AliasSeq!(i + offset, RulePositions!(Rule, i + offset + 1));
		else
			alias RulePositions = AliasSeq!();
	}

	/*
	Get all offsets by Rule in Rule args

	given: AliasSeq!(With!(int, uint), Without!(string), With!(ulong))
	yield: AliasSeq!(tuple(0, 2), tuple(2, 3), tuple(3, 4))
	*/
	template RuleArgsOffsets(size_t index = 0, size_t from = 0)
	{
		alias Slice = Rules[index .. $];
		static if (Slice.length)
		{
			enum to = from + TemplateArgsOf!(Slice[0]).length;
			alias RuleArgsOffsets = AliasSeq!(tuple(from, to), RuleArgsOffsets!(index + 1, to));
		}
		else
			alias RuleArgsOffsets = AliasSeq!();
	}


	alias Fun = TemplateArgsOf!EntityManagerT[0];
	alias StorageOf(Component) = Storage!(Component, Fun);
	alias ElementsAt(Tuple!(size_t, size_t) t, Seq...) = Seq[t[0] .. t[1]];
	enum RuleArgsOffsetAt(size_t pos) = RuleArgsOffsets!()[pos];
	alias RuleElements(alias Rule, Seq...) = Map!(ApplyRight!(ElementsAt, Seq), Map!(RuleArgsOffsetAt, RulePositions!Rule));

	// extracted components
	alias SelectArgs = TemplateArgsOf!Select;
	alias RulesArgs = Map!(TemplateArgsOf, Rules);

	// ctor types
	alias SelectStorages = Map!(StorageOf, SelectArgs);
	alias RuleStorages = Map!(StorageOf, RulesArgs);

	// searching types
	alias Include = AliasSeq!(SelectStorages, RuleElements!(With, RuleStorages));
	alias Exclude = RuleElements!(Without, RuleStorages);

	// component foreach output type
	alias ElementType = Tuple!(Entity, Map!(PointerOf, SelectArgs));
	alias PointerOf(T) = T*;


	struct Query
	{
	package:
		Include include;
		Exclude exclude;
		alias select = include[0 .. SelectArgs.length];
		Entity[] entities;
	}
}
