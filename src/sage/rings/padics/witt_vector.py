r"""
Witt vectors

Implementation of the class :class:`WittVector` of truncated Witt vectors.

AUTHORS:

- Jacob Dennerlein (2022-11-28): initial version
- Rubén Muñoz-\-Bertrand (2025-02-13): major refactoring and clean-up

"""

# ****************************************************************************
#       Copyright (C) 2025 Rubén Muñoz--Bertrand
#                          <ruben.munoz--bertrand@univ-fcomte.fr>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#                  https://www.gnu.org/licenses/
# ****************************************************************************


from sage.rings.finite_rings.finite_field_constructor import GF
from sage.rings.integer import Integer
from sage.rings.padics.factory import Zp
from sage.rings.polynomial.polynomial_ring_constructor import PolynomialRing
from sage.structure.element import CommutativeRingElement
from sage.structure.richcmp import op_EQ, op_NE


class WittVector(CommutativeRingElement):
    """
    Base class for truncated Witt vectors.

    EXAMPLES::

        sage: W = WittVectorRing(GF(25), p=5, prec=3)
        sage: W(12)
        (2, 1, 3)

        sage: W = WittVectorRing(Integers(6), p=3, prec=4)
        sage: w = W([1,2,3,4]) * W([4,5,0,0])
        sage: w
        (4, 1, 3, 4)

        sage: TestSuite(w).run()
    """
    def __init__(self, parent, vec=None):
        """
        Common class for all kinds of Witt vectors.

        EXAMPLES::

            sage: W = WittVectorRing(GF(3))
            sage: e = W.one(); e
            (1)
            sage: e^2
            (1)
            sage: -e
            (2)

            sage: W = WittVectorRing(GF(3), prec=4)
            sage: t = W([1,2,0,1])
            sage: t^2
            (1, 1, 0, 2)
            sage: -t
            (2, 1, 0, 2)
            sage: 1/t
            (1, 1, 1, 0)

            sage: W=WittVectorRing(ZZ, p=5, prec=2)
            sage: WW=WittVectorRing(ZZ, p=5, prec=2)
            sage: W((4,10)) * WW((-5,12,1))
            (-20, -18362)
            sage: WW((1,2,3)) + W((1,2))
            (2, -2)
        """
        self._prec = parent.precision()
        B = parent.base()
        if vec is not None:
            if isinstance(vec, int) or isinstance(vec, Integer):
                self._int_to_vector(vec, parent)
            elif isinstance(vec, WittVector):
                if vec.parent().precision() < self._prec:
                    raise ValueError(f'{vec} has not the correct length. '
                                     'Expected length has to be at least '
                                     f'{self._prec}.')
                if not B.has_coerce_map_from(vec.parent().base()):
                    raise ValueError('Cannot coerce an element of '
                                     f'{vec.base()} to an element of {B}.')
                self._vec = tuple(B(vec._vec[i]) for i in range(self._prec))
            elif isinstance(vec, tuple) or isinstance(vec, list):
                if len(vec) < self._prec:
                    raise ValueError(f'{vec} has not the correct length. '
                                     'Expected length has to be at least '
                                     f'{self._prec}.')
                self._vec = tuple(B(vec[i]) for i in range(self._prec))
            else:
                raise ValueError(f'{vec} cannot be interpreted as a Witt '
                                 'vector.')
        else:
            self._vec = (B(0) for i in range(self._prec))
        CommutativeRingElement.__init__(self, parent)

    def __hash__(self) -> int:
        """
        Return the hash of ``self``.

        EXAMPLES::

            sage: W = WittVectorRing(GF(3), prec=4)
            sage: t = W([1,2,0,1])
            sage: hash(t)  # random
            -2438844084280889141
        """
        return hash(self._vec)

    def _richcmp_(self, other, op) -> bool:
        """
        Compare ``self`` and ``other``.

        EXAMPLES::

            sage: W = WittVectorRing(GF(3), prec=4)
            sage: t = W([1,2,0,1])
            sage: u = 1/t
            sage: u == t
            False
            sage: t != t
            False
        """
        if not isinstance(other, WittVector):
            return NotImplemented
        if op == op_EQ:
            return self._vec == other._vec
        if op == op_NE:
            return self._vec != other._vec
        return NotImplemented

    def _repr_(self) -> str:
        """
        Return a string representation.

        EXAMPLES::

            sage: W = WittVectorRing(GF(3), prec=4)
            sage: t = W([1,2,0,1]); t
            (1, 2, 0, 1)
        """
        return '(' + ', '.join(map(str, self._vec)) + ')'

    def _add_(self, other):
        """
        Return the sum of ``self`` and ``other``.

        EXAMPLES::

            sage: W = WittVectorRing(GF(3), prec=4)
            sage: t = W([1,2,0,1])
            sage: u = 1/t
            sage: u + t
            (2, 1, 1, 1)
        """
        P = self.parent()

        # As a slight optimization, we'll check for zero ahead of time.
        if other == P.zero():
            return self
        elif self == P.zero():
            return other

        alg = P._algorithm
        if alg == 'standard':
            s = P._sum_polynomials
            # note here this is tuple addition, i.e. concatenation
            sum_vec = tuple(s[i](*(self._vec + other._vec))
                            for i in range(self._prec))
        elif alg == 'finotti':
            x = self._vec
            y = other._vec
            prec = P.precision()

            G = []
            for n in range(prec):
                G_n = [x[n], y[n]]
                for i in range(n):
                    G_n.append(P._eta_bar(G[i], n - i))
                G.append(G_n)
            sum_vec = tuple(sum(G[i]) for i in range(prec))
        elif alg == 'Zq_isomorphism':
            x = P._vector_to_series(self._vec)
            y = P._vector_to_series(other._vec)
            sum_vec = P._series_to_vector(x + y)
        elif alg == 'p_invertible':
            p = P._prime  # we know p is a unit in this case!
            x = self._vec
            y = other._vec

            sum_vec = [x[0] + y[0]]
            for n in range(1, self._prec):
                next_sum = x[n] + y[n] + \
                    sum((x[i]**(p**(n - i)) + y[i]**(p**(n - i))
                         - sum_vec[i]**(p**(n - i)))
                        / p**(n - i)
                        for i in range(n))
                sum_vec.append(next_sum)

        return P(sum_vec)

    def _mul_(self, other):
        """
        Return the product of ``self`` and ``other``.

        EXAMPLES::

            sage: W = WittVectorRing(GF(3), prec=4)
            sage: t = W([1,2,0,1])
            sage: u = 1/t + 1
            sage: u * t
            (2, 0, 0, 1)
        """
        P = self.parent()

        # As a slight optimization, we'll check for zero or one ahead of time.
        if self == P.zero() or other == P.zero():
            return P.zero()
        if other == P.one():
            return self
        if self == P.one():
            return other

        alg = P._algorithm
        from sage.rings.padics.witt_vector_ring import _fast_char_p_power as _fcppow
        if alg == 'standard':
            p = P._prod_polynomials
            # note here this is tuple addition, i.e. concatenation
            prod_vec = tuple(p[i](*(self._vec + other._vec))
                             for i in range(self._prec))
        elif alg == 'finotti':
            x = self._vec
            y = other._vec
            prec = P.precision()
            p = P._prime

            G = [[x[0] * y[0]]]
            for n in range(1, prec):
                G_n = [_fcppow(x[0], p**n) * y[n], _fcppow(y[0], p**n) * x[n]]
                G_n.extend(_fcppow(x[i], p**(n - i)) * _fcppow(y[n - i], p**i)
                           for i in range(1, n))
                for i in range(n):
                    G_n.append(P._eta_bar(G[i], n - i))
                G.append(G_n)
            prod_vec = tuple(sum(G[i]) for i in range(prec))
        elif alg == 'Zq_isomorphism':
            x = P._vector_to_series(self._vec)
            y = P._vector_to_series(other._vec)
            prod_vec = P._series_to_vector(x * y)
        elif alg == 'p_invertible':
            p = P._prime  # we know p is a unit in this case!
            x = self._vec
            y = other._vec

            prod_vec = [x[0] * y[0]]
            for n in range(1, self._prec):
                next_prod = (
                    sum(p**i * x[i]**(p**(n - i)) for i in range(n + 1)) *
                    sum(p**i * y[i]**(p**(n - i)) for i in range(n + 1)) -
                    sum(p**i * prod_vec[i]**(p**(n - i)) for i in range(n))
                ) / p**n
                prod_vec.append(next_prod)

        return P(prod_vec)

    def _neg_(self):
        """
        Return the opposite of ``self``.

        EXAMPLES::

            sage: W = WittVectorRing(GF(3), prec=4)
            sage: t = W([1,2,0,1])
            sage: -t
            (2, 1, 0, 2)
        """
        P = self.parent()
        # If p == 2, -1 == (-1, -1, -1, ...)
        # Otherwise, -1 == (-1, 0, 0, ...)
        if P._prime == 2:
            all_ones = P(tuple(-1 for _ in range(self._prec)))
            return all_ones * self
        neg_vec = tuple(-self._vec[i] for i in range(self._prec))
        return P(neg_vec)

    def _div_(self, other):
        """
        Return the quotient of ``self`` and ``other``.

        EXAMPLES::

            sage: W = WittVectorRing(GF(3), prec=4)
            sage: t = W([1,2,0,1])
            sage: u = 1/t + 1
            sage: u / t
            (2, 1, 2, 1)
        """
        P = self.parent()
        # As a slight optimization, we'll check for one ahead of time.
        if other == P.one():
            return self
        elif self == P.one():
            return other._invert_()

        return self * other._invert_()

    def _invert_(self):
        """
        Return the inverse of ``self``.

        EXAMPLES::

            sage: W = WittVectorRing(GF(3), prec=4)
            sage: t = W([1,2,0,1])
            sage: ~t
            (1, 1, 1, 0)
        """
        if not self._vec[0].is_unit():
            raise ZeroDivisionError(f"Inverse of {self} does not exist.")
        P = self.parent()

        if self == P.one():
            return self
        if self._prec == 1:
            return P((self._vec[0]**-1, ))

        # Strategy: Multiply ``self`` by ``(Y_0, Y_1, ...)``, set equal
        # to (1, 0, 0, ...), and solve.
        var_names = [f'Y{i}' for i in range(1, self._prec)]
        poly_ring = PolynomialRing(P.base(), var_names)
        inv_vec = list((self._vec[0]**-1,) + poly_ring.gens())
        # We'll fill this in one-by-one

        from sage.rings.padics.witt_vector_ring import WittVectorRing
        W = WittVectorRing(poly_ring, p=P._prime, prec=P._prec)
        prod_vec = (W(self._vec) * W(inv_vec))._vec
        for i in range(1, self._prec):
            poly = prod_vec[i](inv_vec[1:])
            Y_i = poly.parent().gens()[i - 1]
            try:
                inv_vec[i] = (-poly.constant_coefficient()
                              / poly.monomial_coefficient(Y_i))
            except ZeroDivisionError:
                raise ZeroDivisionError(f"Inverse of {self} does not exist.")
            try:
                inv_vec[i] = P.base()(inv_vec[i])
            except ValueError:
                raise ZeroDivisionError(f"Inverse of {self} does not exist.")

        return P(inv_vec)

    def _int_to_vector(self, k, parent):
        """
        Return the image of ``k`` in ``self`` with coefficients in ``parent``.

        EXAMPLES::

            sage: W = WittVectorRing(ZZ, p=23, prec=2)
            sage: W(-123)
            (-123, 50826444131062300759362981690761165250849615528)
        """
        p = parent._prime
        R = parent.base()

        if p == R.characteristic():
            self._int_to_vector_char_p(k, R)
            return

        should_negate = False
        if k < 0:
            k = -k
            should_negate = True

        vec_k = [k]
        for n in range(1, self._prec):
            total = (
                k - k**(p**n)
                - sum(p**(n-i) * vec_k[n-i]**(p**i) for i in range(1, n))
            )
            total //= p**n
            vec_k.append(total)

        if should_negate:
            if p == 2:
                vec_k = (
                    parent(vec_k)
                    * parent((tuple(-1 for _ in range(self._prec))))
                )._vec
            else:
                vec_k = (-x for x in vec_k)

        self._vec = tuple([R(x) for x in vec_k])

    def _int_to_vector_char_p(self, k, R):
        """
        Return the image of ``k`` in ``self`` with coefficients in ``parent``
        which has characteristic `p`.

        EXAMPLES::

            sage: W = WittVectorRing(GF(13), p=13, prec=3)
            sage: W(11)
            (11, 7, 4)
        """
        p = R.characteristic()
        Z = Zp(p, prec=self._prec+1, type='fixed-mod')
        F = GF(p)

        series = Z(k)
        vec_k = []
        for _ in range(self._prec):
            # Probably slightly faster to do "series % p,"
            # but this way, temp is in F_p
            temp = F(series)
            vec_k.append(R(temp))  # make sure elements of vector are in base
            series = (series - Z.teichmuller(temp)) // p

        self._vec = tuple(vec_k)
