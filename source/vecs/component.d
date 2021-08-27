module vecs.component;

import vecs.entity;

import std.meta : All = allSatisfy;
import std.traits : isAssignable;
import std.traits : isCopyable, isSomeChar;
import std.traits : isSomeFunction;

/**
Checks if a type is a valid Component type.

Params:
	T = a type to evaluate.

Returns: True if the type is a Component type, false otherwise.
*/
enum isComponent(T) = !(is(T == class)
	|| is(T == union)
	|| isSomeFunction!T
	|| !isCopyable!T
	|| isSomeChar!T
	|| is(T == Entity)
	|| !isAssignable!T
);

///
@("[isComponent] valid components")
@safe pure nothrow @nogc unittest
{
	import std.meta : AliasSeq, staticMap;
	import std.traits : PointerTarget;

	struct Empty { }
	struct MutableMembers { string str; int i; }

	assert(isComponent!Empty);
	assert(isComponent!MutableMembers);

	alias PtrIntegrals  = AliasSeq!(byte*, short*, int*, long*);
	alias PtrUIntegrals = AliasSeq!(ubyte*, ushort*, uint*, ulong*);
	alias Strings       = AliasSeq!(string, dstring, wstring);
	alias Integrals     = staticMap!(PointerTarget, PtrIntegrals);
	alias UIntegrals    = staticMap!(PointerTarget, PtrUIntegrals);

	static foreach (T; AliasSeq!(PtrIntegrals, PtrUIntegrals, Integrals, UIntegrals, Strings))
		assert(isComponent!T);
}

///
@("[isComponent] invalid components")
@safe pure nothrow @nogc unittest
{
	class Class {}
	union Union {}
	struct ImmutableMembers { immutable int x; }
	struct ConstMembers { const string x; }
	void FunctionPointer() {}

	assert(!isComponent!Entity);
	assert(!isComponent!Class);
	assert(!isComponent!Union);
	assert(!isComponent!ImmutableMembers);
	assert(!isComponent!ConstMembers);
	assert(!isComponent!(void function()));
	assert(!isComponent!(int delegate()));
	assert(!isComponent!(typeof(FunctionPointer)));
	assert(!isComponent!char);
	assert(!isComponent!wchar);
}

template TypeInfoComponent(Component)
	if (isComponent!Component)
{
	enum TypeInfoComponent = typeid(Component);
}

@safe nothrow @nogc
private static size_t nextId()
{
	import core.atomic : atomicOp;

	shared static size_t value;
	return value.atomicOp!"+="(1);
}

template ComponentId(Component)
	if (isComponent!Component)
{
	size_t ComponentId()
	{
		auto ComponentIdImpl = ()
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

		import vecs.utils : assumePure;
		return (() @trusted pure nothrow @nogc => assumePure(ComponentIdImpl)())();
	}
}

@("[ComponentId] multithreaded")
unittest
{
	import std.algorithm : each;
	import core.thread.osthread;

	struct A {}
	struct B {}

	Thread[2] threads;
	size_t[2] ids;

	threads[0] = new Thread(() {
		ids[0] = ComponentId!A;
	}).start();

	threads[1] = new Thread(() {
		ids[1] = ComponentId!B;
	}).start();

	threads.each!"a.join()";

	assert(ids[0] != ids[1]);
}
