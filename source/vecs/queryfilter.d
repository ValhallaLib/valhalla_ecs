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
	this(StorageInfo[] sinfos)
	{
		this.sinfos = sinfos;
	}

	bool opCall(in Entity e)
	{
		foreach (sinfo; sinfos)
			if (!sinfo.has(e))
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
	this(StorageInfo[] sinfos)
	{
		this.sinfos = sinfos;
	}

	bool opCall(in Entity e)
	{
		foreach (sinfo; sinfos)
			if (sinfo.has(e))
				return false;

		return true;
	}

	StorageInfo[] sinfos;
}


///
package struct QueryFilter(Filter)
	if (isFilter!Filter)
{
	this(Filter filter)
	{
		this.filter = filter;
	}

	bool validate(in Entity e) {
		return filter(e);
	}

	Filter filter;
}


///
package struct QueryFilter(FilterTuple)
	if (isInstanceOf!(Tuple, FilterTuple) && allSatisfy!(isFilter, TemplateArgsOf!(FilterTuple)))
{
	this(FilterTuple filters)
	{
		this.filters = filters;
	}

	bool validate(in Entity e) {
		foreach (filter; filters)
			if (!filter(e))
				return false;

		return true;
	}

	FilterTuple filters;
}
