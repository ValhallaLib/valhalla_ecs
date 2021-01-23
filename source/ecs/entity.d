module ecs.entity;

import ecs.storage;

import std.exception : basicExceptionCtors, enforce;
import std.meta : AliasSeq, NoDuplicates;
import std.typecons : Nullable;

version(unittest) import aurorafw.unit.assertion;


/**
 * EntityType is defined as being an integral and unsigned value. Possible
 *     type are **ubyte, ushort, uint, ulong, size_t**. All remaining type are
 *     defined as being invalid.
 *
 * Params: T = type to classify.
 *
 * Returns: true if it's a valid type, false otherwise.
 */
private template isEntityType(T)
{
	import std.traits : isIntegral, isUnsigned;
	enum isEntityType = isIntegral!T && isUnsigned!T;
}

///
@safe
@("entity: isEntityType")
unittest
{
	import std.meta : AliasSeq, allSatisfy;
	assertTrue(allSatisfy!(isEntityType, AliasSeq!(ubyte, ushort, uint, ulong, size_t)));

	assertFalse(allSatisfy!(isEntityType, AliasSeq!(byte, short, int, long, ptrdiff_t)));
	assertFalse(allSatisfy!(isEntityType, AliasSeq!(float, double, real, ifloat, idouble, ireal)));
	assertFalse(allSatisfy!(isEntityType, AliasSeq!(char, dchar, wchar, string, bool)));
}


/**
 * Defines ground constants used to manipulate entities internaly.
 *
 * Constants:
 *     `entityShift` = division point between the entity's **id** and **batch**. \
 *     `entityMask` = bit mask related to the entity's **id** portion. \
 *     `batchMask` = bit mask related to the entity's **batch** portion. \
 *     `entityNull` = Entity!(T) with an **id** of the max value available for T.
 *
 * Code_Gen:
 * | type   | entityShift | entityMask  | batchMask   | entityNull                    |
 * | :------| :---------: | :---------- | :---------- | :---------------------------- |
 * | ubyte  | 4           | 0xF         | 0xF         | Entity!(ubyte)(15)            |
 * | ushort | 8           | 0xFF        | 0xFF        | Entity!(ushort)(255)          |
 * | uint   | 20          | 0xFFFF_F    | 0xFFF       | Entity!(uint)(1_048_575)      |
 * | ulong  | 32          | 0xFFFF_FFFF | 0xFFFF_FFFF | Entity!(ulong)(4_294_967_295) |
 *
 * Sizes:
 * | type   | id-(bits) | batch-(bits) | max-entities  | batch-reset   |
 * | :----- | :-------: | :----------: | :-----------: | :-----------: |
 * | ubyte  | 4         | 4            | 14            | 15            |
 * | ushort | 8         | 8            | 254           | 255           |
 * | uint   | 20        | 12           | 1_048_574     | 4_095         |
 * | ulong  | 32        | 32           | 4_294_967_295 | 4_294_967_295 |
 *
 * Params: T = valid entity type.
 */
private mixin template genBitMask(T)
	if (isEntityType!T)
{
	static if (is(T == uint))
	{
		enum T entityShift = 20U;
		enum T entityMask = (1UL << 20U) - 1;
		enum T batchMask = (1UL << (T.sizeof * 8 - 20U)) - 1;
	}
	else
	{
		enum T entityShift = T.sizeof * 8 / 2;
		enum T entityMask = (1UL << T.sizeof * 8 / 2) - 1;
		enum T batchMask = (1UL << (T.sizeof * 8 - T.sizeof * 8 / 2)) - 1;
	}

	enum Entity!T entityNull = Entity!T(entityMask);
}

///
@safe
@("entity: genBitMask")
unittest
{
	{
		mixin genBitMask!uint;
		assertTrue(is(typeof(entityShift) == uint));

		assertEquals(20, entityShift);
		assertEquals(0xFFFF_F, entityMask);
		assertEquals(0xFFF, batchMask);
		assertEquals(Entity!uint(entityMask), entityNull);
	}

	{
		mixin genBitMask!ulong;
		assertTrue(is(typeof(entityShift) == ulong));

		assertEquals(32, entityShift);
		assertEquals(0xFFFF_FFFF, entityMask);
		assertEquals(0xFFFF_FFFF, batchMask);
		assertEquals(Entity!ulong(entityMask), entityNull);
	}
}


class MaximumEntitiesReachedException : Exception { mixin basicExceptionCtors; }


/**
 * Defines an entity of entity type T. An entity is defined by an **id** and a
 *     **batch**. It's signature is the combination of both values. The first N
 *     bits belong to the **id** and the last M ending bits to the `batch`. \
 * \
 * An entity in it's raw form is simply a value of entity type T formed by the
 *     junction of the id with the batch. The constant values which define all
 *     masks are calculated in the `genBitMask` mixin template. \
 * \
 * An entity is then defined by: **id | (batch << entity_shift)**. \
 * \
 * Let's imagine an entity of the ubyte type. By default it's **id** and **batch**
 *     occupy **4 bits** each, half the sizeof ubyte. \
 * \
 * `Entity!ubyte` = **0000 0000** = ***(batch << 4) | id***.
 * \
 * What this means is that for a given value of `ubyte` it's first half is
 *     composed with the **id** and it's second half with the **batch**. This
 *     allows entities to be reused at some time in the program's life without
 *     having to resort to a more complicated process. Every time an entity is
 *     **discarded** it's **id** doesn't suffer any alterations however it's
 *     **batch** is increased by **1**, allowing the usage of an entity with the
 *     the same **id** but mantaining it's uniqueness with a new **batch**
 *     generating a completely new signature.
 *
 * See_Also: [skypjack - entt](https://skypjack.github.io/2019-05-06-ecs-baf-part-3/)
 */
@safe
struct Entity(T)
	if (isEntityType!T)
{
public:
	this(in T id) { _id = id; }
	this(in T id, in T batch) { _id = id; _batch = batch; }

	bool opEquals(in Entity other) const
	{
		return other.signature == signature;
	}

	@property
	T id() const { return _id; }

	@property
	T batch() const { return _batch; }

	auto incrementBatch()
	{
		_batch = _batch >= EntityManager!(T).batchMask ? 0 : cast(T)(_batch + 1);

		return this;
	}

	T signature() const
	{
		return cast(T)(_id | (_batch << EntityManager!(T).entityShift));
	}

private:
	T _id;
	T _batch;
}

@safe
@("entity: Entity")
unittest
{
	auto entity0 = Entity!ubyte(0);

	assertEquals(0, entity0.id);
	assertEquals(0, entity0.batch);
	assertEquals(0, entity0.signature);
	assertEquals(Entity!ubyte(0, 0), entity0);

	entity0.incrementBatch();
	assertEquals(0, entity0.id);
	assertEquals(1, entity0.batch);
	assertEquals(16, entity0.signature);
	assertEquals(Entity!ubyte(0, 1), entity0);

	entity0 = Entity!ubyte(0, 15);
	entity0.incrementBatch();
	assertEquals(0, entity0.batch); // batch reseted

	assertEquals(15, Entity!ubyte(0, 15).batch);
}


/**
 * Responsible for managing all entities lifetime and access to components as
 *     well as any operation related to them.
 *
 * Params: T = valid entity type.
 */
class EntityManager(T)
{
public:
	mixin genBitMask!T;


	this() { queue = entityNull; }


	/**
	 * Generates a new entity either by fabricating a new one or by recycling an
	 *     previously fabricated if the queue is not null. Throws a
	 *     **MaximumEntitiesReachedException** if the amount of entities alive
	 *     allowed reaches it's maximum value.
	 *
	 * Returns: a newly generated Entity!T.
	 *
	 * Throws: `MaximumEntitiesReachedException`.
	 *
	 * See_Also: `gen`**`(Component)(Component component)`**, `gen`**`(ComponentRange ...)(ComponentRange components)`**
	 */
	@safe
	Entity!(T) gen()
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
	 * auto em = new EntityManager!size_t;
	 * em.gen!Foo(); // generates a new entity with Foo.init values
	 * --------------------
	 *
	 * Params: component = a valid component.
	 *
	 * Returns: a newly generated Entity!T.
	 *
	 * Throws: `MaximumEntitiesReachedException`.
	 *
	 * See_Also: `gen`**`()`**, `gen`**`(ComponentRange ...)(ComponentRange components)`**
	 */
	Entity!(T) gen(Component)(Component component = Component.init)
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
	 * auto em = new EntityManager!size_t;
	 * em.gen(Foo(3), Bar(6));
	 * --------------------
	 *
	 * Params: component = a valid component.
	 *
	 * Returns: a newly generated Entity!T.
	 *
	 * Throws: `MaximumEntitiesReachedException`.
	 *
	 * See_Also: `gen`**`()`**, `gen`**`(Component)(Component component)`**
	 */
	Entity!(T) gen(ComponentRange ...)(ComponentRange components)
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
	{
		immutable e = gen();
		foreach (component; components) _set(e, component);
		return e;
	}


	///
	Entity!(T) gen(ComponentRange ...)()
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
	@safe
	bool discard(in Entity!(T) entity)
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
	bool set(Component)(Entity!T entity, Component component = Component.init)
	{
		// Invalid action if the entity is not valid
		if (!(entity.id < entities.length && entities[entity.id] == entity))
			return false;

		return _set(entity, component);
	}


	///
	bool set(ComponentRange ...)(Entity!T entity, ComponentRange components)
		if (ComponentRange.length > 1 && is(ComponentRange == NoDuplicates!ComponentRange))
	{
		// Invalid action if the entity is not valid
		if (!(entity.id < entities.length && entities[entity.id] == entity))
			return false;

		foreach (component; components) _set(entity, component);

		return true;
	}


	///
	bool set(ComponentRange ...)(Entity!T entity)
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
	bool remove(Component)(in Entity!T entity)
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
	@safe
	bool removeAll(in Entity!T entity)
	{
		// Invalid action if the entity is not valid
		if (!(entity.id < entities.length && entities[entity.id] == entity))
			return false;

		foreach (storage; storageInfoMap) storage.remove(entity);

		return true;
	}

private:
	/**
	 * Creates a new entity with a new id. The entity's id follows the total
	 *     value of entities created. Throws a **MaximumEntitiesReachedException**
	 *     if the maximum amount of entities allowed is reached.
	 *
	 * Returns: an Entity!T with a new id.
	 *
	 * Throws: `MaximumEntitiesReachedException`.
	 */
	@safe
	Entity!(T) fabricate()
	{
		import std.format : format;
		enforce!MaximumEntitiesReachedException(
			entities.length < entityMask,
			format!"Reached the maximum amount of entities supported for type %s: %s!"(T.stringof, entityMask)
		);

		import std.range : back;
		entities ~= Entity!(T)(cast(T)entities.length); // safe cast
		return entities.back;
	}


	/**
	 * Creates a new entity reusing a **previously discarded entity** with a new
	 *     **batch**. Swaps the current discarded entity stored the queue's entity
	 *     place with it.
	 *
	 * Returns: an Entity!T previously fabricated with a new batch.
	 */
	@safe
	Entity!(T) recycle()
		in (!queue.isNull)
	{
		immutable next = queue;     // get the next entity in queue
		queue = entities[next.id];  // grab the entity which will be the next in queue
		entities[next.id] = next;   // revive the entity
		return next;
	}


	bool _set(Component)(Entity!T entity, Component component = Component.init)
		if (isComponent!Component)
	{
		if (componentId!Component !in storageInfoMap)
		{
			// there isn't a Storage of this Component, create one
			storageInfoMap[componentId!Component] = StorageInfo!(T)().__ctor!(Component)();
		}

		// set the component to entity
		return storageInfoMap[componentId!Component].getStorage!(Component).set(entity, component);
	}


	bool _remove(Component)(in Entity!T entity)
		if (isComponent!Component)
	{
		return storageInfoMap[componentId!Component].remove(entity);
	}


	Entity!(T)[] entities;
	Nullable!(Entity!(T), entityNull) queue;
	StorageInfo!(T)[TypeInfo] storageInfoMap;
}


@safe
@("entity: EntityManager")
unittest
{
	assertTrue(__traits(compiles, EntityManager!uint));
	assertFalse(__traits(compiles, EntityManager!int));
}

@safe
@("entity: EntityManager: discard")
unittest
{
	auto em = new EntityManager!uint();
	assertTrue(em.queue.isNull);

	auto entity0 = em.gen();
	auto entity1 = em.gen();
	auto entity2 = em.gen();


	em.discard(entity1);
	assertFalse(em.queue.isNull);
	assertEquals(em.entityNull, em.entities[entity1.id]);
	(() @trusted => assertEquals(Entity!uint(1, 1), em.queue))(); // batch was incremented

	assertTrue(em.discard(entity0));
	assertEquals(Entity!uint(1, 1), em.entities[entity0.id]);
	(() @trusted => assertEquals(Entity!uint(0, 1), em.queue))(); // batch was incremented

	// cannot discard invalid entities
	assertFalse(em.discard(Entity!uint(50)));
	assertFalse(em.discard(Entity!uint(entity2.id, 40)));

	assertEquals(3, em.entities.length);
}

@safe
@("entity: EntityManager: fabricate")
unittest
{
	import std.range : back;
	auto em = new EntityManager!ubyte();

	auto entity0 = em.gen(); // calls fabricate
	em.discard(entity0); // discards
	em.gen(); // recycles
	assertTrue(em.queue.isNull);

	assertEquals(Entity!(ubyte)(1), em.gen()); // calls fabricate again
	assertEquals(2, em.entities.length);
	assertEquals(Entity!(ubyte)(1), em.entities.back);

	em.entities.length = 15; // max entities allowed for ubyte
	expectThrows!MaximumEntitiesReachedException(em.gen());
}

@safe
@("entity: EntityManager: gen")
unittest
{
	import std.range : front;
	auto em = new EntityManager!uint();

	assertEquals(Entity!(uint)(0), em.gen());
	assertEquals(1, em.entities.length);
	assertEquals(Entity!(uint)(0), em.entities.front);
}

@safe
@("entity: EntityManager: gen with components")
unittest
{
	import std.range : front;
	auto em = new EntityManager!uint();

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

@safe
@("entity: EntityManager: recycle")
unittest
{
	import std.range : front;
	auto em = new EntityManager!uint();

	auto entity0 = em.gen(); // calls fabricate
	em.discard(entity0); // discards
	(() @trusted => assertEquals(Entity!uint(0, 1), em.queue))(); // batch was incremented
	assertFalse(Entity!uint(0, 1) == entity0); // entity's batch is not updated

	entity0 = em.gen(); // recycles
	assertEquals(Entity!uint(0, 1), em.entities.front);
}

@safe
@("entity: EntityManager: remove")
unittest
{
	auto em = new EntityManager!size_t();

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
	assertFalse(em.removeAll(Entity!size_t(15)));

	// cannot call with invalid components
	assertFalse(__traits(compiles, em.remove!InvalidComponent(e)));
}

@safe
@("entity: EntityManager: set")
unittest
{
	auto em = new EntityManager!uint();

	auto e = em.gen();
	assertTrue(em.set(e, Foo(4, 5)));
	assertFalse(em.set(Entity!uint(0, 5), Foo(4, 5)));
	assertFalse(em.set(Entity!uint(2), Foo(4, 5)));
	assertEquals(Foo(4, 5), *em.storageInfoMap[componentId!Foo].getStorage!(Foo).get(e));

	assertTrue(em.set(em.gen(), Foo(4, 5), Bar("str")));
	assertTrue(em.set!(Foo, Bar, ValidComponent)(em.gen()));

	assertFalse(__traits(compiles, em.set!(Foo, Bar, ValidComponent, Bar)(em.gen())));
	assertFalse(__traits(compiles, em.set(em.gen(), Foo(4, 5), Bar("str"), Foo.init)));
	assertFalse(__traits(compiles, em.set!(Foo, Bar, InvalidComponent)(em.gen())));
	assertFalse(__traits(compiles, em.set!(InvalidComponent)(em.gen())));
}
