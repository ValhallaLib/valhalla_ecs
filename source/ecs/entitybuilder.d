module ecs.entitybuilder;

import ecs.entity;

version(unittest) import aurorafw.unit.assertion;


/**
 * Helper struct to perform multiple actions sequences.
 *
 * Params: em = an entity manager to update.
 */
struct EntityBuilder
{
public:
	@safe pure
	this(EntityManager em)
	{
		this.em = em;
	}


	@safe pure
	auto gen()
	{
		entities ~= em.gen();
		return this;
	}


	auto gen(ComponentRange ...)()
	{
		entities ~= em.gen!(ComponentRange)();
		return this;
	}


	auto gen(ComponentRange ...)(ComponentRange components)
	{
		entities ~= em.gen(components);
		return this;
	}


	@safe pure
	auto get()
	{
		return entities;
	}


private:
	Entity[] entities;
	EntityManager em;
}


@safe pure
@("entitybuilder: entityBuilder")
unittest
{
	import ecs.storage;
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
