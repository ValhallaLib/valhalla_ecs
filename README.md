# Valhalla ECS - VECS
An Entity Component System library written in D.

## Brief
An entity component system is a pattern used mostly in gamedev. The objective is
to classify everything in a game as an `Entity`. `Components` are just data
structures used to give so sort of meaning to the generated entities. Some
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

struct Grounder {}
struct Crawler {}

// loops through all (Position, Velocity) components
void systemA(Query!(Tuple!(Position, Velocity)) query)
{
	foreach(pos, vel; query)
	{
		*pos.x += *vel.x
		*pos.y += *vel.y
	}
}

// loops through all (Position, Velocity) components and entities with (Grounder)
void systemB(Query!(Tuple!(Entity,Position,Velocity), With!Grounder) query)
{
	foreach(e, pos, vel; query)
	{
		*pos.x += *vel.x
		*pos.y += *vel.y
	}
}

// loops through all (Position, Velocity) components of entities with (Grounder) and without (Crawler)
void systemC(Query!(Tuple!(Position,Velocity), Tuple!(With!Grounder, Without!Crawler)) query)
{
	...
}

void main()
{
	auto em = new EntityManager();

	em.entityBuilder()
		.gen!Position
		.gen!(Position, Velocity, Grounder)
		.gen(Position(3.0f, 6.0f))
		.gen(Velocity(2.0f, 1.0f), Position(3.0f, 6.0f), Grounder.init, Crawler.init);

	systemA(em.query!(Tuple!(Position,Velocity)));
	systemB(em.query!(Tuple!(Entity, Position,Velocity), With!Grounder));
	systemC(em.query!(Tuple!(Position,Velocity), Tuple!(With!Grounder, Without!Crawler)));
}
```

## Almost anything can be a component
```d
import vecs;

struct Foo {}

void main()
{
	auto em = new EntityManager();

	em.gen(1, 43f, Foo.init);
	em.gen(1, true, "entity");
	em.gen(false, Foo.init, 123);
}
```

## Future features:
* Groups (similar to Entt)
* Further optimize Query
* Full nogc support
* Optimize entity generation
* System support within EntityManager (similar to Bevy/Hecs)
* Events/Signals
* Fast access to some Storage methods with Query (like `remove`)

## License:
Licensed under:
* [MIT license](https://github.com/ValhalaLib/valhala_ecs/blob/master/LICENSE)

## Contribution:
If you are interested in project and want to improve it, creating issues and
pull requests are highly appretiated!
