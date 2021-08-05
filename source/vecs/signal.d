module vecs.signal;

version(vecs_unittest) import aurorafw.unit.assertion;

import std.functional : toDelegate;
import std.traits : isDelegate, Parameters, OriginalType;
import std.traits : FunctionAttribute, functionAttributes, SetFunctionAttributes;

alias Signal = SignalT!(void delegate());

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


	void connect(Fun : void function(Parameters!Slot))(Fun slot)
		if (is(typeof(slot.toDelegate()) : Slot))
	{
		// workarround for toDelegate bug not working with @safe functions
		static if (is(Slot : void delegate(Parameters!Slot) @safe))
			(() @trusted pure nothrow => connect(slot.toDelegate()))();
		else
			connect(slot.toDelegate());
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

private:
	Slot[] slots;
}

///
@("[Signal] basic usage")
@safe pure nothrow unittest
{
	SignalT!(void delegate() @safe pure nothrow @nogc) sig;

	size_t num;

	auto runtest = {
		sig.emit();
		assert(num == 1);
	};

	auto fun = () { num++; };

	sig.connect(fun);
	runtest();

	sig.disconnect(fun);
	runtest();
}

///
@("[Signal] function callbacks")
@safe pure nothrow unittest
{
	SignalT!(void delegate(ref size_t) @safe pure nothrow @nogc) sig;

	size_t num;
	auto fun = function(ref size_t n) @safe pure nothrow @nogc { n++; };

	sig.connect(fun);
	sig.emit(num);

	assert(num == 1);
}

@("[Signal] restrictions")
@safe pure nothrow unittest
{
	static assert(!__traits(compiles, SignalT!(void function() @safe pure nothrow @nogc)));
	static assert(!__traits(compiles, SignalT!(void delegate() @safe).init.connect(() @system {})));

	static assert( __traits(compiles, SignalT!(void delegate() pure).init.connect(() @safe {})));
	static assert( __traits(compiles, SignalT!(void delegate()).init.connect(() @safe {})));
	static assert( __traits(compiles, SignalT!(void delegate() @system).init.connect(() @safe {})));

	static assert(!__traits(compiles, Signal.attributes!(void function())));
	static assert(!__traits(compiles, Signal.attributes!(void delegate(int))));
	static assert(!__traits(compiles, Signal.parameters!(void function(int))));
}

///
@("[Signal] using the builder")
@safe pure nothrow @nogc unittest
{
	{
		alias MySignal = Signal
			.attributes!(void delegate() @safe pure nothrow @nogc)
			.parameters!(void delegate(int));

		static assert(is(MySignal == SignalT!(void delegate(int) @safe pure nothrow @nogc)));
	}

	{
		alias MySignal = Signal
			.attributes!(void delegate() @safe pure nothrow @nogc)
			.attributes!(void delegate() @safe @nogc) // overrides
			.parameters!(void delegate(int))
			.parameters!(void delegate(ref int)); // overrides

		static assert(is(MySignal == SignalT!(void delegate(ref int) @safe @nogc)));
	}
}
