"""
PolyDict engine for generic multivariate polynomial rings

This module provides an implementation of the underlying arithmetic for
multi-variate polynomial rings using Python dicts.

This class is not meant for end users, but instead for implementing
multivariate polynomial rings over a completely general base. It does
not do strong type checking or have parents, etc. For speed, it has been
implemented in Cython.

The functions in this file use the 'dictionary representation' of multivariate
polynomials

``{(e1,...,er):c1,...} <-> c1*x1^e1*...*xr^er+...``,

which we call a polydict. The exponent tuple ``(e1,...,er)`` in this
representation is an instance of the class :class:`ETuple`. The value
corresponding to the given exponent.

AUTHORS:

- William Stein
- David Joyner
- Martin Albrecht (ETuple)
- Joel B. Mohler (2008-03-17) -- ETuple rewrite as sparse C array
"""

# ****************************************************************************
#       Copyright (C) 2005 William Stein <wstein@gmail.com>
#                     2022 Vincent Delecroix <20100.delecroix@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#                  https://www.gnu.org/licenses/
# ****************************************************************************

from libc.string cimport memcpy
from cpython.dict cimport *
cimport cython
from cpython.object cimport (Py_EQ, Py_NE, Py_LT, Py_LE, Py_GT, Py_GE)
from cysignals.memory cimport sig_malloc, sig_free

from sage.structure.richcmp cimport rich_to_bool
from sage.structure.parent cimport Parent

import copy

from functools import reduce
from pprint import pformat

from sage.arith.power import generic_power
from sage.misc.misc import cputime
from sage.misc.latex import latex


def gen_index(PolyDict x):
    r"""
    Return the index of the variable represented by ``x`` or ``-1`` if ``x``
    is not a monomial of degree one.

    EXAMPLES::

        sage: from sage.rings.polynomial.polydict import PolyDict, gen_index
        sage: gen_index(PolyDict({(1, 0): 1}))
        0
        sage: gen_index(PolyDict({(0, 1): 1}))
        1
        sage: gen_index(PolyDict({}))
        -1
    """
    if len(x.__repn) != 1:
        return -1
    cdef ETuple e = next(iter(x.__repn))
    if e._nonzero != 1 or e._data[1] != 1:
        return -1
    if not next(iter(x.__repn.values())).is_one():
        return -1
    return e._data[0]

cdef class PolyDict:
    r"""
    PolyDict is a dictionary all of whose keys are :class:`ETuple` and whose values
    are coefficients on which arithmetic operations can be performed.
    """
    def __init__(PolyDict self, pdict, zero=None, remove_zero=False, force_int_exponents=None, force_etuples=None):
        """
        INPUT:

        - ``pdict`` -- dict or list, which represents a multi-variable
          polynomial with the distribute representation (a copy is not made)

        - ``zero`` --  deprecated

        - ``remove_zero`` -- whether to check for zero coefficient

        - ``force_int_exponents`` -- deprecated

        - ``force_etuples`` -- deprecated

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: PolyDict({(2,3):2, (1,2):3, (2,1):4})
            PolyDict with representation {(1, 2): 3, (2, 1): 4, (2, 3): 2}

            sage: PolyDict({(2,3):0, (1,2):3, (2,1):4}, remove_zero=True)
            PolyDict with representation {(1, 2): 3, (2, 1): 4}

            sage: PolyDict({(0,0):RIF(-1,1)}, remove_zero=True)
            PolyDict with representation {(0, 0): 0.?}

        TESTS::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: len(f)
            3
            sage: f = PolyDict({}, zero=3, force_int_exponents=True, force_etuples=True)
            doctest:warning
            ...
            DeprecationWarning: the arguments "zero", "forced_int_exponents" and "forced_etuples" of PolyDict constructor are deprecated
            See https://trac.sagemath.org/34000 for details.
        """
        if zero is not None or force_int_exponents is not None or force_etuples is not None:
            from sage.misc.superseded import deprecation
            deprecation(34000, 'the arguments "zero", "forced_int_exponents" and "forced_etuples" of PolyDict constructor are deprecated')

        cdef dict v

        if isinstance(pdict, list):
            v = {}
            L = <list> pdict
            for w in L:
                v[ETuple(w[1])] = w[0]
        elif isinstance(pdict, dict):
            v = <dict> pdict.copy()
        else:
            raise TypeError("pdict must be a dict or a list")

        for k in list(v):
            if type(k) is not ETuple:
                val = v[k]
                del v[k]
                v[ETuple(k)] = val

        self.__repn = v
        if remove_zero:
            self.remove_zeros()

    cpdef remove_zeros(self):
        r"""
        Remove the entries with zero coefficients.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):0}, remove_zero=False)
            sage: f
            PolyDict with representation {(2, 3): 0}
            sage: f.remove_zeros()
            sage: f
            PolyDict with representation {}
        """
        for k in list(self.__repn):
            if not self.__repn[k]:
                del self.__repn[k]

    def coerce_coefficients(self, Parent A):
        r"""
        Coerce the coefficients in the parent ``A``
        """
        for k, v in self.__repn.items():
            self.__repn[k] = A.coerce(v)

    cdef PolyDict _new(self, dict pdict):
        cdef PolyDict ans = PolyDict.__new__(PolyDict)
        ans.__repn = pdict
        return ans

    def __hash__(self):
        """
        Return the hash.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: PD1 = PolyDict({(2,3):0, (1,2):3, (2,1):4})
            sage: PD2 = PolyDict({(2,3):0, (1,2):3, (2,1):4})
            sage: PD3 = PolyDict({(2,3):1, (1,2):3, (2,1):4})
            sage: hash(PD1) == hash(PD2)
            True
            sage: hash(PD1) == hash(PD3)
            False
        """
        return hash(frozenset(self.__repn.items()))

    def __bool__(self):
        return bool(self.__repn)

    def __len__(self):
        return len(self.__repn)

    def __richcmp__(PolyDict left, PolyDict right, int op):
        """
        Implement the ``__richcmp__`` protocol for `PolyDict`s.

        Uses `PolyDict.rich_compare` without a key  (so only ``==`` and ``!=``
        are supported on Python 3; on Python 2 this will fall back on Python 2
        default comparison behavior).

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: p1 = PolyDict({(0,): 1})
            sage: p2 = PolyDict({(0,): 2})
            sage: p1 == p2
            False
            sage: p1 < p2
            Traceback (most recent call last):
            ...
            TypeError: '<' not supported between instances of
            'sage.rings.polynomial.polydict.PolyDict' and
            'sage.rings.polynomial.polydict.PolyDict'
        """
        try:
            return left.rich_compare(right, op)
        except TypeError:
            return NotImplemented

    def rich_compare(PolyDict self, PolyDict other, int op, sortkey=None):
        """
        Compare two `PolyDict`s.  If a ``sortkey`` argument is given it should
        be a sort key used to specify a term order.

        If not sort key is provided than only comparison by equality (``==`` or
        ``!=``) is supported.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: from sage.structure.richcmp import op_EQ, op_NE, op_LT
            sage: p1 = PolyDict({(0,): 1})
            sage: p2 = PolyDict({(0,): 2})
            sage: p1.rich_compare(PolyDict({(0,): 1}), op_EQ)
            True
            sage: p1.rich_compare(p2, op_EQ)
            False
            sage: p1.rich_compare(p2, op_NE)
            True
            sage: p1.rich_compare(p2, op_LT)
            Traceback (most recent call last):
            ...
            TypeError: ordering of PolyDicts requires a sortkey

            sage: O = TermOrder()
            sage: p1.rich_compare(p2, op_LT, O.sortkey)
            True

            sage: p3 = PolyDict({(3, 2, 4): 1, (3, 2, 5): 2})
            sage: p4 = PolyDict({(3, 2, 4): 1, (3, 2, 3): 2})
            sage: p3.rich_compare(p4, op_LT, O.sortkey)
            False
        """
        if op == Py_EQ:
            return self.__repn == other.__repn
        elif op == Py_NE:
            return self.__repn != other.__repn
        elif sortkey is None:
            raise TypeError("ordering of PolyDicts requires a sortkey")

        # start with biggest
        left = iter(sorted(self.__repn, key=sortkey, reverse=True))
        right = iter(sorted(other.__repn, key=sortkey, reverse=True))

        for m in left:
            try:
                n = next(right)
            except StopIteration:
                return rich_to_bool(op, 1)  # left has terms, right does not

            # first compare the leading monomials
            keym = sortkey(m)
            keyn = sortkey(n)
            if keym > keyn:
                return rich_to_bool(op, 1)
            elif keym < keyn:
                return rich_to_bool(op, -1)

            # same leading monomial, compare their coefficients
            coefm = self.__repn[m]
            coefn = other.__repn[n]
            if coefm > coefn:
                return rich_to_bool(op, 1)
            elif coefm < coefn:
                return rich_to_bool(op, -1)

        # try next pair
        try:
            n = next(right)
            return rich_to_bool(op, -1)  # right has terms, left does not
        except StopIteration:
            return rich_to_bool(op, 0)  # both have no terms

    def list(self):
        """
        Return a list that defines ``self``. It is safe to change this.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: sorted(f.list())
            [[2, [2, 3]], [3, [1, 2]], [4, [2, 1]]]
        """
        ret = []
        for e, c in self.__repn.items():
            ret.append([c, list(e)])
        return ret

    def dict(self):
        """
        Return a copy of the dict that defines self.  It is
        safe to change this.  For a reference, use dictref.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.dict()
            {(1, 2): 3, (2, 1): 4, (2, 3): 2}
        """
        return self.__repn.copy()

    def coefficients(self):
        """
        Return the coefficients of self.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: sorted(f.coefficients())
            [2, 3, 4]
        """
        return list(self.__repn.values())

    def exponents(self):
        """
        Return the exponents of self.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: sorted(f.exponents())
            [(1, 2), (2, 1), (2, 3)]
        """
        return list(self.__repn)

    def __getitem__(self, e):
        """
        Return a coefficient of the polynomial.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f[1,2]
            3
            sage: f[(2,1)]
            4
        """
        if type(e) is not ETuple:
            e = ETuple(e)
        return self.__repn[e]

    def __repr__(PolyDict self):
        repn = ' '.join(pformat(self.__repn).splitlines())
        return 'PolyDict with representation %s' % repn

    def degree(PolyDict self, PolyDict x=None):
        r"""
        Return the total degree or the maximum degree in the variable ``x``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.degree()
            5
            sage: f.degree(PolyDict({(1, 0): 1}))
            2
            sage: f.degree(PolyDict({(0, 1): 1}))
            3
        """
        if x is None:
            return self.total_degree()
        cdef size_t i = gen_index(x)
        if not self.__repn:
            return -1
        return max((<ETuple> e).get_exp(i) for e in self.__repn)

    def valuation(PolyDict self, PolyDict x=None):
        if x is None:
            _min = []
            negative = False
            for v in self.__repn.values():
                _sum = 0
                for m in v.nonzero_values(sort=False):
                    if m < 0:
                        negative = True
                        break
                    _sum += m
                if negative:
                    break
                _min.append(_sum)
            else:
                return min(_min)
            for v in self.__repn.values():
                _min.append(sum(m for m in v.nonzero_values(sort=False) if m < 0))
            return min(_min)

        i = gen_index(x)
        return min((<ETuple> e).get_exp(i) for e in self.__repn)

    def total_degree(PolyDict self, tuple w=None):
        r"""
        Return the total degree.

        INPUT:

        - ``w`` (optional) -- a tuple of weights

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.total_degree()
            5
            sage: f.total_degree((3, 1))
            9
            sage: PolyDict({}).degree()
            -1
        """
        if not self.__repn:
            return -1
        if w is None:
            return max((<ETuple> e).unweighted_degree() for e in self.__repn)
        else:
            return max((<ETuple> e).weighted_degree(w) for e in self.__repn)

    def monomial_coefficient(PolyDict self, mon):
        """
        Return the coefficient of the monomial ``mon``.

        INPUT:

        a PolyDict with a single key

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.monomial_coefficient(PolyDict({(2,1):1}).dict())
            4
        """
        K, = mon.keys()
        if K not in self.__repn:
            return 0
        return self.__repn[K]

    def polynomial_coefficient(PolyDict self, degrees):
        """
        Return a polydict that defines the coefficient in the current
        polynomial viewed as a tower of polynomial extensions.

        INPUT:

        - ``degrees`` -- a list of degree restrictions; list elements are None
          if the variable in that position should be unrestricted

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.polynomial_coefficient([2,None])
            PolyDict with representation {(0, 1): 4, (0, 3): 2}
            sage: f = PolyDict({(0,3):2, (0,2):3, (2,1):4})
            sage: f.polynomial_coefficient([0,None])
            PolyDict with representation {(0, 2): 3, (0, 3): 2}
        """
        nz = []
        cdef int i
        for i in range(len(degrees)):
            if degrees[i] is not None:
                nz.append(i)
        cdef dict ans = {}
        cdef bint exactly_divides
        for S in self.__repn:
            exactly_divides = True
            for j in nz:
                if S[j] != degrees[j]:
                    exactly_divides = False
                    break
            if exactly_divides:
                t = list(S)
                for m in nz:
                    t[m] = 0
                ans[ETuple(t)] = self.__repn[S]
        return self._new(ans)

    def coefficient(PolyDict self, mon):
        """
        Return a polydict that defines a polynomial in 1 less number
        of variables that gives the coefficient of mon in this
        polynomial.

        The coefficient is defined as follows.  If f is this
        polynomial, then the coefficient is the sum T/mon where the
        sum is over terms T in f that are exactly divisible by mon.
        """
        K, = mon.keys()
        nz = K.nonzero_positions()  # set([i for i in range(len(K)) if K[i] != 0])
        ans = {}
        for S in self.__repn:
            exactly_divides = True
            for j in nz:
                if S[j] != K[j]:
                    exactly_divides = False
                    break
            if exactly_divides:
                t = list(S)
                for m in nz:
                    t[m] = 0
                ans[ETuple(t)] = self.__repn[S]
        return self._new(ans)

    def is_homogeneous(PolyDict self):
        r"""
        Return whether this polynomial is homogeneous.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: PolyDict({}).is_homogeneous()
            True
            sage: PolyDict({(1, 2): 1, (0, 3): -2}).is_homogeneous()
            True
            sage: PolyDict({(1, 0): 1, (1, 2): 3}).is_homogeneous()
            False
        """
        if not self.__repn:
            return True
        it = iter(self.__repn)
        s = sum(next(it))
        for elt in it:
            if sum(elt) != s:
                return False
        return True

    def is_constant(self):
        """
        Return whether this polynomial is constant.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.is_constant()
            False
            sage: g = PolyDict({(0,0):2})
            sage: g.is_constant()
            True
            sage: h = PolyDict({})
            sage: h.is_constant()
            True
        """
        if not self.__repn:
            return True
        if len(self.__repn) > 1:
            return False
        return not any(e for e in self.__repn)

    def homogenize(PolyDict self, size_t var):
        r"""
        Return the homogeneization of ``self`` by increasing the degree of the
        variable ``var``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(0, 0): 1, (2, 1): 3, (1, 1): 5})
            sage: f.homogenize(0)
            PolyDict with representation {(2, 1): 8, (3, 0): 1}
            sage: f.homogenize(1)
            PolyDict with representation {(0, 3): 1, (1, 2): 5, (2, 1): 3}

            sage: PolyDict({(0, 1): 1, (1, 1): -1}).homogenize(0)
            PolyDict with representation {(1, 1): 0}
        """
        cdef dict H = {}
        cdef int deg = self.degree()
        cdef int shift
        for e, val in self.__repn.items():
            shift = deg - (<ETuple> e).unweighted_degree()
            if shift:
                f = (<ETuple> e).eadd_p(shift, var)
            else:
                f = e
            if f in H:
                H[f] += val
            else:
                H[f] = val
        return self._new(H)

    def latex(PolyDict self, vars, atomic_exponents=True,
              atomic_coefficients=True, sortkey=None):
        r"""
        Return a nice polynomial latex representation of this PolyDict, where
        the vars are substituted in.

        INPUT:

        - ``vars`` -- list
        - ``atomic_exponents`` -- bool (default: ``True``)
        - ``atomic_coefficients`` -- bool (default: ``True``)

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.latex(['a', 'WW'])
            '2 a^{2} WW^{3} + 4 a^{2} WW + 3 a WW^{2}'

        TESTS:

        We check that the issue on :trac:`9478` is resolved::

            sage: R2.<a> = QQ[]
            sage: R3.<xi, x> = R2[]
            sage: print(latex(xi*x))
            \xi x

        TESTS:

        Check that :trac:`29604` is fixed::

            sage: PolyDict({(1, 0): GF(2)(1)}).latex(['x', 'y'])
            'x'
        """
        if not self:
            return "0"

        n = len(vars)
        poly = ""

        sort_kwargs = {'reverse': True}
        if sortkey:
            sort_kwargs['key'] = sortkey

        E = sorted(self.__repn, **sort_kwargs)

        try:
            ring = self.__repn[E[0]].parent()
            pos_one = ring.one()
            neg_one = -pos_one
        except AttributeError:
            # probably self.__repn[E[0]] is not a ring element
            pos_one = 1
            neg_one = -1

        is_characteristic_2 = bool(pos_one == neg_one)

        for e in E:
            c = self.__repn[e]
            sign_switch = False
            # First determine the multinomial:
            multi = " ".join([vars[j] +
                              ("^{%s}" % e[j] if e[j] != 1 else "")
                             for j in e.nonzero_positions(sort=True)])
            # Next determine coefficient of multinomial
            if len(multi) == 0:
                multi = latex(c)
            elif c == neg_one and not is_characteristic_2:
                # handle -1 specially because it's a pain
                if len(poly) > 0:
                    sign_switch = True
                else:
                    multi = "-%s" % multi
            elif c != pos_one:
                c = latex(c)
                if (not atomic_coefficients and multi and
                        ('+' in c or '-' in c or ' ' in c)):
                    c = "\\left(%s\\right)" % c
                multi = "%s %s" % (c, multi)

            # Now add on coefficiented multinomials
            if len(poly) > 0:
                if sign_switch:
                    poly = poly + " - "
                else:
                    poly = poly + " + "
            poly = poly + multi
        poly = poly.lstrip().rstrip()
        poly = poly.replace("+ -", "- ")
        if len(poly) == 0:
            return "0"
        return poly

    def poly_repr(PolyDict self, vars, atomic_exponents=True,
                  atomic_coefficients=True, sortkey=None):
        """
        Return a nice polynomial string representation of this PolyDict, where
        the vars are substituted in.

        INPUT:

        - ``vars`` -- list
        - ``atomic_exponents`` -- bool (default: ``True``)
        - ``atomic_coefficients`` -- bool (default: ``True``)

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.poly_repr(['a', 'WW'])
            '2*a^2*WW^3 + 4*a^2*WW + 3*a*WW^2'

        We check to make sure that when we are in characteristic two, we
        don't put negative signs on the generators. ::

            sage: Integers(2)['x, y'].gens()
            (x, y)

        We make sure that intervals are correctly represented. ::

            sage: f = PolyDict({(2,3):RIF(1/2,3/2), (1,2):RIF(-1,1)})
            sage: f.poly_repr(['x', 'y'])
            '1.?*x^2*y^3 + 0.?*x*y^2'

        TESTS:

        Check that :trac:`29604` is fixed::

            sage: PolyDict({(1, 0): GF(4)(1)}).poly_repr(['x', 'y'])
            'x'
            sage: P.<x,y> = LaurentPolynomialRing(GF(2), 2)
            sage: P.gens()
            (x, y)
            sage: -x - y
            x + y
        """
        n = len(vars)
        poly = ""
        sort_kwargs = {'reverse': True}
        if sortkey:
            sort_kwargs['key'] = sortkey

        E = sorted(self.__repn, **sort_kwargs)

        if not E:
            return "0"
        try:
            ring = self.__repn[E[0]].parent()
            pos_one = ring.one()
            neg_one = -pos_one
        except AttributeError:
            # probably self.__repn[E[0]] is not a ring element
            pos_one = 1
            neg_one = -1

        is_characteristic_2 = bool(pos_one == neg_one)

        for e in E:
            c = self.__repn[e]
            sign_switch = False
            # First determine the multinomial:
            multi = ""
            for j in e.nonzero_positions(sort=True):
                if len(multi) > 0:
                    multi = multi + "*"
                multi = multi + vars[j]
                if e[j] != 1:
                    if atomic_exponents:
                        multi = multi + "^%s" % e[j]
                    else:
                        multi = multi + "^(%s)" % e[j]
            # Next determine coefficient of multinomial
            if len(multi) == 0:
                multi = str(c)
            elif c == neg_one and not is_characteristic_2:
                # handle -1 specially because it's a pain
                if len(poly) > 0:
                    sign_switch = True
                else:
                    multi = "-%s" % multi
            elif not c == pos_one:
                if not atomic_coefficients:
                    c = str(c)
                    if c.find("+") != -1 or c.find("-") != -1 or c.find(" ") != -1:
                        c = "(%s)" % c
                multi = "%s*%s" % (c, multi)

            # Now add on coefficiented multinomials
            if len(poly) > 0:
                if sign_switch:
                    poly = poly + " - "
                else:
                    poly = poly + " + "
            poly = poly + multi
        poly = poly.lstrip().rstrip()
        poly = poly.replace("+ -", "- ")
        if len(poly) == 0:
            return "0"
        return poly

    def __iadd__(PolyDict self, PolyDict other):
        r"""
        Inplace addition

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: g = PolyDict({(1,5):-3, (2,3):-2, (1,1):3})
            sage: f += g
            sage: f
            PolyDict with representation {(1, 1): 3, (1, 2): 3, (1, 5): -3, (2, 1): 4, (2, 3): 0}
        """
        cdef dict D = self.__repn
        cdef bint clean = False
        if self is other:
            for e in D:
                v = D[e]
                D[e] += v
        else:
            for e, c in other.__repn.items():
                if e in D:
                    D[e] += c
                else:
                    D[e] = c
        return self

    def __neg__(self):
        r"""
        TESTS::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: -PolyDict({(2,3):2, (1,2):3, (2,1):4})
            PolyDict with representation {(1, 2): -3, (2, 1): -4, (2, 3): -2}
        """
        cdef dict D = self.__repn.copy()
        for e, c in D.items():
            D[e] = -c
        return self._new(D)

    def __add__(PolyDict self, PolyDict other):
        """
        Add two PolyDict's in the same number of variables.

        EXAMPLES:

        We add two polynomials in 2 variables::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: g = PolyDict({(1,5):-3, (2,3):-2, (1,1):3})
            sage: f + g
            PolyDict with representation {(1, 1): 3, (1, 2): 3, (1, 5): -3, (2, 1): 4, (2, 3): 0}

            sage: K = GF(2)
            sage: f = PolyDict({(1, 1): K(1)})
            sage: f + f
            PolyDict with representation {(1, 1): 0}
        """
        cdef dict D = self.__repn
        cdef dict R = other.__repn
        if len(D) < len(R):
            D, R = R, D
        D = D.copy()
        for e, c in R.items():
            if e in D:
                D[e] += c
            else:
                D[e] = c
        return self._new(D)

    def __mul__(PolyDict self, PolyDict right):
        """
        Multiply two PolyDict's in the same number of variables.

        EXAMPLES:
        We multiply two polynomials in 2 variables::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: g = PolyDict({(1,5):-3, (2,3):-2, (1,1):3})
            sage: f*g
            PolyDict with representation {(2, 3): 9, (2, 7): -9, (3, 2): 12, (3, 4): 6, (3, 5): -6, (3, 6): -12, (3, 8): -6, (4, 4): -8, (4, 6): -4}
        """
        cdef PyObject *cc
        cdef dict newpoly = {}
        if not self.__repn:   # product is zero anyways
            return self
        elif not right.__repn:
            return right
        for e0, c0 in self.__repn.items():
            for e1, c1 in right.__repn.items():
                e = (<ETuple> e0).eadd(<ETuple> e1)
                c = c0 * c1
                if c:
                    cc = PyDict_GetItem(newpoly, e)
                    if cc == <PyObject*>0:
                        PyDict_SetItem(newpoly, e, c)
                    else:
                        PyDict_SetItem(newpoly, e, <object>cc+c)
        return self._new(newpoly)

    def scalar_rmult(PolyDict self, s):
        """
        Right Scalar Multiplication

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: x, y = FreeMonoid(2, 'x, y').gens()  # a strange object to live in a polydict, but non-commutative!
            sage: f = PolyDict({(2,3):x})
            sage: f.scalar_rmult(y)
            PolyDict with representation {(2, 3): x*y}
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.scalar_rmult(-2)
            PolyDict with representation {(1, 2): -6, (2, 1): -8, (2, 3): -4}
            sage: f.scalar_rmult(RIF(-1,1))
            PolyDict with representation {(1, 2): 0.?e1, (2, 1): 0.?e1, (2, 3): 0.?e1}
        """
        cdef dict v = {}
        for e, c in self.__repn.items():
            v[e] = c * s
        return self._new(v)

    def scalar_lmult(PolyDict self, s):
        """
        Left Scalar Multiplication

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: x, y = FreeMonoid(2, 'x, y').gens()  # a strange object to live in a polydict, but non-commutative!
            sage: f = PolyDict({(2,3):x})
            sage: f.scalar_lmult(y)
            PolyDict with representation {(2, 3): y*x}
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.scalar_lmult(-2)
            PolyDict with representation {(1, 2): -6, (2, 1): -8, (2, 3): -4}
            sage: f.scalar_lmult(RIF(-1,1))
            PolyDict with representation {(1, 2): 0.?e1, (2, 1): 0.?e1, (2, 3): 0.?e1}
        """
        cdef dict v = {}
        for e, c in self.__repn.items():
            v[e] = s * c
        return self._new(v)

    def term_lmult(self, exponent, s):
        """
        Return this element multiplied by ``s`` on the left
        and with exponents shifted by ``exponent``.

        INPUT:

        - ``exponent`` -- a ETuple

        - ``s`` -- a scalar

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple, PolyDict
            sage: x, y = FreeMonoid(2, 'x, y').gens()  # a strange object to live in a polydict, but non-commutative!
            sage: f = PolyDict({(2, 3): x})
            sage: f.term_lmult(ETuple((1, 2)), y)
            PolyDict with representation {(3, 5): y*x}

            sage: f = PolyDict({(2,3): 2, (1,2): 3, (2,1): 4})
            sage: f.term_lmult(ETuple((1, 2)), -2)
            PolyDict with representation {(2, 4): -6, (3, 3): -8, (3, 5): -4}

        """
        cdef dict v = {}
        for e, c in self.__repn.items():
            v[(<ETuple> e).eadd(exponent)] = s*c
        return self._new(v)

    def term_rmult(self, exponent, s):
        """
        Return this element multiplied by ``s`` on the right
        and with exponents shifted by ``exponent``.

        INPUT:

        - ``exponent`` -- a ETuple

        - ``s`` -- a scalar

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple, PolyDict
            sage: x, y = FreeMonoid(2, 'x, y').gens()  # a strange object to live in a polydict, but non-commutative!
            sage: f = PolyDict({(2, 3): x})
            sage: f.term_rmult(ETuple((1, 2)), y)
            PolyDict with representation {(3, 5): x*y}

            sage: f = PolyDict({(2,3): 2, (1,2): 3, (2,1): 4})
            sage: f.term_rmult(ETuple((1, 2)), -2)
            PolyDict with representation {(2, 4): -6, (3, 3): -8, (3, 5): -4}

        """
        cdef dict v = {}
        for e, c in self.__repn.items():
            v[(<ETuple> e).eadd(exponent)] = c * s
        return self._new(v)

    def __sub__(PolyDict self, PolyDict other):
        """
        Subtract two PolyDict's.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: g = PolyDict({(2,3):2, (1,1):-10})
            sage: f - g
            PolyDict with representation {(1, 1): 10, (1, 2): 3, (2, 1): 4, (2, 3): 0}
            sage: g - f
            PolyDict with representation {(1, 1): -10, (1, 2): -3, (2, 1): -4, (2, 3): 0}
            sage: f - f
            PolyDict with representation {(1, 2): 0, (2, 1): 0, (2, 3): 0}
        """
        cdef dict D = self.__repn.copy()
        cdef dict R = other.__repn
        for e, c in R.items():
            if e in D:
                D[e] -= c
            else:
                D[e] = -c
        return self._new(D)

    def derivative_i(self, size_t i):
        r"""
        Return the derivative of ``self`` with respect to the ``i``-th variable.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: PolyDict({(1, 1): 1}).derivative_i(0)
            PolyDict with representation {(0, 1): 1}
        """
        cdef dict D = {}
        for e, c in self.__repn.items():
            D[(<ETuple> e).eadd_p(-1, i)] = c * (<ETuple> e).get_exp(i)
        return self._new(D)

    def derivative(self, PolyDict x):
        r"""
        Return the derivative of ``self`` with respect to ``x``

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.derivative(PolyDict({(1,0): 1}))
            PolyDict with representation {(0, 2): 3, (1, 1): 8, (1, 3): 4}
            sage: f.derivative(PolyDict({(0,1): 1}))
            PolyDict with representation {(1, 1): 6, (2, 0): 4, (2, 2): 6}

            sage: PolyDict({(-1,): 1}).derivative(PolyDict({(1,): 1}))
            PolyDict with representation {(-2,): -1}
            sage: PolyDict({(-2,): 1}).derivative(PolyDict({(1,): 1}))
            PolyDict with representation {(-3,): -2}
        """
        return self.derivative_i(gen_index(x))

    def integral_i(self, size_t i):
        r"""
        Return the derivative of ``self`` with respect to the ``i``-th variable.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: PolyDict({(1, 1): 1}).integral_i(0)
            PolyDict with representation {(2, 1): 1/2}
        """
        cdef dict D = {}
        cdef int exp
        for e, c in self.__repn.items():
            exp = (<ETuple> e).get_exp(i)
            if exp == -1:
                raise ArithmeticError('integral of monomial with exponent -1')
            D[(<ETuple> e).eadd_p(1, i)] = c / (exp + 1)
        return self._new(D)

    def integral(self, PolyDict x):
        r"""
        Return the integral of ``self`` with respect to ``x``

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.integral(PolyDict({(1,0): 1}))
            PolyDict with representation {(2, 2): 3/2, (3, 1): 4/3, (3, 3): 2/3}
            sage: f.integral(PolyDict({(0,1): 1}))
            PolyDict with representation {(1, 3): 1, (2, 2): 2, (2, 4): 1/2}

            sage: PolyDict({(-1,): 1}).integral(PolyDict({(1,): 1}))
            Traceback (most recent call last):
            ...
            ArithmeticError: integral of monomial with exponent -1
            sage: PolyDict({(-2,): 1}).integral(PolyDict({(1,): 1}))
            PolyDict with representation {(-1,): -1}
        """
        return self.integral_i(gen_index(x))

    def lcmt(PolyDict self, greater_etuple):
        """
        Provides functionality of lc, lm, and lt by calling the tuple
        compare function on the provided term order T.

        INPUT:

        - ``greater_etuple`` -- a term order
        """
        try:
            return ETuple(reduce(greater_etuple, self.__repn))
        except KeyError:
            raise ArithmeticError("%s not supported", greater_etuple)

    def __reduce__(PolyDict self):
        """

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: loads(dumps(f)) == f
            True
        """
        return make_PolyDict, (self.__repn,)

    def min_exp(self):
        """
        Returns an ETuple containing the minimum exponents appearing.  If
        there are no terms at all in the PolyDict, it returns None.

        The nvars parameter is necessary because a PolyDict doesn't know it
        from the data it has (and an empty PolyDict offers no clues).

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.min_exp()
            (1, 1)
            sage: PolyDict({}).min_exp() # returns None
        """
        cdef ETuple r
        if self.__repn:
            it = iter(self.__repn)
            r = next(it)
            for e in it:
                r = r.emin(e)
            return r
        else:
            return None

    def max_exp(self):
        """
        Returns an ETuple containing the maximum exponents appearing.  If
        there are no terms at all in the PolyDict, it returns None.

        The nvars parameter is necessary because a PolyDict doesn't know it
        from the data it has (and an empty PolyDict offers no clues).

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import PolyDict
            sage: f = PolyDict({(2,3):2, (1,2):3, (2,1):4})
            sage: f.max_exp()
            (2, 3)
            sage: PolyDict({}).max_exp() # returns None
        """
        cdef ETuple r
        if self.__repn:
            it = iter(self.__repn)
            r = next(it)
            for e in it:
                r = r.emax(e)
            return r
        else:
            return None

cdef inline bint dual_etuple_iter(ETuple self, ETuple other, size_t *ind1, size_t *ind2, size_t *index, int *exp1, int *exp2):
    """
    This function is a crucial helper function for a number of methods of
    the ETuple class.

    This is a rather fragile function.  Perhaps some Cython guru could make
    it appear a little less stilted -- a principal difficulty is passing
    C types by reference.  In any case, the complicated features of looping
    through two ETuple _data members is all packaged up right here and
    shouldn't be allowed to spread.
    """
    if ind1[0] >= self._nonzero and ind2[0] >= other._nonzero:
        return 0
    if ind1[0] < self._nonzero and ind2[0] < other._nonzero:
        if self._data[2*ind1[0]] == other._data[2*ind2[0]]:
            exp1[0] = self._data[2*ind1[0]+1]
            exp2[0] = other._data[2*ind2[0]+1]
            index[0] = self._data[2*ind1[0]]
            ind1[0] += 1
            ind2[0] += 1
        elif self._data[2*ind1[0]] > other._data[2*ind2[0]]:
            exp1[0] = 0
            exp2[0] = other._data[2*ind2[0]+1]
            index[0] = other._data[2*ind2[0]]
            ind2[0] += 1
        else:
            exp1[0] = self._data[2*ind1[0]+1]
            exp2[0] = 0
            index[0] = self._data[2*ind1[0]]
            ind1[0] += 1
    else:
        if ind2[0] >= other._nonzero:
            exp1[0] = self._data[2*ind1[0]+1]
            exp2[0] = 0
            index[0] = self._data[2*ind1[0]]
            ind1[0] += 1
        elif ind1[0] >= self._nonzero:
            exp1[0] = 0
            exp2[0] = other._data[2*ind2[0]+1]
            index[0] = other._data[2*ind2[0]]
            ind2[0] += 1
    return 1

cdef class ETuple:
    """
    Representation of the exponents of a polydict monomial. If
    (0,0,3,0,5) is the exponent tuple of x_2^3*x_4^5 then this class
    only stores {2:3, 4:5} instead of the full tuple. This sparse
    information may be obtained by provided methods.

    The index/value data is all stored in the _data C int array member
    variable.  For the example above, the C array would contain
    2,3,4,5.  The indices are interlaced with the values.

    This data structure is very nice to work with for some functions
    implemented in this class, but tricky for others.  One reason that
    I really like the format is that it requires a single memory
    allocation for all of the values.  A hash table would require more
    allocations and presumably be slower.  I didn't benchmark this
    question (although, there is no question that this is much faster
    than the prior use of python dicts).
    """
    cdef ETuple _new(ETuple self):
        """
        Quickly creates a new initialized ETuple with the
        same length as self.
        """
        cdef type t = type(self)
        cdef ETuple x = <ETuple>t.__new__(t)
        x._length = self._length
        return x

    def __init__(ETuple self, data=None, length=None):
        """
        - ``ETuple()`` -> an empty ETuple
        - ``ETuple(sequence)`` -> ETuple initialized from sequence's items

        If the argument is an ETuple, the return value is the same object.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: ETuple([1, 1, 0])
            (1, 1, 0)
            sage: ETuple({int(1): int(2)}, int(3))
            (0, 2, 0)
            sage: ETuple([1, -1, 0])
            (1, -1, 0)

        TESTS:

        Iterators are not accepted::

            sage: ETuple(iter([2, 3, 4]))
            Traceback (most recent call last):
            ...
            TypeError: Error in ETuple((), <list... object at ...>, None)
        """
        if data is None:
            return
        cdef size_t ind
        cdef int v
        if isinstance(data, ETuple):
            self._length = (<ETuple>data)._length
            self._nonzero = (<ETuple>data)._nonzero
            self._data = <int*>sig_malloc(sizeof(int)*self._nonzero*2)
            memcpy(self._data, (<ETuple>data)._data, sizeof(int)*self._nonzero*2)
        elif isinstance(data, dict) and isinstance(length, int):
            self._length = length
            self._nonzero = len(data)
            self._data = <int*>sig_malloc(sizeof(int)*self._nonzero*2)
            nz_elts = sorted(data.items())
            ind = 0
            for index, exp in nz_elts:
                self._data[2*ind] = index
                self._data[2*ind+1] = exp
                ind += 1
        elif isinstance(data, (list, tuple)):
            self._length = len(data)
            self._nonzero = 0
            for v in data:
                if v != 0:
                    self._nonzero += 1
            ind = 0
            self._data = <int*>sig_malloc(sizeof(int)*self._nonzero*2)
            for i from 0 <= i < self._length:
                v = data[i]
                if v != 0:
                    self._data[ind] = i
                    self._data[ind+1] = v
                    ind += 2
        else:
            raise TypeError("Error in ETuple(%s, %s, %s)" % (self, data, length))

    def __cinit__(ETuple self):
        self._data = <int*>0

    def __dealloc__(self):
        if self._data != <int*>0:
            sig_free(self._data)

    def __bool__(self):
        r"""
        TESTS::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: bool(ETuple([1]))
            True
            sage: bool(ETuple([]))
            False
            sage: bool(ETuple([0,0,0]))
            False
        """
        return bool(self._nonzero)

    # methods to simulate tuple

    def __add__(ETuple self, ETuple other):
        """
        x.__add__(n) <==> x+n

        concatenates two ETuples

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: ETuple([1,1,0]) + ETuple({int(1):int(2)}, int(3))
            (1, 1, 0, 0, 2, 0)
        """
        cdef size_t index = 0
        cdef ETuple result = <ETuple>ETuple.__new__(ETuple)
        result._length = self._length+other._length
        result._nonzero = self._nonzero+other._nonzero
        result._data = <int*>sig_malloc(sizeof(int)*result._nonzero*2)
        for index from 0 <= index < self._nonzero:
            result._data[2*index] = self._data[2*index]
            result._data[2*index+1] = self._data[2*index+1]
        for index from 0 <= index < other._nonzero:
            result._data[2*(index+self._nonzero)] = other._data[2*index]+self._length  # offset the second tuple (append to end!)
            result._data[2*(index+self._nonzero)+1] = other._data[2*index+1]
        return result

    def __mul__(ETuple self, factor):
        """
        x.__mul__(n) <==> x*n

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: ETuple([1,2,3])*2
            (1, 2, 3, 1, 2, 3)
        """
        cdef int _factor = factor
        cdef ETuple result = <ETuple>ETuple.__new__(ETuple)
        if factor <= 0:
            result._length = 0
            result._nonzero = 0
            return result
        cdef size_t index
        cdef size_t f
        result._length = self._length * factor
        result._nonzero = self._nonzero * factor
        result._data = <int*>sig_malloc(sizeof(int)*result._nonzero*2)
        for index from 0 <= index < self._nonzero:
            for f from 0 <= f < factor:
                result._data[2*(f*self._nonzero+index)] = self._data[2*index]+f*self._length
                result._data[2*(f*self._nonzero+index)+1] = self._data[2*index+1]
        return result

    def __getitem__(ETuple self, i):
        """
        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: m = ETuple([1,2,0,3])
            sage: m[2]
            0
            sage: m[1]
            2
            sage: e = ETuple([1,2,3])
            sage: e[1:]
            (2, 3)
            sage: e[:1]
            (1,)
        """
        cdef size_t ind
        if isinstance(i, slice):
            start, stop = i.start, i.stop
            if start is None:
                start = 0
            elif start < 0:
                start = start % self._length
            elif start > self._length:
                start = self._length

            if stop is None or stop > self._length:
                stop = self._length
            elif stop < 0:
                stop = stop % self._length

            # this is not particularly fast, but I doubt many people care
            # if you do, feel free to tweak!
            d = [self[ind] for ind from start <= ind < stop]
            return ETuple(d)
        else:
            for ind in range(0, 2*self._nonzero, 2):
                if self._data[ind] == i:
                    return self._data[ind+1]
                elif self._data[ind] > i:
                    # the indices are sorted in _data, we are beyond, so quit
                    return 0
            return 0

    cdef int get_exp(ETuple self, size_t i):
        """
        Return the exponent for the ``i``-th variable.
        """
        cdef size_t ind = 0
        for ind in range(0, 2*self._nonzero, 2):
            if self._data[ind] == i:
                return self._data[ind+1]
            elif self._data[ind] > i:
                # the indices are sorted in _data, we are beyond, so quit
                return 0
        return 0

    def __hash__(ETuple self):
        """
        x.__hash__() <==> hash(x)
        """
        cdef int i
        cdef int result = 0
        for i from 0 <= i < self._nonzero:
            result += (1000003 * result) ^ self._data[2*i]
            result += (1000003 * result) ^ self._data[2*i+1]
        result = (1000003 * result) ^ self._length
        return result

    def __len__(ETuple self):
        """
        x.__len__() <==> len(x)

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e=ETuple([1,0,2,0,3])
            sage: len(e)
            5
        """
        return self._length

    def __contains__(ETuple self, elem):
        """
        x.__contains__(n) <==> n in x

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple({int(1):int(2)}, int(3)); e
            (0, 2, 0)
            sage: 1 in e
            False
            sage: 2 in e
            True
        """
        if elem==0:
            return self._length > self._nonzero

        cdef size_t ind = 0
        for ind from 0 <= ind < self._nonzero:
            if elem == self._data[2*ind+1]:
                return True
        return False

    def __richcmp__(ETuple self, ETuple other, op):
        """
        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: ETuple([1,1,0])<ETuple([1,1,0])
            False
            sage: ETuple([1,1,0])<ETuple([1,0,0])
            False
            sage: ETuple([1,1,0])<ETuple([1,2,0])
            True
            sage: ETuple([1,1,0])<ETuple([1,-1,0])
            False
            sage: ETuple([0,-2,0])<ETuple([1,-1,0])
            True
            sage: ETuple([1,1,0])>ETuple([1,1,0])
            False
            sage: ETuple([1,1,0])>ETuple([1,0,0])
            True
            sage: ETuple([1,1,0])>ETuple([1,2,0])
            False
            sage: ETuple([1,1,0])>ETuple([1,-1,0])
            True
            sage: ETuple([0,-2,0])>ETuple([1,-1,0])
            False
        """
        cdef size_t ind = 0
        if op == Py_EQ:  # ==
            if self._nonzero != other._nonzero:
                return False
            for ind from 0 <= ind < self._nonzero:
                if self._data[2*ind] != other._data[2*ind]:
                    return False
                if self._data[2*ind+1] != other._data[2*ind+1]:
                    return False
            return self._length == other._length

        if op == Py_LT:  # <
            while ind < self._nonzero and ind < other._nonzero:
                if self._data[2*ind] < other._data[2*ind]:
                    return self._data[2*ind+1] < 0
                if self._data[2*ind] > other._data[2*ind]:
                    return other._data[2*ind+1] > 0
                if self._data[2*ind] == other._data[2*ind] and self._data[2*ind+1] != other._data[2*ind+1]:
                    return self._data[2*ind+1] < other._data[2*ind+1]
                ind += 1
            if ind < self._nonzero and ind == other._nonzero:
                return self._data[2*ind+1] < 0
            if ind < other._nonzero and ind == self._nonzero:
                return other._data[2*ind+1] > 0
            return self._length < other._length

        if op == Py_GT:  # >
            while ind < self._nonzero and ind < other._nonzero:
                if self._data[2*ind] < other._data[2*ind]:
                    return self._data[2*ind+1] > 0
                if self._data[2*ind] > other._data[2*ind]:
                    return other._data[2*ind+1] < 0
                if self._data[2*ind] == other._data[2*ind] and self._data[2*ind+1] != other._data[2*ind+1]:
                    return self._data[2*ind+1] > other._data[2*ind+1]
                ind += 1
            if ind < self._nonzero and ind == other._nonzero:
                return self._data[2*ind+1] > 0
            if ind < other._nonzero and ind == self._nonzero:
                return other._data[2*ind+1] < 0
            return self._length < other._length

        # the rest of these are not particularly fast

        if op == Py_LE:  # <=
            return tuple(self) <= tuple(other)

        if op == Py_NE:  # !=
            return tuple(self) != tuple(other)

        if op == Py_GE:  # >=
            return tuple(self) >= tuple(other)

    def __iter__(ETuple self):
        """
        x.__iter__() <==> iter(x)

        TESTS::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple((4,0,0,2,0))
            sage: list(e)
            [4, 0, 0, 2, 0]

        Check that :trac:`28178` is fixed::

            sage: it = iter(e)
            sage: iter(it) is it
            True
        """
        cdef size_t i
        cdef size_t ind = 0

        for i in range(self._length):
            if ind >= self._nonzero:
                yield 0
            elif self._data[2*ind] == i:
                yield self._data[2*ind + 1]
                ind += 1
            else:
                yield 0

    def __str__(ETuple self):
        return repr(self)

    def __repr__(ETuple self):
        r"""
        TESTS::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: ETuple((0,))
            (0,)
            sage: ETuple((1,))
            (1,)
            sage: ETuple((0,1,2))
            (0, 1, 2)
        """
        if self._length == 1:
            if self._nonzero:
                return '(%d,)' % self._data[1]
            else:
                return '(0,)'
        else:
            return '(' + ', '.join(map(str, self)) + ')'

    def __reduce__(ETuple self):
        """
        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,1,0])
            sage: bool(e == loads(dumps(e)))
            True
        """
        cdef size_t ind
        # this is not particularly fast, but I doubt many people care
        # if you do, feel free to tweak!
        d = {self._data[2*ind]: self._data[2*ind+1]
             for ind from 0 <= ind < self._nonzero}
        return make_ETuple, (d, int(self._length))

    # additional methods

    cpdef size_t unweighted_degree(self):
        r"""
        Return the sum of entries.

        ASSUMPTION:

        All entries are non-negative.

        EXAMPLES::

             sage: from sage.rings.polynomial.polydict import ETuple
             sage: e = ETuple([1,1,0,2,0])
             sage: e.unweighted_degree()
             4
        """
        cdef size_t degree = 0
        cdef size_t i
        for i in range(1, 2*self._nonzero, 2):
            degree += self._data[i]
        return degree

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef size_t weighted_degree(self, tuple w):
        r"""
        Return the weighted sum of entries.

        INPUT:

        - ``w`` -- tuple of non-negative integers

        ASSUMPTIONS:

        ``w`` has the same length as ``self``, and the entries of ``self``
        and ``w`` are non-negative.
        """
        cdef size_t i
        cdef size_t deg = 0
        if len(w) != self._length:
            raise ValueError
        for i in range(0, 2*self._nonzero, 2):
            deg += <size_t> self._data[i+1] * <size_t> w[self._data[i]]
        return deg

    cdef size_t unweighted_quotient_degree(self, ETuple other):
        """
        Degree of ``self`` divided by its gcd with ``other``.

        It amounts to counting the non-negative entries of
        ``self.esub(other)``.
        """
        cdef size_t ind1 = 0    # both ind1 and ind2 will be increased in double steps.
        cdef size_t ind2 = 0
        cdef int exponent
        cdef int position
        cdef size_t selfnz = 2 * self._nonzero
        cdef size_t othernz = 2 * other._nonzero

        cdef size_t deg = 0
        while ind1 < selfnz:
            position = self._data[ind1]
            exponent = self._data[ind1+1]
            while ind2 < othernz and other._data[ind2] < position:
                ind2 += 2
            if ind2 == othernz:
                while ind1 < selfnz:
                    deg += self._data[ind1+1]
                    ind1 += 2
                return deg
            if other._data[ind2] > position:
                # other[position] = 0
                deg += exponent
            elif other._data[ind2+1] < exponent:
                # There is a positive difference that we have to insert
                deg += (exponent - other._data[ind2+1])
            ind1 += 2
        return deg

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef size_t weighted_quotient_degree(self, ETuple other, tuple w):
        r"""
        Weighted degree of ``self`` divided by its gcd with ``other``.

        INPUT:

        - ``other`` -- an :class:`~sage.rings.polynomial.polydict.ETuple`
        - ``w`` -- tuple of non-negative integers.

        ASSUMPTIONS:

        ``w`` and ``other`` have the same length as ``self``, and the
        entries of ``self``, ``other`` and ``w`` are non-negative.
        """
        cdef size_t ind1 = 0    # both ind1 and ind2 will be increased in double steps.
        cdef size_t ind2 = 0
        cdef size_t exponent
        cdef int position
        cdef size_t selfnz = 2 * self._nonzero
        cdef size_t othernz = 2 * other._nonzero

        cdef size_t deg = 0
        assert len(w) == self._length
        while ind1 < selfnz:
            position = self._data[ind1]
            exponent = self._data[ind1+1]
            while ind2 < othernz and other._data[ind2] < position:
                ind2 += 2
            if ind2 == othernz:
                while ind1 < selfnz:
                    deg += <size_t>self._data[ind1+1] * <size_t> w[self._data[ind1]]
                    ind1 += 2
                return deg
            if other._data[ind2] > position:
                # other[position] = 0
                deg += exponent * <size_t>w[position]
            elif other._data[ind2+1] < exponent:
                # There is a positive difference that we have to insert
                deg += <size_t> (exponent - other._data[ind2+1]) * <size_t>w[position]
            ind1 += 2
        return deg

    cpdef ETuple eadd(ETuple self, ETuple other):
        """
        Vector addition of ``self`` with ``other``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2])
            sage: f = ETuple([0,1,1])
            sage: e.eadd(f)
            (1, 1, 3)

        Verify that :trac:`6428` has been addressed::

            sage: R.<y, z> = Frac(QQ['x'])[]
            sage: type(y)
            <class 'sage.rings.polynomial.multi_polynomial_libsingular.MPolynomial_libsingular'>
            sage: y^(2^32)
            Traceback (most recent call last):
            ...
            OverflowError: exponent overflow (...)   # 64-bit
            OverflowError: Python int too large to convert to C unsigned long  # 32-bit
        """
        if self._length!=other._length:
            raise ArithmeticError

        cdef size_t ind1 = 0
        cdef size_t ind2 = 0
        cdef size_t index
        cdef int exp1
        cdef int exp2
        cdef int s  # sum
        cdef size_t alloc_len = self._nonzero + other._nonzero  # we simply guesstimate the length -- there might be double the correct amount allocated -- who cares?
        if alloc_len > self._length:
            alloc_len = self._length
        cdef ETuple result = <ETuple>self._new()
        result._nonzero = 0  # we don't know the correct length quite yet
        result._data = <int*>sig_malloc(sizeof(int)*alloc_len*2)
        while dual_etuple_iter(self, other, &ind1, &ind2, &index, &exp1, &exp2):
            s = exp1 + exp2
            # Check for overflow and underflow
            if (exp2 > 0 and s < exp1) or (exp2 < 0 and s > exp1):
                raise OverflowError("exponent overflow (%s)" % (int(exp1)+int(exp2)))
            if s != 0:
                result._data[2*result._nonzero] = index
                result._data[2*result._nonzero+1] = s
                result._nonzero += 1
        return result

    cpdef ETuple eadd_p(ETuple self, int other, size_t pos):
        """
        Add ``other`` to ``self`` at position ``pos``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2])
            sage: e.eadd_p(5, 1)
            (1, 5, 2)
            sage: e = ETuple([0]*7)
            sage: e.eadd_p(5,4)
            (0, 0, 0, 0, 5, 0, 0)

            sage: ETuple([0,1]).eadd_p(1, 0) == ETuple([1,1])
            True

            sage: e = ETuple([0, 1, 0])
            sage: e.eadd_p(0, 0).nonzero_positions()
            [1]
            sage: e.eadd_p(0, 1).nonzero_positions()
            [1]
            sage: e.eadd_p(0, 2).nonzero_positions()
            [1]

        TESTS:

        :trac:`34000`::

            sage: e = ETuple([0, 1, 0])
            sage: e.eadd_p(0, 0).nonzero_positions()
            [1]
            sage: e.eadd_p(0, 1).nonzero_positions()
            [1]
            sage: e.eadd_p(0, 2).nonzero_positions()
            [1]
            sage: e.eadd_p(-1, 1).nonzero_positions()
            []
        """
        cdef size_t sindex = 0
        cdef size_t rindex = 0
        cdef int new_value
        if pos >= self._length:
            raise ValueError("pos must be between 0 and %s" % self._length)

        cdef ETuple result = self._new()
        result._nonzero = self._nonzero
        if not other:
            # return a copy
            result._data = <int*> sig_malloc(sizeof(int) * self._nonzero * 2)
            memcpy(result._data, self._data, sizeof(int) * self._nonzero * 2)
            return result

        result._data = <int*> sig_malloc(sizeof(int) * (self._nonzero + 1) * 2)
        while sindex < self._nonzero and self._data[2*sindex] < pos:
            result._data[2*sindex] = self._data[2*sindex]
            result._data[2*sindex+1] = self._data[2*sindex+1]
            sindex += 1

        if sindex < self._nonzero and self._data[2*sindex] == pos:
            new_value = self._data[2*sindex+1] + other
            if new_value:
                result._data[2*sindex] = pos
                result._data[2*sindex+1] = new_value
                sindex += 1
                rindex = sindex
            else:
                result._nonzero -= 1
                rindex = sindex
                sindex += 1
        else:
            result._data[2*sindex] = pos
            result._data[2*sindex+1] = other
            result._nonzero += 1
            rindex = sindex + 1

        while sindex < self._nonzero:
            result._data[2*rindex] = self._data[2*sindex]
            result._data[2*rindex+1] = self._data[2*sindex+1]
            sindex += 1
            rindex += 1

        return result

    cpdef ETuple eadd_scaled(ETuple self, ETuple other, int scalar):
        """
        Vector addition of ``self`` with ``scalar * other``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2])
            sage: f = ETuple([0,1,1])
            sage: e.eadd_scaled(f, 3)
            (1, 3, 5)
        """
        if self._length != other._length:
            raise ArithmeticError

        cdef size_t ind1 = 0
        cdef size_t ind2 = 0
        cdef size_t index
        cdef int exp1
        cdef int exp2
        cdef int s  # sum
        cdef size_t alloc_len = self._nonzero + other._nonzero  # we simply guesstimate the length -- there might be double the correct amount allocated -- who cares?
        if alloc_len > self._length:
            alloc_len = self._length
        cdef ETuple result = <ETuple>self._new()
        result._nonzero = 0  # we don't know the correct length quite yet
        result._data = <int*>sig_malloc(sizeof(int)*alloc_len*2)
        while dual_etuple_iter(self, other, &ind1, &ind2, &index, &exp1, &exp2):
            exp2 *= scalar
            s = exp1 + exp2
            # Check for overflow and underflow
            if (exp2 > 0 and s < exp1) or (exp2 < 0 and s > exp1):
                raise OverflowError("exponent overflow (%s)" % (int(exp1)+int(exp2)))
            if s != 0:
                result._data[2*result._nonzero] = index
                result._data[2*result._nonzero+1] = s
                result._nonzero += 1
        return result

    cpdef ETuple esub(ETuple self, ETuple other):
        """
        Vector subtraction of ``self`` with ``other``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2])
            sage: f = ETuple([0,1,1])
            sage: e.esub(f)
            (1, -1, 1)
        """
        if self._length!=other._length:
            raise ArithmeticError

        cdef size_t ind1 = 0
        cdef size_t ind2 = 0
        cdef size_t index
        cdef int exp1
        cdef int exp2
        cdef int d  # difference
        cdef size_t alloc_len = self._nonzero + other._nonzero  # we simply guesstimate the length -- there might be double the correct amount allocated -- who cares?
        if alloc_len > self._length:
            alloc_len = self._length
        cdef ETuple result = <ETuple>self._new()
        result._nonzero = 0  # we don't know the correct length quite yet
        result._data = <int*>sig_malloc(sizeof(int)*alloc_len*2)
        while dual_etuple_iter(self, other, &ind1, &ind2, &index, &exp1, &exp2):
            # Check for overflow and underflow
            d = exp1 - exp2
            if (exp2 > 0 and d > exp1) or (exp2 < 0 and d < exp1):
                raise OverflowError("Exponent overflow (%s)" % (int(exp1)-int(exp2)))
            if d != 0:
                result._data[2*result._nonzero] = index
                result._data[2*result._nonzero+1] = d
                result._nonzero += 1
        return result

    cpdef ETuple emul(ETuple self, int factor):
        """
        Scalar Vector multiplication of ``self``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2])
            sage: e.emul(2)
            (2, 0, 4)
        """
        cdef size_t ind
        cdef ETuple result = <ETuple>self._new()
        if factor == 0:
            result._nonzero = 0  # all zero, no non-zero entries!
            result._data = <int*>sig_malloc(sizeof(int)*result._nonzero*2)
        else:
            result._nonzero = self._nonzero
            result._data = <int*>sig_malloc(sizeof(int)*result._nonzero*2)
            for ind from 0 <= ind < self._nonzero:
                result._data[2*ind] = self._data[2*ind]
                result._data[2*ind+1] = self._data[2*ind+1]*factor
        return result

    cpdef ETuple emax(ETuple self, ETuple other):
        """
        Vector of maximum of components of ``self`` and ``other``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2])
            sage: f = ETuple([0,1,1])
            sage: e.emax(f)
            (1, 1, 2)
            sage: e = ETuple((1,2,3,4))
            sage: f = ETuple((4,0,2,1))
            sage: f.emax(e)
            (4, 2, 3, 4)
            sage: e = ETuple((1,-2,-2,4))
            sage: f = ETuple((4,0,0,0))
            sage: f.emax(e)
            (4, 0, 0, 4)
            sage: f.emax(e).nonzero_positions()
            [0, 3]
        """
        if self._length!=other._length:
            raise ArithmeticError

        cdef size_t ind1 = 0
        cdef size_t ind2 = 0
        cdef size_t index
        cdef int exp1
        cdef int exp2
        cdef size_t alloc_len = self._nonzero + other._nonzero  # we simply guesstimate the length -- there might be double the correct amount allocated -- who cares?
        if alloc_len > self._length:
            alloc_len = self._length
        cdef ETuple result = <ETuple>self._new()
        result._nonzero = 0  # we don't know the correct length quite yet
        result._data = <int*>sig_malloc(sizeof(int)*alloc_len*2)
        while dual_etuple_iter(self, other, &ind1, &ind2, &index, &exp1, &exp2):
            if exp1 >= exp2 and exp1 != 0:
                result._data[2*result._nonzero] = index
                result._data[2*result._nonzero+1] = exp1
                result._nonzero += 1
            elif exp2 >= exp1 and exp2 != 0:
                result._data[2*result._nonzero] = index
                result._data[2*result._nonzero+1] = exp2
                result._nonzero += 1
        return result

    cpdef ETuple emin(ETuple self, ETuple other):
        """
        Vector of minimum of components of ``self`` and ``other``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2])
            sage: f = ETuple([0,1,1])
            sage: e.emin(f)
            (0, 0, 1)
            sage: e = ETuple([1,0,-1])
            sage: f = ETuple([0,-2,1])
            sage: e.emin(f)
            (0, -2, -1)
        """
        if self._length != other._length:
            raise ArithmeticError

        cdef size_t ind1 = 0
        cdef size_t ind2 = 0
        cdef size_t index
        cdef int exp1
        cdef int exp2
        cdef size_t alloc_len = self._nonzero + other._nonzero  # we simply guesstimate the length -- there might be double the correct amount allocated -- who cares?
        if alloc_len > self._length:
            alloc_len = self._length
        cdef ETuple result = <ETuple>self._new()
        result._nonzero = 0  # we don't know the correct length quite yet
        result._data = <int*>sig_malloc(sizeof(int)*alloc_len*2)
        while dual_etuple_iter(self, other, &ind1, &ind2, &index, &exp1, &exp2):
            if exp1 <= exp2 and exp1 != 0:
                result._data[2*result._nonzero] = index
                result._data[2*result._nonzero+1] = exp1
                result._nonzero += 1
            elif exp2 <= exp1 and exp2 != 0:
                result._data[2*result._nonzero] = index
                result._data[2*result._nonzero+1] = exp2
                result._nonzero += 1
        return result

    cpdef int dotprod(ETuple self, ETuple other):
        """
        Return the dot product of this tuple by ``other``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2])
            sage: f = ETuple([0,1,1])
            sage: e.dotprod(f)
            2
            sage: e = ETuple([1,1,-1])
            sage: f = ETuple([0,-2,1])
            sage: e.dotprod(f)
            -3

        """
        if self._length != other._length:
            raise ArithmeticError

        cdef size_t ind1 = 0
        cdef size_t ind2 = 0
        cdef size_t index
        cdef int exp1
        cdef int exp2
        cdef int result = 0
        while dual_etuple_iter(self, other, &ind1, &ind2, &index, &exp1, &exp2):
            result += exp1 * exp2
        return result

    cpdef ETuple escalar_div(ETuple self, int n):
        r"""
        Divide each exponent by ``n``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: ETuple([1,0,2]).escalar_div(2)
            (0, 0, 1)
            sage: ETuple([0,3,12]).escalar_div(3)
            (0, 1, 4)

            sage: ETuple([1,5,2]).escalar_div(0)
            Traceback (most recent call last):
            ...
            ZeroDivisionError

        TESTS:

        Checking that memory allocation works fine::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: t = ETuple(list(range(2048)))
            sage: for n in range(1,9):
            ....:     t = t.escalar_div(n)
            sage: assert t.is_constant()
        """
        if not n:
            raise ZeroDivisionError
        cdef size_t i, j
        cdef ETuple result = self._new()
        result._data = <int*> sig_malloc(sizeof(int) * 2 * self._nonzero)
        result._nonzero = 0
        for i in range(self._nonzero):
            result._data[2 * result._nonzero + 1] = self._data[2 * i + 1] / n
            if result._data[2 * result._nonzero + 1]:
                result._data[2 * result._nonzero] = self._data[2 * i]
                result._nonzero += 1
        return result

    cdef ETuple divide_by_gcd(self, ETuple other):
        """
        Return ``self / gcd(self, other)``.

        The entries of the result are the maximum of 0 and the
        difference of the corresponding entries of ``self`` and ``other``.
        """
        cdef size_t ind1 = 0    # both ind1 and ind2 will be increased in 2-steps.
        cdef size_t ind2 = 0
        cdef int exponent
        cdef int position
        cdef size_t selfnz = 2 * self._nonzero
        cdef size_t othernz = 2 * other._nonzero
        cdef ETuple result = <ETuple> self._new()
        result._nonzero = 0
        result._data = <int*> sig_malloc(sizeof(int)*self._nonzero*2)
        while ind1 < selfnz:
            position = self._data[ind1]
            exponent = self._data[ind1+1]
            while ind2 < othernz and other._data[ind2] < position:
                ind2 += 2
            if ind2 == othernz:
                while ind1 < selfnz:
                    result._data[2*result._nonzero] = self._data[ind1]
                    result._data[2*result._nonzero+1] = self._data[ind1+1]
                    result._nonzero += 1
                    ind1 += 2
                return result
            if other._data[ind2] > position:
                # other[position] == 0
                result._data[2*result._nonzero] = position
                result._data[2*result._nonzero+1] = exponent
                result._nonzero += 1
            elif other._data[ind2+1] < exponent:
                # There is a positive difference that we have to insert
                result._data[2*result._nonzero] = position
                result._data[2*result._nonzero+1] = exponent - other._data[ind2+1]
                result._nonzero += 1
            ind1 += 2
        return result

    cdef ETuple divide_by_var(self, size_t index):
        """
        Return division of ``self`` by ``var(index)`` or ``None``.

        If ``self[Index] == 0`` then None is returned. Otherwise, an
        :class:`~sage.rings.polynomial.polydict.ETuple` is returned
        that is zero in position ``index`` and coincides with ``self``
        in the other positions.
        """
        cdef size_t i, j
        cdef int exp1
        cdef ETuple result
        for i in range(0, 2*self._nonzero,2):
            if self._data[i] == index:
                result = <ETuple>self._new()
                result._data = <int*>sig_malloc(sizeof(int)*self._nonzero*2)
                exp1 = self._data[i+1]
                if exp1>1:
                    # division doesn't change the number of nonzero positions
                    result._nonzero = self._nonzero
                    for j in range(0, 2*self._nonzero, 2):
                        result._data[j] = self._data[j]
                        result._data[j+1] = self._data[j+1]
                    result._data[i+1] = exp1-1
                else:
                    # var(index) disappears from self
                    result._nonzero = self._nonzero-1
                    for j in range(0, i, 2):
                        result._data[j] = self._data[j]
                        result._data[j+1] = self._data[j+1]
                    for j in range(i+2, 2*self._nonzero, 2):
                        result._data[j-2] = self._data[j]
                        result._data[j-1] = self._data[j+1]
                return result
        return None

    cdef bint divides(self, ETuple other):
        """
        Whether ``self`` divides ``other``, i.e., no entry of ``self``
        exceeds that of ``other``.
        """
        cdef size_t ind1     # will be increased in 2-steps
        cdef size_t ind2 = 0 # will be increased in 2-steps
        cdef int pos1, exp1
        if self._nonzero > other._nonzero:
            # Trivially self cannot divide other
            return False
        cdef size_t othernz2 = 2 * other._nonzero
        for ind1 in range(0, 2*self._nonzero, 2):
            pos1 = self._data[ind1]
            exp1 = self._data[ind1+1]
            # Because of the above trivial test, other._nonzero>0.
            # So, other._data[ind2] initially makes sense.
            while other._data[ind2] < pos1:
                ind2 += 2
                if ind2 >= othernz2:
                    return False
            if other._data[ind2] > pos1 or other._data[ind2+1] < exp1:
                # Either other has no exponent at position pos1 or the exponent is less than in self
                return False
        return True

    cpdef bint is_constant(ETuple self):
        """
        Return if all exponents are zero in the tuple.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2])
            sage: e.is_constant()
            False
            sage: e = ETuple([0,0])
            sage: e.is_constant()
            True
        """
        return self._nonzero == 0

    cpdef bint is_multiple_of(ETuple self, int n):
        r"""
        Test whether each entry is a multiple of ``n``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple

            sage: ETuple([0,0]).is_multiple_of(3)
            True
            sage: ETuple([0,3,12,0,6]).is_multiple_of(3)
            True
            sage: ETuple([0,0,2]).is_multiple_of(3)
            False
        """
        if not n:
            raise ValueError('n should not be zero')
        cdef int i
        for i in range(self._nonzero):
            if self._data[2 * i + 1] % n:
                return False
        return True

    cpdef list nonzero_positions(ETuple self, bint sort=False):
        """
        Return the positions of non-zero exponents in the tuple.

        INPUT:

        - ``sort`` -- (default: ``False``) if ``True`` a sorted list is
          returned; if ``False`` an unsorted list is returned

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2])
            sage: e.nonzero_positions()
            [0, 2]
        """
        cdef size_t ind
        return [self._data[2*ind] for ind from 0 <= ind < self._nonzero]

    cpdef common_nonzero_positions(ETuple self, ETuple other, bint sort=False):
        """
        Returns an optionally sorted list of non zero positions either
        in self or other, i.e. the only positions that need to be
        considered for any vector operation.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2])
            sage: f = ETuple([0,0,1])
            sage: e.common_nonzero_positions(f)
            {0, 2}
            sage: e.common_nonzero_positions(f, sort=True)
            [0, 2]
        """
        # TODO:  we should probably make a fast version of this!
        res = set(self.nonzero_positions()).union(other.nonzero_positions())
        if sort:
            return sorted(res)
        else:
            return res

    cpdef list nonzero_values(ETuple self, bint sort=True):
        """
        Return the non-zero values of the tuple.

        INPUT:

        - ``sort`` -- (default: ``True``) if ``True`` the values are sorted
          by their indices; otherwise the values are returned unsorted

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([2,0,1])
            sage: e.nonzero_values()
            [2, 1]
            sage: f = ETuple([0,-1,1])
            sage: f.nonzero_values(sort=True)
            [-1, 1]
        """
        cdef size_t ind
        return [self._data[2*ind+1] for ind from 0 <= ind < self._nonzero]

    cpdef ETuple reversed(ETuple self):
        """
        Return the reversed ETuple of ``self``.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,2,3])
            sage: e.reversed()
            (3, 2, 1)
        """
        cdef size_t ind
        cdef ETuple result = <ETuple>self._new()
        result._nonzero = self._nonzero
        result._data = <int*>sig_malloc(sizeof(int)*result._nonzero*2)
        for ind from 0 <= ind < self._nonzero:
            result._data[2*(result._nonzero-ind-1)] = self._length - self._data[2*ind] - 1
            result._data[2*(result._nonzero-ind-1)+1] = self._data[2*ind+1]
        return result

    def sparse_iter(ETuple self):
        """
        Iterator over the elements of ``self`` where the elements are returned
        as ``(i, e)`` where ``i`` is the position of ``e`` in the tuple.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([1,0,2,0,3])
            sage: list(e.sparse_iter())
            [(0, 1), (2, 2), (4, 3)]
        """
        cdef size_t ind
        for ind from 0 <= ind < self._nonzero:
            yield (self._data[2*ind], self._data[2*ind+1])

    def combine_to_positives(ETuple self, ETuple other):
        """
        Given a pair of ETuples (self, other), returns a triple of
        ETuples (a, b, c) so that self = a + b, other = a + c and b and c
        have all positive entries.

        EXAMPLES::

            sage: from sage.rings.polynomial.polydict import ETuple
            sage: e = ETuple([-2,1,-5, 3, 1,0])
            sage: f = ETuple([1,-3,-3,4,0,2])
            sage: e.combine_to_positives(f)
            ((-2, -3, -5, 3, 0, 0), (0, 4, 0, 0, 1, 0), (3, 0, 2, 1, 0, 2))
        """
        m = self.emin(other)
        return m, self.esub(m), other.esub(m)


def make_PolyDict(data):
    return PolyDict(data, remove_zero=False)


def make_ETuple(data, length):
    return ETuple(data, length)
