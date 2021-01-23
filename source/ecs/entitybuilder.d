module ecs.entitybuilder;

import ecs.entity;

version(unittest) import aurorafw.unit.assertion;


/**
 * Helper struct to perform multiple actions sequences.
 *
 * Params: em = an entity manager to update.
 *
 * Returns: an EntityBuilder!EntityType.
 */
auto entityBuilder(EntityType)(EntityManager!EntityType em)
{
	return EntityBuilder!EntityType(em);
}

@("entitybuilder: entityBuilder")
unittest
{
	import ecs.storage;
	EntityManager!uint em = new EntityManager!uint();
	auto entities = em.entityBuilder
		.gen()
		.gen()
		.gen()
		.get();

	assertEquals([Entity!uint(0), Entity!uint(1), Entity!uint(2)], entities);

	entities = em.entityBuilder
		.gen!(Foo)()
		.gen()
		.gen(Bar("str"))
		.gen!(Foo, ValidComponent)()
		.get();

	assertEquals([Entity!uint(3), Entity!uint(4), Entity!uint(5), Entity!uint(6)], entities);

	assertFalse(__traits(compiles, em.entityBuilder.gen!(Foo, Bar, Foo)()));
	assertFalse(__traits(compiles, em.entityBuilder.gen(Foo.init, Bar.init, Foo(3, 4))));
	assertFalse(__traits(compiles, em.entityBuilder.gen!(Foo, Bar, InvalidComponent)()));
}


/**
 * Helper struct to perform multiple actions sequences.
 *
 * Params:
 *     EntityType = a valid entity type.
 *     em = an entity manager to update.
 */
struct EntityBuilder(EntityType)
{
public:
	this(EntityManager!EntityType em)
	{
		this.em = em;
	}


	@safe
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


	@safe
	auto get()
	{
		return entities;
	}


private:
	Entity!(EntityType)[] entities;
	EntityManager!EntityType em;
}
