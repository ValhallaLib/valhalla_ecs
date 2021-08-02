module vecs.entity;

private enum VECS_32 = typeof(int.sizeof).sizeof == 4;
private enum VECS_64 = typeof(int.sizeof).sizeof == 8;
static assert(VECS_32 || VECS_64, "Unsuported target!");

static if (VECS_32) version = VECS_32;
else version = VECS_64;

import vecs.entitybuilder : EntityBuilder;
import vecs.storage;
import vecs.query;
import vecs.queryfilter;
import vecs.queryworld;
import vecs.resource;

import std.exception : basicExceptionCtors, enforce;
import std.format : format;
import std.meta : AliasSeq, NoDuplicates;
import std.range : iota;
import std.traits : isInstanceOf, TemplateArgsOf;
import std.typecons : Nullable, Tuple, tuple;

version(vecs_unittest)
{
	import aurorafw.unit.assertion;
	import std.exception : assertThrown;
	import core.exception : AssertError;
}


/**
An entity is defined by an `id` and `batch`. It's signature is the combination
of both values. The **first N bits** define the `id` and the **last M bits**
the `batch`. The signature is an integral value of 32 bits or 64 bits depending
on the architecture. The type of this variable is `size_t` and its composition
is divided in two parts, id and batch.

Supposing an entity is an integral type of **8 bits**.
First half defines the batch.
Second half defines the id.

Composition:
| batch | id   |
| :---- | :--- |
| 0000  | 0000 |

Fields:
| name        | description                                               |
| :---------- | :-------------------------------------------------------- |
| `idshift`   | division point between the entity's **id** and **batch**. |
| `idmask`    | bit mask related to the entity's **id** portion.          |
| `batchmask` | bit mask related to the entity's **batch** portion.       |
| `maxid`     | the maximum number of ids allowed                         |
| `maxbatch`  | the maximum number of batches allowed                     |

Values:
| `void* size (bytes)` | `idshift (bits)` | `idmask`    | `batchmask`       |
| :------------------- | :--------------- | :---------- | :---------------- |
| 4                    | 20               | 0xFFFF_F    | 0xFFF << 20       |
| 8                    | 32               | 0xFFFF_FFFF | 0xFFFF_FFFF << 32 |

Sizes:
| `void* size (bytes)` | `id (bits)` | `batch (bits)` | `maxid`       | `maxbatch`    |
| :------------------- | :---------- | :------------- | :------------ | :------------ |
| 4                    | 20          | 12             | 1_048_574     | 4_095         |
| 8                    | 32          | 32             | 4_294_967_295 | 4_294_967_295 |

See_Also: [skypjack - entt](https://skypjack.github.io/2019-05-06-ecs-baf-part-3/)
*/
struct Entity
{
public:
	@safe pure nothrow @nogc
	this(in size_t id)
		in (id <= maxid)
	{
		_signature = id;
	}

	@safe pure nothrow @nogc
	this(in size_t id, in size_t batch)
		in (id <= maxid)
		in (batch <= maxbatch)
	{
		_signature = (id | (batch << idshift));
	}


	@safe pure nothrow @nogc
	bool opEquals(in Entity other) const
	{
		return other._signature == _signature;
	}


	@safe pure nothrow @nogc @property
	size_t id() const
	{
		return _signature & maxid;
	}


	@safe pure nothrow @nogc @property
	size_t batch() const
	{
		return _signature >> idshift;
	}

	@safe pure nothrow @nogc @property
	size_t signature() const
	{
		return _signature;
	}


	// if size_t is 32 or 64 bits
	version(VECS_32)
	{
		enum size_t idshift = 20UL;   /// 20 bits   or 32 bits
		enum size_t maxid = 0xFFFF_F; /// 1_048_575 or 4_294_967_295
		enum size_t maxbatch = 0xFFF; /// 4_095     or 4_294_967_295
	}
	else
	{
		enum size_t idshift = 32UL;      /// ditto
		enum size_t maxid = 0xFFFF_FFFF; /// ditto
		enum size_t maxbatch = maxid;    /// ditto
	}

	enum size_t idmask = maxid;                  /// first 20 bits or 32 bits
	enum size_t batchmask = maxbatch << idshift; /// last  12 bits or 32 bits

private:
	@safe pure nothrow @nogc
	auto incrementBatch()
	{
		_signature = (id | ((batch + 1) << idshift));
		return this;
	}

	size_t _signature;
}

@("[Entity]")
@safe pure nothrow @nogc unittest
{
	assert(Entity.init == Entity(0));
	assert(Entity.init == Entity(0, 0));

	{
		immutable e = Entity.init;
		assert(e.id == 0);
		assert(e.batch == 0);
		assert(e.signature == 0);
	}

	{
		immutable e = Entity.init.incrementBatch();
		assert(e.id == 0);
		assert(e.batch == 1);
		assert(e.signature == Entity.maxid + 1);
		assert(e == Entity(0, 1));
	}

	assert(Entity(0, Entity.maxbatch).incrementBatch().batch == 0);
}


/**
 * Responsible for managing all entities lifetime and access to components as
 *     well as any operation related to them.
 */
class EntityManager
{
public:
	@safe pure nothrow @nogc
	this()
	{
		queue = entityNull;
	}


	// FIXME: documentation
	void registerComponent(Components...)()
		if (Components.length)
	{
		static foreach (Component; Components) _assure!Component;
	}


	// FIXME: documentation
	auto addComponent(Components...)(in Entity e)
		if (Components.length)
		in (validEntity(e))
	{
		import std.meta : staticMap;
		alias PointerOf(T) = T*;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components) C[i] = _assureStorage!Component.add(e);

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
	}


	// FIXME: documentation
	Component* emplaceComponent(Component, Args...)(in Entity e, auto ref Args args)
		in (validEntity(e))
	{
		return _assureStorage!Component.emplace(e, args);
	}


	// FIXME: documentation
	@safe pure nothrow @nogc
	void releaseEntity(in Entity e)
	{
		releaseEntity(e, (e.batch + 1) & Entity.maxbatch);
	}


	// FIXME: documentation
	@safe pure nothrow @nogc
	void releaseEntity(in Entity e, in size_t batch)
		in (shallowEntity(e))
	{
		releaseId(e, batch);
	}


	// FIXME: documentation
	/**
	 * Destroys a valid entity. When destroyed all the associated components are
	 *     removed. Passig an invalid entity leads to undefined behaviour.
	 *
	 * Params:
	 *     e = entity to discard.
	 *
	 * Examples:
	 * ---
	 * auto em = new EntityManager();
	 *
	 * // discards the newly generated entity
	 * em.destroyEntity(em.gen());
	 * ---
	 */
	@system
	void destroyEntity(in Entity e)
	{
		destroyEntity(e, (e.batch + 1) & Entity.maxbatch);
	}


	// FIXME: documentation
	void destroyEntity(in Entity e, in size_t batch)
	{
		removeAllComponents(e);
		releaseId(e, batch);
	}


	// FIXME: documentation
	@safe pure nothrow @nogc
	size_t aliveEntities()
	{
		if (queue.isNull) return _entities.length;

		auto alive = _entities.length - 1;

		// search all destroyed entities
		for (auto e = _entities[queue.id]; e != entityNull; alive--)
			e = _entities[e.id];

		return alive;
	}


	// FIXME: documentation
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
	 * This signal occurs every time a Component is set. The onSet signal is
	 *     emitted **after** the Component is set. A Component is set when
	 *     assigning a new one to an entity or when updating an existing one.
	 *
	 * Params:
	 *     Component = a valid component type
	 *
	 * Examples:
	 * ---
	 * struct Foo {}
	 * auto em = new EntityManager();
	 * int i;
	 *
	 * // callback **MUST be a delegate** and return **void**
	 * auto fun = (Entity,Foo*) { i++; };
	 *
	 * // bind a callback
	 * em.onSet!Foo().connect(fun);
	 *
	 * // this emits onSet
	 * em.gen!Foo();
	 *
	 * assert(1 == i);
	 *
	 * // unbind a callback
	 * em.onSet!Foo().disconnect(fun);
	 *
	 * em.gen!Foo();
	 * assert(1 == i);
	 * ---
	 *
	 * Returns: `Signal!(Entity,Component*)`
	 */
	ref auto onSet(Component)()
	{
		return _assureStorage!Component.onSet;
	}


	/**
	 * This signal occurs every time a Component is disassociated from an
	 *     entity. The onRemove signal is emitted **before** the Component is
	 *     removed. A Component is removed when removing a one from an entity or
	 *     when discarding an entity.
	 *
	 * Examples:
	 * ---
	 * struct Foo {}
	 * auto em = new EntityManager();
	 * int i;
	 *
	 * // callback **MUST be a delegate** and return **void**
	 * auto fun = (Entity,Foo*) { i++; };
	 *
	 * // bind a callback
	 * em.onSet!Foo().connect(fun);
	 *
	 * // this emits onRemove
	 * em.destroyEntity(em.gen!Foo());
	 *
	 * assert(1 == i);
	 *
	 * // unbind a callback
	 * em.onSet!Foo().disconnect(fun);
	 *
	 * em.destroyEntity(em.gen!Foo());
	 * assert(1 == i);
	 * ---
	 *
	 * Params:
	 *     Component = a valid component type
	 *
	 * Returns: `Signal!(Entity,Component*)`
	 */
	ref auto onRemove(Component)()
	{
		return _assureStorage!Component.onRemove;
	}


	// FIXME: documentation
	/**
	 * Associates an entity to a component. Passing an invalid entity leads to
	 *     undefined behaviour. Emits onSet after associating the component to
	 *     the entity, either by creation or by replacement.
	 *
	 * Safety: The **internal code** is @safe, however, because of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onSet **after** setting the component.
	 *
	 * Params:
	 *     e = entity to associate.
	 *     component = component to set.
	 *     components = components to set.
	 *
	 * Examples:
	 * ---
	 * struct Foo { int i; }
	 * auto em = new EntityManager();
	 *
	 * // associates the newly generated entity with Foo.init
	 * em.set!Foo(em.gen());
	 *
	 * // associates the newly generated entity with Foo(3)
	 * em.set(em.gen(), Foo(3));
	 * ---
	 *
	 * Returns: `Component*` pointing to the component set either by creation or
	 *     replacement.
	 */
	auto setComponent(Components...)(in Entity e, Components components)
		if (Components.length)
		in (validEntity(e))
	{
		import std.meta : staticMap;
		alias PointerOf(T) = T*;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components) C[i] = _assureStorage!Component.set(e, components[i]);

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
	}


	/**
	 * Disassociates an entity from a component. Passing and invalid entity or
	 *     an entity which isn't associated with Component leads to undefined
	 *     behaviour.
	 *
	 * Safety: The **internal code** is @safe, however, because of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onRemove **before** disassociating the component.
	 *
	 * Examples:
	 * ---
	 * struct Foo {}
	 * auto em = new EntityManager();
	 *
	 * // disassociates Foo from the newly generated entity
	 * em.removeComponent!Foo(em.gen!Foo());
	 * ---
	 *
	 * Params:
	 *     e = entity to disassociate.
	 *     Component = component to remove.
	 */
	auto removeComponent(Components...)(in Entity e)
		if (Components.length)
		in (validEntity(e))
	{
		import std.meta : Repeat;
		Repeat!(Components.length, bool) R; // removed components

		static foreach (i, Component; Components) R[i] = _assureStorageInfo!Component.remove(e);

		static if (Components.length == 1)
			return R[0];
		else
			return [R];
	}


	/**
	 * Removes all components associated to an entity. Passing an invalid entity
	 *     leads to undefined behaviour. If a component is passed instead, it
	 *     clears the storage of the same disassociating every entity in it.
	 *
	 * Safety: The **internal code** is @safe, however, because of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onRemove **before** disassociating the component.
	 *
	 * Params:
	 *     e = entity to disassociate.
	 *     Component = component storage to clear.
	 *
	 * Examples:
	 * ---
	 * struct Foo {}
	 * auto em = new EntityManager();
	 *
	 * // safely removes every component associated with the newly generated entity
	 * em.removeAll(em.gen());
	 *
	 * // safely clears Foo's storage
	 * em.removeAll!Foo();
	 * ---
	 *
	 * Params:
	 *     e = entity to disassociate.
	 */
	@system
	void removeAllComponents(in Entity e)
		in (validEntity(e))
	{
		foreach (sinfo; storageInfoMap)
			if (sinfo.storage !is null)
				sinfo.remove(e);
	}


	// TODO: removeAllIfHas to safely try to remove from an entity


	// FIXME: documentation
	void clear(Components...)()
	{
		static if (Components.length)
			static foreach (Component; Components) _assureStorageInfo!Component().clear();

		else
			foreach (sinfo; storageInfoMap) if (sinfo.storage) sinfo.clear();
	}


	// FIXME: documentation
	/**
	 * Fetch a component associated to an entity. The entity must be associated
	 *     with the Component passed. Passing an invalid entity leads to
	 *     undefined behaviour.
	 *
	 * Params:
	 *     e = entity to get the associated Component.
	 *     Component = component type to retrieve.
	 *
	 * Examples:
	 * ---
	 * struct Foo { int i; }
	 * auto em = new EntityManager();
	 *
	 * // gets Foo from the newly generated entity
	 * em.getComponent!Foo(em.gen!Foo());
	 * ---
	 *
	 * Returns: `Component*` pointing to the component fetched.
	 */
	auto getComponent(Components...)(in Entity e)
		if (Components.length)
		in (validEntity(e))
	{
		import std.meta : staticMap;
		alias PointerOf(T) = T*;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components) C[i] = _assureStorage!Component.get(e);

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
	}


	// FIXME: documentation
	auto tryGetComponent(Components...)(in Entity e)
		if (Components.length)
		in (validEntity(e))
	{
		import std.meta : staticMap;
		alias PointerOf(T) = T*;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components) C[i] = _assureStorage!Component.tryGet(e);

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
	}


	/**
	 * Fetch the component associated to an entity. If the entity is already
	 *     associated with a component of that type then the same is immediatly
	 *     returned, otherwise the component is set and returned. Passing an
	 *     invalid entity leads to undefined behaviour.
	 *
	 * Safety: The **internal code** is @safe, however, because of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onSet **after** the component is set **if** set.
	 *
	 * Params:
	 *     e = entity to fetch the associated component.
	 *     component = component to set if there is none associated.
	 *
	 * Examples:
	 * ---
	 * struct Foo { int i; }
	 * auto em = new EntityManager();
	 * auto e = em.gen();
	 *
	 * // asociates Foo.init with e returning a pointer to it
	 * assert(Foo.init == *em.getOrSet!Foo(e));
	 *
	 * // returns a pointer to the already associated Foo
	 * assert(Foo.init == *em.getOrSet(e, Foo(5)));
	 * ---
	 *
	 * Returns: `Component*` pointing to the component associated.
	 */
	Component* getOrSet(Component)(in Entity e, Component component = Component.init)
		in (validEntity(e))
	{
		return _assureStorage!Component().getOrSet(e, component);
	}


	// TODO: getOrSetIfHas to safely try to get or set a component


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
	 * Returns a new builder used for chaining entity calls.
	 *
	 * Examples:
	 * ---
	 * struct Foo {}
	 * auto em = new EntityManager();
	 *
	 * // gets an EntityBuilder with a new entity and binds Foo to it
	 * em.entity.set!Foo;
	 * ---
	 *
	 * Returns: `EntityBuilder`.
	 */
	@safe pure nothrow @property
	EntityBuilder entity()
	{
		EntityBuilder builder = {
			entity: createEntity(),
			em: this
		};

		return builder;
	}


	// FIXME: documentation
	@safe pure nothrow @property
	EntityBuilder entity(in Entity e)
	{
		// entity: generates entities until one with e.id and returns the latter
		EntityBuilder builder = {
			entity: createEntity(e),
			em: this
		};

		return builder;
	}


	/**
	 * Checks if an entity is valid within EntityManager.
	 *
	 * Params:
	 *     e = entity to check.
	 *
	 * Returns: `true` if the entity exists, `false` otherwise.
	 */
	@safe pure nothrow @nogc
	bool validEntity(in Entity e) const
		in (e.id < Entity.maxid)
	{
		return e.id < _entities.length && _entities[e.id] == e;
	}


	/**
	 * Searches entities with the components passed. The first argument is the
	 *     output signature and is used to fetch all components from entities
	 *     which are associated with all of them, basically it does an
	 *     intersection of all entities containing the set of components passed.
	 *     The second argument filters the those components fetched to further
	 *     customize the search. All components are returned as pointers,
	 *     meaning they can be instantly updated with new data. To iterate
	 *     through entities, the Entity type **must** be specified as the first
	 *     type in the first argument. The Query's output returns a Tuple if it
	 *     contains more than one type, otherwise it returns the type as is. \
	 * Using the `queryOne` variant, instead of range, the first result is
	 *         returned.
	 *
	 * Params:
	 *     Output = Tuple of the signature being searched. It searches every
	 *         entity with all the components passed in common. If the first
	 *         argument is Entity then it also includes the entity of such
	 *         components as the first argument in the output tuple.
	 *     Filter = Tuple of filters to further customize the query search.
	 *         Currently the filters available are: `With`, `Without`
	 *
	 * Filters:
	 * * With - acts the same as the types in the Output argument but it doesn't
	 *       return them to the Output.
	 * * Without - the inverse of With and types in Output, leaves out entities
	 *       with a certaint type.
	 *
	 * Examples:
	 * --------------------
	 * auto em = new EntityManager();
	 *
	 * // Query: all entities alive/existent
	 * // Outputs: `Entity`
	 * foreach (e; em.query!Entity) { ... }
	 * foreach (e; em.query!(Tuple!Entity)) { ... }
	 *
	 * // Tuple is discarded when of length 1
	 * assert(is(typeof(em.query!Entity.front) == typeof(em.query!(Tuple!Entity).front)));
	 *
	 * // Query: entities with `int` and `string`
	 * // Outputs: `ìnt*`, `string*`
	 * foreach (i, str; em.query!(Tuple!(int,string))) { ... }
	 *
	 * // Query: entities with `int`, `string`
	 * // Outputs: `Entity`, `int*`, `string*`
	 * foreach (e, i, str; em.query!(Tuple!(Entity,int,string))) { ... }
	 *
	 * // Query: entities with `int`, `string`
	 * // Outputs: `int*`
	 * foreach (i; em.query!(int, With!string)) { ... }
	 *
	 * // Query: entities with `int` and without `string`
	 * // Outputs: `int*`
	 * foreach (i; em.query!(int, Without!string)) { ... }
	 *
	 * // Query: entities with `int`, `string`, `float`, `ubyte`, and without `double`
	 * // Outputs: `Entity`, `int*`, `string`
	 * foreach (i;
	 * em.query!(Tuple!(Entity,int,string),Tuple!(With!(Tuple(float,ubyte)),Without!string))) { ... }
	 *
	 * // gets the first result of the range
	 * assert(is(Tuple!(Entity, int*) == typeof(queryOne!(Tuple!(Entity,int)))));
	 * --------------------
	 *
	 * Returns: `Query` range which iterates through components of entities with
	 *     the same set of components in common passed in both Query's parameters.
	 */
	auto query(Output)()
	{
		auto queryW = _queryWorld!Output();

		return Query!(TemplateArgsOf!(typeof(queryW)))(queryW);
	}


	/// Ditto
	auto query(Output, Filter)()
	{
		import std.meta : metaFilter = Filter, staticMap;
		enum isWith(T) = isInstanceOf!(With, T);

		static if (isInstanceOf!(Tuple, Filter))
			alias Extra = staticMap!(TemplateArgsOf, metaFilter!(isWith, TemplateArgsOf!(Filter)));
		else
			alias Extra = staticMap!(TemplateArgsOf, metaFilter!(isWith, Filter));


		auto queryW = _queryWorld!(Output, Extra)();
		auto queryF = _queryFilter!Filter();

		return Query!(TemplateArgsOf!(typeof(queryW)),TemplateArgsOf!(typeof(queryF)))(queryW, queryF);
	}


	/// Ditto
	auto queryOne(Output)() { return query!Output.front; }


	/// Ditto
	auto queryOne(Output, Filter)() { return query!(Output, Filter).front; }


	// FIXME: documentation
	/**
	 * Gets every entity currently alive/existent within EntityManager.
	 *
	 * Returns: `Entity[]` of alive/existent entities.
	 */
	void eachEntity(F)(F fun) const
	{
		if (queue.isNull)
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

private:
	/**
	 * Creates a new entity with a new id. The entity's id follows the number
	 *     of entities created.
	 *
	 * Returns: `Entity` newly created or asserts is maximum is reached.
	 */
	@safe pure nothrow
	Entity createEntity()
	{
		if (queue.isNull)
		{
			import std.range : back;
			_entities ~= generateId(_entities.length);
			return _entities.back;
		}

		else return recycleId();
	}


	// FIXME: documentation
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
			if (queue.id == hint.id)
			{
				// ensures the queue is not broken
				queue = _entities[hint.id];
				_entities[hint.id] = hint;

				return hint;
			}

			Entity* eptr = &_entities[queue.id];

			while (eptr.id != hint.id)
				eptr = &_entities[eptr.id];

			// ensures the queue is not broken
			*eptr = _entities[hint.id];
			_entities[hint.id] = hint;

			return hint;
		}
	}


	// FIXME: documentation
	@safe pure nothrow @nogc
	Entity generateId(in size_t pos)
	{
		static immutable err = "Maximum entities (" ~ Entity.maxid.stringof ~ ") reached!";
		if (pos >= Entity.maxid) assert(false, err);

		return Entity(pos);
	}


	/**
	 * Creates a new entity reusing the id of a **previously discarded entity**
	 *     with a new batch. Swaps the current discarded entity stored the
	 *     queue's entity place with it.
	 *
	 * Returns: `Entity` newly created.
	 */
	@safe pure nothrow @nogc
	Entity recycleId()
		in (!queue.isNull)
	{
		immutable next = queue;     // get the next entity in queue
		queue = _entities[next.id]; // grab the entity which will be the next in queue
		_entities[next.id] = next;  // revive the entity
		return next;
	}


	// FIXME: documentation
	@safe pure nothrow @nogc
	void releaseId(in Entity e, in size_t batch)
		in (batch <= Entity.maxbatch)
	{
		_entities[e.id] = queue.isNull ? entityNull : queue.get();
		queue = Entity(e.id, batch);
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
			storageInfoMap[index] = StorageInfo().__ctor!(Component)();
		}

		return index;
	}


	/// Assures the Component's storage availability and returns the Storage
	Storage!Component _assureStorage(Component)()
		if (isComponent!Component)
	{
		immutable index = _assure!Component(); // to fix dmd boundscheck=off
		return storageInfoMap[index].get!Component();
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


	/// Query helper
	QueryWorld!(Entity) _queryWorld(Output : Entity, Extra ...)()
	{
		return QueryWorld!Entity(_queryEntities!(Extra).idup);
	}


	/// Ditto
	QueryWorld!(Entity) _queryWorld(Output : Tuple!Entity, Extra ...)()
	{
		return _queryWorld!(Entity, Extra)();
	}


	/// Ditto
	QueryWorld!(Component) _queryWorld(Component, Extra ...)()
		if (isComponent!Component)
	{
		auto storage = _assureStorage!Component();
		auto entities = _queryEntities!(Component);
		return QueryWorld!Component(entities.idup, storage.components());
	}


	/// Ditto
	QueryWorld!(Component) _queryWorld(Output : Tuple!(Component), Component, Extra ...)()
		if (isComponent!Component && Output.length == 1)
	{
		return _queryWorld!(Component, Extra)();
	}


	/// Ditto
	QueryWorld!(OutputTuple) _queryWorld(OutputTuple, Extra ...)()
		if (isInstanceOf!(Tuple, OutputTuple))
	{
		alias Out = NoDuplicates!(TemplateArgsOf!OutputTuple);
		static if (is(Out[0] == Entity))
			alias Components = Out[1..$];
		else
			alias Components = Out;

		// gets all StoragesInfo
		enum components = format!q{[%(_assureStorageInfo!(Components[%s])%|,%)]}(Components.length.iota);

		// get entities and build the Query
		auto entities = _queryEntities!(Components, Extra);
		enum queryworld = format!q{QueryWorld!(OutputTuple)(entities.idup,%s)}(components);

		return mixin(queryworld);
	}


	/// Ditto
	QueryFilter!(Filter) _queryFilter(Filter)()
		if (!isInstanceOf!(Tuple, Filter))
	{
		alias F = TemplateArgsOf!Filter;
		enum queryFilter = format!q{QueryFilter!Filter(Filter([%(_assureStorageInfo!(F[%s])%|,%)]))}(F.length.iota);

		return mixin(queryFilter);
	}


	/// Ditto
	QueryFilter!(FilterTuple) _queryFilter(FilterTuple)()
		if (isInstanceOf!(Tuple, FilterTuple))
	{
		alias Filters = TemplateArgsOf!FilterTuple;

		string filterfy()
		{
			import std.array : appender;
			import std.meta : staticMap;
			auto str = appender!string;

			// iterate every unique component from all filters
			// alias Filters = AliasSeq!(With!(Foo,Bar,Foo))
			// NoDuplicates!(staticMap!(TemplateArgsOf,Filters)) == AliasSeq!(Foo,Bar)
			foreach (F; Filters)
			{
				alias Components = NoDuplicates!(TemplateArgsOf!F);
				str ~= F.stringof~"([";
				foreach (C; Components)
				{
					str ~= "_assureStorageInfo!("~C.stringof~"),";
				}
				str ~= "]),";
			}

			return str.data;
		}

		enum filters = "QueryFilter!(FilterTuple)(tuple(" ~ filterfy() ~ "))";

		return mixin(filters);
	}


	/**
	 * Finds the Storage with the lowest size of all ComponentRange storages and
	 *     returns all entities in it. If ComponentRange.length is 0 then all
	 *     valid entities are returned.
	 *
	 * Params:
	 *     ComponentRange = components to search.
	 *
	 * Returns: `Entity[]` of the lowest Storage's size if ComponentRange.len > 0,
	 *     otherwise all valid entities.
	 */
	Entity[] _queryEntities(ComponentRange ...)()
	{
		static if (ComponentRange.length == 0)
		{
			Entity[] ret;
			ret.reserve(aliveEntities());
			eachEntity((const Entity entity) { ret ~= entity; });
			return ret;
		}
		else
		{
			import std.algorithm : minElement;
			alias Comp = NoDuplicates!(ComponentRange);
			enum comp = format!q{[%(_assureStorageInfo!(Comp[%s])%|,%)]}(Comp.length.iota);
			enum entts = format!q{%s.minElement!"a.size()".entities();}(comp);
			mixin("return " ~ entts);
		}
	}


	Entity[] _entities;
	Nullable!(Entity, entityNull) queue;
	StorageInfo[] storageInfoMap;
	Resource[] resources;

public:
	enum Entity entityNull = Entity(Entity.maxid);
}

@("[EntityManager] component operations (adding and updating)")
unittest
{
	scope world = new EntityManager();

	assert(*world.addComponent!int(world.entity) == 0);
	assert(*world.emplaceComponent!int(world.entity, 34) == 34);
	assert(*world.setComponent(world.entity, 45) == 45);

	struct Position { ulong x, y; }
	auto entity = world.entity
		.add!int
		.set("Hello")
		.emplace!Position(1LU, 4LU);

	int* integral;
	string* str;

	AliasSeq!(integral, str) = world.getComponent!(int, string)(entity);

	assert(*integral == 0);
	assert(*str == "Hello");

	entity.emplace!int(45);

	assert(*integral == 45);

	Position* position;
	uint* uintegral;

	AliasSeq!(position, uintegral) = world.tryGetComponent!(Position, uint)(entity);

	assert(*position == Position(1, 4));
	assert(!uintegral);

	assert(*world.getOrSet!uint(entity, 45) == 45);
	assert(*world.getOrSet!uint(entity, 64) == 45);
}

version(assert)
@("[EntityManager] component operations (invalid entities)")
unittest
{
	scope world = new EntityManager();
	const entity = world.entity;

	assertThrown!AssertError(world.getComponent!int(entity));

	const invalid = Entity(entity.id, entity.batch + 1);

	assertThrown!AssertError(world.addComponent!int(invalid));
	assertThrown!AssertError(world.setComponent!int(invalid, 0));
	assertThrown!AssertError(world.emplaceComponent!int(invalid, 0));
	assertThrown!AssertError(world.getComponent!int(invalid));
	assertThrown!AssertError(world.getOrSet!int(invalid));
	assertThrown!AssertError(world.removeComponent!int(invalid));
	assertThrown!AssertError(world.removeAllComponents(invalid));
}

@("[EntityManager] component operations (register and remove)")
unittest
{
	scope world = new EntityManager();

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
unittest
{
	scope world = new EntityManager();

	auto entity = world.entity();

	assert(world.aliveEntities() == 1);
	assert(world.shallowEntity(entity));
	assert(world.validEntity(entity));

	world.releaseEntity(entity);

	assert(!world.aliveEntities());
	assert(!world.validEntity(entity));
}

@("[EntityManager] entity manipulation (generated and recycled)")
unittest
{
	scope world = new EntityManager();

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
	assertThrown!AssertError(world.entity(world.entityNull));
	assertThrown!AssertError(world.validEntity(world.entityNull));
	assertThrown!AssertError(world.generateId(world.entityNull.id));
}

@("[EntityManager] entity manipulation (queue properties)")
unittest
{
	scope world = new EntityManager();

	assert(world.queue.isNull);

	auto entity = world.entity.destroy();

	assert(world.queue == Entity(entity.id, entity.batch + 1));
	assert(world._entities[entity.id] == world.entityNull);
}

@("[EntityManager] entity manipulation (request batches on destruction and release)")
unittest
{
	scope world = new EntityManager();
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
unittest
{
	scope world = new EntityManager();
	auto entity = world.entity(Entity(5, 78));

	assert(entity.id == 5);
	assert(entity.batch == 78);
	assert(world.entity(Entity(entity.id, 94)) == entity);
}
