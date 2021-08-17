module vecs.entitybuilder;

import vecs.entity;
import vecs.entitymanager;

version(vecs_unittest) import aurorafw.unit.assertion;


/**
 * Helper struct to perform multiple action sequences.
 */
struct EntityBuilder(EntityManagerT)
	if (is(EntityManagerT == E!T, alias E = .EntityManagerT, T))
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
	Assigns the Components to an entity. The Components are initialized with
	the args provided.

	Attempting to use an invalid entity leads to undefined behavior.

	Signal: emits `onSet` after each component is assigned.

	Params:
		Components = Component types to emplace.
		args = arguments to contruct the Component types.

	Returns: This instance.
	*/
	template emplace(Components...)
		if (Components.length)
	{
		import core.lifetime : forward;

		static if (Components.length == 1)
		{
			EntityBuilder emplace(Args...)(auto ref Args args)
			{
				entityManager.emplaceComponent!Components(entity, forward!args);
				return this;
			}
		}
		else
		{
			EntityBuilder emplace(auto ref Components args)
			{
				entityManager.emplaceComponent!Components(entity, forward!args);
				return this;
			}
		}
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
	Replaces components of an entity.

	Attempting to use an invalid entity leads to undefined behavior.

	Params:
		Components: Component types to replace.
		args: arguments to contruct the Component types.

	Returns: This instance.
	*/
	template replace(Components...)
	{
		static if (Components.length == 1)
		{
			EntityBuilder replace(Args...)(auto ref Args args)
			{
				import core.lifetime : forward;

				entityManager.replaceComponent!Components(entity, forward!args);
				return this;
			}
		}
		else
		{
			EntityBuilder replace(auto ref Components args)
			{
				import core.lifetime : forward;

				entityManager.replaceComponent!Components(entity, forward!args);
				return this;
			}
		}
	}

	/**
	Replaces or emplaces components of an entity if it owes or not the same
	Component types.

	Attempting to use an invalid entity leads to undefined behavior.

	Params:
		Components: Component types to emplace or replace.
		args: arguments to contruct the Component types.

	Returns: This instance.
	*/
	template emplaceOrReplace(Components...)
	{
		static if (Components.length == 1)
		{
			EntityBuilder emplaceOrReplace(Args...)(auto ref Args args)
			{
				import core.lifetime : forward;

				entityManager.emplaceOrReplaceComponent!Components(entity, forward!args);
				return this;
			}
		}
		else
		{
			EntityBuilder emplaceOrReplace(auto ref Components args)
			{
				import core.lifetime : forward;

				entityManager.emplaceOrReplaceComponent!Components(entity, forward!args);
				return this;
			}
		}
	}

	/**
	Replaces a component of an entity with the init state of the Component type
	if it owes it.

	Attempting to use an invalid entity leads to undefined behavior.

	Params:
		Comonents: Component types to replace.

	Returns: This instance.
	*/
	EntityBuilder reset(Components...)()
	{
		entityManager.resetComponent!Components(entity);
		return this;
	}

	/**
	Adds or replaces a component of an entity with the init state of the
	Component type if it owes it.

	Attempting to use an invalid entity leads to undefined behavior.

	Params:
		Comonents: Component types to add or replace.

	Returns: This instance.
	*/
	EntityBuilder addOrReset(Components...)()
	{
		entityManager.addOrResetComponent!Components(entity);
		return this;
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
