module vecs.entity;

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


class MaximumEntitiesReachedException : Exception { mixin basicExceptionCtors; }


/**
 * An entity is defined by an **id** and a  **batch**. It's signature is the
 *     combination of both values. The first N bits belong to the **id** and the
 *     last M ending bits to the `batch`. \
 * \
 * An entity in it's raw form is simply an integral value formed by the junction
 *     of the id with the batch.
 * \
 * An entity is then defined by: **id | (batch << idshift)**. \
 * \
 * Let's imagine an entity of 8 bites. By default it's **id** and **batch**
 *     occupy **4 bits** each. \
 * \
 * `Entity` = **0000 0000** = ***(batch << 4) | id***.
 *
 * Constants:
 *     `idshift` = division point between the entity's **id** and **batch**. \
 *     `idmask` = bit mask related to the entity's **id** portion. \
 *     `batchmask` = bit mask related to the entity's **batch** portion. \
 *     `maxid` = the maximum number of ids allowed
 *     `maxbatch` = the maximum number of batches allowed
 *
 * Values:
 * | `void* size (bits)` | `idshift` | `idmask`    | `batchmask`       |
 * | :-----------------  | :----  -- | :---------- | :---------------- |
 * | 4                   | 20        | 0xFFFF_F    | 0xFFF << 20       |
 * | 8                   | 32        | 0xFFFF_FFFF | 0xFFFF_FFFF << 32 |
 *
 * Sizes:
 * | `void* size (bits)` | `id (bits)` | `batch (bits)` | `maxid`       | `maxbatch`    |
 * | :----------------   | :--------   | :-----------   | :------------ | :------------ |
 * | 4                   | 20          | 12             | 1_048_574     | 4_095         |
 * | 8                   | 32          | 32             | 4_294_967_295 | 4_294_967_295 |
 *
 * See_Also: [skypjack - entt](https://skypjack.github.io/2019-05-06-ecs-baf-part-3/)
 */
struct Entity
{
public:
	@safe pure nothrow @nogc
	this(in size_t id)
		in (id <= maxid)
	{
		_id = id;
	}

	@safe pure nothrow @nogc
	this(in size_t id, in size_t batch)
		in (id <= maxid)
		in (batch <= maxbatch)
	{
		_id = id;
		_batch = batch;
	}


	@safe pure nothrow @nogc
	bool opEquals(in Entity other) const
	{
		return other.signature == signature;
	}


	@safe pure nothrow @nogc @property
	size_t id() const
	{
		return _id;
	}


	@safe pure nothrow @nogc @property
	size_t batch() const
	{
		return _batch;
	}


	@safe pure nothrow @nogc
	size_t signature() const
	{
		return (_id | (_batch << idshift));
	}


	static if (typeof(int.sizeof).sizeof == 4)
	{
		enum size_t idshift = 20UL;   // 20 bits for ids
		enum size_t maxid = 0xFFFF_F; // 1_048_575 unique ids
		enum size_t maxbatch = 0xFFF; // 4_095 unique batches
	}
	else static if (typeof(int.sizeof).sizeof == 8)
	{
		enum size_t idshift = 32UL;      // 32 bits for ids
		enum size_t maxid = 0xFFFF_FFFF; // 4_294_967_295 unique ids
		enum size_t maxbatch = maxid;    // 4_294_967_295 unique batches
	}
	else
		static assert(false, "unsuported target");

	enum size_t idmask = maxid; // first 20 bits (sizeof==4), 32 bits (sizeof==8)
	enum size_t batchmask = maxbatch << idshift; // last 12 bits (sizeof==4), 32 bits (sizeof==8)

private:
	@safe pure nothrow @nogc
	auto incrementBatch()
	{
		_batch = _batch >= maxbatch ? 0 : _batch + 1;

		return this;
	}

	size_t _id;
	size_t _batch;
}

@safe pure
@("entity: Entity")
unittest
{
	auto entity0 = Entity(0);

	assertEquals(0, entity0.id);
	assertEquals(0, entity0.batch);
	assertEquals(0, entity0.signature);
	assertEquals(Entity(0, 0), entity0);

	entity0.incrementBatch();
	assertEquals(0, entity0.id);
	assertEquals(1, entity0.batch);

	static if (typeof(int.sizeof).sizeof == 4)
		assertEquals(1_048_576, entity0.signature);
	else
		assertEquals(4_294_967_296, entity0.signature);

	assertEquals(Entity(0, 1), entity0);

	entity0 = Entity(0, Entity.maxbatch);
	entity0.incrementBatch();
	assertEquals(0, entity0.batch); // batch reseted

	static if (typeof(int.sizeof).sizeof == 4)
		assertEquals(0xFFF, Entity.maxbatch);
	else
		assertEquals(0xFFFF_FFFF, Entity.maxbatch);
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


	/**
	 * Generates a new entity either by fabricating a new one or recycling a
	 *     previously fabricated if available in the queue. Throws
	 *     **MaximumEntitiesReachedException** if the amount of entities alive
	 *     reaches it's maximum value. \
	 * \
	 * If used with components, the entity is generated with the assigned
	 *     components. When passing the type of the component with no initializer,
	 *     then the default initializer is used.
	 *
	 * Params:
	 *     component = component to set.
	 *     components = components to set.
	 *
	 * Safety: When passing components the method is @system. It uses `set`
	 *     internally. The **internal code** is @safe, however, because of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits **onSet** when used with components.
	 *
	 * Examples:
	 * ---
	 * auto em = new EntityManager();
	 *
	 * // generates a new entity
	 * em.gen();
	 * ---
	 * ---
	 * struct Foo { int x; }
	 * struct Bar { string x; }
	 * auto em = new EntityManager();
	 *
	 * // generates a new entity and assigns Foo.init
	 * em.gen!Foo();
	 *
	 * // generates a new entity and assigns Foo(3) and Bar("str")
	 * em.gen(Foo(3), Bar("str"));
	 * ---
	 *
	 * Returns: the newly generated Entity.
	 *
	 * Throws: `MaximumEntitiesReachedException`.
	 */
	@safe pure
	Entity gen()
	{
		return queue.isNull ? fabricate() : recycle();
	}


	/// Ditto
	Entity gen(Component)(Component component = Component.init)
		if (isComponent!Component)
	{
		immutable e = gen();
		_set(e, component);
		return e;
	}


	/// Ditto
	Entity gen(ComponentRange ...)(ComponentRange components)
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
	{
		immutable e = gen();
		foreach (component; components) _set(e, component);
		return e;
	}


	/// Ditto
	Entity gen(ComponentRange ...)()
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
	{
		immutable e = gen();
		foreach (Component; ComponentRange) _set!Component(e);
		return e;
	}


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
	 * em.discard(em.gen());
	 * ---
	 */
	@system
	void discard(in Entity e)
		in (has(e))
	{
		removeAll(e);                                              // remove all components
		_entities[e.id] = queue.isNull ? entityNull : queue.get(); // move the next in queue to back
		queue = e;                                                 // update the next in queue
		queue.incrementBatch();                                    // increment batch for when it's revived
	}


	/**
	 * Safely tries to discard an entity. If invalid does nothing.
	 *
	 * Params:
	 *     e = entity to discard.
	 *
	 * Examples:
	 * ---
	 * auto em = new EntityManager();
	 *
	 * // might lead to undefined behavior
	 * em.discard(em.entityNull);
	 *
	 * // safely tries to discard an entity
	 * em.discardIfHas(em.entityNull);
	 * ---
	 */
	void discardIfHas(in Entity e)
	{
		if (has(e)) discard(e);
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
	 * em.discard(em.gen!Foo());
	 *
	 * assert(1 == i);
	 *
	 * // unbind a callback
	 * em.onSet!Foo().disconnect(fun);
	 *
	 * em.discard(em.gen!Foo());
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
	Component* set(Component)(in Entity e, Component component = Component.init)
		in (has(e))
	{
		return _set(e, component);
	}


	/// Ditto
	auto set(ComponentRange ...)(in Entity e, ComponentRange components)
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
		in (has(e))
	{
		mixin(format!q{Tuple!(%(ComponentRange[%s]*%|, %)) ret;}(ComponentRange.length.iota));

		foreach (i, component; components) ret[i] = _set(e, component);

		return ret;
	}


	/// Ditto
	auto set(ComponentRange ...)(in Entity e)
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
		in (has(e))
	{
		mixin(format!q{Tuple!(%(ComponentRange[%s]*%|, %)) ret;}(ComponentRange.length.iota));

		foreach (i, Component; ComponentRange) ret[i] = _set!Component(e);

		return ret;
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
	 * em.remove!Foo(em.gen!Foo());
	 * ---
	 *
	 * Params:
	 *     e = entity to disassociate.
	 *     Component = component to remove.
	 */
	void remove(Component)(in Entity e)
		in (has(e))
	{
		_remove!Component(e);
	}


	/**
	 * Safely tries to disassociate an entity from a component. If invalid does
	 *     nothing.
	 *
	 * Safety: The **internal code** is @safe, however, because of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onRemove **before** disassociating the component.
	 *
	 * Examples:
	 * ---
	 * auto em = new EntityManager();
	 *
	 * // might lead to undefined behavior
	 * em.remove!Foo(em.entityNull);
	 * em.remove!Foo(em.gen());
	 *
	 * // safely tries to remove Foo from an entity
	 * em.removeIfHas!Foo(em.entityNull);
	 * em.removeIfHas!Foo(em.gen());
	 * ---
	 *
	 * Params:
	 *     e = entity to disassociate.
	 *     Component = component to remove.
	 */
	void removeIfHas(Component)(in Entity e)
	{
		if (has(e)) _assureStorage!Component().removeIfHas(e);
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
	void removeAll(in Entity e)
		in (has(e))
	{
		foreach (sinfo; storageInfoMap)
			if (sinfo.storage !is null)
				sinfo.removeIfHas(e);
	}


	// TODO: removeAllIfHas to safely try to remove from an entity


	/// Ditto
	void removeAll(Component)()
	{
		// FIXME: emit onRemove
		_assureStorage!Component().removeAll();
	}


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
	 * em.get!Foo(em.gen!Foo());
	 * ---
	 *
	 * Returns: `Component*` pointing to the component fetched.
	 */
	Component* get(Component)(in Entity e)
		in (has(e))
	{
		return _assureStorage!Component().get(e);
	}


	// TODO: getIfHas to safely try to get a component from an entity


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
		in (has(e))
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
	 * Returns a new builder used for chaining entity generation sequences and
	 *     binds it to EntityManager.
	 *
	 * Examples:
	 * ---
	 * struct Foo {}
	 * auto em = new EntityManager();
	 *
	 * // gets an EntityBuilder and generates 2 entities
	 * em.entityBuilder()
	 *     .gen()
	 *     .gen!Foo();
	 * ---
	 *
	 * Returns: `EntityBuilder`.
	 */
	@safe pure nothrow @nogc
	EntityBuilder entityBuilder()
	{
		return EntityBuilder(this);
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
	bool has(in Entity e) const
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


	/**
	 * Gets every entity currently alive/existent within EntityManager.
	 *
	 * Returns: `Entity[]` of alive/existent entities.
	 */
	@safe pure nothrow @property
	Entity[] entities() const
	{
		import std.array : appender;
		auto ret = appender!(Entity[]);

		foreach (i, e; _entities)
			if (e.id == i)
				ret ~= e;

		return ret.data;
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
	 * Creates a new entity with a new id. The entity's id follows the total
	 *     value of entities created. Throws **MaximumEntitiesReachedException**
	 *     if the maximum amount of entities is reached.
	 *
	 * Throws: `MaximumEntitiesReachedException`.
	 *
	 * Returns: `Entity` newly created.
	 */
	@safe pure
	Entity fabricate()
	{
		enforce!MaximumEntitiesReachedException(
			_entities.length < Entity.maxid,
			format!"Reached the maximum amount of _entities supported: %s!"(Entity.maxid)
		);

		import std.range : back;
		_entities ~= Entity(_entities.length);
		return _entities.back;
	}


	/**
	 * Creates a new entity reusing the id of a **previously discarded entity**
	 *     with a new batch. Swaps the current discarded entity stored the
	 *     queue's entity place with it.
	 *
	 * Returns: `Entity` newly created.
	 */
	@safe pure nothrow @nogc
	Entity recycle()
		in (!queue.isNull)
	{
		immutable next = queue;     // get the next entity in queue
		queue = _entities[next.id]; // grab the entity which will be the next in queue
		_entities[next.id] = next;  // revive the entity
		return next;
	}


	/// Common logic for set dependencies
	Component* _set(Component)(in Entity entity, Component component = Component.init)
		if (isComponent!Component)
	{
		// set the component to entity
		return _assureStorage!Component().set(entity, component);
	}


	/// Common logic for remove dependencies
	void _remove(Component)(in Entity entity)
		if (isComponent!Component)
	{
		_assureStorage!Component().remove(entity);
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
			return entities();
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


@system
@("entity: EntityManager: discard")
unittest
{
	auto em = new EntityManager();
	assertTrue(em.queue.isNull);

	auto entity0 = em.gen();
	auto entity1 = em.gen();
	auto entity2 = em.gen();


	em.discard(entity1);
	assertFalse(em.queue.isNull);
	assertEquals(em.entityNull, em._entities[entity1.id]);
	(() @trusted pure => assertEquals(Entity(1, 1), em.queue.get))(); // batch was incremented

	em.discard(entity0);
	assertEquals(Entity(1, 1), em._entities[entity0.id]);
	(() @trusted pure => assertEquals(Entity(0, 1), em.queue.get))(); // batch was incremented

	// cannot discard invalid entities
	assertThrown!AssertError(em.discard(Entity(50)));
	assertThrown!AssertError(em.discard(Entity(entity2.id, 40)));

	assertEquals(3, em._entities.length);
}

@system
@("entity: EntityManager: fabricate")
unittest
{
	import std.range : back;
	auto em = new EntityManager();

	auto entity0 = em.gen(); // calls fabricate
	em.discard(entity0); // discards
	em.gen(); // recycles
	assertTrue(em.queue.isNull);

	assertEquals(Entity(1), em.gen()); // calls fabricate again
	assertEquals(2, em._entities.length);
	assertEquals(Entity(1), em._entities.back);

	// FIXME: add MaximumEntitiesReachedException
}

@safe pure
@("entity: EntityManager: gen")
unittest
{
	import std.range : front;
	auto em = new EntityManager();

	assertEquals(Entity(0), em.gen());
	assertEquals(1, em._entities.length);
	assertEquals(Entity(0), em._entities.front);
}

@system
@("entity: EntityManager: gen with components")
unittest
{
	import std.range : front;
	auto em = new EntityManager();

	auto e = em.gen(Foo(3, 5), Bar("str"));
	assertEquals(Foo(3, 5), *em.storageInfoMap[ComponentId!Foo].get!(Foo).get(e));
	assertEquals(Bar("str"), *em.storageInfoMap[ComponentId!Bar].get!(Bar).get(e));

	e = em.gen!(int, string, size_t);
	assertEquals(int.init, *em.storageInfoMap[ComponentId!int].get!int.get(e));
	assertEquals(string.init, *em.storageInfoMap[ComponentId!string].get!string.get(e));
	assertEquals(size_t.init, *em.storageInfoMap[ComponentId!size_t].get!size_t.get(e));

	e = em.gen(3, "entity", [2, 2]);
	assertEquals(3, *em.storageInfoMap[ComponentId!int].get!int.get(e));
	assertEquals("entity", *em.storageInfoMap[ComponentId!string].get!string.get(e));
	assert([2, 2] == *em.storageInfoMap[ComponentId!(int[])].get!(int[]).get(e));

	assertFalse(__traits(compiles, em.gen!(size_t, size_t)()));
	assertFalse(__traits(compiles, em.gen(Foo(3,3), Bar(5,3), Foo.init)));
	assertFalse(__traits(compiles, em.gen!(Foo, Bar, void delegate())()));
	assertFalse(__traits(compiles, em.gen!(immutable(int))()));
}

@system
@("entity: EntityManager: get")
unittest
{
	auto em = new EntityManager();

	auto e = em.gen!(Foo, Bar);

	assertEquals(Foo.init, *em.get!Foo(e));
	assertEquals(Bar.init, *em.get!Bar(e));
	assertThrown!AssertError(em.get!int(e));

	em.get!Foo(e).y = 10;
	assertEquals(Foo(int.init, 10), *em.get!Foo(e));

	assertFalse(__traits(compiles, em.get!(immutable(int))(em.gen())));
}

@system
@("entity: EntityManager: getOrSet")
unittest
{
	auto em = new EntityManager();

	auto e = em.gen!(Foo)();
	assertEquals(Foo.init, *em.getOrSet!Foo(e));
	assertEquals(Foo.init, *em.getOrSet(e, Foo(2, 3)));
	assertEquals(Bar("str"), *em.getOrSet(e, Bar("str")));

	assertThrown!AssertError(em.getOrSet!Foo(Entity(0, 12)));
	assertThrown!AssertError(em.getOrSet!Foo(Entity(3)));
}

@system
@("entity: EntityManager: onRemove")
unittest
{
	auto em = new EntityManager();
	em.onRemove!Foo.connect((Entity,Foo* foo) { assertEquals(Foo(7, 8), *foo); });
	em.remove!Foo(em.gen(Foo(7, 8)));
}

@system
@("entity: EntityManager: onSet")
unittest
{
	auto em = new EntityManager();
	em.onSet!Foo.connect((Entity,Foo* foo) { *foo = Foo(12, 3); });

	em.gen!Foo;
	assertEquals(Foo(12,3), *em.get!Foo(Entity(0)));
}

@system
@("entity: EntityManager: recycle")
unittest
{
	import std.range : front;
	auto em = new EntityManager();

	auto entity0 = em.gen(); // calls fabricate
	em.discard(entity0); // discards
	(() @trusted pure => assertEquals(Entity(0, 1), em.queue.get))(); // batch was incremented
	assertFalse(Entity(0, 1) == entity0); // entity's batch is not updated

	entity0 = em.gen(); // recycles
	assertEquals(Entity(0, 1), em._entities.front);
}

@system
@("entity: EntityManager: remove")
unittest
{
	auto em = new EntityManager();

	auto e = em.gen!(Foo, Bar, int);
	assertThrown!AssertError(em.remove!size_t(e)); // not in the storageInfoMap

	em.remove!Foo(e); // removes Foo
	assertThrown!AssertError(em.remove!Foo(e)); // e does not contain Foo
	assertThrown!AssertError(em.storageInfoMap[ComponentId!Foo].get!(Foo).get(e));

	// removes only if associated
	em.removeAll(e); // removes int
	em.removeAll(e); // doesn't remove any

	assertThrown!AssertError(em.remove!Foo(e)); // e does not contain Foo
	assertThrown!AssertError(em.remove!Bar(e)); // e does not contain Bar
	assertThrown!AssertError(em.remove!int(e)); // e does not contain ValidImmutable

	// invalid entity
	assertThrown!AssertError(em.removeAll(Entity(15)));

	// cannot call with invalid components
	assertFalse(__traits(compiles, em.remove!(void delegate())(e)));
}

@system
@("entity: EntityManager: removeAll")
unittest
{
	auto em = new EntityManager();

	foreach (i; 0..10) em.gen!(Foo, Bar);

	assertEquals(10, em.size!Foo());
	em.removeAll!Foo();
	assertEquals(0, em.size!Foo());
}

@system
@("entity: EntityManager: set")
unittest
{
	auto em = new EntityManager();

	auto e = em.gen();
	assertTrue(em.set(e, Foo(4, 5)));
	assertThrown!AssertError(em.set(Entity(0, 5), Foo(4, 5)));
	assertThrown!AssertError(em.set(Entity(2), Foo(4, 5)));
	assertEquals(Foo(4, 5), *em.storageInfoMap[ComponentId!Foo].get!(Foo).get(e));

	{
		auto components = em.set(em.gen(), Foo(4, 5), Bar("str"));
		assertEquals(Foo(4,5), *components[0]);
		assertEquals(Bar("str"), *components[1]);
	}

	{
		auto components = em.set!(Foo, Bar, int)(em.gen());
		assertEquals(Foo.init, *components[0]);
		assertEquals(Bar.init, *components[1]);
		assertEquals(int.init, *components[2]);
	}

	assertThrown!AssertError(em.set!Foo(Entity(45)));
	assertThrown!AssertError(em.set!(Foo, Bar)(Entity(45)));
	assertThrown!AssertError(em.set(Entity(45), Foo.init, Bar.init));

	assertFalse(__traits(compiles, em.set!(Foo, Bar, int, Bar)(em.gen())));
	assertFalse(__traits(compiles, em.set(em.gen(), Foo(4, 5), Bar("str"), Foo.init)));
	assertFalse(__traits(compiles, em.set!(Foo, Bar, InvalidComponent)(em.gen())));
	assertFalse(__traits(compiles, em.set!(InvalidComponent)(em.gen())));
}

@system
@("entity: EntityManager: size")
unittest
{
	auto em = new EntityManager();

	auto e = em.gen!Foo;
	assertEquals(1, em.size!Foo());
	assertEquals(0, em.size!Bar());

	em.remove!Foo(e);
	assertEquals(0, em.size!Foo());
}
