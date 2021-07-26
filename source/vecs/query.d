module vecs.query;

import vecs.entity;
import vecs.storage;
import vecs.queryfilter;
import vecs.queryworld;

import std.format : format;
import std.meta : AliasSeq, allSatisfy, anySatisfy, Filter, NoDuplicates;
import std.range : iota;
import std.traits : isInstanceOf, staticMap, TemplateArgsOf;
import std.typecons : Tuple, tuple;

version(vecs_unittest) import aurorafw.unit.assertion;

struct Query(Output)
{
package:
	@safe pure nothrow @nogc
	this(QueryWorld!Output range)
	{
		this.range = range;
	}

public:
	@safe pure nothrow @nogc
	void popFront()
	{
		range.popFront();
	}

	@safe pure nothrow @nogc @property
	bool empty()
	{
		return range.empty;
	}

	@safe pure nothrow @nogc @property
	auto front()
	{
		return range.front;
	}

private:
	QueryWorld!Output range;
}

@system
@("query: Entity")
unittest
{
	import std.algorithm : each;

	auto em = new EntityManager();
	11.iota.each!(i => em.entity());

	em.discard(Entity(2));
	em.discard(Entity(3));
	em.discard(Entity(5));
	em.discard(Entity(6));
	em.discard(Entity(7));
	em.discard(Entity(9));
	em.discard(Entity(10));

	assertRangeEquals([Entity(0),Entity(1),Entity(4),Entity(8)], em.query!Entity);
	assertRangeEquals(em.query!(Tuple!Entity), em.query!Entity);
	assertEquals(Entity(0), em.queryOne!Entity);
}

@system
@("query: Component")
unittest
{
	import std.algorithm : map;

	auto em = new EntityManager();
	with(em) {
		entity.set(Foo(2, 4)).set!Bar.set(4);
		entity.set!Foo;
		entity.set!Foo;
		entity.set!Foo.set!Bar;
		entity.set!Foo.set!Bar;
		entity.set!Foo.set!Bar;
		entity.set!Bar.set!int;
		entity.set!Bar.set!int;
		entity.set!Foo.set!Bar.set!int;
		entity.set!Foo.set!Bar.set!int;
	}

	assertEquals(5, em.query!int.range.entities.length);
	assertRangeEquals([4,0,0,0,0], em.query!int.map!"*a");
	assertRangeEquals(em.query!(Tuple!int), em.query!int);
	assertEquals(4, *em.queryOne!int);
}

@system
@("query: OutputTuple")
unittest
{
	import std.algorithm : map;

	auto em = new EntityManager();
	with(em) {
		entity.set(Foo(2, 4)).set!Bar.set(4);
		entity.set!Foo;
		entity.set!Foo;
		entity.set!Foo.set!Bar;
		entity.set!Foo.set!Bar;
		entity.set!Foo.set!Bar;
		entity.set!Bar.set!int;
		entity.set!Bar.set!int;
		entity.set!Foo.set!Bar.set!int;
		entity.set!Foo.set!Bar.set!int;
	}

	auto range = [
		tuple(4,Bar.init),
		tuple(0,Bar.init),
		tuple(0,Bar.init),
		tuple(0,Bar.init),
		tuple(0,Bar.init)
	];

	assertEquals(5, em.query!(Tuple!(int, Bar)).range.entities.length);
	assertRangeEquals(range, em.query!(Tuple!(int, Bar)).map!"tuple(*a[0], *a[1])");

	int* i; Bar* bar;
	AliasSeq!(i, bar) = em.queryOne!(Tuple!(int, Bar));
	assertEquals(tuple(4, Bar.init), tuple(*i, *bar));

	assertFalse(__traits(compiles, em.query!(Tuple!(Entity,Entity))));
	assertFalse(__traits(compiles, em.query!(Tuple!(int,Entity))));

	assertTrue(__traits(compiles, em.query!(Tuple!(int,int))));
	assertTrue(__traits(compiles, em.query!(Tuple!(Entity,int,int))));
}


struct Query(Output, Filter)
{
package:
	@safe pure nothrow @nogc
	this(QueryWorld!Output range, QueryFilter!Filter filter)
	{
		this.range = range;
		this.filter = filter;
		_prime();
	}

public:
	@safe pure nothrow @nogc
	void popFront()
	{
		do {
			range.popFront();
		} while (!empty && !_validate());
	}

	@safe pure nothrow @nogc @property
	bool empty()
	{
		return range.empty;
	}

	@safe pure nothrow @nogc @property
	auto front()
	{
		return range.front;
	}

private:
	@safe pure nothrow @nogc
	void _prime()
	{
		if (!empty && !_validate())
			popFront();
	}

	@safe pure nothrow @nogc
	bool _validate()
	{
		return filter.validate(range.entities[0]);
	}

	QueryWorld!Output range;
	QueryFilter!Filter filter;
}

@system
@("query: Entity + Filter")
unittest
{
	auto em = new EntityManager();
	with(em) {
		entity.set(Foo(2, 4)).set!Bar.set(4);
		entity.set!Foo;
		entity.set!Foo;
		entity.set!Foo.set!Bar;
		entity.set!Foo.set!Bar;
		entity.set!Foo.set!Bar;
		entity.set!Bar.set!int;
		entity.set!Bar.set!int;
		entity.set!Foo.set!Bar.set!int;
		entity.set!Foo.set!Bar.set!int;
	}

	auto range = [Entity(0),Entity(6),Entity(7),Entity(8),Entity(9)];
	assertEquals(5, em.query!(Entity, With!int).range.entities.length);
	assertRangeEquals(range, em.query!(Entity, With!int)());
	assertEquals(Entity(0), em.queryOne!(Entity, With!int)());

	range = [Entity(0),Entity(8),Entity(9)];
	assertEquals(5, em.query!(Entity, With!(int,Foo,Bar)).range.entities.length);
	assertRangeEquals(range, em.query!(Entity, With!(int,Foo,Bar)));
	assertEquals(Entity(0), em.queryOne!(Entity, With!(int,Foo,Bar))());
}

@system
@("query: Component + Filter")
unittest
{
	import std.algorithm : map;

	auto em = new EntityManager();
	with(em) {
		entity.set(Foo(2, 4)).set!Bar.set(4);
		entity.set!Foo;
		entity.set!Foo;
		entity.set!Foo.set!Bar;
		entity.set!Foo.set!Bar;
		entity.set!Foo.set!Bar;
		entity.set!Bar.set!int;
		entity.set!Bar.set!int;
		entity.set!Foo.set!Bar.set!int;
		entity.set!Foo.set!Bar.set!int;
	}

	auto range = [
		tuple(Entity(0), 4),
		tuple(Entity(6), 0),
		tuple(Entity(7), 0),
		tuple(Entity(8), 0),
		tuple(Entity(9), 0)
	];

	assertEquals(5, em.query!(Tuple!(Entity, int), With!Bar).range.entities.length);
	assertRangeEquals(range, em.query!(Tuple!(Entity, int), With!Bar).map!"tuple(a[0],*a[1])");

	range = [
		tuple(Entity(0), 4),
		tuple(Entity(8), 0),
		tuple(Entity(9), 0)
	];

	assertEquals(5, em.query!(Tuple!(Entity, int), With!(Foo,Bar)).range.entities.length);
	assertRangeEquals(range, em.query!(Tuple!(Entity, int), With!(Foo,Bar)).map!"tuple(a[0],*a[1])");
}

@system
@("query: OutputTuple + Filter")
unittest
{
	import std.algorithm : map;
	import std.range : take;

	{
		auto em = new EntityManager();
		with(em) {
			entity.set(Foo(2, 4)).set!Bar.set(4);
			entity.set!Foo;
			entity.set!Foo;
			entity.set!Foo.set!Bar;
			entity.set!Foo.set!Bar;
			entity.set!Foo.set!Bar;
			entity.set!Bar.set!int;
			entity.set!Bar.set!int;
			entity.set!Foo.set!Bar.set!int;
			entity.set!Foo.set!Bar.set!int;
		}

		auto range = [4,0,0,0,0];
		assertEquals(5, em.query!(int, With!Bar).range.entities.length);
		assertRangeEquals(range, em.query!(int, With!Bar).map!"*a");

		range = [4,0,0];
		assertEquals(5, em.query!(int, With!(Foo,Bar)).range.entities.length);
		assertRangeEquals(range, em.query!(int, With!(Foo,Bar)).map!"*a");
	}

	{
		auto em = new EntityManager();
		with(em) {
			entity.set("Foo").set(1f);
			entity.set("Bar").set(1f);
			entity.set("Foobar").set(1f).set(5);
		}

		assertEquals(*em.query!(Tuple!(string, int)).front[0], *em.query!(string, With!int).front);
		assertEquals(*em.query!(Tuple!(string, float, int)).front[0], *em.query!(Tuple!(string, float), With!int).front[0]);
		assertEquals(*em.query!(Tuple!(string, float, int)).front[0], *em.query!(string, With!(int, float)).front);

		assertRangeEquals(["Foo", "Bar"], em.query!(string, Without!int).map!"*a");
	}
}

@system
@("query: OutputTuple + FilterTuple")
unittest
{
	import std.algorithm : map;

	auto em = new EntityManager();
	with(em) {
		entity.set(Foo(2, 4)).set!Bar.set(4);
		entity.set!Foo;
		entity.set!Foo;
		entity.set!Foo.set!Bar;
		entity.set!Foo.set!Bar;
		entity.set!Foo.set!Bar;
		entity.set!Bar.set!int;
		entity.set!Bar.set!int;
		entity.set!Foo.set!Bar.set!int;
		entity.set!Foo.set!Bar.set!int;
	}

	auto range = [0,0];

	// not 5 because the first Entity is removed by _prime function --> Without!Foo
	assertEquals(4, em.query!(int, Tuple!(With!Bar, Without!Foo)).range.entities.length);
	assertRangeEquals(range, em.query!(int, Tuple!(With!Bar, Without!Foo)).map!"*a");

	auto trange = [
		tuple(Entity(6), 0),
		tuple(Entity(7), 0)
	];

	// not 5 because the first Entity is removed by _prime function --> Without!Foo
	assertEquals(4, em.query!(Tuple!(Entity,int), Tuple!(With!Bar,Without!Foo)).range.entities.length);
	assertRangeEquals(trange, em.query!(Tuple!(Entity,int), Tuple!(With!Bar,Without!Foo)).map!"tuple(a[0],*a[1])");

	Tuple!(Entity,int*)[] range_; // empty range

	// not 5 because all entities are removes by _prime function --> With!int && Without!int
	assertEquals(0, em.query!(Tuple!(Entity, int), Tuple!(With!int,Without!int)).range.entities.length);
	assertRangeEquals(range_, em.query!(Tuple!(Entity, int), Tuple!(With!int,Without!int)));

	assertEquals(0, em.query!(Entity, With!(string)).range.entities.length);
}
