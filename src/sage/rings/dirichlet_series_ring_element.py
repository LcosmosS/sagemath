"""
Dirichlet Series

Sage provides an implementation of dense and sparse fixed-precision Dirichlet series
over any Sage base ring.

AUTHORS:

- Kiran Kedlaya (2024-05): initial implementation

EXAMPLES::

    sage: R = DirichletSeriesRing(ZZ, 8)
    sage: f = R([1, 2, 3]); f
    1 + 2*2^-s + 3*3^-s + O(8^-s)
    sage: -2*f
    -2 - 4*2^-s - 6*3^-s + O(8^-s)
    sage: g = R([1, 2, 4]); f*g
    1 + 4*2^-s + 7*3^-s + 4*4^-s + 14*6^-s + O(8^-s)
    sage: f/g
    1 - 3^-s + 2*6^-s + O(8^-s)
"""
from sage.structure.element import parent, CommutativeAlgebraElement

class DirichletSeries_generic(CommutativeAlgebraElement):
    """
    Abstract base class for Dirichlet series.

    EXAMPLES::

        sage: R = DirichletSeriesRing(ZZ, 8)
        sage: f = R([1, 2, 3]); f
        1 + 2*2^-s + 3*3^-s + O(8^-s)
        sage: g = R({1: 1, 2: 2, 4: 4}); g
        1 + 2*2^-s + 4*4^-s + O(8^-s)
        sage: f*g
        1 + 4*2^-s + 3*3^-s + 8*4^-s + 6*6^-s + O(8^-s)
        sage: h = R(lambda x: x); h
        1 + 2*2^-s + 3*3^-s + 4*4^-s + 5*5^-s + 6*6^-s + 7*7^-s + O(8^-s)
     """
    def __init__(self, parent, data=None):
        """
        Construct a Dirichlet series.

        The coefficients can be specified as a list, a dict, or a callable.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 8)
            sage: f = R([1, 2, 3]); f
            1 + 2*2^-s + 3*3^-s + O(8^-s)
            sage: g = R({1: 1, 2: 2, 4: 4}); g
            1 + 2*2^-s + 4*4^-s + O(8^-s)
            sage: f*g
            1 + 4*2^-s + 3*3^-s + 8*4^-s + 6*6^-s + O(8^-s)
            sage: h = R(lambda x: x); h
            1 + 2*2^-s + 3*3^-s + 4*4^-s + 5*5^-s + 6*6^-s + 7*7^-s + O(8^-s)
        """
        CommutativeAlgebraElement.__init__(self, parent)
        base_ring = parent.base_ring()
        prec = parent.precision()
        if data in base_ring:
            self.data[1] = base_ring(data)
        elif isinstance(data, DirichletSeries_generic):
            for i, j in data.coefficients().items():
                if i > 0 and i < prec:
                    self.data[i] = base_ring(j)
        elif isinstance(data, list):
            for i in range(min(len(data), prec-1)):
                self.data[i+1] = base_ring(data[i])
        elif isinstance(data, dict):
            for i, j in data.items():
                if i > 0 and i < prec:
                    self.data[i] = base_ring(j)
        elif callable(data):
            z = parent.zero()
            for i in range(1, prec):
                j = data(i)
                if j != z:
                    self.data[i] = j

    def __eq__(self, other):
        """
        Test equality of Dirichlet series.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 8)
            sage: f = R([1, 2, 3])
            sage: g = R([1, 2, 4])
            sage: f == f
            True
            sage: f == g
            False
            sage: R(1) == 1
            True
            sage: 1 == R(1)
            True
        """
        other = other - self
        return all(not other[i] for i in range(1, other.parent().precision()))

    def __bool__(self):
        """
        Convert a Dirichlet series to a boolean.
        """
        return bool(self.coefficients())

    def __getitem__(self, n):
        """
        Retrieve a coefficient of a Dirichlet series.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 8)
            sage: f = R([1, 2, 3])
            sage: f[2]
            2
        """
        try:
            return self.data[n]
        except KeyError:
            return self.base_ring().zero()

    def __iter__(self):
        """
        Return an iterator over coefficients.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 10)
            sage: f = R([1, 2, 3])
            sage: list(f)
            [1, 2, 3, 0, 0, 0, 0, 0, 0]
        """
        return DirichletSeriesIterator(self)

    def _repr_(self):
        """
        Return a string representation.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 10)
            sage: f = R([1, 2, 3])
            sage: f
            1 + 2*2^-s + 3*3^-s + O(10^-s)
        """
        coeffs = self.coefficients()
        ans = ""
        prec = self.parent().precision()
        atomic_repr = self.parent().base_ring()._repr_option('element_is_atomic')
        for i in range(1, prec):
            if i in coeffs:
                x = repr(self[i])
                if x != "0":
                    if not atomic_repr and i > 1 and (x.find("+") != -1 or x.find("-") != -1):
                        x = "(%s)" % x
                    if i > 1:
                        var = "*%s^-s" % (i)
                    else:
                        var = ""
                    ans += "%s%s + " % (x,var)
        ans = ans.replace(" + -", " - ")
        ans = ans.replace(" 1*", " ")
        ans = ans.replace(" -1*", " -")
        ans += "O({}^-s)".format(prec)
        return ans

    def _add_(self, other):
        """
        Add two formal Dirichlet series.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 8)
            sage: f = R([1, 2, 3])
            sage: g = R({1: 1, 2: 2, 4: 4})
            sage: f+g
            2 + 4*2^-s + 3*3^-s + 4*4^-s + O(8^-s)
        """
        raise NotImplementedError

    def _sub_(self, other):
        """
        Subtract two formal Dirichlet series.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 8)
            sage: f = R([1, 2, 3])
            sage: g = R({1: 1, 2: 2, 4: 4})
            sage: f-g
            3*3^-s - 4*4^-s + O(8^-s)
        """
        raise NotImplementedError

    def _mul_(self, other):
        """
        Multiply two formal Dirichlet series.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 8, sparse=True)
            sage: f = R([1, 2, 3]); f
            1 + 2*2^-s + 3*3^-s + O(8^-s)
            sage: g = R({1: 1, 2: 2, 4: 4}); g
            1 + 2*2^-s + 4*4^-s + O(8^-s)
            sage: f*g
            1 + 4*2^-s + 3*3^-s + 8*4^-s + 6*6^-s + O(8^-s)
            sage: R = DirichletSeriesRing(ZZ, 8, sparse=False)
            sage: f = R([1, 2, 3]); f
            1 + 2*2^-s + 3*3^-s + O(8^-s)
            sage: g = R({1: 1, 2: 2, 4: 4}); g
            1 + 2*2^-s + 4*4^-s + O(8^-s)
            sage: f*g
            1 + 4*2^-s + 3*3^-s + 8*4^-s + 6*6^-s + O(8^-s)
        """
        raise NotImplementedError

    def _div_(self, other):
        """
        Implement division of Dirichlet series.

        The constant coefficient of ``other`` is required to be a unit.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 10)
            sage: f = R([1, 2, 3])
            sage: 1/f
            1 - 2*2^-s - 3*3^-s + 4*4^-s + 12*6^-s - 8*8^-s + 9*9^-s + O(10^-s)
        """
        c = other[1]
        if not c.is_unit():
            return ValueError("Leading coefficient must be a unit")
        inv = self.base_ring()(~c)
        other1 = 1 - inv*other
        assert other1[1] == 0
        tmp = self.parent()(1)
        tmp2 = other1
        while tmp2:
            tmp += tmp2
            tmp2 *= other1
        return self*inv*tmp

    def coefficients(self):
        """
        Return a dictionary of coefficients.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 10)
            sage: f = R([1,2]) * R([1,3])
            sage: f.coefficients()
            {1: 1, 2: 5, 4: 6}
            sage: f = R([1,2]) * R([1,0,3])
            sage: f.coefficients()
            {1: 1, 2: 2, 3: 3, 6: 6}
        """
        raise NotImplementedError

class DirichletSeries_dense(DirichletSeries_generic):
    def __init__(self, parent, data=None):
        base_ring = parent.base_ring()
        zero = base_ring(0)
        self.data = [zero for _ in range(parent.precision())]
        DirichletSeries_generic.__init__(self, parent, data)

    def coefficients(self):
        return {i: j for i,j in enumerate(self.data) if j}

    def _add_(self, other):
        parent = self.parent()
        return parent([self[i] + other[i] for i in range(1, len(self.data))])

    def _sub_(self, other):
        parent = self.parent()
        return parent([self[i] - other[i] for i in range(1, len(self.data))])

    def _mul_(self, other):
        return self.dense_times_generic(other)

    def dense_times_generic(self, other):
        """
        Multiply a dense Dirichlet series by a generic Dirichlet series.
        """
        parent = self.parent()
        base_ring = self.base_ring()
        ans = [base_ring.zero() for i in range(1, parent.precision())]
        for i, x in other.coefficients().items():
            for j in range(1, (parent.precision()-1)//i + 1):
                y = self[j]
                if y:
                    ans[i*j-1] += x*y
        return parent(ans)

class DirichletSeries_sparse(DirichletSeries_generic):
    def __init__(self, parent, data=None):
        self.data = {}
        DirichletSeries_generic.__init__(self, parent, data)

    def coefficients(self):
        return {i: j for i,j in self.data.items() if j}

    def _add_(self, other):
        parent = self.parent()
        base_ring = self.base_ring()
        out = dict(self.data)
        for i,j in other.data.items():
            out[i] = out[i] + j if i in out else j
        return parent(out)

    def _sub_(self, other):
        parent = self.parent()
        base_ring = self.base_ring()
        out = {i: j for i,j in self.data.items()}
        for i,j in other.data.items():
            out[i] = out[i] - j if i in out else -j
        return parent(out)

    def _mul_(self, other):
        parent = self.parent()
        base_ring = self.base_ring()
        out = {}
        prec = parent.precision()
        for i, x in self.data.items():
            for j, y in other.data.items():
                k = i*j
                if k < prec:
                    out[k] = out[k] + x*y if k in out else x*y
        return parent(out)

class DirichletSeriesIterator:
    def __init__(self, x):
        """
        Initialize this iterator.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 10)
            sage: f = R([1, 2, 3])
            sage: list(f)
            [1, 2, 3, 0, 0, 0, 0, 0, 0]
        """
        self.base_ring = x.base_ring()
        self._coeffs = x.coefficients()
        self._precision = x.parent().precision()
        self._index = 1

    def __next__(self):
        """
        Step this iterator forward.

        EXAMPLES::

            sage: R = DirichletSeriesRing(ZZ, 10)
            sage: f = R([1, 2, 3])
            sage: list(f)
            [1, 2, 3, 0, 0, 0, 0, 0, 0]
        """
        if self._index < self._precision:
            item = self._coeffs[self._index] if self._index in self._coeffs else self.base_ring(0)
            self._index += 1
            return item
        else:
            raise StopIteration
