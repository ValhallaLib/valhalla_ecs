module vecs.signal;

version(vecs_unittest) import aurorafw.unit.assertion;

import std.traits : isDelegate, Parameters, OriginalType;
import std.traits : FunctionAttribute, functionAttributes, SetFunctionAttributes;

alias Signal(T...) = SignalT!(void delegate(T));
struct SignalT(Slot)
	if (isDelegate!Slot)
{
	template attributes(alias attrs)
		if (is(typeof(attrs) : OriginalType!FunctionAttribute))
	{
		alias attributes = SignalT!(SetFunctionAttributes!(Slot, "D", attrs));
	}


	template attributes(alias slot)
		if (is(slot : void delegate()))
	{
		alias attributes = SignalT!slot;
	}


	template parameters(alias slot)
		if (is(slot : void delegate(Args), Args...))
	{
		alias parameters = SignalT!(SetFunctionAttributes!(slot, "D", functionAttributes!Slot));
	}


	void connect(Slot slot)
	{
		import std.algorithm : canFind;

		if (!slots.canFind(slot))
			slots ~= slot;
	}


	void disconnect(Slot slot)
	{
		import std.algorithm : countUntil, remove, SwapStrategy;
		immutable index = slots.countUntil(slot);

		if (index != -1)
			slots = slots.remove!(SwapStrategy.unstable)(index);
	}


	void emit(Parameters!Slot args)
	{
		foreach (slot; slots) slot(args);
	}

	Slot[] slots;
}

@system
@("signal: empty")
unittest
{
	Signal!() sig; // empty signal
	size_t num;
	auto fun = () { num++; };

	sig.connect(fun);
	sig.emit();
	assertEquals(1, num);

	sig.disconnect(fun);
	sig.emit();
	assertEquals(1, num);
}

@system
@("signal: different instances having the same Signal type")
unittest
{
	Signal!(int) sigA;
	Signal!(int) sigB;
	size_t num;

	sigA.connect((int x) { num = x; });
	sigB.connect((int x) { num += x; });

	sigA.emit(4);
	sigB.emit(16);
	assertEquals(20, num);
}

@system
@("signal: using a function")
unittest
{
	import std.functional : toDelegate;
	Signal!(size_t*) sig;
	size_t num;

	auto fun = function(size_t* n) { (*n)++; };
	sig.connect(toDelegate(fun));

	sig.emit(&num);
	assertEquals(1, num);
}
