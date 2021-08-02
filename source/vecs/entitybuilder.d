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
