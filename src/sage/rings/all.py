"""
Rings
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

# Polynomial Rings and Polynomial Quotient Rings
from .polynomial.all import *

# c-finite sequences
from .cfinite_sequence import CFiniteSequence, CFiniteSequences

from .fast_arith import prime_range

# asymptotic ring
#from .asymptotic.all import *
lazy_import('sage.rings.asymptotic.asymptotic_ring', 'AsymptoticRing')
lazy_import('sage.rings.asymptotic.asymptotic_expansion_generators', 'asymptotic_expansions')

# Register classes in numbers abc
from . import numbers_abc
