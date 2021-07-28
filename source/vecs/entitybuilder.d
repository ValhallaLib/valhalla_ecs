module vecs.entitybuilder;

import vecs.entity;

version(vecs_unittest) import aurorafw.unit.assertion;


/**
 * Helper struct to perform multiple action sequences.
 */
struct EntityBuilder
{
public:
	// FIXME: documentation
	EntityBuilder add(Components...)()
	{
		em.addComponent!Components(entity);
		return this;
	}

	// FIXME: documentation
	EntityBuilder emplace(Component, Args...)(auto ref Args args)
	{
		em.emplaceComponent!Component(entity, args);
		return this;
	}

	// FIXME: documentation
	EntityBuilder set(Components...)(Components components)
	{
		em.setComponent!Components(entity, components);
		return this;
	}

	// FIXME: documentation
	EntityBuilder remove(Components...)()
	{
		em.removeComponent!Components(entity);
		return this;
	}

	// FIXME: documentation
	EntityBuilder removeAll()()
	{
		em.removeAllComponents(entity);
		return this;
	}

	// FIXME: documentation
	EntityBuilder destroy()()
	{
		em.destroyEntity(entity);
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
		entity.add!Foo,
		entity,
		entity.set(Bar("str")),
		entity.add!(Foo, int),
	];

	assertEquals([Entity(3), Entity(4), Entity(5), Entity(6)], entts);
}
