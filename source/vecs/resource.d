module vecs.resource;

version(vecs_unittest) import vecs.entitymanager;


///
@safe nothrow @nogc
private static size_t nextId()
{
	shared static size_t value;

	import core.atomic : atomicOp;
	return value.atomicOp!"+="(1);
}


///
template ResourceId(Res)
{
	size_t ResourceId()
	{
		auto ResourceIdImpl = ()
		{
			shared static bool initialized;
			shared static size_t id;

			if (!initialized)
			{
				import core.atomic : atomicStore;
				id.atomicStore(nextId());
				initialized.atomicStore(true);
			}

			return id;
		};

		import vecs.storage : assumePure;
		return (() @trusted pure nothrow @nogc => assumePure(ResourceIdImpl)())();
	}
}


///
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

	import std.string : empty;
	assert(em.resource!State.name.empty);

	em.addResource!CState;
	assert(!em.resource!CState);

	// replace old CState resource
	em.addResource(new CState(2f, 5f));
	assert(em.resource!CState == new CState(2f, 5f));

	em.addResource(EState.b);
	assert(em.resource!EState == EState.b);

	assert(!__traits(compiles, em.addResource!(int)()));
	assert(!__traits(compiles, em.addResource!(int[])()));
	assert(!__traits(compiles, em.addResource!(State*)()));
}


@("resource: Resource multithreaded")
@system
unittest
{
	import std.algorithm : each;
	import core.thread.osthread;
	Thread[2] threads;
	size_t[2] ids;

	threads[0] = new Thread(() {
		ids[0] = ResourceId!State;
	}).start();

	threads[1] = new Thread(() {
		ids[1] = ResourceId!CState;
	}).start();

	threads.each!"a.join()";

	assert(ids[0] != ids[1]);
}
