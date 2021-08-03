module vecs.queryworld;

import vecs.entity;
import vecs.entitymanager;
import vecs.storage;

import std.format : format;
import std.range : iota;
import std.traits : isInstanceOf, TemplateArgsOf;
import std.typecons : Tuple, tuple;


package struct QueryWorld(Output : Entity)
{
	@safe pure nothrow @nogc
	this(immutable Entity[] entities)
	{
		this.entities = entities;
	}

	@safe pure nothrow @nogc
	void popFront()
	{
		entities = entities[1..$];
	}

	@safe pure nothrow @nogc @property
	bool empty()
	{
		return entities.length == 0;
	}

	@safe pure nothrow @nogc @property
	Entity front()
	{
		return entities[0];
	}

	immutable(Entity)[] entities;
}


alias QueryWorld(T : Tuple!Entity) = QueryWorld!Entity;


package struct QueryWorld(Output)
	if (isComponent!Output)
{
	@safe pure nothrow @nogc
	this(immutable Entity[] entities, Output[] components)
		in (entities.length == components.length)
	{
		this.entities = entities;
		this.components = components;
	}

	@safe pure nothrow @nogc
	void popFront()
	{
		entities = entities[1..$];
		components = components[1..$];
	}

	@safe pure nothrow @nogc @property
	bool empty()
	{
		return entities.length == 0;
	}

	@safe pure nothrow @nogc @property
	Output* front()
	{
		return &components[0];
	}

	immutable(Entity)[] entities;
	Output[] components;
}


package struct QueryWorld(OutputTuple)
	if (isInstanceOf!(Tuple, OutputTuple))
{
	@safe pure nothrow @nogc
	this(immutable Entity[] entities, StorageInfo[] sinfos)
	{
		this.entities = entities;
		this.sinfos = sinfos;
		_prime();
	}

	@safe pure nothrow @nogc
	void _prime()
	{
		while (!empty && !_validate())
			popFront();
	}

	@safe pure nothrow @nogc
	bool _validate()
	{
		foreach (sinfo; sinfos)
			if (!sinfo.contains(entities[0]))
				return false;

		return true;
	}

	@safe pure nothrow @nogc
	void popFront()
	{
		do {
			entities = entities[1..$];
		} while (!empty && !_validate());
	}

	@safe pure nothrow @nogc @property
	bool empty()
	{
		return entities.length == 0;
	}

	@safe pure nothrow @nogc @property
	auto front()
	{
		immutable e = entities[0];
		enum components = format!q{%(sinfos[%s].get!(Components[%s]).get(e)%|,%)}(Components.length.iota);
		static if (is(Out[0] == Entity))
			return mixin(format!q{tuple(e, %s)}(components));
		else
			return mixin(format!q{tuple(%s)}(components));
	}

	alias Out = TemplateArgsOf!OutputTuple;
	static if (is(Out[0] == Entity))
		alias Components = Out[1..$];
	else
		alias Components = Out;

	immutable(Entity)[] entities;
	StorageInfo[] sinfos;
}
