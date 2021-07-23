module vecs.entitybuilder;

import vecs.entity;

version(vecs_unittest) import aurorafw.unit.assertion;


/**
 * Helper struct to perform multiple action sequences.
 */
struct EntityBuilder
{
public:
	EntityBuilder set(Component)(Component component = Component.init)
	{
		em.set!Component(entity, component);
		return this;
	}


	immutable Entity entity = EntityManager.entityNull;
	alias entity this;

package:
	EntityManager em;
}

@system
@("entitybuilder: entityBuilder")
unittest
{
	import vecs.storage;
	EntityManager em = new EntityManager();

	Entity[] entts;
	with(em) entts = [
		entity,
		entity,
		entity,
	];

	assertEquals([Entity(0), Entity(1), Entity(2)], entts);

	with(em) entts = [
		entity.set!Foo,
		entity,
		entity.set(Bar("str")),
		entity.set!Foo.set!int,
	];

	assertEquals([Entity(3), Entity(4), Entity(5), Entity(6)], entts);
}
