# sage_setup: distribution = sagemath-categories
r"""
Lattice posets
"""
# ****************************************************************************
#  Copyright (C) 2011 Nicolas M. Thiery <nthiery at users.sf.net>
#
#  Distributed under the terms of the GNU General Public License (GPL)
#                  https://www.gnu.org/licenses/
# *****************************************************************************

from sage.categories.category import Category
from sage.categories.category_with_axiom import CategoryWithAxiom, all_axioms
from sage.categories.posets import Posets
from sage.misc.abstract_method import abstract_method
from sage.misc.cachefunc import cached_method
from sage.misc.lazy_import import LazyImport


all_axioms += ("Distributive", "Semidistributive",
               "CongruenceUniform", "Trim")


class LatticePosets(Category):
    r"""
    The category of lattices, i.e. partially ordered sets in which any
    two elements have a unique supremum (the elements' least upper
    bound; called their *join*) and a unique infimum (greatest lower bound;
    called their *meet*).

    EXAMPLES::

        sage: LatticePosets()
        Category of lattice posets
        sage: LatticePosets().super_categories()
        [Category of posets]
        sage: LatticePosets().example()
        NotImplemented

    .. SEEALSO:: :class:`~sage.categories.posets.Posets`, :class:`FiniteLatticePosets`, :func:`LatticePoset`

    TESTS::

        sage: C = LatticePosets()
        sage: TestSuite(C).run()
    """
    @cached_method
    def super_categories(self):
        r"""
        Return a list of the (immediate) super categories of
        ``self``, as per :meth:`Category.super_categories`.

        EXAMPLES::

            sage: LatticePosets().super_categories()
            [Category of posets]
        """
        return [Posets()]

    Finite = LazyImport('sage.categories.finite_lattice_posets',
                        'FiniteLatticePosets')

    class ParentMethods:

        @abstract_method
        def meet(self, x, y):
            """
            Return the meet of `x` and `y` in this lattice.

            INPUT:

            - ``x``, ``y`` -- elements of ``self``

            EXAMPLES::

                sage: D = LatticePoset((divisors(30), attrcall("divides")))             # needs sage.graphs sage.modules
                sage: D.meet( D(6), D(15) )                                             # needs sage.graphs sage.modules
                3
            """

        @abstract_method
        def join(self, x, y):
            """
            Return the join of `x` and `y` in this lattice.

            INPUT:

            - ``x``, ``y`` -- elements of ``self``

            EXAMPLES::

                sage: D = LatticePoset((divisors(60), attrcall("divides")))             # needs sage.graphs sage.modules
                sage: D.join( D(6), D(10) )                                             # needs sage.graphs sage.modules
                30
            """

    class SubcategoryMethods:
        def Distributive(self):
            r"""
            A lattice `(L, \vee, \wedge)` is distributive if meet
            distributes over join: `x \wedge (y \vee z) = (x \wedge y)
            \vee (x \wedge z)` for every `x,y,z \in L`.

            From duality in lattices, it follows that then also join
            distributes over meet.
            """
            return self._with_axiom("Distributive")

        def Semidistributive(self):
            r"""
            A lattice `(L, \vee, \wedge)` is semidistributive if
            it is both join-semidistributive and meet-semidistributive.

            A lattice is join-semidistributive if
            for all elements `e, x, y` in the lattice we have

            .. MATH::

                e \vee x = e \vee y \implies e \vee x = e \vee (x \wedge y)

            Meet-semidistributivity is the dual property.
            """
            return self._with_axiom("Semidistributive")

        def CongruenceUniform(self):
            r"""
            A lattice `(L, \vee, \wedge)` is congruence uniform if it
            can be constructed by a sequence of interval doublings
            starting with the lattice with one element.
            """
            return self._with_axiom("CongruenceUniform")

        def Trim(self):
            r"""
            A lattice `(L, \vee, \wedge)` is trim if it is extremal
            and left modular.

            This notion is defined in [Thom2006]_.
            """
            return self._with_axiom("Trim")

    class Distributive(CategoryWithAxiom):
        """
        The category of distributive lattices.

        EXAMPLES::

            sage: LatticePosets().Distributive()
            Category of distributive lattice posets
        """
        class ParentMethods:
            def is_distributive(self):
                return True

    class Semidistributive(CategoryWithAxiom):
        """
        The category of semidistributive lattices.

        EXAMPLES::

            sage: LatticePosets().Semidistributive()
            Category of semidistributive lattice posets
        """
        class ParentMethods:
            def is_semidistributive(self):
                return True

    class CongruenceUniform(CategoryWithAxiom):
        """
        The category of congruence uniform lattices.

        EXAMPLES::

            sage: LatticePosets().CongruenceUniform()
            Category of congruence uniform lattice posets
        """
        class ParentMethods:
            def is_congruence_uniform(self):
                return True

    class Trim(CategoryWithAxiom):
        """
        The category of trim uniform lattices.

        EXAMPLES::

            sage: LatticePosets().Trim()
            Category of trim lattice posets
        """
        class ParentMethods:
            def is_trim(self):
                return True
