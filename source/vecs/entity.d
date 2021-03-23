module vecs.entity;

import vecs.storage;
import vecs.query;
import vecs.queryfilter;
import vecs.queryworld;

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
 * | void* size (bits) | idshift | idmask      | batchmask         |
 * | :-----------------| :-----: | :---------- | :---------------- |
 * | 4                 | 20      | 0xFFFF_F    | 0xFFF << 20       |
 * | 8                 | 32      | 0xFFFF_FFFF | 0xFFFF_FFFF << 32 |
 *
 * Sizes:
 * | void* size (bits) | id (bits) | batch (bits) | maxid         | maxbatch      |
 * | :---------------- | :-------: | :----------: | :-----------: | :-----------: |
 * | 4                 | 20        | 12           | 1_048_574     | 4_095         |
 * | 8                 | 32        | 32           | 4_294_967_295 | 4_294_967_295 |
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
	 * Generates a new entity either by fabricating a new one or by recycling an
	 *     previously fabricated if the queue is not null. Throws a
	 *     **MaximumEntitiesReachedException** if the amount of entities alive
	 *     allowed reaches it's maximum value.
	 *
	 * Safety: The **internal code** is @safe, however, beacause of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onSet.
	 *
	 * Returns: a newly generated Entity.
	 *
	 * Throws: `MaximumEntitiesReachedException`.
	 *
	 * See_Also: `gen`**`(Component)(Component component)`**, `gen`**`(ComponentRange ...)(ComponentRange components)`**
	 */
	@safe pure
	Entity gen()
	{
		return queue.isNull ? fabricate() : recycle();
	}


	/**
	 * Generates a new entity and assigns the component to it. If the component
	 *     has no ctor or a default ctor then only it's type can be passed.
	 *
	 * Examples:
	 * --------------------
	 * @Component struct Foo { int x; } // x gets default initialized to int.init
	 * auto em = new EntityManager;
	 * em.gen!Foo(); // generates a new entity with Foo.init values
	 * --------------------
	 *
	 * Safety: The **internal code** is @safe, however, beacause of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onSet.
	 *
	 * Params: component = a valid component.
	 *
	 * Returns: a newly generated Entity.
	 *
	 * Throws: `MaximumEntitiesReachedException`.
	 *
	 * See_Also: `gen`**`()`**, `gen`**`(ComponentRange ...)(ComponentRange components)`**
	 */
	Entity gen(Component)(Component component = Component.init)
		if (isComponent!Component)
	{
		immutable e = gen();
		_set(e, component);
		return e;
	}


	/**
	 * Generates a new entity and assigns the components to it.
	 *
	 * Examples:
	 * --------------------
	 * @Component struct Foo { int x; }
	 * @Component struct Bar { int x; }
	 * auto em = new EntityManager;
	 * em.gen(Foo(3), Bar(6));
	 * --------------------
	 *
	 * Safety: The **internal code** is @safe, however, beacause of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onSet.
	 *
	 * Params: component = a valid component.
	 *
	 * Returns: a newly generated Entity.
	 *
	 * Throws: `MaximumEntitiesReachedException`.
	 *
	 * See_Also: `gen`**`()`**, `gen`**`(Component)(Component component)`**
	 */
	Entity gen(ComponentRange ...)(ComponentRange components)
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
	{
		immutable e = gen();
		foreach (component; components) _set(e, component);
		return e;
	}


	///
	Entity gen(ComponentRange ...)()
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
	{
		immutable e = gen();
		foreach (Component; ComponentRange) _set!Component(e);
		return e;
	}


	/**
	 * Destroys a valid entity. When destroyed all it's components are removed.
	 *     Passig an invalid entity leads to undefined behaviour.
	 *
	 * Params: e = valid entity to discard.
	 */
	@system
	void discard(in Entity e)
		in (has(e))
	{
		removeAll(e);                                             // remove all components
		_entities[e.id] = queue.isNull ? entityNull : queue.get(); // move the next in queue to back
		queue = e;                                                // update the next in queue
		queue.incrementBatch();                                   // increment batch for when it's revived
	}


	///
	void discardIfHas(in Entity e)
	{
		if (has(e)) discard(e);
	}


	/**
	 * This signal occurs every time a Component is set. The onSet signal is
	 *     emitted **after** the Component is set. A Component is set when
	 *     assigning a new one to an entity or when updating an existing one.
	 *
	 * Params: Component = a valid component type
	 *
	 * Returns: Signal!(Entity,Component*)
	 */
	ref auto onSet(Component)()
	{
		return _assureStorage!Component.onSet;
	}


	/**
	 * This signal occurs every time a Component is disassociated from an
	 *     entity. The onRemove signal is emitted **after** the Component is
	 *     set. A Component is removed when removing a one from an entity or
	 *     when discarding an entity.
	 *
	 * Params: Component = a valid component type
	 *
	 * Returns: Signal!(Entity,Component*)
	 */
	ref auto onRemove(Component)()
	{
		return _assureStorage!Component.onRemove;
	}


	/**
	 * Associates an entity to a component. The entity must be valid. Passing an
	 *     invalid entity leads to undefined behaviour. Emits onSet after
	 *     associating the component to the entity, either by creation or by
	 *     replacement.
	 *
	 * Params:
	 *     e = the entity to associate.
	 *     component = a valid component to set.
	 *
	 * Safety: The **internal code** is @safe, however, beacause of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onSet.
	 *
	 * Returns: a pointer to the component set.
	 */
	Component* set(Component)(in Entity e, Component component = Component.init)
		in (has(e))
	{
		return _set(e, component);
	}


	///
	auto set(ComponentRange ...)(in Entity e, ComponentRange components)
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
		in (has(e))
	{
		mixin(format!q{Tuple!(%(ComponentRange[%s]*%|, %)) ret;}(ComponentRange.length.iota));

		foreach (i, component; components) ret[i] = _set(e, component);

		return ret;
	}


	///
	auto set(ComponentRange ...)(in Entity e)
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
		in (has(e))
	{
		mixin(format!q{Tuple!(%(ComponentRange[%s]*%|, %)) ret;}(ComponentRange.length.iota));

		foreach (i, Component; ComponentRange) ret[i] = _set!Component(e);

		return ret;
	}


	/**
	 * Disassociates an entity from a component. The entity must be associated
	 *     with the Component passed. Passing and invalid entity leads to
	 *     undefined behaviour. See **removeIfHas** which removes the Component
	 *     only if the entity is associated to it.
	 *
	 * Safety: The **internal code** is @safe, however, beacause of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onRemove.
	 *
	 * Params:
	 *     e = an entity to disassociate.
	 *     Component = a valid component to remove.
	 */
	void remove(Component)(in Entity e)
		in (has(e))
	{
		_remove!Component(e);
	}


	/**
	 * Disassociates an entity from a component. If the entity is not associated
	 *     with the given Component nothing happens. Passing and invalid entity
	 *     leads to undefined behaviour.
	 *
	 * Safety: The **internal code** is @safe, however, beacause of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onRemove.
	 *
	 * Params:
	 *     e = an entity to disassociate.
	 *     Component = a valid component to remove.
	 */
	void removeIfHas(Component)(in Entity e)
		in (has(e))
	{
		_assureStorage!Component().removeIfHas(e);
	}


	/**
	 * Removes all components associated to an entity. If the entity passed is
	 *     invalid it leads to undefined behaviour.
	 *
	 * Safety: The **internal code** is @safe, however, beacause of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Emits onRemove.
	 *
	 * Params: e = an entity to disassociate.
	 */
	@system
	void removeAll(in Entity e)
		in (has(e))
	{
		foreach (sinfo; storageInfoMap)
			if (sinfo.storage !is null)
				sinfo.removeIfHas(e);
	}


	/**
	 * Disassociates al entities from a Component, reseting the Storage for that
	 *     Component.
	 *
	 * Params: Component = a valid Component.
	 */
	void removeAll(Component)()
	{
		// FIXME: emit onRemove
		_assureStorage!Component().removeAll();
	}


	/**
	 * Fetch a component associated to an entity. The entity must be associated
	 *     with the Component passed. Passing and invalid entity. See **getOrSet**
	 *     which sets a component to an entity if the same isn't associated with
	 *     one.
	 *
	 * Params:
	 *     e= the entity to get the associated Component.
	 *     Component = a valid component type to retrieve.
	 *
	 * Returns: a pointer to the Component.
	 */
	Component* get(Component)(in Entity e)
		in (has(e))
	{
		return _assureStorage!Component().get(e);
	}


	/**
	 * Fetch the component if associated to the entity, otherwise the component
	 *     passed in the parameters is set and returned. If no Storage for the
	 *     passed Component exists, one is initialized. If the entity passed is
	 *     invalid it leads to undefined behaviour.
	 *
	 * Safety: The **internal code** is @safe, however, beacause of **Signal**
	 *     dependency, the method must be @system.
	 *
	 * Signal: Might emit onSet.
	 *
	 * Params:
	 *     e = the entity to fetch the associated component.
	 *     component = a valid component to set if there is none associated.
	 *
	 * Returns: a pointer to the Component.
	 */
	Component* getOrSet(Component)(in Entity e, Component component = Component.init)
		in (has(e))
	{
		return _assureStorage!Component().getOrSet(e, component);
	}


	/**
	 * Get the size of Component Storage. The size represents how many entities
	 *     are associated to a component type.
	 *
	 * Params: Component = a Component type to search.
	 *
	 * Returns: the amount of entities in the Component Storage.
	 */
	size_t size(Component)()
	{
		return _assureStorage!Component().size();
	}


	/**
	 * Helper struct to perform multiple actions sequences.
	 *
	 * Returns: an EntityBuilder.
	 */
	@safe pure nothrow @nogc
	auto entityBuilder()
	{
		import vecs.entitybuilder : EntityBuilder;
		return EntityBuilder(this);
	}


	///
	@safe pure nothrow @nogc
	bool has(in Entity e) const
		in (e.id < Entity.maxid)
	{
		return e.id < _entities.length && _entities[e.id] == e;
	}


	/**
	 * Query of `Output` args. `Output` must either be an `Entity`, a
	 *     `Component` or a `Tuple` of these. `Component` arguments passed in `Output`
	 *     are returned by reference by the range. `Entity` is copied. To have
	 *     an `Entity` as an `Output` parameter, the type must **always** be in
	 *     the first "slot".
	 *
	 * If using the range with a `foreach` loop, then the arguments are
	 *     implicitly converted to the respective variables.
	 *
	 * Examples:
	 * --------------------
	 * auto em = new EntityManager();
	 * ...
	 *
	 * // query valid entities
	 * foreach (e; em.query!Entity) { ... }
	 *
	 * // same as above --> infers to em.query!Entity
	 * foreach (e; em.query!(Tuple!Entity)) { ... }
	 *
	 * // query entities with int, string
	 * foreach (e, i, str; em.query!(Tuple!(Entity,int,string))) { ... }
	 *
	 * // same as above but doesn't return the entities
	 * foreach (i, str; em.query!(Tuple!(int,string))) { ... }
	 * --------------------
	 *
	 * Parameters: Output = valid query arguments (Entity and Component)
	 *
	 * Returns: a `Query!Output` which iterates through the entities with
	 *     `Output` arguments.
	 */
	auto query(Output)()
	{
		auto queryW = _queryWorld!Output();

		return Query!(TemplateArgsOf!(typeof(queryW)))(queryW);
	}


	/**
	 * Query of `Output` args with `Filter` args. Behaves the same as the normal
	 *     query with the addition of filtering Components not wanted in the
	 *     `Output` parameters. All `Filter` arguments must be `Components`.
	 *
	 * Examples:
	 * --------------------
	 * auto em = new EntityManager();
	 * ...
	 *
	 * // query entities with int and string but only returns entities
	 * foreach (e; em.query!(Entity, With!(int, string))) { ... }
	 *
	 * // query entities without int but only returns entities
	 * foreach (e; em.query!(Entity, Without!int)) { ... }
	 *
	 * // query entities with int, string but only returns entities and int
	 * foreach (e, i; em.query!(Tuple!(Entity,int), With!string)) { ... }
	 *
	 * // query entities with int, string and without bool but only returns entities and int
	 * foreach (e, i; em.query!(Tuple!(Entity,int), Tuple!(With!string, Without!bool))) { ... }
	 * --------------------
	 */
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


	///
	auto queryOne(Output)() { return query!Output.front; }


	///
	auto queryOne(Output, Filter)() { return query!(Output, Filter).front; }


	///
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

private:
	/**
	 * Creates a new entity with a new id. The entity's id follows the total
	 *     value of entities created. Throws a **MaximumEntitiesReachedException**
	 *     if the maximum amount of entities allowed is reached.
	 *
	 * Returns: an Entity with a new id.
	 *
	 * Throws: `MaximumEntitiesReachedException`.
	 */
	@safe pure
	Entity fabricate()
	{
		import std.format : format;
		enforce!MaximumEntitiesReachedException(
			_entities.length < Entity.maxid,
			format!"Reached the maximum amount of _entities supported: %s!"(Entity.maxid)
		);

		import std.range : back;
		_entities ~= Entity(_entities.length); // safe pure cast
		return _entities.back;
	}


	/**
	 * Creates a new entity reusing a **previously discarded entity** with a new
	 *     **batch**. Swaps the current discarded entity stored the queue's entity
	 *     place with it.
	 *
	 * Returns: an Entity previously fabricated with a new batch.
	 */
	@safe pure nothrow @nogc
	Entity recycle()
		in (!queue.isNull)
	{
		immutable next = queue;     // get the next entity in queue
		queue = _entities[next.id];  // grab the entity which will be the next in queue
		_entities[next.id] = next;   // revive the entity
		return next;
	}


	///
	Component* _set(Component)(in Entity entity, Component component = Component.init)
		if (isComponent!Component)
	{
		// set the component to entity
		return _assureStorage!Component().set(entity, component);
	}


	///
	void _remove(Component)(in Entity entity)
		if (isComponent!Component)
	{
		_assureStorage!Component().remove(entity);
	}


	///
	size_t _assure(Component)()
		if (isComponent!Component)
	{
		immutable index = ComponentId!Component;

		if (index >= storageInfoMap.length)
		{
			storageInfoMap.length = index + 1;
		}

		if (storageInfoMap[index].storage is null)
		{
			storageInfoMap[index] = StorageInfo().__ctor!(Component)();
		}

		return index;
	}


	///
	Storage!Component _assureStorage(Component)()
		if (isComponent!Component)
	{
		immutable index = _assure!Component(); // to fix dmd boundscheck=off
		return storageInfoMap[index].get!Component();
	}


	///
	auto ref StorageInfo _assureStorageInfo(Component)()
		if (isComponent!Component)
	{
		immutable index = _assure!Component();
		return storageInfoMap[index];
	}


	///
	QueryWorld!(Entity) _queryWorld(Output : Entity, Extra ...)()
	{
		return QueryWorld!Entity(_queryEntities!(Extra).idup);
	}


	///
	QueryWorld!(Entity) _queryWorld(Output : Tuple!Entity, Extra ...)()
	{
		return _queryWorld!(Entity, Extra)();
	}


	///
	QueryWorld!(Component) _queryWorld(Component, Extra ...)()
		if (isComponent!Component)
	{
		auto storage = _assureStorage!Component();
		auto entities = _queryEntities!(Component, Extra);
		return QueryWorld!Component(entities.idup, storage.components());
	}


	///
	QueryWorld!(Component) _queryWorld(Output : Tuple!(Component), Component, Extra ...)()
		if (isComponent!Component && Output.length == 1)
	{
		return _queryWorld!(Component, Extra)();
	}


	///
	QueryWorld!(OutputTuple) _queryWorld(OutputTuple, Extra ...)()
		if (isInstanceOf!(Tuple, OutputTuple))
	{
		alias Out = NoDuplicates!(TemplateArgsOf!OutputTuple);
		static if (is(Out[0] == Entity))
			alias Components = Out[1..$];
		else
			alias Components = Out;

		enum components = format!q{[%(_assureStorageInfo!(Components[%s])%|,%)]}(Components.length.iota);

		auto entities = _queryEntities!(Components, Extra);
		enum queryworld = format!q{QueryWorld!(OutputTuple)(entities.idup,%s)}(components);

		return mixin(queryworld);
	}


	///
	QueryFilter!(Filter) _queryFilter(Filter)()
		if (!isInstanceOf!(Tuple, Filter))
	{
		alias F = TemplateArgsOf!Filter;
		enum queryFilter = format!q{QueryFilter!Filter(Filter([%(_assureStorageInfo!(F[%s])%|,%)]))}(F.length.iota);

		return mixin(queryFilter);
	}


	///
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
	 * Finds the Storage with the lowest size of all ComponentRange storages. If
	 *     ComponentRange.length is 0 then all valid entities are chosen.
	 *
	 * Paramters: ComponentRange = components to search.
	 *
	 * Returns: the lowest Entity[] in size of all Storages if
	 * ComponentRange.len > 0, otherwise all valid entities.
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
