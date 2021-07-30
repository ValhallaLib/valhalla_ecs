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
@safe pure
@("storage: isComponent")
unittest
{
	import std.meta : AliasSeq;

	struct ComponentStructEmpty {}
	struct ComponentStructInt { int a; }
	struct ComponentStructString { immutable(char)[] x; } // aka string

	class NotComponentClass() {}
	union NotComponentUnion() {}
	struct NotComponentStructImmutable { immutable int x; }
	struct NotComponentStructConst { const string x; }
	void NotComponentFuncPtr() {}

	assertTrue(isComponent!ComponentStructEmpty);
	assertTrue(isComponent!ComponentStructInt);
	assertTrue(isComponent!ComponentStructString);

	foreach (t; AliasSeq!(byte, short, int, long))
		assertTrue(isComponent!t);

	foreach (t; AliasSeq!(ubyte, ushort, uint, ulong))
		assertTrue(isComponent!t);

	foreach (t; AliasSeq!(byte*, short*, int*, long*))
		assertTrue(isComponent!t);

	foreach (t; AliasSeq!(ubyte*, ushort*, uint*, ulong*))
		assertTrue(isComponent!t);

	foreach (t; AliasSeq!(string, wstring, string*, wstring*))
		assertTrue(isComponent!t);

	assertFalse(isComponent!NotComponentStructImmutable);
	assertFalse(isComponent!NotComponentStructConst);
	assertFalse(isComponent!(void function()));
	assertFalse(isComponent!(int delegate()));
	assertFalse(isComponent!char);
	assertFalse(isComponent!wchar);

	assertFalse(__traits(compiles, isComponent!NotComponentClass));
	assertFalse(__traits(compiles, isComponent!NotComponentUnion));
	assertFalse(__traits(compiles, isComponent!NotComponentFuncPtr));
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


@("storage: ComponentId multithreaded")
@system
unittest
{
	import std.algorithm : each;
	import core.thread.osthread;
	import vecs.entity;

	Thread[2] threads;
	size_t[2] ids;

	auto em = new EntityManager();

	threads[0] = new Thread(() {
		ids[0] = ComponentId!Foo;
	}).start();

	threads[1] = new Thread(() {
		ids[1] = ComponentId!Bar;
	}).start();

	threads.each!"a.join()";

	assertFalse(ids[0] == ids[1]);
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
		this.has = &storage.contains;
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

	bool delegate(in Entity e) @safe pure nothrow @nogc const has;
	bool delegate(in Entity e) @system remove;
	void delegate() @safe pure nothrow clear;
	size_t delegate() @safe pure nothrow @nogc @property const size;


package:
	Entity[] delegate() @safe pure nothrow @property @nogc entities;

	TypeInfo cid;
	void* storage;
}

@trusted pure
@("storage: StorageInfo")
unittest
{
	auto sinfo = StorageInfo().__ctor!(int)();

	assertTrue(typeid(Storage!int) is typeid(sinfo.get!int));
	assertThrown!AssertError(sinfo.get!size_t());
	assertFalse(__traits(compiles, sinfo.get!(immutable(int))()));
}

@system
@("storage: StorageInfo")
unittest
{
	import std.range : front;

	auto sinfo = StorageInfo().__ctor!(int)();
	Storage!int storage = sinfo.get!(int);

	assertTrue(storage.set(Entity(0), 3));
	assertEquals(1, storage._packedEntities.length);
	assertEquals(Entity(0), storage._packedEntities.front);

	assertFalse(storage.remove(Entity(0, 45)));

	storage.remove(Entity(0));
	assertEquals(0, storage._packedEntities.length);
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

version(vecs_unittest)
{
	struct Foo { int x, y; }
	struct Bar { string str; }

	// problem: cannot return &(_components[_sparsedEntities[e.id]] = component
	// directly if Component contains has an opAssign template overload,
	// accepting it's type as a value
	// solution: split action in 2 sections, assingn then return the reference
private:
	struct Assign
	{
		// accepts Assign, we're doomed to failure
		void opAssign(T : Assign)(T other) {}
	}
}

@safe pure
@("storage: Storage")
unittest
{
	assertTrue(__traits(compiles, new Storage!Foo));
	assertTrue(__traits(compiles, new Storage!Bar));
	assertFalse(__traits(compiles, new Storage!InvalidComponent));
}

@system
@("storage: Storage: get")
unittest
{
	auto storage = new Storage!Foo();

	storage.set(Entity(0), Foo(3, 3));

	assertThrown!AssertError(storage.get(Entity(0, 54)));
	assertThrown!AssertError(storage.get(Entity(21)));
	assertEquals(Foo(3, 3), *storage.get(Entity(0)));
}

@system
@("storage: Storage: getOrSet")
unittest
{
	auto storage = new Storage!Foo();

	assertEquals(Foo.init, *storage.getOrSet(Entity(0), Foo.init));
	assertEquals(Foo.init, *storage.getOrSet(Entity(0), Foo(2, 3)));
	assertThrown!AssertError(storage.getOrSet(Entity(0, 54), Foo(2, 3)));
}

@system
@("storage: Storage: onRemove")
unittest
{
	scope storage = new Storage!Foo();
	int i;
	storage.onRemove.connect((Entity, Foo*) { i++; });
	assertEquals(0, i);

	storage.set(Entity(0), Foo.init);
	storage.remove(Entity(0));
	assertEquals(1, i);
}

@system
@("storage: Storage: onSet")
unittest
{
	scope storage = new Storage!Foo();
	int i;
	storage.onSet.connect((Entity, Foo*) { i++; });
	assertEquals(0, i);

	storage.set(Entity(0), Foo.init);
	assertEquals(1, i);
}

@system
@("storage: Storage: remove")
unittest
{
	auto storage = new Storage!Bar();

	storage.set(Entity(0), Bar("bar"));
	storage.set(Entity(1), Bar("bar"));

	assertFalse(storage.remove(Entity(0, 5)));
	assertFalse(storage.remove(Entity(42)));

	storage.remove(Entity(0));
	assertEquals(1, storage._sparsedEntities[0]);
	assertEquals(Entity(1), storage._packedEntities[storage._sparsedEntities[1]]);
	assertEquals(Entity(1), storage._packedEntities[0]);
}

@system
@("storage: Storage: set")
unittest
{
	{
		scope storage = new Storage!Foo();

		assertTrue(storage.set(Entity(0), Foo(3, 2)));
		assertThrown!AssertError(storage.set(Entity(0, 4), Foo(3, 2)));
		assertEquals(Entity(0), storage._packedEntities[storage._sparsedEntities[0]]);
		assertEquals(Entity(0), storage._packedEntities[0]);
		assertEquals(Foo(3, 2), storage._components[0]);

		assertTrue(storage.set(Entity(0), Foo(5, 5)));
		assertEquals(Entity(0), storage._packedEntities[storage._sparsedEntities[0]]);
		assertEquals(Entity(0), storage._packedEntities[0]);
		assertEquals(Foo(5, 5), storage._components[0]);
	}

	{
		scope storage = new Storage!Assign();
		storage.set(Entity(0), Assign());
	}
}
