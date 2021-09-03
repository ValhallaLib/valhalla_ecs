module app;

import vecs;

import std.algorithm : std_each = each;
import std.datetime.stopwatch : benchmark;
import std.range : iota;
import std.stdio;

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
	auto world = new EntityManager();
	enum Loops = 100_000;

	with (world)
	{
		3_000.iota.std_each!(i => entity.add!PositionComponent);
		3_000.iota.std_each!(i => entity.add!(PositionComponent, DirectionComponent));
		1_000.iota.std_each!(i => entity.add!(ComflabulationComponent, DirectionComponent));
		1_000.iota.std_each!(i => entity.add!(ComflabulationComponent, DirectionComponent, PositionComponent));
		2_000.iota.std_each!(i => entity.add!(DirectionComponent, ComflabulationComponent));
	}

	with (world) benchmark!({
		foreach (_, pos, dir; query!(PositionComponent, DirectionComponent).each())
		{
			pos.x += dir.x * 0.15;
			pos.y += dir.y * 0.15;
		}
	},{
		foreach (_, com; query!(ComflabulationComponent).each())
		{
			com.thingy *= 1.0000001f;
			com.dingy++;
			com.mingy = !com.mingy;
		}
	},{
		foreach (_, pos, dir, com; query!(PositionComponent, DirectionComponent, ComflabulationComponent).each())
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
		foreach (_, pos, i; query!(PositionComponent, int).each())
		{
			pos.x++;
		}
	},{
		foreach (_, pos, dir; query!(Select!(PositionComponent, DirectionComponent), With!ComflabulationComponent).each())
		{
			pos.x += dir.x * 0.15;
			pos.y += dir.y * 0.15;
		}
	})(Loops).std_each!(dur => writeln(dur/Loops));
}
