module app;

import vecs;

import std.stdio;

  // ====================
 // Simple combat system
// ====================

void combatSystem(Body* enemy, Query!(Body, Without!Enemy) query)
{
	foreach (b; query)
	{
		// enemy gets hit
		onHit.emit(b, enemy);
		if (enemy.hp <= 0) break;

		// enemy hits back
		onHit.emit(enemy, b);
		if (b.hp <= 0) break;
	}
}


  // =================
 // Game State system
// =================

void gameSystem(Query!Body query, ref State state)
{
	import std.algorithm : filter, each;
	import std.typecons : No;

	query.filter!"a.hp <= 0".each!((q) {
		state = State.over;
		return No.each;
	});
}


  // ==========================
 // Listens to onHit emissions
// ==========================

void hitListener(Body* hit, Body* damaged)
{
	import std.format : format;

	damaged.hp -= hit.damage;
	writefln!"%s was hitted by %s and suffered %s damage! HP left: %s"(damaged.name, hit.name, hit.damage, damaged.hp);
}


  // ======================
 // Components and Signals
// ======================

struct Body { int hp; int damage; string name; }
struct Enemy {}
enum State { over, running }

Signal!(Body*,Body*) onHit;


void main()
{
	auto em = new EntityManager();

	  // ============
	 // Bind signals
	// ============

	import std.functional : toDelegate;
	onHit.connect(toDelegate(&hitListener));

	// on Body set
	em.onSet!Body().connect((Entity,Body* b) {
		writefln!"Entity %s created with %s HP and %s damage."(b.name, b.hp, b.damage);
	});


	  // ================
	 // Create resources
	// ================

	em.addResource(State.running);


	  // ===============
	 // Create entities
	// ===============

	em.entityBuilder()
		.gen(Body(10, 3, "Foo"))
		.gen(Body(10, 3, "Bar"))
		.gen(Body(13, 1, "Enemy"), Enemy());



	  // =========
	 // Main loop
	// =========

	while (em.resource!State() == State.running)
	{
		combatSystem(em.queryOne!(Body, With!Enemy), em.query!(Body, Without!Enemy));
		gameSystem(em.query!Body, em.resource!State);
	}

	"Over!".writeln;
}
