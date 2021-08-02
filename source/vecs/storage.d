module vecs.storage;

import vecs.entity : Entity;
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

/**
 * A component must define this as an UDA.
 */
enum Component;


/**
 * Evalute is some T is a valid component. A component is defined by being a
 *     **struct** with **all fields mutable** and must have the **Component**
 *     UDA.
 *
 * Params: T = valid component type.
 *
 * Returns: true is is a valid component, false otherwise.
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
	this(Component)()
	{
		auto storage = new Storage!Component();
		this.cid = TypeInfoComponent!Component;

		(() @trusted pure nothrow @nogc => this.storage = cast(void*) storage)();
		this.entities = &storage.entities;
		this.contains = &storage.contains;
		this.remove = &storage.remove;
		this.clear = &storage.clear;
		this.size = &storage.size;
	}

	///
	Storage!Component get(Component)()
		in (cid is TypeInfoComponent!Component)
	{
		return (() @trusted pure nothrow @nogc => cast(Storage!Component) storage)(); // safe cast
	}

	bool delegate(in Entity e) @safe pure nothrow @nogc const contains;
	bool delegate(in Entity e) @system remove;
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
	auto sinfo = StorageInfo().__ctor!int;

	assert(sinfo.cid is TypeInfoComponent!int);
	assert(sinfo.get!int !is null);

	auto storage = sinfo.get!int;

	assert(&storage.contains is sinfo.contains);
	assert(&storage.remove is sinfo.remove);
	assert(&storage.clear is sinfo.clear);
	assert(&storage.size is sinfo.size);
}

version(assert)
@("[StorageInfo] instance manipulation (component getter missmatch)")
unittest
{
	auto sinfo = StorageInfo().__ctor!int;

	assertThrown!AssertError(sinfo.get!size_t());
}


/**
 * Used to save every component of a Component type and to keep track of which
 *     entities of type  are connected to a component.
 *
 * Params: Component = a valid component.
 */
package class Storage(Component)
	if (isComponent!Component)
{
	// FIXME: documentation
	Component* add(in Entity e)
	{
		Component* component = _add(e);
		*component = Component.init;
		onSet.emit(e, component);
		return component;
	}


	// FIXME: documentation
	Component* emplace(Args...)(in Entity e, auto ref Args args)
	{
		import core.lifetime : emplace;
		Component* component = _add(e);
		component.emplace(args);
		onSet.emit(e, component);
		return component;
	}


	/**
	 * Associates a component to an entity. If the entity is already connected to
	 *     a component of this type then it's component will be updated.
	 *     Passing an invalid entity leads to undefined behaviour. Emits onSet
	 *     after associating the component to the entity, either by creation or
	 *     by replacement.
	 *
	 * Safety: The **internal code** is @safe, however, beacause of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onSet **after** associating the component.
	 *
	 * Params:
	 *     e = entity to associate.
	 *     component = a valid component.
	 *
	 * Returns: `Component*` pointing to the component set either by creation or
	 *     replacement.
	 */
	@system
	Component* set(in Entity e, Component component)
	{
		Component* comp = _add(e);
		*comp = component;
		onSet.emit(e, comp);
		return comp;
	}


	// FIXME: documentation
	/**
	 * Disassociates an entity from it's component. Passing an invalid entity
	 *     leads to undefined behaviour.
	 *
	 * Safety: The **internal code** is @safe, however, beacause of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onRemove **before** disassociating the component.
	 *
	 * Params: e = the entity to disassociate from it's component.
	 */
	@system
	bool remove(in Entity e)
	{
		if (!contains(e)) return false;

		import std.algorithm : swap;
		import std.range : back, popBack;

		// emit onRemove
		onRemove.emit(e, &_components[_sparsedEntities[e.id]]);

		immutable last = _packedEntities.back;

		// swap with the last element of packedEntities
		swap(_components.back, _components[_sparsedEntities[e.id]]);
		swap(_packedEntities.back, _packedEntities[_sparsedEntities[e.id]]);

		// map the sparseEntities to the new value in packedEntities
		swap(_sparsedEntities[last.id], _sparsedEntities[e.id]);

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
	 * Fetches the component associated to an entity. Passing an invalid entity
	 *     leads to undefined behaviour.
	 *
	 * Params:
	 *     e = entity to search.
	 *
	 * Returns: `Component*` pointing to the entity's component.
	 */
	@safe pure nothrow @nogc
	Component* get(in Entity e)
		in (contains(e))
	{
		return &_components[_sparsedEntities[e.id]];
	}


	// FIXME: documentation
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
	@system
	Component* getOrSet(in Entity e, Component component)
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
	 * Checks if an entity exists in the Storage.
	 *
	 * Params:
	 *     e = entity to check.
	 *
	 * Returns:`true` if exists, `false` otherwise.
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
	// FIXME: documentation
	Component* _add(in Entity e)
		in (!(e.id < _sparsedEntities.length
			&& _sparsedEntities[e.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[e.id]].id == e.id
			&& _packedEntities[_sparsedEntities[e.id]].batch != e.batch
		))
	{
		if (!contains(e))
		{
			_packedEntities ~= e; // set entity
			_components.length++;

			// map to the correct entity from the packedEntities from sparsedEntities
			if (e.id >= _sparsedEntities.length)
				_sparsedEntities.length = e.id + 1;

			_sparsedEntities[e.id] = _packedEntities.length - 1;
		}

		return &_components[_sparsedEntities[e.id]];
	}


	size_t[] _sparsedEntities;
	Entity[] _packedEntities;
	Component[] _components;

public:
	Signal!(Entity,Component*) onSet;
	Signal!(Entity,Component*) onRemove;
}

@("[Storage] component manipulation")
unittest
{
	struct Position { ulong x, y; }
	scope storage = new Storage!Position;

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
unittest
{
	scope storage = new Storage!int;

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
unittest
{
	scope storage = new Storage!int();

	assert(*storage.getOrSet(Entity(0), 55) == 55);
	assert(*storage.getOrSet(Entity(0), 13) == 55);
}

version(assert)
@("[Storage] getOrSet (invalid entities)")
unittest
{
	scope storage = new Storage!int();

	storage.add(Entity(0));

	assertThrown!AssertError(storage.getOrSet(Entity(0, 1), 6));
}

@("[Storage] signals")
unittest
{
	scope storage = new Storage!int;
	enum e = Entity(0);

	int value;
	void delegate(Entity, int*) fun = (Entity, int*) { value++; };

	storage.onSet.connect(fun);
	storage.onRemove.connect(fun);

	storage.add(e);
	assert(value == 1);

	storage.remove(e);
	assert(value == 2);
}
