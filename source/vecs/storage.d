module vecs.storage;

import vecs.entity;
import vecs.signal;

import std.meta : allSatisfy;
import std.traits : isSomeChar, isCopyable, isDelegate, isFunctionPointer, isInstanceOf, isMutable, isSomeFunction, Fields;
import std.typecons : Tuple;

version(vecs_unittest)
{
	import aurorafw.unit.assertion;
	import std.exception : assertThrown;
	import core.exception : AssertError;
}


// TODO: remove this
/**
 * A component must define this as an UDA.
 */
enum Component;


/**
Checks if a type is a valid Component type.

Params:
	T = a type to evaluate.

Returns: True if the type is a Component type, false otherwise.
*/
enum isComponent(T) = !(is(T == class)
	|| is(T == union)
	|| isSomeFunction!T
	|| isInstanceOf!(Tuple, T)
	|| !isCopyable!T
	|| isSomeChar!T
	|| is(Entity == T)
	|| (is(T == struct) && !allSatisfy!(isMutable, Fields!T))
	|| !isMutable!T
);

///
@("[isComponent] valid components")
@safe pure nothrow @nogc unittest
{
	import std.meta : AliasSeq, staticMap;
	import std.traits : PointerTarget;

	struct Empty { }
	struct MutableMembers { string str; int i; }

	assert(isComponent!Empty);
	assert(isComponent!MutableMembers);

	alias PtrIntegrals  = AliasSeq!(byte*, short*, int*, long*);
	alias PtrUIntegrals = AliasSeq!(ubyte*, ushort*, uint*, ulong*);
	alias Strings       = AliasSeq!(string, dstring, wstring);
	alias Integrals     = staticMap!(PointerTarget, PtrIntegrals);
	alias UIntegrals    = staticMap!(PointerTarget, PtrUIntegrals);

	static foreach (T; AliasSeq!(PtrIntegrals, PtrUIntegrals, Integrals, UIntegrals, Strings))
		assert(isComponent!T);
}

///
@("[isComponent] invalid components")
@safe pure nothrow @nogc unittest
{
	class Class {}
	union Union {}
	struct ImmutableMembers { immutable int x; }
	struct ConstMembers { const string x; }
	void FunctionPointer() {}

	assert(!isComponent!Entity);
	assert(!isComponent!Class);
	assert(!isComponent!Union);
	assert(!isComponent!ImmutableMembers);
	assert(!isComponent!ConstMembers);
	assert(!isComponent!(void function()));
	assert(!isComponent!(int delegate()));
	assert(!isComponent!(typeof(FunctionPointer)));
	assert(!isComponent!char);
	assert(!isComponent!wchar);
}


///
enum areComponents(T ...) = allSatisfy!(isComponent, T);


///
template TypeInfoComponent(Component)
	if (isComponent!Component)
{
	enum TypeInfoComponent = typeid(Component);
}


///
auto assumePure(T)(T t)
if (isFunctionPointer!T || isDelegate!T)
{
	import std.traits : FunctionAttribute, functionAttributes, functionLinkage, SetFunctionAttributes;
    enum attrs = functionAttributes!T | FunctionAttribute.pure_;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) t;
}


///
@safe nothrow @nogc
private static size_t nextId()
{
	import core.atomic : atomicOp;

	shared static size_t value;
	return value.atomicOp!"+="(1);
}


///
template ComponentId(Component)
	if (isComponent!Component)
{
	size_t ComponentId()
	{
		auto ComponentIdImpl = ()
		{
			shared static bool initialized;
			shared static size_t id;

			if (!initialized)
			{
				import core.atomic : atomicStore;
				id.atomicStore(nextId());
				initialized.atomicStore(true);
			}

			return id;
		};

		return (() @trusted pure nothrow @nogc => assumePure(ComponentIdImpl)())();
	}
}

@("[ComponentId] multithreaded")
unittest
{
	import std.algorithm : each;
	import core.thread.osthread;

	struct A {}
	struct B {}

	Thread[2] threads;
	size_t[2] ids;

	threads[0] = new Thread(() {
		ids[0] = ComponentId!A;
	}).start();

	threads[1] = new Thread(() {
		ids[1] = ComponentId!B;
	}).start();

	threads.each!"a.join()";

	assert(ids[0] != ids[1]);
}


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
	alias fun = void delegate();
	auto sinfo = StorageInfo().__ctor!(int, fun);

	assertThrown!AssertError(sinfo.get!(size_t, fun)());
}


/**
 * Used to save every component of a Component type and to keep track of which
 *     entities of type  are connected to a component.
 *
 * Params: Component = a valid component.
 */
package class Storage(Component, Fun = void delegate() @safe)
	if (isComponent!Component)
{
	/**
	Adds or updates the component for the entity.

	Signal: emits $(LREF onSet) after adding the component.

	Params:
		entity = a valid entity.

	Returns: A pointer to the component of the entity.
	*/
	Component* add()(in Entity entity)
	{
		Component* component = _add(entity);
		*component = Component.init;
		onSet.emit(entity, component);
		return component;
	}


	/**
	Emplace or replace the component for the entity.

	Signal: emits $(LREF onSet) after adding the component.

	Params:
		entity = a valid entity.
		args = arguments to construct the component to emplace or replace.

	Returns: A pointer to the component of the entity.
	*/
	Component* emplace(Args...)(in Entity entity, auto ref Args args)
	{
		import core.lifetime : emplace;
		Component* component = _add(entity);
		component.emplace(args);
		onSet.emit(entity, component);
		return component;
	}


	/**
	Assigns or updates the component for the entity.

	Signal: emits $(LREF onSet) after adding the component.

	Params:
		entity = a valid entity.
		component = component to assign or update.

	Returns: A pointer to the component of the entity.
	*/
	Component* set()(in Entity entity, Component component)
	{
		Component* comp = _add(entity);
		*comp = component;
		onSet.emit(entity, comp);
		return comp;
	}


	/**
	Patch a component of an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Params:
		entity: an entity in the storage.
		fn: the callback to call.
	*/
	Component* patch(Fn : void delegate(ref Component))(in Entity entity, Fn fn)
		in (contains(entity))
	{
		Component* component = &_components[_sparsedEntities[entity]];
		fn(*component);
		return component;
	}


	/// Ditto
	Component* patch(Fn : void function(ref Component))(in Entity entity, Fn fn)
	{
		import std.functional : toDelegate;

		// workarround for toDelegate bug not working with @safe functions
		static if (is(Fn : void function(ref Component) @safe))
			return patch(entity, (() @trusted => fn.toDelegate())());
		else
			return patch(entity, fn.toDelegate());
	}


	/*
	Removes the entity and its component from this storage. If the storage does
	not contain the entity, nothing happens.

	Signal: emits $(LREF onRemove) before removing the component.

	Params:
		entity = an entity.

	Returns: True if the entity was removed, false otherwise.
	*/
	bool remove()(in Entity entity)
	{
		if (!contains(entity)) return false;

		import std.algorithm : swap;
		import std.range : back, popBack;

		// emit onRemove
		onRemove.emit(entity, &_components[_sparsedEntities[entity.id]]);

		immutable last = _packedEntities.back;

		// swap with the last element of packedEntities
		swap(_components.back, _components[_sparsedEntities[entity.id]]);
		swap(_packedEntities.back, _packedEntities[_sparsedEntities[entity.id]]);

		// map the sparseEntities to the new value in packedEntities
		swap(_sparsedEntities[last.id], _sparsedEntities[entity.id]);

		// remove the last element
		_components.popBack;
		_packedEntities.popBack;

		return true;
	}


	/**
	 * Clears all components and entities.
	 */
	@safe pure nothrow
	void clear()
	{
		// FIXME: emit onRemove
		_sparsedEntities = [];
		_packedEntities = [];
		_components = [];
	}


	/**
	Fetches the component of the entity.

	Attempting to use an entity not in the storage leads to undefined behavior.

	Params:
		entity = a valid entity.

	Returns: A pointer to the component of the entity.
	*/
	@safe pure nothrow @nogc
	Component* get(in Entity entity)
		in (contains(entity))
	{
		return &_components[_sparsedEntities[entity.id]];
	}


	/**
	Fetches the component of the entity.

	Params:
		entity = an entity.

	Returns: A pointer to the component of the entity, `null` otherwise.
	*/
	@safe pure nothrow @nogc
	Component* tryGet(in Entity e)
	{
		return contains(e) ? get(e) : null;
	}


	/**
	 * Fetch the component if associated to the entity, otherwise the component
	 *     passed set then returned. Emits onSet if the component is set.
	 *
	 * Safety: The **internal code** is @safe, however, beacause of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onSet **after** the component is set **if** set.
	 *
	 * Params:
	 *     e = entity to search.
	 *     component = component to set if there is none associated.
	 *
	 * Returns: `Component*` pointing to the component associated.
	 */
	Component* getOrSet()(in Entity e, Component component)
		in (!(e.id < _sparsedEntities.length
			&& _sparsedEntities[e.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[e.id]].id == e.id
			&&_packedEntities[_sparsedEntities[e.id]].batch != e.batch)
		)
	{
		return contains(e) ? get(e) : set(e, component);
	}


	/**
	 * Gets the amount of components/entities stored.
	 *
	 * Returns: `size_t` with the amount of components/entities.
	 */
	@safe pure nothrow @nogc @property
	size_t size() const
	{
		return _components.length;
	}


	/**
	Checks if an entity is in the storage.

	Params:
		entity = entity to check.

	Returns: True if the entity is in the storage, false otherwise.
	*/
	@safe pure nothrow @nogc
	bool contains(in Entity e) const
	{
		return e.id < _sparsedEntities.length
			&& _sparsedEntities[e.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[e.id]] == e;
	}


package:

	/**
	 * Gets the entities stored.
	 *
	 * Returns: `Entity[]` of stored entities.
	 */
	@safe pure nothrow @nogc @property
	Entity[] entities()
	{
		return _packedEntities;
	}


	/**
	 * Gets the components stored.
	 *
	 * Returns: `Component[]` of components stored.
	 */
	@safe pure nothrow @nogc @property
	Component[] components()
	{
		return _components;
	}


private:
	/**
	Adds the entity if not in the storage.

	Params:
		entity = an entity.

	Retuns: A pointer to the component of the entity.
	*/
	@safe pure nothrow
	Component* _add(in Entity entity)
		in (!(entity.id < _sparsedEntities.length
			&& _sparsedEntities[entity.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[entity.id]].id == entity.id
			&& _packedEntities[_sparsedEntities[entity.id]].batch != entity.batch
		))
	{
		if (!contains(entity))
		{
			_packedEntities ~= entity; // set entity
			_components.length++;

			// map to the correct entity from the packedEntities from sparsedEntities
			if (entity.id >= _sparsedEntities.length)
				_sparsedEntities.length = entity.id + 1;

			_sparsedEntities[entity.id] = _packedEntities.length - 1;
		}

		return &_components[_sparsedEntities[entity.id]];
	}


	size_t[] _sparsedEntities;
	Entity[] _packedEntities;
	Component[] _components;

public:
	SignalT!Fun.parameters!(void delegate(Entity, Component*)) onSet;
	SignalT!Fun.parameters!(void delegate(Entity, Component*)) onRemove;
}

@("[Storage] component manipulation")
@safe pure nothrow unittest
{
	struct Position { ulong x, y; }
	scope storage = new Storage!(Position, void delegate() @safe pure nothrow);

	with (storage) {
		add(Entity(0));
		emplace(Entity(5), 4, 6);
		set(Entity(3), Position(2, 3));
	}

	assert(*storage.get(Entity(0)) == Position.init);
	assert(*storage.get(Entity(5)) == Position(4, 6));
	assert(*storage.get(Entity(3)) == Position(2, 3));

	assert( storage.tryGet(Entity(0)));
	assert(!storage.tryGet(Entity(1234)));

	with (storage) {
		assert(*add(Entity(5)) == *storage.get(Entity(5)));
		assert(*emplace(Entity(3), 4, 6) == *storage.get(Entity(3)));
		assert(*set(Entity(0), Position(2, 3)) == *storage.get(Entity(0)));
	}

	assert( storage.remove(Entity(3)));
	assert(!storage.tryGet(Entity(3)));

	storage.patch(Entity(0), (ref Position pos) { pos.x = 12; });

	assert(storage.get(Entity(0)).x == 12);
}

@("[Storage] construct")
@safe pure nothrow @nogc unittest
{
	struct Foo {}
	class Bar {}

	assert( __traits(compiles, { scope foo = new Storage!Foo; }));
	assert(!__traits(compiles, { scope bar = new Storage!Bar; }));
}

@("[Storage] entity manipulation")
@safe pure nothrow unittest
{
	scope storage = new Storage!(int, void delegate() @safe pure nothrow @nogc);

	with (storage) {
		add(Entity(0));
		add(Entity(5));
	}

	assert(storage.contains(Entity(0)));

	assert(storage._sparsedEntities.length == 6);
	assert(storage._packedEntities.length == 2);
	assert(storage.size() == 2);

	assert(storage.remove(Entity(0)));

	assert(storage._sparsedEntities.length == 6);
	assert(storage._packedEntities.length == 1);
	assert(storage.size() == 1);

	assert(!storage.contains(Entity(0)));

	assert(!storage.remove(Entity(5, 1)));
	assert( storage.contains(Entity(5)));
}

version(assert)
@("[Storage] entity manipulation (invalid entities)")
unittest
{
	scope storage = new Storage!int;

	storage.add(Entity(1));

	assertThrown!AssertError(storage.add(Entity(1, 4)));
}

@("[Storage] getOrSet")
@safe pure nothrow unittest
{
	scope storage = new Storage!(int, void delegate() @safe pure nothrow @nogc);

	assert(*storage.getOrSet(Entity(0), 55) == 55);
	assert(*storage.getOrSet(Entity(0), 13) == 55);
}

version(assert)
@("[Storage] getOrSet (invalid entities)")
unittest
{
	scope storage = new Storage!int;

	storage.add(Entity(0));

	assertThrown!AssertError(storage.getOrSet(Entity(0, 1), 6));
}

@("[Storage] signals")
@safe pure nothrow unittest
{
	scope storage = new Storage!(int, void delegate() @safe pure nothrow @nogc);
	enum e = Entity(0);

	int value;
	void delegate(Entity, int*) @safe pure nothrow @nogc fun = (Entity, int*) { value++; };

	storage.onSet.connect(fun);
	storage.onRemove.connect(fun);

	storage.add(e);
	assert(value == 1);

	storage.remove(e);
	assert(value == 2);
}
