module vecs.storage;

import vecs.component;
import vecs.entity;
import vsignal.signal;
import vsignal.sink;

import std.traits : functionAttributes, functionLinkage, SetFunctionAttributes;

version(vecs_unittest)
{
	import std.exception : assertThrown;
	import core.exception : AssertError;
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
	this() @trusted
	{
		// @trusted according to Signal.sink's documentation
		onConstructSink = onConstruct.sink;
		onUpdateSink = onUpdate.sink;
		onRemoveSink = onRemove.sink;
	}

	/**
	Adds or updates the component for the entity.

	Signal: emits $(LREF onConstruct) after adding the component.

	Params:
		entity = a valid entity.

	Returns: A pointer to the component of the entity.
	*/
	Component* add()(in Entity entity)
	{
		import core.lifetime : emplace;

		Component* component = _add(entity);
		emplace(component);
		onConstruct.emit(entity, *component);
		return component;
	}


	/**
	Emplace or replace the component for the entity.

	Signal: emits $(LREF onConstruct) after adding the component.

	Params:
		entity = a valid entity.
		args = arguments to construct the component to emplace or replace.

	Returns: A pointer to the component of the entity.
	*/
	Component* emplace(Args...)(in Entity entity, auto ref Args args)
	{
		import core.lifetime : emplace, forward;

		Component* component = _add(entity);
		component.emplace(forward!args);
		onConstruct.emit(entity, *component);
		return component;
	}


	/**
	Patch a component of an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Signal: emits $(LREF onUpdate) after the patch.

	Params:
		entity: an entity in the storage.
		fn: the callback to call.

	Returns: A pointer to the patched component.
	*/
	Component* patch(Callback)(in Entity entity, Callback callback)
		in (contains(entity))
	{
		import std.traits : Parameters, ReturnType;
		enum isCallback(Fun) = is(ReturnType!Fun function(Parameters!Fun) : void function(ref Component));
		static assert(isCallback!Callback);

		Component* component = &_components[_sparsedEntities[entity]];
		callback(*component);
		onUpdate.emit(entity, *component);
		return component;
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
		onRemove.emit(entity, _components[_sparsedEntities[entity.id]]);

		immutable last = _packedEntities.back;

		// swap with the last element of packedEntities
		swap(_components.back, _components[_sparsedEntities[entity.id]]);
		swap(_packedEntities.back, _packedEntities[_sparsedEntities[entity.id]]);

		// map the sparseEntities to the new value in packedEntities
		_sparsedEntities[last.id] = _sparsedEntities[entity.id];
		_sparsedEntities[entity.id] = nullentity;

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
		return e.id < _sparsedEntities.length && _sparsedEntities[e.id] != nullentity;
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
		in (!contains(entity))
	{
		// map to the correct entity from the packedEntities from sparsedEntities
		if (entity.id >= _sparsedEntities.length)
		{
			import std.algorithm : uninitializedFill;

			immutable size = entity.id + 1;

			_sparsedEntities.reserve(size);
			auto slice = (() @trusted => _sparsedEntities.ptr[_sparsedEntities.length .. size])();
			slice.uninitializedFill(nullentity);
			_sparsedEntities ~= slice;
		}

		_sparsedEntities[entity.id] = _packedEntities.length;

		_packedEntities ~= entity; // set entity
		_components.length++;

		return &_components[_sparsedEntities[entity.id]];
	}


	size_t[] _sparsedEntities;
	Entity[] _packedEntities;
	Component[] _components;

	alias CallbackFun = SetFunctionAttributes!(
		void delegate(Entity, ref Component),
		functionLinkage!Fun,
		functionAttributes!Fun
	);

package:
	Sink!CallbackFun onConstructSink;
	Sink!CallbackFun onUpdateSink;
	Sink!CallbackFun onRemoveSink;

public:
	Signal!CallbackFun onConstruct;
	Signal!CallbackFun onUpdate;
	Signal!CallbackFun onRemove;
}

@("[Storage] component manipulation")
@safe pure nothrow unittest
{
	struct Position { ulong x, y; }
	scope storage = new Storage!(Position, void delegate() @safe pure nothrow);

	with (storage) {
		add(Entity(0));
		emplace(Entity(5), 4, 6);
		emplace(Entity(3), Position(2, 3));
	}

	assert(*storage.get(Entity(0)) == Position.init);
	assert(*storage.get(Entity(5)) == Position(4, 6));
	assert(*storage.get(Entity(3)) == Position(2, 3));

	assert( storage.tryGet(Entity(0)));
	assert(!storage.tryGet(Entity(1234)));

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

	// ignores batches, however they are tested by EntityManagerT
	assert( storage.remove(Entity(5, 1)));
	assert(!storage.contains(Entity(5)));
}

version(assert)
@("[Storage] entity manipulation (invalid entities)")
unittest
{
	scope storage = new Storage!int;

	storage.add(Entity(1));

	assertThrown!AssertError(storage.add(Entity(1, 4)));
	assertThrown!AssertError(storage.emplace(Entity(1, 4), 0));
}

@("[Storage] signals")
@safe pure nothrow unittest
{
	scope storage = new Storage!(int, void delegate() @safe pure nothrow @nogc);
	enum e = Entity(0);

	int value;
	void delegate(Entity, ref int) @safe pure nothrow @nogc fun = (Entity, ref int) { value++; };

	storage.onConstructSink.connect!fun;
	storage.onUpdateSink.connect!fun;
	storage.onRemoveSink.connect!fun;

	storage.add(e);
	assert(value == 1);

	storage.patch(e, (ref int) {});
	assert(value == 2);

	storage.remove(e);
	assert(value == 3);
}
