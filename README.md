# Valhalla ECS - VECS
An Entity Component System library written in D.

---

[![codecov](https://codecov.io/gh/ValhallaLib/valhalla_ecs/branch/master/graph/badge.svg?token=5K0BE7HG2X)](https://codecov.io/gh/ValhallaLib/valhalla_ecs)
![workflow](https://github.com/ValhallaLib/valhalla_ecs/actions/workflows/workflow.yml/badge.svg)

---

## Brief
An entity component system is a pattern used mostly in gamedev. The objective is
to classify everything in a game as an `Entity`. `Components` are just data
structures used to give some sort of meaning to the generated entities. Some
common examples are: `Position`, `Velocity`, `Sprite`. All these components can
be associated to an entity. An entity can be rendered if has `Position` and
`Sprite`, etc. Components can be almost anything! A `System` gives functionality
to entities. Some common examples are: `Render`, `Collision`, `Movement`.

This project aims to create an easy-to-use yet robust and fast ECS library. It's
inspired by the [Entt](https://github.com/skypjack/entt) C++ lib which
revolutioned the ECS model using Sparsed-Sets as storage for components and entities,
[Hecs](https://github.com/Ralith/hecs) Rust lib and
[Bevy](https://github.com/bevyengine/bevy) Rust engine, (which uses hecs) for
their user-friendly approach.

## Code Example
```d
import vecs;

struct Position
{
	float x = 0.0f;
	float y = 0.0f;
}

struct Velocity
{
	float x = 0.0f;
	float y = 0.0f;
}

@safe pure nothrow @nogc
void system(EntityManager.Query!(Position, Velocity) query)
{
	// loop with callbacks
	query.each!((entity, ref pos, ref vel) { /*...*/ });
	query.each!((ref pos, ref vel) { /*...*/ });

	// loop in a foreach
	foreach(entity, pos, vel; query.each()) { /*...*/ }

	// loop entities
	foreach(entity; query)
	{
		// ask the query for components
		Position* pos;
		Velocity* vel;

		AliasSeq!(pos, vel) = query.get!(Position, Velocity)(entity);
	}

	// loop reversed
	foreach_reverse(entity; query) { /*...*/ }
	foreach_reverse(entity, pos, vel; query.each()) { /*...*/ }

	// ask the query for entites in it
	assert(query.contains(Entity(0)));
}

void main()
{
	auto world = new EntityManager();

	foreach (i; 0 .. 10) with (world)
	{
		if (!(i & 1))
			entity(Entity(i)) // constructs or gets the entity with id 'i'
				.emplace!Position(i, i)
				.emplace!Velocity(i * 0.1f, i * 0.1f);
	}

	system(world.query!(Position, Velocity));
}
```

## Query Rules
```d
// Select:  defines which components are selected, and filters entities that own them
// With:    behaves as Select but the components are not returned
// Without: filters entities that do not own the components

import vecs;

// queries entities with A, B, C, ...
alias Q1 = EntityManager.Query!(A, B, C, ...);

// queries entities with A, B, C but Selects only A, B
alias Q2 = EntityManager.Query!(A, B).With!C;

// queries entities with A, B and without C but Selects only A
alias Q3 = EntityManager.Query!A.With!B.Without!C;

// the above alias to:
alias _Q1 = Query!(EntityManager, Select!(A, B, C, ...));
alias _Q2 = Query!(EntityManager, Select!(A, B), With!C);
alias _Q2 = Query!(EntityManager, Select!A, With!B, Without!C);

void main()
{
	auto world = new EntityManager();

	// when using rules the Select wrapper must be used
	world.query!(Select!(A, B), With!(C, D), ...);

	// Select is a special Rule and can only be used as the first argument
	// All other argument must be QueryRules 'With and Without'
	static assert(!_traits(compiles, world.query!(Select!A, Select!B)));
}
```

## Safety
EntityManagerT can be used in `@safe pure nothrow` code and some parts are
`@nogc`. What defines the majority of code safeness is the Signal. Right now
in D it is impossible to store functions with different attributes in one common
type and still be able to track them. The common attribute to all functions is
having none, which is the same as having `@system`. This forces all code that
depends on it to be `@system` as well (which is almost the entire lib)

The user can define their own safety restrictions by passing a delegate with the
attributes they desire for their callbacks. Those attributes influence the
safeness of almost the entire lib, as explained above.
```d
import vecs;

alias World = EntityManagerT!(void delegate() @safe pure nothrow);
```

Using `@nogc` **does not** make the usage `@nogc`, it only defines that **the
user** will have **`@nogc` callbacks** and therefore dependent functions will be
`@nogc` **if they can**.
```d
import vecs;

void main()
{
	auto world = new EntityManagerT!(void delegate() @nogc);

	world.onConstruct!int.connect!((const ref i) {}); // @nogc callback
	world.entity.emplace!int(4); // this won't be @nogc
}
```

This happens because the internal code uses GC for allocations (still). However,
`@safe pure nothrow` works like a charm.
```d
import vecs;

@safe pure nothrow
void main()
{
	auto world = new EntityManagerT!(void delegate() @safe pure nothrow);

	world.onConstruct!int.connect!((const ref i) {});
	auto entity = world.entity.emplace!int(4);

	assert(*world.get!int(entity) == 4);
}
```

## Almost anything can be a component
```d
import vecs;

struct Foo {}
enum E { first, second }

void main()
{
	auto world = new EntityManager();

	with (world)
	{
		entity.emplace(1, 43f, Foo.init);
		entity.emplace(1, true, "entity");
		entity.emplace(false, E.first, 123);
	}
}
```

## Future features:
* Groups (similar to Entt)
* Full nogc support
* Multithread
* System support within EntityManager (similar to Bevy/Hecs)

## License:
Licensed under:
* [MIT license](https://github.com/ValhalaLib/valhala_ecs/blob/master/LICENSE)

## Contribution:
If you are interested in project and want to improve it, creating issues and
pull requests are highly appretiated!
