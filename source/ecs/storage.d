module ecs.storage;

import ecs.entity : Entity;

version(unittest) import aurorafw.unit.assertion;

/**
 * A component must define this as an UDA.
 */
enum Component;


/**
 * Evalute is some T is a valid component. A component is defined by being a
 *     **struct** and must have the **Component** UDA.
 *
 * Params: T = valid component type.
 *
 * Returns: true is is a valid component, false otherwise.
 */
template isComponent(T)
{
	import std.traits : hasUDA;
	enum isComponent = is(T == struct) && hasUDA!(T, Component);
}

version(unittest)
{
	@Component struct ValidComponent {}
	@Component struct OtherValidComponent { int a; }
	struct InvalidComponent {}
}

///
@safe
@("storage: isComponent")
unittest
{
	assertTrue(isComponent!ValidComponent);
	assertTrue(isComponent!OtherValidComponent);
	assertFalse(isComponent!InvalidComponent);
}


template componentId(Component)
	if (isComponent!Component)
{
	enum componentId = typeid(Component);
}

///
@safe
@("storage: componentId")
unittest
{
	assertTrue(__traits(compiles, componentId!ValidComponent));
	assertTrue(__traits(compiles, componentId!OtherValidComponent));
	assertFalse(__traits(compiles, componentId!InvalidComponent));
}


/**
 * Structure to communicate with the Storage. Easier to keep diferent components
 *     in the same data structure for better access to it's storage. It can also
 *     have some fast access functions which map directly to the storage's
 *     functions.
 *
 * Params:
 *     EntityType = a valid entity type
 *     Component = a valid component
 */
package struct StorageInfo(EntityType)
{
public:
	this(Component)()
	{
		auto storage = new Storage!(EntityType, Component);
		this.cid = componentId!Component;

		(() @trusted => this.storage = cast(void*) storage)();
		this.remove = &storage.remove;
	}

	Storage!(EntityType, Component) getStorage(Component)()
	{
		return cid is componentId!Component
			? (() @trusted => cast(Storage!(EntityType, Component)) storage)() // safe cast
			: null;
	}

	bool delegate(Entity!EntityType entity) remove;

private:
	TypeInfo cid;
	void* storage;
}

@safe
@("storage: StorageInfo")
unittest
{
	auto sinfo = StorageInfo!(uint)().__ctor!(ValidComponent)();

	assertNotNull(sinfo.getStorage!ValidComponent);
	assertNull(sinfo.getStorage!OtherValidComponent);
	assertFalse(__traits(compiles, sinfo.getStorage!InvalidComponent));
}

@safe
@("storage: StorageInfo")
unittest
{
	import std.range : front;

	auto sinfo = StorageInfo!(uint)().__ctor!(ValidComponent)();
	Storage!(uint, ValidComponent) storage = sinfo.getStorage!(ValidComponent);

	assertTrue(storage.set(Entity!uint(0), ValidComponent()));
	assertEquals(1, storage._packedEntities.length);
	assertEquals(Entity!uint(0), storage._packedEntities.front);

	assertFalse(storage.remove(Entity!uint(0, 45)));
	assertTrue(storage.remove(Entity!uint(0)));
	assertEquals(0, storage._packedEntities.length);
}


/**
 * Used to save every component of a Component type and to keep track of which
 *     entities of type EntityType are connected to a component.
 *
 * Params:
 *     EntityType = a valid entity type.
 *     Component = a valid component.
 */
package class Storage(EntityType, Component)
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
	@safe
	bool set(in Entity!EntityType entity, in Component component)
	{
		if (entity.id < _sparsedEntities.length
			&& _sparsedEntities[entity.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[entity.id]] != entity
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
			_packedEntities ~= entity; // set entity
			_components ~= component; // set component

			// map to the correct entity from the packedEntities from sparsedEntities
			if (entity.id >= _sparsedEntities.length) _sparsedEntities.length = entity.id + 1;
			_sparsedEntities[entity.id] = cast(EntityType)(_packedEntities.length - 1); // safe cast
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
	@safe
	bool remove(in Entity!EntityType entity)
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


	/**
	 * Fetches the component of entity if exists. If the entity is not storage
	 *     valid it returns null.
	 *
	 * Params: entity = the entity used to search for the component.
	 *
	 * Returns: a pointer to the component if search was successful, null otherwise.
	 */
	@safe
	Component* get(in Entity!EntityType entity)
	{
		// return null if the entity is invalid
		if (!(entity.id < _sparsedEntities.length
			&& _sparsedEntities[entity.id] < _packedEntities.length
			&& _packedEntities[_sparsedEntities[entity.id]] == entity)
		)
			return null;

		return &_components[_sparsedEntities[entity.id]];
	}

private:
	EntityType[] _sparsedEntities;
	Entity!EntityType[] _packedEntities;
	Component[] _components;
}

version(unittest)
{
	@Component struct Foo { int x; float y; }
	@Component struct Bar { string str; }
}

@safe
@("storage: Storage")
unittest
{
	assertTrue(__traits(compiles, new Storage!(uint, Foo)));
	assertTrue(__traits(compiles, new Storage!(uint, Bar)));
	assertFalse(__traits(compiles, new Storage!(uint, InvalidComponent)));
}

@safe
@("storage: Storage: get")
unittest
{
	auto storage = new Storage!(size_t, Foo);

	storage.set(Entity!size_t(0), Foo(3, 3));

	assertNotNull(storage.get(Entity!size_t(0)));

	assertNull(storage.get(Entity!size_t(0, 54)));
	assertNull(storage.get(Entity!size_t(21)));

	assertEquals(Foo(3, 3), *storage.get(Entity!size_t(0)));
}

@safe
@("storage: Storage: remove")
unittest
{
	auto storage = new Storage!(ubyte, Bar);

	storage.set(Entity!ubyte(0), Bar("bar"));
	storage.set(Entity!ubyte(1), Bar("bar"));

	assertFalse(storage.remove(Entity!ubyte(0, 5)));
	assertFalse(storage.remove(Entity!ubyte(42)));
	assertTrue(storage.remove(Entity!ubyte(0)));

	assertEquals(1, storage._sparsedEntities[0]);
	assertEquals(Entity!ubyte(1), storage._packedEntities[storage._sparsedEntities[1]]);
	assertEquals(Entity!ubyte(1), storage._packedEntities[0]);
}

@safe
@("storage: Storage: set")
unittest
{
	auto storage = new Storage!(uint, Foo);

	assertTrue(storage.set(Entity!uint(0), Foo(3, 2)));
	assertFalse(storage.set(Entity!uint(0, 4), Foo(3, 2)));
	assertEquals(Entity!uint(0), storage._packedEntities[storage._sparsedEntities[0]]);
	assertEquals(Entity!uint(0), storage._packedEntities[0]);
	assertEquals(Foo(3, 2), storage._components[0]);


	assertTrue(storage.set(Entity!uint(0), Foo(5, 5)));
	assertEquals(Entity!uint(0), storage._packedEntities[storage._sparsedEntities[0]]);
	assertEquals(Entity!uint(0), storage._packedEntities[0]);
	assertEquals(Foo(5, 5), storage._components[0]);
}
