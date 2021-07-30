module vecs.queryfilter;

import vecs.entity : Entity;
import vecs.storage : areComponents, ComponentId, StorageInfo;

import std.meta : allSatisfy, NoDuplicates, staticMap;
import std.traits : isInstanceOf, TemplateArgsOf;
import std.typecons : Tuple;

///
enum areFilterArgs(T ...) = areComponents!T;

///
enum isFilter(T) = isInstanceOf!(With, T) || isInstanceOf!(Without, T);

/**
 * Filter entities with the T components
 */
struct With(T ...)
	if (areFilterArgs!T)
{
package:
	@safe pure nothrow @nogc
	this(StorageInfo[] sinfos)
	{
		this.sinfos = sinfos;
	}

	@safe pure nothrow @nogc
	bool opCall(in Entity e)
	{
		foreach (sinfo; sinfos)
			if (!sinfo.contains(e))
				return false;

		return true;
	}

	StorageInfo[] sinfos;
}


/**
 * Filter entities without the T components
 */
struct Without(T ...)
	if (areFilterArgs!T)
{
package:
	@safe pure nothrow @nogc
	this(StorageInfo[] sinfos)
	{
		this.sinfos = sinfos;
	}

	@safe pure nothrow @nogc
	bool opCall(in Entity e)
	{
		foreach (sinfo; sinfos)
			if (sinfo.contains(e))
				return false;

		return true;
	}

	StorageInfo[] sinfos;
}


///
package struct QueryFilter(Filter)
	if (isFilter!Filter)
{
	@safe pure nothrow @nogc
	this(Filter filter)
	{
		this.filter = filter;
	}

	@safe pure nothrow @nogc
	bool validate(in Entity e) {
		return filter(e);
	}

	Filter filter;
}


///
package struct QueryFilter(FilterTuple)
	if (isInstanceOf!(Tuple, FilterTuple) && allSatisfy!(isFilter, TemplateArgsOf!(FilterTuple)))
{
	@safe pure nothrow @nogc
	this(FilterTuple filters)
	{
		this.filters = filters;
	}

	@safe pure nothrow @nogc
	bool validate(in Entity e) {
		foreach (filter; filters)
			if (!filter(e))
				return false;

		return true;
	}

	FilterTuple filters;
}
