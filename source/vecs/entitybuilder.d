module vecs.entitybuilder;

import vecs.entity;

version(vecs_unittest) import aurorafw.unit.assertion;


/**
 * Helper struct to perform multiple action sequences.
 */
struct EntityBuilder
{
public:
	@safe pure nothrow @nogc
	this(EntityManager em)
	{
		this.em = em;
	}


	/// Uses EntityManager's gen method
	@safe pure
	auto gen()
	{
		entities ~= em.gen();
		return this;
	}


	/// Ditto
	auto gen(ComponentRange ...)()
	{
		entities ~= em.gen!(ComponentRange)();
		return this;
	}


	/// Ditto
	auto gen(ComponentRange ...)(ComponentRange components)
	{
		entities ~= em.gen(components);
		return this;
	}


	/**
	 * Gets all entities generated with an instance of EntityBuilder.
	 *
	 * Returns: `Entity[]` with the generated entities.
	 */
	@safe pure nothrow @nogc
	Entity[] get()
	{
		return entities;
	}


private:
	Entity[] entities;
	EntityManager em;
}


@system
@("entitybuilder: entityBuilder")
unittest
{
	import vecs.storage;
	EntityManager em = new EntityManager();
	auto entities = em.entityBuilder
		.gen()
		.gen()
		.gen()
		.get();

	assertEquals([Entity(0), Entity(1), Entity(2)], entities);

	entities = em.entityBuilder
		.gen!(Foo)()
		.gen()
		.gen(Bar("str"))
		.gen!(Foo, int)()
		.get();

	assertEquals([Entity(3), Entity(4), Entity(5), Entity(6)], entities);

	assertFalse(__traits(compiles, em.entityBuilder.gen!(Foo, Bar, Foo)()));
	assertFalse(__traits(compiles, em.entityBuilder.gen(Foo.init, Bar.init, Foo(3, 4))));
	assertFalse(__traits(compiles, em.entityBuilder.gen!(Foo, Bar, immutable(int))()));
}
