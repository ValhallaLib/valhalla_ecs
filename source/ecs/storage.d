module ecs.storage;

import ecs.entity : Entity;

version(unittest) import aurorafw.unit.assertion;

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
template isComponent(T)
{
	import std.meta : allSatisfy;
	import std.traits : isMutable, isSomeFunction, Fields;

	static if (is(T == struct))
	{
		enum isComponent = allSatisfy!(isMutable, Fields!T);
	}
	else static if (is(T == class) || is(T == union) || isSomeFunction!T)
	{
		enum isComponent = false;
	}
	else
	{
		enum isComponent = isMutable!T;
	}
}


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

	foreach (t; AliasSeq!(char, wchar, string, wstring))
		assertTrue(isComponent!t);

	foreach (t; AliasSeq!(char*, wchar*, string*, wstring*))
		assertTrue(isComponent!t);

	assertFalse(isComponent!NotComponentStructImmutable);
	assertFalse(isComponent!NotComponentStructConst);
	assertFalse(isComponent!(void function()));
	assertFalse(isComponent!(int delegate()));

	assertFalse(__traits(compiles, isComponent!NotComponentClass));
	assertFalse(__traits(compiles, isComponent!NotComponentUnion));
	assertFalse(__traits(compiles, isComponent!NotComponentFuncPtr));
}


///
template TypeInfoComponent(Component)
	if (isComponent!Component)
{
	enum TypeInfoComponent = typeid(Component);
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

		(() @trusted => this.storage = cast(void*) storage)();
		this.remove = &storage.remove;
		this.removeAll = &storage.removeAll;
		this.size = &storage.size;
	}

	///
	Storage!Component getStorage(Component)()
	{
		return cid is TypeInfoComponent!Component
			? (() @trusted => cast(Storage!Component) storage)() // safe cast
			: null;
	}

	bool delegate(in Entity entity) @safe pure remove;
	void delegate() @safe pure removeAll;
	size_t delegate() @safe pure size;

private:
	TypeInfo cid;
	void* storage;
}

@safe pure
@("storage: StorageInfo")
unittest
{
	auto sinfo = StorageInfo().__ctor!(int)();

	assertNotNull(sinfo.getStorage!int);
	assertNull(sinfo.getStorage!size_t);
	assertFalse(__traits(compiles, sinfo.getStorage!(immutable(int))()));
}

@safe pure
@("storage: StorageInfo")
unittest
{
	import std.range : front;

	auto sinfo = StorageInfo().__ctor!(int)();
	Storage!int storage = sinfo.getStorage!(int);

	assertTrue(storage.set(Entity(0), 3));
	assertEquals(1, storage._packedEntities.length);
	assertEquals(Entity(0), storage._packedEntities.front);

	assertFalse(storage.remove(Entity(0, 45)));
	assertTrue(storage.remove(Entity(0)));
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
	/**
	 * Connects a component to an entity. If the entity is already connected to
	 *     a component of this type then it'll be replaced by the new one. A
	 *     component cannot be connected to an invalid storage entity.
	 *
	 * Params:
	 *     entity = an entity to set the component.
	 *     component = a valid component.
	 *
	 * Returns: true if the component was set, false otherwise.
	 */
	@safe pure
	bool set(in Entity entity, in Component component)
	{
		if (entity.id < _sparsedEntities.length
			&& _sparsedEntities[entity.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[entity.id]].id == entity.id
			&& _packedEntities[_sparsedEntities[entity.id]].batch != entity.batch
		) {
			// don't set if the entity is storage invalid
			return false;
		}
		else if (entity.id < _sparsedEntities.length
			&& _sparsedEntities[entity.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[entity.id]] == entity
		) {
			// the entity already has a component of this type, so replace it
			_components[_sparsedEntities[entity.id]] = component;
		}
		else
		{
			// the entity does not exist in this Storage, add it and set it's component
			_set(entity, component);
		}

		return true;
	}


	/**
	 * Disaasociates an entity from it's component. If the entity is storage
	 *     invalid false is returned and the operation is halted. Both the
	 *     component and the entity get swapped with the last elements from it's
	 *     packed arrays and then removed. The sparse array is then mapped to
	 *     the new location of the swapped entity.
	 *
	 * Params: entity = the entity to disassociate from it's component.
	 *
	 * Returns: true if successfuly removed, false otherwise;
	 */
	@safe pure
	bool remove(in Entity entity)
	{
		if (!(entity.id < _sparsedEntities.length
			&& _sparsedEntities[entity.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[entity.id]] == entity)
		)
			return false;

		import std.algorithm : swap;
		import std.range : back, popBack;
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


	///
	@safe pure
	void removeAll()
	{
		_sparsedEntities = [];
		_packedEntities = [];
		_components = [];
	}


	/**
	 * Fetches the component of entity if exists. If the entity is not storage
	 *     valid it returns null.
	 *
	 * Params: entity = the entity used to search for the component.
	 *
	 * Returns: a pointer to the component if search was successful, null otherwise.
	 */
	@safe pure
	Component* get(in Entity entity)
	{
		// return null if the entity is invalid
		if (!(entity.id < _sparsedEntities.length
			&& _sparsedEntities[entity.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[entity.id]] == entity)
		)
			return null;

		return &_components[_sparsedEntities[entity.id]];
	}


	/**
	 * Fetch the component if associated to the entity, otherwise the component
	 *     passed in the parameters is set and returned. If the entity is
	 *     storage invalid then null is returned.
	 *
	 * Params:
	 *     entity = the entity to fetch the associated component.
	 *     component = a valid component to set if there is none associated.
	 *
	 * Returns: the Component* associated or created if successful, null otherwise.
	 */
	@safe pure
	Component* getOrSet(in Entity entity, in Component component)
	{
		if (entity.id < _sparsedEntities.length
			&& _sparsedEntities[entity.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[entity.id]].id == entity.id
			&& _packedEntities[_sparsedEntities[entity.id]].batch != entity.batch
		) {
			// don't set if the entity is storage invalid, the entity exists but
			// with a diferent batch
			return null;
		}
		else if (!(entity.id < _sparsedEntities.length
			&& _sparsedEntities[entity.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[entity.id]] == entity)
		) {
			// set if the entity is invalid
			return _set(entity, component);
		}

		return &_components[_sparsedEntities[entity.id]];
	}


	@safe pure
	size_t size() const
	{
		return _components.length;
	}

private:
	@safe pure
	Component* _set(in Entity entity, in Component component)
	{
		_packedEntities ~= entity; // set entity
		_components ~= component; // set component

		// map to the correct entity from the packedEntities from sparsedEntities
		if (entity.id >= _sparsedEntities.length) _sparsedEntities.length = entity.id + 1;
		_sparsedEntities[entity.id] = _packedEntities.length - 1; // safe pure cast

		return &_components[_sparsedEntities[entity.id]];
	}

	size_t[] _sparsedEntities;
	Entity[] _packedEntities;
	Component[] _components;
}

version(unittest)
{
	@Component struct Foo { int x, y; }
	@Component struct Bar { string str; }
}

@safe pure
@("storage: Storage")
unittest
{
	assertTrue(__traits(compiles, new Storage!Foo));
	assertTrue(__traits(compiles, new Storage!Bar));
	assertFalse(__traits(compiles, new Storage!InvalidComponent));
}

@safe pure
@("storage: Storage: get")
unittest
{
	auto storage = new Storage!Foo();

	storage.set(Entity(0), Foo(3, 3));

	assertNotNull(storage.get(Entity(0)));

	assertNull(storage.get(Entity(0, 54)));
	assertNull(storage.get(Entity(21)));

	assertEquals(Foo(3, 3), *storage.get(Entity(0)));
}

@safe pure
@("storage: Storage: getOrSet")
unittest
{
	auto storage = new Storage!Foo();

	assertEquals(Foo.init, *storage.getOrSet(Entity(0), Foo.init));
	assertEquals(Foo.init, *storage.getOrSet(Entity(0), Foo(2, 3)));
	assertNull(storage.getOrSet(Entity(0, 54), Foo(2, 3)));
}

@safe pure
@("storage: Storage: remove")
unittest
{
	auto storage = new Storage!Bar();

	storage.set(Entity(0), Bar("bar"));
	storage.set(Entity(1), Bar("bar"));

	assertFalse(storage.remove(Entity(0, 5)));
	assertFalse(storage.remove(Entity(42)));
	assertTrue(storage.remove(Entity(0)));

	assertEquals(1, storage._sparsedEntities[0]);
	assertEquals(Entity(1), storage._packedEntities[storage._sparsedEntities[1]]);
	assertEquals(Entity(1), storage._packedEntities[0]);
}

@safe pure
@("storage: Storage: set")
unittest
{
	auto storage = new Storage!Foo();

	assertTrue(storage.set(Entity(0), Foo(3, 2)));
	assertFalse(storage.set(Entity(0, 4), Foo(3, 2)));
	assertEquals(Entity(0), storage._packedEntities[storage._sparsedEntities[0]]);
	assertEquals(Entity(0), storage._packedEntities[0]);
	assertEquals(Foo(3, 2), storage._components[0]);


	assertTrue(storage.set(Entity(0), Foo(5, 5)));
	assertEquals(Entity(0), storage._packedEntities[storage._sparsedEntities[0]]);
	assertEquals(Entity(0), storage._packedEntities[0]);
	assertEquals(Foo(5, 5), storage._components[0]);
}
