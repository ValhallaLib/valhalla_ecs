module app;

import vecs.entity;
import vecs.storage;
import vecs.query;
import vecs.queryfilter;

import std.algorithm : each;
import std.datetime.stopwatch : benchmark;
import std.range : iota;
import std.stdio;
import std.typecons : Tuple;

struct PositionComponent
{
	float x = 0.0f;
	float y = 0.0f;
}

struct DirectionComponent
{
	float x = 0.0f;
	float y = 0.0f;
}

struct ComflabulationComponent
{
	float thingy = 0.1f;
	int dingy;
	bool mingy;
	string stringy = "";
}

void main()
{
	auto em = new EntityManager();
	enum Loops = 100_000;

	3_000.iota.each!(i => em.gen!(PositionComponent)());
	3_000.iota.each!(i => em.gen!(PositionComponent, DirectionComponent)());
	1_000.iota.each!(i => em.gen!(ComflabulationComponent, DirectionComponent)());
	1_000.iota.each!(i => em.gen!(ComflabulationComponent, DirectionComponent, PositionComponent)());
	2_000.iota.each!(i => em.gen!(DirectionComponent, ComflabulationComponent)());

	benchmark!({
		foreach (pos, dir; em.query!(Tuple!(PositionComponent, DirectionComponent)))
		{
			pos.x += dir.x * 0.15;
			pos.y += dir.y * 0.15;
		}
	},{
		foreach (com; em.query!(ComflabulationComponent))
		{
			com.thingy *= 1.0000001f;
			com.dingy++;
			com.mingy = !com.mingy;
		}
	},{
		foreach (pos, dir, com; em.query!(Tuple!(PositionComponent, DirectionComponent, ComflabulationComponent)))
		{
			if ((com.mingy = !com.mingy) == false)
			{
				com.dingy++;

				pos.x += dir.x * com.thingy;
				pos.y += dir.y * com.thingy;
			}

			com.thingy *= 1.0000001f;
		}
	},{
		foreach (pos, i; em.query!(Tuple!(PositionComponent, int)))
		{
			pos.x++;
		}
	},{
		foreach (pos, dir; em.query!(Tuple!(PositionComponent, DirectionComponent), With!(ComflabulationComponent)))
		{
			pos.x += dir.x * 0.15;
			pos.y += dir.y * 0.15;
		}
	})(Loops).each!(dur => writeln(dur/Loops));
}
