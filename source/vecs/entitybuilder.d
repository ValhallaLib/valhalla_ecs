module vecs.entitybuilder;

import vecs.entity;
import vecs.entitymanager;

import std.traits : isInstanceOf;

version(vecs_unittest) import aurorafw.unit.assertion;


/**
 * Helper struct to perform multiple action sequences.
 */
struct EntityBuilder(EntityManagerT)
	if (isInstanceOf!(.EntityManagerT, EntityManagerT))
{
public:
	bool opEquals(R)(in R other) const
	{
		return entity == other;
	}

	/**
	Add `Components` to an `entity`. `Components` are contructed according to
	their dafault initializer.

	Attempting to use an invalid entity leads to undefined behavior.

	Signal: emits `onSet` after each component is assigned.

	Params:
		Components = Component types to add.

	Returns: This instance.
	*/
	EntityBuilder add(Components...)()
	{
		entityManager.addComponent!Components(entity);
		return this;
	}

	/**
	Assigns the `Component` to the `entity`. The `Component` is initialized with
	the `args` provided.

	Attempting to use an invalid entity leads to undefined behavior.

	Signal: emits `onSet` after each component is assigned.

	Params:
		Component = Component type to emplace.
		args = arguments to contruct the Component type.

	Returns: This instance.
	*/
	EntityBuilder emplace(Component, Args...)(auto ref Args args)
	{
		entityManager.emplaceComponent!Component(entity, args);
		return this;
	}

	/**
	Assigns the components to an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Signal: emits `onSet` after each component is assigned.

	Params:
		components = components to assign.

	Returns: This instance.
	*/
	EntityBuilder set(Components...)(Components components)
	{
		entityManager.setComponent!Components(entity, components);
		return this;
	}

	/**
	Patch a component of an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Params:
		Components: Component types to patch.
		callbacks: callbacks to call for each Component type.

	Returns: This instance.
	*/
	template patch(Components...)
	{
		EntityBuilder patch(Callbacks...)(Callbacks callbacks)
		{
			entityManager.patchComponent!Components(entity, callbacks);
			return this;
		}
	}

	/**
	Removes components from an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Signal: emits $(LREF onRemove) before each component is removed.

	Params:
		Components = Component types to remove.

	Returns: This instance.
	*/
	EntityBuilder remove(Components...)()
	{
		entityManager.removeComponent!Components(entity);
		return this;
	}

	/**
	Removes all components from an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Signal: emits $(LREF onRemove) before each component is removed.

	Returns: This instance.
	*/
	EntityBuilder removeAll()()
	{
		entityManager.removeAllComponents(entity);
		return this;
	}

	/**
	Removes all components from an entity and releases it.

	Attempting to use an invalid entity leads to undefined behavior.

	Signal: emits `onRemove` before each component is removed.

	Params:
		batch = batch to update upon release.

	Returns: This instance.
	*/
	EntityBuilder destroy()()
	{
		entityManager.destroyEntity(entity);
		return this;
	}

	/// Ditto
	EntityBuilder destroy()(in size_t batch)
	{
		entityManager.destroyEntity(entity, batch);
		return this;
	}

	/**
	Releases a `shallow entity`. It's `id` is released and the `batch` is updated
	to be ready for the next recycling.

	Attempting to use an invalid entity leads to undefined behavior.

	Params:
		batch = batch to update upon release.

	Returns: This instance.
	*/
	EntityBuilder release()()
	{
		entityManager.releaseEntity(entity);
		return this;
	}

	/// Ditto
	EntityBuilder release()(in size_t batch)
	{
		entityManager.releaseEntity(entity, batch);
		return this;
	}


	Entity entity = nullentity;
	alias entity this;

	EntityManagerT entityManager;
}
