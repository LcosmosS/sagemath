"""
Rings

Tests for deprecations of imports in global namespace from :trac:`33602`::

    sage: PowerSeries
    doctest:warning...:
    DeprecationWarning:
    Importing PowerSeries from here is deprecated;
    please use "from sage.rings.power_series_ring_element import PowerSeries" instead.
    See https://github.com/sagemath/sage/issues/33602 for details.
    ...
    sage: PuiseuxSeries
    doctest:warning...:
    DeprecationWarning:
    Importing PuiseuxSeries from here is deprecated;
    please use "from sage.rings.puiseux_series_ring_element import PuiseuxSeries" instead.
    See https://github.com/sagemath/sage/issues/33602 for details.
    ...
    sage: LaurentSeries
    doctest:warning...:
    DeprecationWarning:
    Importing LaurentSeries from here is deprecated;
    please use "from sage.rings.laurent_series_ring_element import LaurentSeries" instead.
    See https://github.com/sagemath/sage/issues/33602 for details.
    ...
"""
# ****************************************************************************
#       Copyright (C) 2005 William Stein <wstein@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#                  https://www.gnu.org/licenses/
# ****************************************************************************
from sage.misc.lazy_import import lazy_import

from .all__sagemath_combinat import *
from .all__sagemath_flint import *
from .all__sagemath_modules import *

try:
    from .all__sagemath_symbolics import *
except ImportError:
    pass

# Finite fields
from .finite_rings.all import *

# Function field
from .function_field.all import *

# p-adic field
from .padics.all import *
from .padics.padic_printing import _printer_defaults as padic_printing

# valuations
from .valuation.all import *

# Polynomial Rings and Polynomial Quotient Rings
from .polynomial.all import *

# Tate algebras
from .tate_algebra import TateAlgebra

# Pseudo-ring of PARI objects.
from .pari_ring import PariRing, Pari

# c-finite sequences
from .cfinite_sequence import CFiniteSequence, CFiniteSequences

from .bernoulli_mod_p import bernoulli_mod_p, bernoulli_mod_p_single

# invariant theory
from .invariants.all import *

from .fast_arith import prime_range

# asymptotic ring
#from .asymptotic.all import *
lazy_import('sage.rings.asymptotic.asymptotic_ring', 'AsymptoticRing')
lazy_import('sage.rings.asymptotic.asymptotic_expansion_generators', 'asymptotic_expansions')

# Register classes in numbers abc
from . import numbers_abc
