module vecs.query;

import vecs.entity;
import vecs.entitymanager;

private enum QueryRule;

// TODO: documentation
// TODO: unittests
template Query(EntityManagerT, Select, Rules...)
{
	static assert(is(EntityManagerT == E!Fun, alias E = .EntityManagerT, Fun),
		"Type (%s) must be a valid 'vecs.entitymanager.EntityManagerT' type".format(EntityManagerT.stringof)
	);

	struct Query
	{
		Entity[] entities;
	}
}
