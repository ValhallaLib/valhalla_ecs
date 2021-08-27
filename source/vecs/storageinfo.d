module vecs.storageinfo;

import vecs.component;
import vecs.entity;
import vecs.storage;

/**
 * Structure to communicate with the Storage. Easier to keep diferent components
 *     in the same data structure for better access to it's storage. It can also
 *     have some fast access functions which map directly to the storage's
 *     functions.
 *
 * Params: Component = a valid component
 */
package struct StorageInfo
{
public:
	this(Component, Fun = void delegate() @safe)()
	{
		auto storage = new Storage!(Component, Fun)();
		this.cid = TypeInfoComponent!Component;

		(() @trusted pure nothrow @nogc => this.storage = cast(void*) storage)();
		this.entities = &storage.entities;
		this.contains = &storage.contains;
		this.remove = &storage.remove!();
		this.clear = &storage.clear;
		this.size = &storage.size;
	}

	///
	Storage!(Component, Fun) get(Component, Fun)()
		in (cid is TypeInfoComponent!Component)
	{
		return (() @trusted pure nothrow @nogc => cast(Storage!(Component, Fun)) storage)(); // safe cast
	}

	bool delegate(in Entity e) @safe pure nothrow @nogc const contains;
	bool delegate(in Entity e) remove;
	void delegate() @safe pure nothrow clear;
	size_t delegate() @safe pure nothrow @nogc @property const size;


package:
	Entity[] delegate() @safe pure nothrow @property @nogc entities;

	TypeInfo cid;
	void* storage;
}

@("[StorageInfo] construct")
@safe pure nothrow @nogc unittest
{
	class Foo {}

	assert( __traits(compiles, { scope sinfo = StorageInfo().__ctor!int; }));
	assert(!__traits(compiles, { scope sinfo = StorageInfo().__ctor!Foo; }));
}

@("[StorageInfo] instance manipulation")
@safe pure nothrow unittest
{
	alias fun = void delegate();
	auto sinfo = StorageInfo().__ctor!(int, fun);

	assert(sinfo.cid is TypeInfoComponent!int);
	assert(sinfo.get!(int, fun) !is null);

	auto storage = sinfo.get!(int, fun);

	assert(&storage.contains is sinfo.contains);
	assert(&storage.remove!() is sinfo.remove);
	assert(&storage.clear is sinfo.clear);
	assert(&storage.size is sinfo.size);
}

version(assert)
@("[StorageInfo] instance manipulation (component getter missmatch)")
unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	alias fun = void delegate();
	auto sinfo = StorageInfo().__ctor!(int, fun);

	assertThrown!AssertError(sinfo.get!(size_t, fun)());
}
