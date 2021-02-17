module ecs.queryworld;

import ecs.entity;
import ecs.storage;

import std.format : format;
import std.range : iota;
import std.traits : isInstanceOf, TemplateArgsOf;
import std.typecons : Tuple, tuple;

@safe
package struct QueryWorld(Output : Entity)
{
	this(immutable Entity[] entities)
	{
		this.entities = entities;
	}

	void popFront()
	{
		entities = entities[1..$];
	}

	@property
	bool empty()
	{
		return entities.length == 0;
	}

	@property
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
	this(immutable Entity[] entities, Output[] components)
	{
		this.entities = entities;
		this.components = components;
	}

	void popFront()
	{
		entities = entities[1..$];
		components = components[1..$];
	}

	@property
	bool empty()
	{
		return entities.length == 0;
	}

	@property
	Output* front()
	{
		return &components[0];
	}

	immutable(Entity)[] entities;
	Output[] components;
}


@safe
package struct QueryWorld(OutputTuple)
	if (isInstanceOf!(Tuple, OutputTuple))
{
	this(immutable Entity[] entities, StorageInfo[] sinfos)
	{
		this.entities = entities;
		this.sinfos = sinfos;
		_prime();
	}

	void _prime()
	{
		while (!empty && !_validate())
			popFront();
	}

	bool _validate()
	{
		foreach (sinfo; sinfos)
			if (!sinfo.has(entities[0]))
				return false;

		return true;
	}

	void popFront()
	{
		do {
			entities = entities[1..$];
		} while (!empty && !_validate());
	}

	@property
	bool empty()
	{
		return entities.length == 0;
	}

	@property
	auto front()
	{
		auto e = entities[0];
		enum components = format!q{%(sinfos[%s].get!(Components[%s]).get(entities[0])%|,%)}(Components.length.iota);
		static if (is(Out[0] == Entity))
			return mixin(format!q{tuple(entities[0], %s)}(components));
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
