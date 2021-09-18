module vecs.entitymanager;

import vecs.component;
import vecs.entity;
import vecs.entitybuilder : EntityBuilder;
import vecs.storage;
import vecs.storageinfo;
import vecs.query;
import vecs.resource;
import vecs.utils : PointerOf;

import std.format : format;
import std.meta : AliasSeq;
import std.range : iota;
import std.traits : TemplateArgsOf;
import std.typecons : tuple;

version(vecs_unittest)
{
	import std.exception : assertThrown;
	import core.exception : AssertError;
}

alias EntityManager = EntityManagerT!(void delegate() @safe);

/**
 * Responsible for managing all entities lifetime and access to components as
 *     well as any operation related to them.
 */
class EntityManagerT(Fun)
	if(is(Fun : void delegate()))
{
public:
	/**
	Registers all `Components` in `EntityManager`.

	Params:
		Components = Component types to register.
	*/
	void registerComponent(Components...)()
		if (Components.length)
	{
		static foreach (Component; Components) _assure!Component;
	}


	/**
	Add `Components` to an `entity`. `Components` are contructed according to
	their dafault initializer.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	struct Position { ulong x, y; }
	auto world = new EntityManager();

	Position* i = world.add!Position(world.entity);
	Tuple!(int*, string*) t = world.add!(int, string)(world.entity);
	---

	Signal: emits `onConstruct` after each component is assigned.

	Params:
		Components = Component types to add.
		entity = a valid entity.

	Returns: A pointer or a `Tuple` of pointers to the added components.
 	*/
	auto addComponent(Components...)(in Entity entity)
		if (Components.length)
		in (validEntity(entity))
	{
		import std.meta : staticMap;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components) C[i] = _assureStorage!Component.add(entity);

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
	}


	/**
	Assigns Components to an entity. The Components is initialized with
	the args provided.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	struct Position { ulong x, y; }
	auto world = new EntityManager();

	// with one component field arguments can be used
	Position* i = world.emplaceComponent!Position(world.entity, 2LU, 3LU);

	int* i; Position* pos;

	// with multiple components only the type can be used, not field arguments
	// components can be infered as well
	AliasSeq!(i, pos) = world.emplaceComponent!(int, Position)(world.entity, 3, Position(1, 2));

	assert(*i = 3 && *pos = Position(1, 2));
	---

	Signal: emits `onConstruct` after each component is assigned.

	Params:
		Components = Component types to emplace.
		entity = a valid entity.
		args = arguments to contruct the Component types.

	Returns: A pointer or `Tuple` of pointers to the emplaced components.
	*/
	Component* emplaceComponent(Component, Args...)(in Entity entity, auto ref Args args)
		in (validEntity(entity))
	{
		import core.lifetime : forward;

		return _assureStorage!Component.emplace(entity, forward!args);
	}

	/// Ditto
	auto emplaceComponent(Components...)(in Entity entity, auto ref Components args)
		if (Components.length > 1)
		in (validEntity(entity))
	{
		import core.lifetime : forward;
		import std.meta : staticMap;

		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components)
			C[i] = emplaceComponent!Component(entity, forward!(args[i]));

		return tuple(C);
	}


	/**
	Releases a `shallow entity`. It's `id` is released and the `batch` is updated
	to be ready for the next recycling.

	Attempting to use an invalid entity leads to undefined behavior.

	Params:
		entity = a valid entity.
		batch = batch to update upon release.

	See_Also: $(LREF shallowEntity)
	*/
	@safe pure nothrow @nogc
	void releaseEntity(in Entity entity)
	{
		releaseEntity(entity, (entity.batch + 1) & Entity.maxbatch);
	}


	/// Ditto
	@safe pure nothrow @nogc
	void releaseEntity(in Entity entity, in size_t batch)
		in (shallowEntity(entity))
	{
		releaseId(entity, batch);
	}


	/**
	Removes all components from an entity and releases it.

	Attempting to use an invalid entity leads to undefined behavior.

	Params:
		entity = a valid entity.
		batch = batch to update upon release.

	Signal: emits `onRemove` before each component is removed.

	See_Also: $(LREF releaseEntity), $(LREF removeAll)
	*/
	void destroyEntity()(in Entity entity)
	{
		destroyEntity(entity, (entity.batch + 1) & Entity.maxbatch);
	}


	/// Ditto
	void destroyEntity()(in Entity e, in size_t batch)
	{
		removeAllComponents(e);
		releaseId(e, batch);
	}


	/**
	Returns the number of entities currently alive.

	Returns: Number of entities in use.

	See_Also: $(LREF eachEntity)
	*/
	@safe pure nothrow @nogc
	size_t aliveEntities()
	{
		auto alive = _entities.length;

		// search all destroyed entities
		for (auto entity = queue; entity != nullentity; alive--)
			entity = _entities[entity.id];

		return alive;
	}


	/**
	Checks if an entity is shallow. A shallow entity does not have assigned
	components.

	Attempting to use an invalid entity leads to undefined behavior.

	Params:
		entity = a valid entity.

	Returns: True if shallow, false otherwise.
	*/
	@safe pure nothrow @nogc
	bool shallowEntity(in Entity e)
		in (validEntity(e))
	{
		import std.algorithm : filter;

		auto range = storageInfoMap.filter!(sinfo => sinfo.storage !is null);

		foreach (sinfo; range)
			if (sinfo.contains(e))
				return false;

		return true;
	}


	/**
	Signal emited when a component is contructed.

	Examples:
	---
	auto world = new EntityManager();

	int result;
	world.onConstruct!int.connect!((in Entity, ref i) { result = i; });

	world.entity.emplace!int(5);

	assert(result == 5);
	---

	Params:
		Component = Signal's Component type.

	Returns: A reference to the Signal.
	*/
	ref onConstruct(Component)()
	{
		return _assureStorage!Component.onConstructSink;
	}


	/**
	Signal emited when a component is contructed.

	Examples:
	---
	auto world = new EntityManager();

	int result;
	world.onUpdate!int.connect!((in Entity, ref i) { result = i; });

	world.entity
		.add!int
		.replace!int(5);

	assert(result == 5);
	---

	Params:
		Component = Signal's Component type.

	Returns: A reference to the Signal.
	*/
	ref onUpdate(Component)()
	{
		return _assureStorage!Component.onUpdateSink;
	}


	/**
	Signal emited before a component is removed.

	Examples:
	---
	auto world = new EntityManager();

	int result;
	world.onRemove!int.connect!((in Entity, ref i) { result = i; });

	world.removeComponent!int(world.entity.emplace!int(5));

	assert(result == 5);
	---
	*/
	ref onRemove(Component)()
	{
		return _assureStorage!Component.onRemoveSink;
	}


	/**
	Patch a component of an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	struct Position { ulong x, y; }
	auto world = new EntityManager();

	auto entity = world.entity.add!Position;
	entity.patch!Position((ref Position pos) { pos.x = 24; });
	---

	Signal: emits $(LREF onUpdate) after the patch.

	Params:
		Components: Component types to patch.
		entity: a valid entity.
		callbacks: callbacks to call for each Component type.

	Returns: A pointer or `Tuple` of pointers to the patched components.
	*/
	Component* patchComponent(Component, Callbacks...)(in Entity entity, Callbacks callbacks)
		if (Callbacks.length)
		in (validEntity(entity))
	{
		Component* component;

		static foreach (i, callback; callbacks)
			component = _assureStorage!Component.patch(entity, callbacks[i]);

		return component;
	}


	/**
	Replaces components of an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	auto world = new EntityManager();

	assert(*world.replaceComponent!int(world.entity.add!int, 3) == 3);


	struct Position { ulong x, y; }
	int* i; Position* pos;

	// with multiple components only the type can be used, not field arguments
	// components can be infered as well
	AliasSeq!(i, pos) = world.emplaceComponent!(int, Position)(world.entity.add!(int, Position), 3, Position(1, 2));

	assert(*i = 3 && *pos = Position(1, 2));
	---

	Signal: emits $(LREF onUpdate) after the replacement.

	Params:
		Components: Component types to replace.
		entity: a valid entity.
		args: arguments to contruct the Component types.

	Returns: A pointer or `Tuple` of pointers to the replaced components.
	*/
	Component* replaceComponent(Component, Args...)(in Entity entity, auto ref Args args)
		in (validEntity(entity))
	{
		import core.lifetime : emplace, forward;

		return _assureStorage!Component.patch(entity, (ref Component c) {
			ubyte[Component.sizeof] tmp = void;
			auto buf = (() @trusted => cast(Component*)(tmp.ptr))();

			c = *emplace!Component(buf, forward!args);
		});
	}

	/// Ditto
	auto replaceComponent(Components...)(in Entity entity, auto ref Components args)
		if (Components.length > 1)
		in (validEntity(entity))
	{
		import core.lifetime : emplace, forward;
		import std.meta : staticMap;

		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components)
			C[i] = replaceComponent!Component(entity, forward!(args[i]));

		return tuple(C);
	}


	/**
	Replaces or emplaces components of an entity if it owes or not the same
	Component types.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	auto world = new EntityManager();

	assert(*world.entity.emplaceOrReplace!int(3) == 3);

	struct Position { ulong x, y; }
	int* i; Position* pos;

	// with multiple components only the type can be used, not field arguments
	// components can be infered as well
	AliasSeq!(i, pos) = world.emplaceComponent!(int, Position)(world.entity, 3, Position(1, 2));

	assert(*i = 3 && *pos = Position(1, 2));
	---

	Signal: emits $(LREF onUpdate) if replaced.

	Params:
		Comonents: Component types to emplace or replace.
		entity: a valid entity.
		args: arguments to contruct the Component types.

	Returns: A pointer os `Tuple` of pointers to the emplaced or replaced components.
	*/
	Component* emplaceOrReplaceComponent(Component, Args...)(in Entity entity, auto ref Args args)
		in (validEntity(entity))
	{
		import core.lifetime : emplace, forward;

		auto storage = _assureStorage!Component;

		return storage.contains(entity)
			? storage.patch(entity, (ref Component c) {
					ubyte[Component.sizeof] tmp = void;
					auto buf = (() @trusted => cast(Component*)(tmp.ptr))();

					c = *emplace!Component(buf, forward!args);
				})
			: storage.emplace(entity, forward!args);
	}

	/// Ditto
	auto emplaceOrReplaceComponent(Components...)(in Entity entity, auto ref Components args)
		if (Components.length > 1)
		in (validEntity(entity))
	{
		import core.lifetime : emplace, forward;
		import std.meta : staticMap;

		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components)
			C[i] = emplaceOrReplaceComponent!Component(entity, forward!(args[i]));

		return tuple(C);
	}


	/**
	Replaces a component of an entity with the init state of the Component type
	if it owes it.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	auto world = new EntityManager();

	assert(*world.resetComponent!int(world.entity.emplace!int(4)) == int.init);
	---

	Signal: emits $(LREF onUpdate) after the reset.

	Params:
		Comonents: Component types to replace.
		entity: a valid entity.

	Returns: A pointer or `Tuple` of pointers to the replaced component.
	*/
	auto resetComponent(Components...)(in Entity entity)
		if (Components.length)
		in (validEntity(entity))
	{
		import std.meta : staticMap;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components)
			C[i] = _assureStorage!Component.patch(entity, (ref Component c) {
				c = Component.init;
			});

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
	}


	/**
	Adds or replaces a component of an entity with the init state of the
	Component type if it owes it.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	auto world = new EntityManager();

	assert(*world.addOrResetComponent!int(world.entity.addOrReset!int) == int.init);
	---

	Signal: emits $(LREF onUpdate) if reset.

	Params:
		Comonents: Component types to add or replace.
		entity: a valid entity.

	Returns: A pointer or `Tuple` of pointers to the added or replaced components.
	*/
	auto addOrResetComponent(Components...)(in Entity entity)
		if (Components.length)
		in (validEntity(entity))
	{
		import std.meta : staticMap;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components)
		{
			auto storage = _assureStorage!Component;
			C[i] = storage.contains(entity)
				? storage.patch(entity, (ref Component c) { c = Component.init; })
				: storage.add(entity);
		}

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
	}


	/**
	Removes components from an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	auto world = new EntityManager();

	assert(world.removeComponent!int(world.entity.add!int));
	assert(world.removeComponent!(int, string)(world.entity.add!int) == [true, false]);
	---

	Signal: emits $(LREF onRemove) before each component is removed.

	Params:
		Components = Component types to remove.
		entity = a valid entity.

	Returns: A boolean or and array of booleans evaluating to `true` if the
	component was removed, `false` otherwise;
	*/
	auto removeComponent(Components...)(in Entity entity)
		if (Components.length)
		in (validEntity(entity))
	{
		import std.meta : Repeat;
		Repeat!(Components.length, bool) R; // removed components

		static foreach (i, Component; Components) R[i] = _assureStorage!Component.remove(entity);

		static if (Components.length == 1)
			return R[0];
		else
			return [R];
	}


	/**
	Removes all components from an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Signal: emits $(LREF onRemove) before each component is removed.

	Params:
		entity = a valid entity.
	*/
	void removeAllComponents()(in Entity e)
		in (validEntity(e))
	{
		import std.traits : functionAttributes, SetFunctionAttributes;

		foreach (sinfo; storageInfoMap)
			if (sinfo.storage !is null)
				(() @trusted => cast(SetFunctionAttributes!(typeof(sinfo.remove), "D", functionAttributes!Fun)) sinfo.remove)()(e);
	}


	/**
	Removes all entities from each Component storage. If no Components are
	provided it clears all storages.

	Params:
		Components = Component types to clear.
	*/
	void clear(Components...)()
	{
		static if (Components.length)
			static foreach (Component; Components) _assureStorageInfo!Component().clear();

		else
			foreach (sinfo; storageInfoMap) if (sinfo.storage) sinfo.clear();
	}


	/**
	Fetches components of an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	auto world = new EntityManager();

	int* i = world.get!int(world.entity.add!int);
	Tuple!(int*, string*) t = world.get!(int, string)(world.entity.add!(int, string));
	---

	Params:
		Components = Component types to get.
		entity = a valid entity.

	Returns: A pointer or a `Tuple` of pointers to the components of the entity.
	*/
	auto getComponent(Components...)(in Entity entity)
		if (Components.length)
		in (validEntity(entity))
	{
		import std.meta : staticMap;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components) C[i] = _assureStorage!Component.get(entity);

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
	}


	/**
	Attempts to get components of an entity. A `null` pointer is returned for
	components that are not assigned to the entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	auto world = new EntityManager();

	assert(!world.tryGetComponent!int(world.entity));

	int* i; string* str;
	AliasSeq!(i, str) = world.tryGetComponent!(int, string)(world.entity);
	assert(!i); assert(!str);
	---

	Params:
		Components = Component types to get.
		entity = a valid entity.

	Returns: A pointer or a `Tuple` with pointers to the components potencialy
	assigned to the entity. A pointer is `null` if the component is not assigned
	to the entity.
	*/
	auto tryGetComponent(Components...)(in Entity entity)
		if (Components.length)
		in (validEntity(entity))
	{
		import std.meta : staticMap;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components) C[i] = _assureStorage!Component.tryGet(entity);

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
	}


	/**
	Gets the type if owned by an entity otherwise emplaces a new one.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	auto world = new EntityManager();

	auto entity = world.entity;
	assert(*world.getOrEmplaceComponent!int(entity, 3) == 3);

	struct Position { ulong x, y; }
	int* i; Position* pos;
	AliasSeq!(i, pos) = world.getOrEmplaceComponent!(int, Position)(entity, 27, Position(1, 2));

	assert(*i == 3); // entity owed an int type
	assert(*pos == Position(1, 2)); // entity didn't owe a Position type
	---

	Params:
		Components = Component types to get.
		entity = a valid entity.
		args = arguments to contruct the Component types if the entity does not
			owe them.

	Returns: A pointer or a `Tuple` of pointers to the components previously
	owed or emplaced.
	*/
	Component* getOrEmplaceComponent(Component, Args...)(in Entity entity, auto ref Args args)
		in (validEntity(entity))
	{
		import core.lifetime : forward;

		auto storage = _assureStorage!Component;
		return storage.contains(entity)
			? storage.get(entity)
			: storage.emplace(entity, forward!args);
	}

	/// Ditto
	auto getOrEmplaceComponent(Components...)(in Entity entity, auto ref Components args)
		if (Components.length > 1)
		in (validEntity(entity))
	{
		import core.lifetime : forward;
		import std.meta : staticMap;

		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components)
			C[i] = getOrEmplaceComponent!Component(entity, forward!(args[i]));

		return tuple(C);
	}


	/**
	Gets the type if owned by an entity otherwise emplaces a new one constructed
	to its init state.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	auto world = new EntityManager();

	auto entity = world.entity.emplace!int(3);

	struct Position { ulong x, y; }
	int* i; Position* pos;
	AliasSeq!(i, pos) = world.getOrAdd!(int, Position)(entity);

	assert(*i == 3); // entity owed an int type
	assert(*pos == Position.init); // entity didn't owe a Position type
	---

	Params:
		Components = Component types to get.
		entity = a valid entity.

	Returns: A pointer or a `Tuple` of pointers to the components previously
	owed or emplaced.
	*/
	auto getOrAddComponent(Components...)(in Entity entity)
		if (Components.length)
		in (validEntity(entity))
	{
		import std.meta : staticMap;

		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components)
		{
			auto storage = _assureStorage!Component;
			C[i] = storage.contains(entity)
				? storage.get(entity)
				: storage.add(entity);
		}

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
	}


	/**
	 * Get the size of Component Storage. The size represents how many entities
	 *     and components are stored in the Component's storage.
	 *
	 * Params:
	 *     Component = a Component type to search.
	 *
	 * Examples:
	 * ---
	 * struct Foo {}
	 * auto em = new EntityManager();
	 *
	 * // gets Foo's storage size
	 * assert(0 == em.size!Foo);
	 * ---
	 *
	 * Returns: the amount of entities/components in the Component Storage.
	 */
	size_t size(Component)()
	{
		return _assureStorage!Component().size;
	}


	/**
	Creates new entity and wraps it in an EntityBuilder. If a hint is provided,
	then it will create an entity matching the hint if the id is not in use,
	otherwise it will return the entity in use.

	Attempting to use an invalid entity id leads to undefined behavior.

	Params:
		hint = an entity with valid id.

	Returns: The created or in use entity wrapped in an EntityBuilder.
	*/
	@safe pure nothrow @property
	EntityBuilder!EntityManagerT entity()
	{
		EntityBuilder!EntityManagerT builder = {
			entity: createEntity(),
			entityManager: this
		};

		return builder;
	}


	/// Ditto
	@safe pure nothrow @property
	EntityBuilder!EntityManagerT entity(in Entity hint)
	{
		EntityBuilder!EntityManagerT builder = {
			entity: createEntity(hint),
			entityManager: this
		};

		return builder;
	}


	/**
	Checks if an entity is in use.

	Attempting to use an invalid entity id leads to undefined behavior.

	Params:
		entity = a valid entity.

	Returns: True if the entity is valid, false otherwise.
	*/
	@safe pure nothrow @nogc
	bool validEntity(in Entity entity) const
		in (entity.id < Entity.maxid)
	{
		return entity.id < _entities.length && _entities[entity.id] == entity;
	}


	/**
	Iterates each entity in use and applies a function to it.

	Params:
		fun = the function to apply to each entity.
	*/
	void eachEntity(F)(F fun) const
	{
		if (queue == nullentity)
			foreach (i, entity; _entities) fun(entity);

		else
			foreach (i, entity; _entities) if (entity.id == i) fun(entity);
	}


	/**
	 * Inserts a new resource. If there's already the same type stored, then
	 *     it's content will be replaced be the new one. If no value is passed,
	 *     then the resource is stored with it's default initializer.
	 *
	 * Examples:
	 * ---
	 * class Foo {}
	 * auto em = new EntityManager();
	 *
	 * // will be stored as null!
	 * em.addResource!Foo;
	 *
	 * // update Foo instance
	 * em.addResource(new Foo());
	 * ---
	 *
	 * Params:
	 *     res = resource to add.
	 */
	void addResource(R)(R res = R.init)
		if (isResource!R)
	{
		auto resource = &_assureResource!R();
		resource.data[] = (() @trusted pure nothrow @nogc => (cast(void*)(&res))[0 .. R.sizeof])();
	}


	/**
	 * Gets the resource stored of type R. If none was added then a new resource
	 *     of the same type is stored.
	 *
	 * Examples:
	 * ---
	 * struct Foo { int i; }
	 * auto em = new EntityManager();
	 *
	 * assert(Foo() == em.resource!Foo);
	 * em.resource!Foo = Foo(3);
	 * assert(Foo(3) == em.resource!Foo);
	 * ---
	 *
	 * Params:
	 *     R = type to add as a resource.
	 *
	 */
	auto ref R resource(R)()
		if (isResource!R)
	{
		auto resource = &_assureResource!R();
		return *(() @trusted pure nothrow @nogc => cast(R*)resource.data)();
	}


	/**
	Creates a new entity. If the queue is null a new id is generated, otherwise
	an id is recycled. If a hint is provided, an entity matching the hint is
	created, only if the id is not in use, otherwise it will return the entity
	in use.

	Attempting to use an invalid entity id leads to undefined behavior.

	Params:
		entity = an entity with valid id.

	Returns: The created or in use entity.
	*/
	@safe pure nothrow
	Entity createEntity()
	{
		if (queue == nullentity)
		{
			import std.range : back;
			_entities ~= generateId(_entities.length);
			return _entities.back;
		}

		else return recycleId();
	}


	/// Ditto
	@safe pure nothrow
	Entity createEntity(in Entity hint)
		in (hint.id < Entity.maxid)
	{
		// if the identifier wasn't yet generated, generate it
		if (hint.id >= _entities.length)
		{
			_entities.length = hint.id + 1;

			// must release identifiers in between and set their next batch to 0
			// to avoid shallow entities and make sure the batch 0 is used
			foreach (pos; _entities.length .. hint.id)
				releaseId(generateId(pos), 0);

			_entities[hint.id] = hint;
			return hint;
		}

		// if the hint's identifier is alive, return it
		else if (hint.id == _entities[hint.id].id) return _entities[hint.id];

		// if the hint's id is released revive it
		else
		{
			Entity* eptr = &queue;

			while (eptr.id != hint.id)
				eptr = &_entities[eptr.id];

			// ensures the queue is not broken
			*eptr = _entities[hint.id];
			_entities[hint.id] = hint;

			return hint;
		}
	}


	/// Query type of this EntityManagerT type
	template Query(Args...)
		if (Args.length)
	{
		static if (is(Args[0] Select == S!Components, alias S = .Select, Components...))
			alias Query = .Query!(EntityManagerT, Select!Components, Args[1 .. $]);
		else
			alias Query = .Query!(EntityManagerT, Select!Args);
	}


	/**
	A Query to iterate entities with the provided Component types.

	Examples:
	---
	auto world = new EntityManager();

	// Query!(EntityManager, Select!(int, uint))
	world.query!(int, uint);

	// Query!(EntityManager, Select!int, With!uint, Without!long)
	world.query!(Select!int, With!uint, Without!long);

	// types can be constructed via building
	alias MyQuery = EntityManager
		.Query!(int, uint)
		.With!long
		.Without!string;

	// when working with rules Select must be used
	alias MyOtherQuery = EntityManager
		.Query!(Select!(int, uint), With!long)
		.Without!string;
	---

	Params:
		Args = Types to select and filter.

	Returns: A new Query instance.
	*/
	Query!Args query(Args...)()
	{
		static if (TemplateArgsOf!(Query!Args).length == 2)
		{
			// Query!(EntityManagerT, Select!(Args...))
			alias Components = Args;
		}
		else
		{
			// Query!(EntityManagerT, Args...)
			import std.meta : Map = staticMap;
			alias Components = Map!(TemplateArgsOf, Args);
		}

		return mixin (q{ Query!Args(%(_assureStorage!(Components[%s])%|, %)) }
			.format(Components.length.iota)
		);
	}

private:
	/**
	Generates a new entity identifier.

	If the position reaches maximum capacity, the program will attempt to halt.

	Params:
		pos = valid entity position.

	Returns: The created entity with id equal to its position.
	*/
	@safe pure nothrow @nogc
	Entity generateId(in size_t pos)
	{
		static immutable err = "Maximum entities (" ~ Entity.maxid.stringof ~ ") reached!";
		if (pos >= Entity.maxid) assert(false, err);

		return Entity(pos);
	}


	/**
	Creates a new entity by recycling a previously generated id.

	Returns: The created entity with id and batch equal to the last entity in
	queue.
	*/
	@safe pure nothrow @nogc
	Entity recycleId()
		in (queue != nullentity)
	{
		immutable next = queue;     // get the next entity in queue
		queue = _entities[next.id]; // grab the entity which will be the next in queue
		_entities[next.id] = next;  // revive the entity
		return next;
	}


	/**
	Invalidates the entity's id and prepares the batch for the next recycling.

	Params:
		entity = an entity with valid id.
		batch = batch to update for the next recycling call.
	*/
	@safe pure nothrow @nogc
	void releaseId(in Entity entity, in size_t batch)
		in (batch <= Entity.maxbatch)
	{
		_entities[entity.id] = queue;
		queue = Entity(entity.id, batch);
	}


	/// Assures the Component's storage availability
	size_t _assure(Component)()
		if (isComponent!Component)
	{
		// Component's generated id
		immutable index = ComponentId!Component;

		// allocates enough space for the new Component
		if (index >= storageInfoMap.length)
		{
			storageInfoMap.length = index + 1;
		}

		// creates a storage if there is none of Component
		if (storageInfoMap[index].storage is null)
		{
			storageInfoMap[index] = StorageInfo().__ctor!(Component, Fun)();
		}

		return index;
	}


	/// Assures the Component's storage availability and returns the Storage
	Storage!(Component, Fun) _assureStorage(Component)()
		if (isComponent!Component)
	{
		immutable index = _assure!Component(); // to fix dmd boundscheck=off
		return storageInfoMap[index].get!(Component, Fun)();
	}


	/// Assures the Component's storage availability and returns the StorageInfo
	auto ref StorageInfo _assureStorageInfo(Component)()
		if (isComponent!Component)
	{
		immutable index = _assure!Component();
		return storageInfoMap[index];
	}


	ref Resource _assureResource(Res)()
	{
		immutable id = ResourceId!Res();
		if (resources.length <= id) resources.length = id + 1;
		if (resources[id].data.ptr is null) resources[id].data.length = Res.sizeof;
		return resources[id];
	}


	Entity[] _entities;
	Entity queue = nullentity;
	StorageInfo[] storageInfoMap;
	Resource[] resources;
}

@("[EntityManager] component operations (adding and updating)")
@safe pure nothrow unittest
{
	scope world = new EntityManagerT!(void delegate() @safe pure nothrow @nogc);

	assert(*world.addComponent!int(world.entity) == 0);
	assert(*world.emplaceComponent!int(world.entity, 34) == 34);

	struct Position { ulong x, y; }
	auto entity = world.entity
		.addOrReset!int
		.emplaceOrReplace!string("Hello")
		.emplaceOrReplace!Position(1LU, 4LU);

	int* integral;
	string* str;

	AliasSeq!(integral, str) = world.getComponent!(int, string)(entity);

	assert(*integral == 0);
	assert(*str == "Hello");

	assert(!__traits(compiles, entity.patch!int()));
	assert(!__traits(compiles, entity.patch!int((int) {})));
	assert(!__traits(compiles, entity.patch!int((char) {})));
	assert(!__traits(compiles, entity.patch!int((ref int i) => i++)));
	assert( __traits(compiles, entity.patch!int((ref int) {}, (ref int) {})));

	entity.patch!int((ref int i) { i = 45; });

	assert(*integral == 45);
	assert(world.patchComponent!(int)(entity, (ref int) {}) == integral);
	assert(world.patchComponent!(string)(entity, (ref string s) {}) == str);

	assert(*world.replaceComponent!int(entity, 3) == 3);
	assert(*world.resetComponent!int(entity) == int.init);

	Position* position;
	uint* uintegral;

	AliasSeq!(position, uintegral) = world.tryGetComponent!(Position, uint)(entity);

	assert(*position == Position(1, 4));
	assert(!uintegral);

	int* i; ulong* ul;
	AliasSeq!(i, ul) = world.getOrEmplaceComponent!(int, ulong)(entity, 24, 45);

	assert(*i == 0); // entity had an int
	assert(*ul == 45); // entity didn't have an ulong

	assert(*world.getOrAddComponent!int(world.entity) == int.init);
}

version(assert)
@("[EntityManager] component operations (invalid entities)")
unittest
{
	scope world = new EntityManager();
	const entity = world.entity;

	assertThrown!AssertError(world.getComponent!int(entity));
	assertThrown!AssertError(world.resetComponent!int(entity));
	assertThrown!AssertError(world.replaceComponent!int(entity, 0));
	assertThrown!AssertError(world.patchComponent!int(entity, (ref int i) {}));

	const invalid = Entity(entity.id, entity.batch + 1);

	assertThrown!AssertError(world.addComponent!int(invalid));
	assertThrown!AssertError(world.resetComponent!int(invalid));
	assertThrown!AssertError(world.addOrResetComponent!int(invalid));
	assertThrown!AssertError(world.emplaceComponent!int(invalid, 0));
	assertThrown!AssertError(world.replaceComponent!int(invalid, 0));
	assertThrown!AssertError(world.emplaceOrReplaceComponent!int(invalid, 0));
	assertThrown!AssertError(world.patchComponent!int(invalid, (ref int i) {}));
	assertThrown!AssertError(world.getComponent!int(invalid));
	assertThrown!AssertError(world.getOrAddComponent!int(invalid));
	assertThrown!AssertError(world.getOrEmplaceComponent!int(invalid));
	assertThrown!AssertError(world.removeComponent!int(invalid));
	assertThrown!AssertError(world.removeAllComponents(invalid));
}

@("[EntityManager] component operations (register and remove)")
@safe pure nothrow unittest
{
	scope world = new EntityManagerT!(void delegate() @safe pure nothrow @nogc);

	world.registerComponent!(int, string, ulong);

	import std.meta : staticMap;
	import std.algorithm : max;
	immutable maxid = staticMap!(ComponentId, int, string, ulong).max;

	assert(world.storageInfoMap.length == maxid + 1);

	with(world) {
		world.entity.add!int;
		world.entity.add!int;
		world.entity.add!(int, uint, ulong);
	}

	assert(world.size!int == 3);

	world.clear!int();

	assert(!world.size!int);
	assert( world.size!uint == 1);
	assert( world.size!ulong == 1);

	world.clear();

	assert(!world.size!uint);
	assert(!world.size!ulong);

	auto entity = world.entity
		.add!int
		.add!uint
		.add!ulong;

	assert( world.removeComponent!int(entity));
	assert(!world.removeComponent!int(entity));
	assert(world.shallowEntity(entity.removeAll()));
}

@("[EntityManager] entity manipulation (entity properties)")
@safe pure nothrow unittest
{
	scope world = new EntityManagerT!(void delegate() @safe pure nothrow @nogc);

	auto entity = world.entity();

	assert(world.aliveEntities() == 1);
	assert(world.shallowEntity(entity));
	assert(world.validEntity(entity));

	world.releaseEntity(entity);

	assert(!world.aliveEntities());
	assert(!world.validEntity(entity));
}

@("[EntityManager] entity manipulation (generated and recycled)")
@safe pure nothrow unittest
{
	scope world = new EntityManagerT!(void delegate() @safe pure nothrow @nogc);

	assert(!world._entities);

	auto entity = world.entity();

	assert(entity.id == 0);
	assert(entity.batch == 0);
	assert(world._entities.length == 1);

	auto generated = world.entity();

	assert(generated.id == 1);
	assert(generated.batch == 0);
	assert(world._entities.length == 2);

	generated.destroy();
	auto recycled = world.entity();

	assert(recycled.id == generated.id);
	assert(recycled.batch == generated.batch + 1);
	assert(world._entities.length == 2);
}

version(assert)
@("[EntityManager] entity manipulation (invalid entities)")
unittest
{
	scope world = new EntityManager();
	const entity = world.entity;
	const invalid = Entity(entity.id, entity.batch + 1);

	assertThrown!AssertError(world.shallowEntity(invalid));
	assertThrown!AssertError(world.destroyEntity(invalid));
	assertThrown!AssertError(world.releaseEntity(invalid));
	assertThrown!AssertError(world.releaseEntity(entity, size_t.max));
	assertThrown!AssertError(world.entity(nullentity));
	assertThrown!AssertError(world.validEntity(nullentity));
	assertThrown!AssertError(world.generateId(nullentity.id));
}

@("[EntityManager] entity manipulation (queue properties)")
@safe pure nothrow unittest
{
	scope world = new EntityManagerT!(void delegate() @safe pure nothrow @nogc);

	assert(world.queue == nullentity);

	auto entity = world.entity.destroy();

	assert(world.queue == Entity(entity.id, entity.batch + 1));
	assert(world._entities[entity.id] == nullentity);
}

@("[EntityManager] entity manipulation (request batches on destruction and release)")
@safe pure nothrow unittest
{
	scope world = new EntityManagerT!(void delegate() @safe pure nothrow @nogc);
	immutable eid = 4;

	world.destroyEntity(world.entity(Entity(eid)), 78);
	Entity entity = world.entity();

	assert(entity.id == eid);
	assert(entity.batch == 78);

	world.releaseEntity(entity, 28);
	entity = world.entity();

	assert(entity.id == eid);
	assert(entity.batch == 28);
}

@("[EntityManager] entity manipulation (request ids and batches on construction)")
@safe pure nothrow unittest
{
	scope world = new EntityManagerT!(void delegate() @safe pure nothrow @nogc);
	auto entity = world.entity(Entity(5, 78));

	assert(entity.id == 5);
	assert(entity.batch == 78);
	assert(world.entity(Entity(entity.id, 94)) == entity);
}
