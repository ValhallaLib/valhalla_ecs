module vecs.entity;

private enum VECS_32 = typeof(int.sizeof).sizeof == 4;
private enum VECS_64 = typeof(int.sizeof).sizeof == 8;
static assert(VECS_32 || VECS_64, "Unsuported target!");

static if (VECS_32) version = VECS_32;
else version = VECS_64;


/**
An entity is defined by an `id` and `batch`. It's signature is the combination
of both values. The **first N bits** define the `id` and the **last M bits**
the `batch`. The signature is an integral value of 32 bits or 64 bits depending
on the architecture. The type of this variable is `size_t` and its composition
is divided in two parts, id and batch.

Supposing an entity is an integral type of **8 bits**.
First half defines the batch.
Second half defines the id.

Composition:
| batch | id   |
| :---- | :--- |
| 0000  | 0000 |

Fields:
| name        | description                                               |
| :---------- | :-------------------------------------------------------- |
| `idshift`   | division point between the entity's **id** and **batch**. |
| `idmask`    | bit mask related to the entity's **id** portion.          |
| `batchmask` | bit mask related to the entity's **batch** portion.       |
| `maxid`     | the maximum number of ids allowed                         |
| `maxbatch`  | the maximum number of batches allowed                     |

Values:
| `void* size (bytes)` | `idshift (bits)` | `idmask`    | `batchmask`       |
| :------------------- | :--------------- | :---------- | :---------------- |
| 4                    | 20               | 0xFFFF_F    | 0xFFF << 20       |
| 8                    | 32               | 0xFFFF_FFFF | 0xFFFF_FFFF << 32 |

Sizes:
| `void* size (bytes)` | `id (bits)` | `batch (bits)` | `maxid`       | `maxbatch`    |
| :------------------- | :---------- | :------------- | :------------ | :------------ |
| 4                    | 20          | 12             | 1_048_574     | 4_095         |
| 8                    | 32          | 32             | 4_294_967_295 | 4_294_967_295 |

See_Also: [skypjack - entt](https://skypjack.github.io/2019-05-06-ecs-baf-part-3/)
*/
struct Entity
{
public:
	@safe pure nothrow @nogc
	this(in size_t signature)
	{
		this.signature = signature;
	}

	@safe pure nothrow @nogc
	this(in size_t id, in size_t batch)
		in (id <= maxid)
		in (batch <= maxbatch)
	{
		signature = (id | (batch << idshift));
	}


	@safe pure nothrow @nogc
	bool opEquals(in size_t signature) const
	{
		return this.signature == signature;
	}


	@safe pure nothrow @nogc
	bool opEquals(in NullEntity other) const
	{
		return other.opEquals(this);
	}


	@safe pure nothrow @nogc @property
	size_t id() const
	{
		return id(signature);
	}


	@safe pure nothrow @nogc @property
	static size_t id(in size_t signature)
	{
		return signature & Entity.idmask;
	}


	@safe pure nothrow @nogc @property
	size_t batch() const
	{
		return batch(signature);
	}


	@safe pure nothrow @nogc @property
	static size_t batch(in size_t signature)
	{
		return signature >> Entity.idshift;
	}


	// if size_t is 32 or 64 bits
	version(VECS_32)
	{
		enum size_t idshift = 20U;    /// 20 bits   or 32 bits
		enum size_t maxid = 0xFFFF_F; /// 1_048_575 or 4_294_967_295
		enum size_t maxbatch = 0xFFF; /// 4_095     or 4_294_967_295
	}
	else
	{
		enum size_t idshift = 32UL;      /// ditto
		enum size_t maxid = 0xFFFF_FFFF; /// ditto
		enum size_t maxbatch = maxid;    /// ditto
	}

	enum size_t idmask = maxid;                  /// first 20 bits or 32 bits
	enum size_t batchmask = maxbatch << idshift; /// last  12 bits or 32 bits

	size_t signature;
	alias signature this;
}

@("[Entity] properties")
@safe pure nothrow @nogc unittest
{
	{
		immutable entity = Entity.init;
		assert(entity.id == 0);
		assert(entity.batch == 0);
		assert(entity.signature == 0);
	}

	assert(Entity(Entity.maxid) == nullentity);
	assert(Entity(Entity.maxid, 45) == nullentity);
}

version(assert)
@("[Entity] invalid id and batch")
unittest
{
	import std.exception : assertThrown;
	import core.exception : AssertError;

	assertThrown!AssertError(Entity(size_t.max, 0));
	assertThrown!AssertError(Entity(0, size_t.max));
}


enum nullentity = NullEntity();
struct NullEntity
{
	alias entity this;

	@safe pure nothrow @nogc
	Entity entity() const
	{
		with(Entity) return Entity(batchmask | idmask);
	}

	@safe pure nothrow @nogc
	bool opEquals(in size_t signature) const
	{
		return this.id == Entity.id(signature);
	}

	@safe pure nothrow @nogc
	bool opEquals(in NullEntity) const
	{
		return true;
	}

	@safe pure nothrow @nogc
	bool opEquals(typeof(null)) const
	{
		return true;
	}

	Entity opBinary(string op)(in size_t signature) const
		if (op == "|")
	{
		return Entity(this.id, Entity.batch(signature));
	}
}

///
@("[NullEntity] properties")
@safe pure nothrow @nogc unittest
{
	assert(is(NullEntity : Entity));
	assert(nullentity == nullentity);
	assert(nullentity == null);
	assert(nullentity == Entity.maxid);
	assert((nullentity | Entity(4, 3)).batch == 3);
}
