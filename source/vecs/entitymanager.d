module vecs.entitymanager;

import vecs.entity;
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
import std.typecons : Tuple, tuple;

version(vecs_unittest)
{
	import aurorafw.unit.assertion;
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

	Signal: emits `onSet` after each component is assigned.

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
		alias PointerOf(T) = T*;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components) C[i] = _assureStorage!Component.add(entity);

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
	}


	/**
	Assigns the `Component` to the `entity`. The `Component` is initialized with
	the `args` provided.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	struct Position { ulong x, y; }
	auto world = new EntityManager();

	Position* i = world.emplace!Position(world.entity, 2LU, 3LU);
	---

	Signal: emits `onSet` after each component is assigned.

	Params:
		Component = Component type to emplace.
		entity = a valid entity.
		args = arguments to contruct the Component type.

	Returns: A pointer to the emplaced component.
	*/
	Component* emplaceComponent(Component, Args...)(in Entity entity, auto ref Args args)
		in (validEntity(entity))
	{
		return _assureStorage!Component.emplace(entity, args);
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


	/**
	Assigns the components to an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Examples:
	---
	struct Position { ulong x, y; }
	auto world = new EntityManager();

	Position* i = world.set(world.entity, Position(2, 3));
	Tuple!(int*, string*) = world.set(world.entity, 45, "str")
	---

	Signal: emits `onSet` after each component is assigned.

	Params:
		entity = a valid entity.
		components = components to assign.

	Returns: A pointer or `Tuple` of pointers to the components set.
	*/
	auto setComponent(Components...)(in Entity entity, Components components)
		if (Components.length)
		in (validEntity(entity))
	{
		import std.meta : staticMap;
		alias PointerOf(T) = T*;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components) C[i] = _assureStorage!Component.set(entity, components[i]);

		static if (Components.length == 1)
			return C[0];
		else
			return tuple(C);
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

	Params:
		Components: Component types to patch.
		entity: a valid entity.
		callbacks: callbacks to call for each Component type.
	*/
	template patchComponent(Components...)
	{
		void patchComponent(Callbacks...)(in Entity entity, Callbacks callbacks)
			if (Components.length == Callbacks.length)
			in (validEntity(entity))
		{
			static foreach (i, Component; Components)
				_assureStorage!Component.patch(entity, callbacks[i]);
		}
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
		alias PointerOf(T) = T*;
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
		alias PointerOf(T) = T*;
		staticMap!(PointerOf, Components) C;

		static foreach (i, Component; Components) C[i] = _assureStorage!Component.tryGet(entity);

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

		return Query!(EntityManagerT, TemplateArgsOf!(typeof(queryW))[1 .. $])(queryW);
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

		return Query!(EntityManagerT, TemplateArgsOf!(typeof(queryW))[1 .. $],TemplateArgsOf!(typeof(queryF)))(queryW, queryF);
	}


	/// Ditto
	auto queryOne(Output)() { return query!Output.front; }


	/// Ditto
	auto queryOne(Output, Filter)() { return query!(Output, Filter).front; }


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


	/// Query helper
	QueryWorld!(EntityManagerT, Entity) _queryWorld(Output : Entity, Extra ...)()
	{
		return QueryWorld!(EntityManagerT, Entity)(_queryEntities!(Extra).idup);
	}


	/// Ditto
	QueryWorld!(EntityManagerT, Entity) _queryWorld(Output : Tuple!Entity, Extra ...)()
	{
		return _queryWorld!(Entity, Extra)();
	}


	/// Ditto
	QueryWorld!(EntityManagerT, Component) _queryWorld(Component, Extra ...)()
		if (isComponent!Component)
	{
		auto storage = _assureStorage!Component();
		auto entities = _queryEntities!(Component);
		return QueryWorld!(EntityManagerT, Component)(entities.idup, storage.components());
	}


	/// Ditto
	QueryWorld!(EntityManagerT, Component) _queryWorld(Output : Tuple!(Component), Component, Extra ...)()
		if (isComponent!Component && Output.length == 1)
	{
		return _queryWorld!(Component, Extra)();
	}


	/// Ditto
	QueryWorld!(EntityManagerT, OutputTuple) _queryWorld(OutputTuple, Extra ...)()
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
		enum queryworld = format!q{QueryWorld!(EntityManagerT, OutputTuple)(entities.idup,%s)}(components);

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

	assert(!__traits(compiles, entity.patch!int()));
	assert(!__traits(compiles, entity.patch!int((int) {})));
	assert(!__traits(compiles, entity.patch!int((char) {})));
	assert(!__traits(compiles, entity.patch!int((ref int i) => i++)));
	assert(!__traits(compiles, entity.patch!int((ref int) {}, (ref int) {})));

	entity.patch!int((ref int i) { i = 45; });

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
	assertThrown!AssertError(world.patchComponent!int(entity, (ref int i) {}));

	const invalid = Entity(entity.id, entity.batch + 1);

	assertThrown!AssertError(world.addComponent!int(invalid));
	assertThrown!AssertError(world.setComponent!int(invalid, 0));
	assertThrown!AssertError(world.emplaceComponent!int(invalid, 0));
	assertThrown!AssertError(world.patchComponent!int(invalid, (ref int i) {}));
	assertThrown!AssertError(world.getComponent!int(invalid));
	assertThrown!AssertError(world.getOrSet!int(invalid));
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
