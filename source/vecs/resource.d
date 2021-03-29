module vecs.resource;

version(vecs_unittest)
{
	import aurorafw.unit.assertion;
	import vecs.entity;
}


///
@safe nothrow @nogc
private static size_t nextId()
{
	static size_t value;
	return value++;
}


///
template ResourceId(Res)
{
	size_t ResourceId()
	{
		auto ResourceIdImpl = ()
		{
			static bool initialized;
			static size_t id;

			if (!initialized)
			{
				id = nextId();
				initialized = true;
			}

			return id;
		};

		import vecs.storage : assumePure;
		return (() @trusted pure nothrow @nogc => assumePure(ResourceIdImpl)())();
	}
}


enum isResource(R) = is(R == class)
	|| is(R == struct)
	|| is(R == enum);


/**
 * A wrapper to store any data type.
 */
package struct Resource
{
	void[] data;
}


version(vecs_unittest)
{
	struct State { string name; }
	class CState
	{
		@safe pure nothrow @nogc
		this(float a, float b) { fa = a; fb = b; }

		@safe pure nothrow @nogc
		override bool opEquals(const Object other) const
		{
			CState rhs = (() @trusted pure nothrow @nogc => cast(CState) other)();
			if (rhs is null) return false;
			return fa == rhs.fa && fb == rhs.fb;
		}

		float fa,fb;
	}
	enum EState { a, b }
}

@("resource: Resource")
@system
unittest
{
	auto em = new EntityManager();

	em.addResource!State;
	assertEquals("", em.resource!State.name);

	em.addResource!CState;
	assertNull(em.resource!CState);

	// replace old CState resource
	em.addResource(new CState(2f, 5f));
	assertEquals(new CState(2f, 5f), em.resource!CState);

	em.addResource(EState.b);
	assertEquals(EState.b, em.resource!EState);

	assertFalse(__traits(compiles, em.addResource!(int)()));
	assertFalse(__traits(compiles, em.addResource!(int[])()));
	assertFalse(__traits(compiles, em.addResource!(State*)()));
}
