module app;

import vecs;

import std.stdio;

  // ====================
 // Simple combat system
// ====================

@safe
void combatSystem(World.Query!Body.With!Enemy queryEnemies, World.Query!Body.Without!Enemy queryOthers)
{
	// assume there is an entity
	auto enemyBody = queryEnemies.get!Body(queryEnemies.front);

	foreach (_, otherBody; queryOthers.each())
	{
		// enemy gets hit
		onHit.emit(*otherBody, *enemyBody);
		if (enemyBody.hp <= 0) break;

		// enemy hits back
		onHit.emit(*enemyBody, *otherBody);
		if (otherBody.hp <= 0) break;
	}
}


  // =================
 // Game State system
// =================

@safe pure nothrow
void gameSystem(World.Query!Body query, ref State state)
{
	import std.algorithm : filter, each;
	import std.range : takeOne;

	query.filter!((entity) => query.get!Body(entity).hp <= 0)
		.takeOne
		.each!(_ => state.running = true);
}


  // ==========================
 // Listens to onHit emissions
// ==========================

@safe
void hitListener(ref Body hit, ref Body damaged)
{
	damaged.hp -= hit.damage;
	writefln!"%s was hitted by %s and suffered %s damage! HP left: %s"(damaged.name, hit.name, hit.damage, damaged.hp);
}


  // ======================
 // Components and Signals
// ======================

struct Body { int hp; int damage; string name; }
struct Enemy {}
struct State { bool running; }

Signal!(void delegate(ref Body, ref Body) @safe) onHit;

alias World = EntityManager;

void main()
{
	auto world = new World();

	  // ============
	 // Bind signals
	// ============

	import std.functional : toDelegate;
	onHit.sink.connect!hitListener;

	// on Body set
	world.onConstruct!Body.connect!((Entity, ref Body b) {
		writefln!"Entity %s created with %s HP and %s damage."(b.name, b.hp, b.damage);
	});


	  // ================
	 // Create resources
	// ================

	world.addResource!State;


	  // ===============
	 // Create entities
	// ===============

	with (world)
	{
		entity.emplace!Body(10, 3, "Foo");
		entity.emplace!Body(10, 3, "Bar");
		entity.emplace!Body(13, 1, "Enemy").add!Enemy;
	}



	  // =========
	 // Main loop
	// =========

	while (world.resource!State.running) with (world)
	{
		combatSystem(query!(Select!Body, With!Enemy), query!(Select!Body, Without!Enemy));
		gameSystem(query!Body, resource!State);
	}

	"Over!".writeln;
}
