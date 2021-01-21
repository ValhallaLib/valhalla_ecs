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
	EntityManager!uint em = new EntityManager!uint();
	auto entitites = em.entityBuilder
		.gen()
		.gen()
		.gen()
		.get();

	assertEquals([Entity!uint(0), Entity!uint(1), Entity!uint(2)], entitites);
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


	@safe
	auto get() const
	{
		return entities;
	}


private:
	Entity!(EntityType)[] entities;
	EntityManager!EntityType em;
}
