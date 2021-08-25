module vecs.query;

import vecs.entity;
import vecs.entitymanager;
import vecs.storage;

import std.algorithm : minIndex;
import std.format : format;
import std.functional : toDelegate, unaryFun;
import std.meta : All = allSatisfy;
import std.meta : IndexOf = staticIndexOf;
import std.meta : Map = staticMap;
import std.meta : Not = templateNot;
import std.meta : AliasSeq, ApplyRight, Filter;
import std.range : iota;
import std.traits : hasUDA, TemplateArgsOf, TemplateOf;
import std.typecons : Tuple, tuple;


void each(alias pred, Query)(Query query)
	if (is(typeof(unaryFun!pred)))
{
	static assert (is(Query == Q!Args, alias Q = .Query, Args...),
		"Type (%s) must be a valid 'vecs.query.Query' type".format(Query.stringof)
	);

	foreach (entity; query) with (query)
	{
		static immutable components = "%(*select[%s].get(entity)%|, %)".format(select.length.iota);

		static if (__traits(compiles, { mixin (q{ pred(entity, %s); }.format(components)); }))
			mixin (q{ pred(entity, %s); }.format(components));
		else
			mixin (q{ pred(%s); }.format(components));
	}
}


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
		Entity front() @property const
			in (!empty, "Attempting to fetch the front of an empty query")
		{
			return entities[0];
		}

		void popFront()
		{
			do { entities = entities[1 .. $]; }
			while (!empty && !contains(entities[0]));
		}

		Entity back() @property const
			in (!empty, "Attempting to fetch the back of an empty query")
		{
			return entities[$ - 1];
		}

		void popBack()
		{
			do { entities = entities[0 .. $ - 1]; }
			while (!empty && !contains(entities[$ - 1]));
		}

		bool empty() @property const
		{
			return !entities.length;
		}

		bool contains(in Entity entity)
		{
			bool all(alias pred, Storages...)(Storages storages)
			{
				foreach (storage; storages) if (!pred(storage)) return false;
				return true;
			}

			return all!(s => s.contains(entity))(include) && all!(s => !s.contains(entity))(exclude);
		}

		auto get(Components...)(in Entity entity)
			if (Components.length)
			in (contains(entity))
		{
			enum bool Contains(Component) = IndexOf!(Component, TemplateArgsOf!Select) >= 0;
			static assert(All!(Contains, Components),
				"Query can not select %s from %s Components".format(
					Filter!(Not!Contains, Components).stringof,
					TemplateArgsOf!Select.stringof
				)
			);

			Map!(PointerOf, Components) C;

			static foreach (i, Component; Components)
				C[i] = include[IndexOf!(Component, TemplateArgsOf!Select)].get(entity);

			static if (Components.length == 1)
				return C[0];
			else
				return tuple(C);
		}

	package:
		this(SelectStorages selects, RuleStorages rules)
		{
			alias storages = AliasSeq!(selects, RuleElements!(With, rules));

			size_t[Include.length] counter;
			static foreach (i, storage; storages) counter[i] = storage.size();

			Lswitch: final switch (counter[].minIndex())
			{
				static foreach (i, storage; storages)
				{
					case i: entities = storage.entities(); break Lswitch;
				}
			}

			include = storages;

			static if (Exclude.length)
				exclude = RuleElements!(.Without, rules);

			while (!empty && !contains(entities[0])) entities = entities[1 .. $];
			while (!empty && !contains(entities[$ - 1])) entities = entities[0 .. $ - 1];
		}

		Include include;
		Exclude exclude;
		alias select = include[0 .. SelectArgs.length];
		Entity[] entities;


		struct QueryEach
		{
			ElementType front() @property
			{
				auto entity = query.front;
				return mixin (q{ ElementType(entity, %(query.select[%s].get(entity)%|, %)) }
					.format(SelectArgs.length.iota)
				);
			}

			void popFront() { query.popFront(); }

			ElementType back() @property
			{
				auto entity = query.back;
				return mixin (q{ ElementType(entity, %(query.select[%s].get(entity)%|, %)) }
					.format(SelectArgs.length.iota)
				);
			}

			void popBack() { query.popBack(); }

			bool empty() @property const { return query.empty; }

		package:
			Query query;
		}
	}
}
