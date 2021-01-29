module ecs.entity;

import ecs.storage;

import std.exception : basicExceptionCtors, enforce;
import std.meta : AliasSeq, NoDuplicates;
import std.typecons : Nullable;

version(unittest) import aurorafw.unit.assertion;


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
	@safe pure this(in size_t id)
		in (id <= maxid)
	{
		_id = id;
	}

	@safe pure this(in size_t id, in size_t batch)
		in (id <= maxid)
		in (batch <= maxbatch)
	{
		_id = id;
		_batch = batch;
	}


	@safe pure
	bool opEquals(in Entity other) const
	{
		return other.signature == signature;
	}


	@property @safe pure
	size_t id() const { return _id; }


	@property @safe pure
	size_t batch() const { return _batch; }


	@safe pure
	auto incrementBatch()
	{
		_batch = _batch >= maxbatch ? 0 : _batch + 1;

		return this;
	}

	@safe pure
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

	alias signature this;

private:
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
	enum Entity entityNull = Entity(Entity.maxid);

	@safe pure this() { queue = entityNull; }


	/**
	 * Generates a new entity either by fabricating a new one or by recycling an
	 *     previously fabricated if the queue is not null. Throws a
	 *     **MaximumEntitiesReachedException** if the amount of entities alive
	 *     allowed reaches it's maximum value.
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
	 * Params: component = a valid component.
	 *
	 * Returns: a newly generated Entity.
	 *
	 * Throws: `MaximumEntitiesReachedException`.
	 *
	 * See_Also: `gen`**`()`**, `gen`**`(ComponentRange ...)(ComponentRange components)`**
	 */
	Entity gen(Component)(Component component = Component.init)
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
	 * Makes a valid entity invalid. When an entity is discarded it's **swapped**
	 *     with the current entity in the **queue** and it's **batch** is
	 *     incremented. The operation is aborted when trying to discard an
	 *     invalid entity.
	 *
	 * Params: entity = valid entity to discard.
	 *
	 * Returns: true if successful, false otherwise.
	 */
	@safe pure
	bool discard(in Entity entity)
	{
		// Invalid action if the entity is not valid
		if (!(entity.id < entities.length && entities[entity.id] == entity))
			return false;

		removeAll(entity);                                        // remove all components
		entities[entity.id] = queue.isNull ? entityNull : queue ; // move the next in queue to back
		queue = entity;                                           // update the next in queue
		queue.incrementBatch();                                   // increment batch for when it's revived
		return true;
	}


	/**
	 * Associates an entity to a component. Invalid cannot be associated with
	 *     components. If set fails false is returned and the operation is
	 *     halted.
	 *
	 * Params:
	 *     entity = the entity to associate.
	 *     component = a valid component to set.
	 *
	 * Returns: true if the component is set, false otherwise.
	 */
	bool set(Component)(Entity entity, Component component = Component.init)
	{
		// Invalid action if the entity is not valid
		if (!(entity.id < entities.length && entities[entity.id] == entity))
			return false;

		return _set(entity, component);
	}


	///
	bool set(ComponentRange ...)(Entity entity, ComponentRange components)
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
	{
		// Invalid action if the entity is not valid
		if (!(entity.id < entities.length && entities[entity.id] == entity))
			return false;

		foreach (component; components) _set(entity, component);

		return true;
	}


	///
	bool set(ComponentRange ...)(Entity entity)
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
	{
		// Invalid action if the entity is not valid
		if (!(entity.id < entities.length && entities[entity.id] == entity))
			return false;

		foreach (Component; ComponentRange) _set!Component(entity);

		return true;
	}


	/**
	 * Disassociates an entity from a component. If the entity is invalid or the
	 *     does not exist within the storageInfoMap, meaning that an instance of
	 *     the component was not ever associated to an entity yet false is
	 *     returned.
	 *
	 * Params:
	 *     entity = an entity to disassociate.
	 *     Component = a valid component to remove.
	 *
	 * Returns: true is the component is sucessfuly removed, false otherwise.
	 */
	bool remove(Component)(in Entity entity)
	{
		// Invalid action if the entity is not valid
		if (!(entity.id < entities.length
			&& entities[entity.id] == entity
			&& componentId!Component in storageInfoMap)
		)
			return false;

		return _remove!Component(entity);
	}


	///
	@safe pure
	bool removeAll(in Entity entity)
	{
		// Invalid action if the entity is not valid
		if (!(entity.id < entities.length && entities[entity.id] == entity))
			return false;

		foreach (storage; storageInfoMap) storage.remove(entity);

		return true;
	}


	///
	bool removeAll(Component)()
	{
		if (componentId!Component !in storageInfoMap)
			return false;

		storageInfoMap[componentId!Component].removeAll();

		return true;
	}


	/**
	 * Fetch a component associated to an entity. If the entity is invalid, the
	 *     Component wasn't associated with any entity or the entity does not
	 *     have this Component associated to it a null is returned instead.
	 *
	 * Params:
	 *     entity = the entity to get the associated Component.
	 *     Component = a valid component type to retrieve.
	 *
	 * Returns: Component* with the associated component if sucessful, null otherwise
	 */
	Component* get(Component)(in Entity entity)
	{
		// Invalid action if the entity is not valid
		if (!(entity.id < entities.length
			&& entities[entity.id] == entity
			&& componentId!Component in storageInfoMap)
		)
			return null;

		return storageInfoMap[componentId!Component].getStorage!(Component).get(entity);
	}


	/**
	 * Fetch the component if associated to the entity, otherwise the component
	 *     passed in the parameters is set and returned. If the entity is
	 *     invalid null is returned instead.
	 *
	 * Params:
	 *     entity = the entity to fetch the associated component.
	 *     component = a valid component to set if there is none associated.
	 *
	 * Returns: the Component* associated or created if successful, null otherwise.
	 */
	Component* getOrSet(Component)(in Entity entity, in Component component = Component.init)
	{
		// Invalid action if the entity is not valid
		if (!(entity.id < entities.length && entities[entity.id] == entity))
			return null;
		else if (componentId!Component !in storageInfoMap)
			storageInfoMap[componentId!Component] = StorageInfo().__ctor!(Component)();

		return storageInfoMap[componentId!Component].getStorage!(Component).getOrSet(entity, component);
	}


	/**
	 * Get the size of Component Storage. The size represents how many entities
	 *     are associated to a component type.
	 *
	 * Params: Component = a Component type to search.
	 *
	 * Returns: the amount of entities/components within that Storage or 0 if it
	 *     fails.
	 */
	size_t size(Component)() const
	{
		return componentId!Component in storageInfoMap
			? storageInfoMap[componentId!Component].size()
			: 0;
	}


	/**
	 * Helper struct to perform multiple actions sequences.
	 *
	 * Returns: an EntityBuilder.
	 */
	@safe pure
	auto entityBuilder()
	{
		import ecs.entitybuilder : EntityBuilder;
		return EntityBuilder(this);
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
			entities.length < Entity.maxid,
			format!"Reached the maximum amount of entities supported: %s!"(Entity.maxid)
		);

		import std.range : back;
		entities ~= Entity(entities.length); // safe pure cast
		return entities.back;
	}


	/**
	 * Creates a new entity reusing a **previously discarded entity** with a new
	 *     **batch**. Swaps the current discarded entity stored the queue's entity
	 *     place with it.
	 *
	 * Returns: an Entity previously fabricated with a new batch.
	 */
	@safe pure
	Entity recycle()
		in (!queue.isNull)
	{
		immutable next = queue;     // get the next entity in queue
		queue = entities[next.id];  // grab the entity which will be the next in queue
		entities[next.id] = next;   // revive the entity
		return next;
	}


	bool _set(Component)(Entity entity, Component component = Component.init)
		if (isComponent!Component)
	{
		if (componentId!Component !in storageInfoMap)
		{
			// there isn't a Storage of this Component, create one
			storageInfoMap[componentId!Component] = StorageInfo().__ctor!(Component)();
		}

		// set the component to entity
		return storageInfoMap[componentId!Component].getStorage!(Component).set(entity, component);
	}


	bool _remove(Component)(in Entity entity)
		if (isComponent!Component)
	{
		return storageInfoMap[componentId!Component].remove(entity);
	}


	Entity[] entities;
	Nullable!(Entity, entityNull) queue;
	StorageInfo[TypeInfo] storageInfoMap;
}


@safe pure
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
	assertEquals(em.entityNull, em.entities[entity1.id]);
	(() @trusted pure => assertEquals(Entity(1, 1), em.queue.get))(); // batch was incremented

	assertTrue(em.discard(entity0));
	assertEquals(Entity(1, 1), em.entities[entity0.id]);
	(() @trusted pure => assertEquals(Entity(0, 1), em.queue.get))(); // batch was incremented

	// cannot discard invalid entities
	assertFalse(em.discard(Entity(50)));
	assertFalse(em.discard(Entity(entity2.id, 40)));

	assertEquals(3, em.entities.length);
}

@safe pure
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
	assertEquals(2, em.entities.length);
	assertEquals(Entity(1), em.entities.back);

	// FIXME: add MaximumEntitiesReachedException
}

@safe pure
@("entity: EntityManager: gen")
unittest
{
	import std.range : front;
	auto em = new EntityManager();

	assertEquals(Entity(0), em.gen());
	assertEquals(1, em.entities.length);
	assertEquals(Entity(0), em.entities.front);
}

@safe pure
@("entity: EntityManager: gen with components")
unittest
{
	import std.range : front;
	auto em = new EntityManager();

	auto e = em.gen(Foo(3, 5), Bar("str"));
	assertEquals(Foo(3, 5), *em.storageInfoMap[componentId!Foo].getStorage!(Foo).get(e));
	assertEquals(Bar("str"), *em.storageInfoMap[componentId!Bar].getStorage!(Bar).get(e));

	e = em.gen!(ValidComponent, OtherValidComponent, ValidImmutable);
	assertEquals(ValidComponent.init, *em.storageInfoMap[componentId!ValidComponent].getStorage!(ValidComponent).get(e));
	assertEquals(OtherValidComponent.init, *em.storageInfoMap[componentId!OtherValidComponent].getStorage!(OtherValidComponent).get(e));
	assertEquals(ValidImmutable.init, *em.storageInfoMap[componentId!ValidImmutable].getStorage!(ValidImmutable).get(e));

	assertFalse(__traits(compiles, em.gen!(ValidImmutable, ValidImmutable)()));
	assertFalse(__traits(compiles, em.gen(Foo(3,3), Bar(5,3), Foo.init)));
	assertFalse(__traits(compiles, em.gen!(Foo, Bar, InvalidComponent)()));
	assertFalse(__traits(compiles, em.gen!InvalidComponent()));
}

@safe pure
@("entity: EntityManager: get")
unittest
{
	auto em = new EntityManager();

	auto e = em.gen!(Foo, Bar);

	assertEquals(Foo.init, *em.get!Foo(e));
	assertEquals(Bar.init, *em.get!Bar(e));
	assertNull(em.get!ValidComponent(e));

	em.get!Foo(e).y = 10;
	assertEquals(Foo(int.init, 10), *em.get!Foo(e));

	assertFalse(__traits(compiles, em.get!InvalidComponent(em.gen())));
}

@safe pure
@("entity: EntityManager: getOrSet")
unittest
{
	auto em = new EntityManager();

	auto e = em.gen!(Foo)();
	assertEquals(Foo.init, *em.getOrSet!Foo(e));
	assertEquals(Foo.init, *em.getOrSet(e, Foo(2, 3)));
	assertEquals(Bar("str"), *em.getOrSet(e, Bar("str")));

	assertNull(em.getOrSet!Foo(Entity(0, 12)));
	assertNull(em.getOrSet!Foo(Entity(3)));
}

@safe pure
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
	assertEquals(Entity(0, 1), em.entities.front);
}

@safe pure
@("entity: EntityManager: remove")
unittest
{
	auto em = new EntityManager();

	auto e = em.gen!(Foo, Bar, ValidComponent);
	assertFalse(em.remove!ValidImmutable(e)); // not in the storageInfoMap

	assertTrue(em.remove!Foo(e)); // removes Foo
	assertFalse(em.remove!Foo(e)); // e does not contain Foo
	assertNull(em.storageInfoMap[componentId!Foo].getStorage!(Foo).get(e));

	// removes only if associated
	assertTrue(em.removeAll(e)); // removes ValidComponent
	assertTrue(em.removeAll(e)); // doesn't remove any

	assertFalse(em.remove!Foo(e)); // e does not contain Foo
	assertFalse(em.remove!Bar(e)); // e does not contain Bar
	assertFalse(em.remove!ValidImmutable(e)); // e does not contain ValidImmutable

	// removing from invalid entities returns null
	assertFalse(em.removeAll(Entity(15)));

	// cannot call with invalid components
	assertFalse(__traits(compiles, em.remove!InvalidComponent(e)));
}

@safe pure
@("entity: EntityManager: removeAll")
unittest
{
	auto em = new EntityManager();

	foreach (i; 0..10) em.gen!(Foo, Bar);

	assertEquals(10, em.size!Foo());
	assertTrue(em.removeAll!Foo());
	assertEquals(0, em.size!Foo());

	assertFalse(em.removeAll!ValidComponent);
}

@safe pure
@("entity: EntityManager: set")
unittest
{
	auto em = new EntityManager();

	auto e = em.gen();
	assertTrue(em.set(e, Foo(4, 5)));
	assertFalse(em.set(Entity(0, 5), Foo(4, 5)));
	assertFalse(em.set(Entity(2), Foo(4, 5)));
	assertEquals(Foo(4, 5), *em.storageInfoMap[componentId!Foo].getStorage!(Foo).get(e));

	assertTrue(em.set(em.gen(), Foo(4, 5), Bar("str")));
	assertTrue(em.set!(Foo, Bar, ValidComponent)(em.gen()));

	assertFalse(em.set!Foo(Entity(45)));
	assertFalse(em.set!(Foo, Bar)(Entity(45)));
	assertFalse(em.set(Entity(45), Foo.init, Bar.init));

	assertFalse(__traits(compiles, em.set!(Foo, Bar, ValidComponent, Bar)(em.gen())));
	assertFalse(__traits(compiles, em.set(em.gen(), Foo(4, 5), Bar("str"), Foo.init)));
	assertFalse(__traits(compiles, em.set!(Foo, Bar, InvalidComponent)(em.gen())));
	assertFalse(__traits(compiles, em.set!(InvalidComponent)(em.gen())));
}

@safe pure
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
